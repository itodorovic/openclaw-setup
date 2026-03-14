# ── DigitalOcean Resources ──────────────────────────────────────────────────

resource "digitalocean_ssh_key" "default" {
  name       = "OpenClaw Deployment Key"
  public_key = file(var.ssh_key_path)
}

resource "digitalocean_droplet" "openclaw" {
  image    = "ubuntu-24-04-x64"
  name     = var.droplet_name
  region   = var.droplet_region
  size     = var.droplet_size
  ssh_keys = [digitalocean_ssh_key.default.fingerprint]

  user_data = templatefile("${path.module}/cloud-init.yaml", {
    repo_clone_url          = var.repo_clone_url
    domain_name             = var.domain_name
    admin_domain            = var.admin_domain
    status_domain           = var.status_domain
    cloudflare_tunnel_token = cloudflare_zero_trust_tunnel_cloudflared.openclaw.tunnel_token
    gateway_auth_mode       = "token"
    gateway_token           = random_password.gateway_token.result
    s3_bucket               = var.r2_backup_access_key_id != "" ? "openclaw-backups" : ""
    s3_access_key           = var.r2_backup_access_key_id
    s3_secret_key           = var.r2_backup_secret_access_key
    s3_region               = "auto"
    s3_endpoint             = var.r2_backup_access_key_id != "" ? "${var.cloudflare_account_id}.r2.cloudflarestorage.com" : ""
    backup_password         = var.r2_backup_access_key_id != "" ? random_password.backup_passphrase.result : ""
    openclaw_config_json    = indent(6, jsonencode(local.openclaw_seed_config))
    agent_team_json         = indent(6, jsonencode(local.agent_team_seed))
    browser_enabled         = var.browser_enabled ? "true" : "false"
    extra_apt_packages      = var.extra_apt_packages
  })
}

resource "digitalocean_firewall" "openclaw" {
  name        = "openclaw-strict-rules"
  droplet_ids = [digitalocean_droplet.openclaw.id]

  inbound_rule {
    protocol         = "tcp"
    port_range       = "22"
    source_addresses = local.ssh_cidrs
  }

  outbound_rule {
    protocol              = "tcp"
    port_range            = "1-65535"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }

  outbound_rule {
    protocol              = "udp"
    port_range            = "1-65535"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }
}

# ── Health gate: wait for cloud-init before creating DNS/tunnel config ──────
# Prevents Error 1033 (tunnel not connected) during initial deploy.

resource "terraform_data" "wait_for_cloudinit" {
  depends_on = [digitalocean_droplet.openclaw, digitalocean_firewall.openclaw]

  provisioner "file" {
    content     = <<-SCRIPT
      #!/bin/bash
      set -e
      echo "Waiting for cloud-init to finish..."
      LAST=""
      while true; do
        RAW=$(cloud-init status 2>&1) || true
        STATUS=$(echo "$RAW" | head -1 | sed 's/^status: //')
        PROGRESS=""
        [ -f /swapfile ]                                                                      && PROGRESS="$PROGRESS swap"
        command -v docker >/dev/null 2>&1                                                      && PROGRESS="$PROGRESS docker"
        [ -d /root/openclaw-setup/.git ]                                                       && PROGRESS="$PROGRESS repo"
        command -v ttyd >/dev/null 2>&1                                                        && PROGRESS="$PROGRESS ttyd"
        docker ps --format '{{.Names}}' 2>/dev/null | grep -q openclaw-gateway                 && PROGRESS="$PROGRESS gateway"
        docker ps --format '{{.Names}}' 2>/dev/null | grep -q cloudflared                      && PROGRESS="$PROGRESS tunnel"
        docker ps --format '{{.Names}}' 2>/dev/null | grep -q dozzle                           && PROGRESS="$PROGRESS dozzle"
        LINE="cloud-init: $STATUS |$PROGRESS"
        if [ "$LINE" != "$LAST" ]; then
          echo "$LINE"
          LAST="$LINE"
        fi
        case "$STATUS" in
          done)  echo "cloud-init: finished OK"; exit 0 ;;
          error) echo "cloud-init: finished with errors"; exit 1 ;;
        esac
        sleep 5
      done
    SCRIPT
    destination = "/tmp/wait-cloudinit.sh"
    connection {
      type        = "ssh"
      host        = digitalocean_droplet.openclaw.ipv4_address
      user        = "root"
      private_key = file(local.ssh_private_key_path)
    }
  }

  provisioner "remote-exec" {
    inline = ["chmod +x /tmp/wait-cloudinit.sh && /tmp/wait-cloudinit.sh"]
    connection {
      type        = "ssh"
      host        = digitalocean_droplet.openclaw.ipv4_address
      user        = "root"
      private_key = file(local.ssh_private_key_path)
    }
  }
}

# ── Restart cloudflared after Terraform pushes tunnel config + DNS ───────────
# Cloud-init starts cloudflared before Terraform creates ingress rules, so it
# serves 503. This provisioner fires AFTER both the config and DNS CNAMEs exist.

resource "terraform_data" "restart_cloudflared" {
  depends_on = [
    cloudflare_zero_trust_tunnel_cloudflared_config.openclaw,
    cloudflare_record.dashboard,
    cloudflare_record.status,
    cloudflare_record.admin,
  ]

  provisioner "remote-exec" {
    inline = [
      "docker restart cloudflared",
      "sleep 5",
      "docker logs cloudflared --tail 5 2>&1",
    ]
    connection {
      type        = "ssh"
      host        = digitalocean_droplet.openclaw.ipv4_address
      user        = "root"
      private_key = file(local.ssh_private_key_path)
    }
  }
}
