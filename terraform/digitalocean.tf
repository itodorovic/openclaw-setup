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
    s3_endpoint             = var.r2_backup_access_key_id != "" ? "https://${var.cloudflare_account_id}.r2.cloudflarestorage.com" : ""
    backup_password         = var.r2_backup_access_key_id != "" ? random_password.backup_passphrase.result : ""
    openclaw_model          = var.openclaw_model
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

  provisioner "remote-exec" {
    inline = ["cloud-init status --wait"]
    connection {
      type        = "ssh"
      host        = digitalocean_droplet.openclaw.ipv4_address
      user        = "root"
      private_key = file(local.ssh_private_key_path)
    }
  }
}
