# ── DigitalOcean Resources ──────────────────────────────────────────────────

resource "digitalocean_ssh_key" "default" {
  name       = "${var.droplet_name}-key"
  public_key = file(var.ssh_key_path)
}

resource "digitalocean_droplet" "openclaw" {
  image    = "ubuntu-24-04-x64"
  name     = var.droplet_name
  region   = var.droplet_region
  size     = var.droplet_size
  ssh_keys = [digitalocean_ssh_key.default.fingerprint]

  # Minimal cloud-init: swap only (Ansible handles everything else)
  user_data = <<-CLOUD_INIT
    #cloud-config
    package_update: true
    package_upgrade: true

    runcmd:
      - fallocate -l 4G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
      - echo '/swapfile none swap sw 0 0' >> /etc/fstab
  CLOUD_INIT

  connection {
    type        = "ssh"
    user        = "root"
    private_key = file(local.ssh_private_key_path)
    host        = self.ipv4_address
  }

  # Wait for cloud-init to finish before handing off to Ansible
  provisioner "remote-exec" {
    inline = [
      "cloud-init status --wait > /dev/null 2>&1 || true",
      "echo 'Cloud-init complete.'"
    ]
  }
}

resource "digitalocean_firewall" "openclaw" {
  name        = "${var.droplet_name}-fw"
  droplet_ids = [digitalocean_droplet.openclaw.id]

  # SSH (restricted to deployer IP by default)
  inbound_rule {
    protocol         = "tcp"
    port_range       = "22"
    source_addresses = local.ssh_cidrs
  }

  # Tailscale WireGuard (direct connections)
  inbound_rule {
    protocol         = "udp"
    port_range       = "41641"
    source_addresses = ["0.0.0.0/0", "::/0"]
  }

  # All outbound (Tailscale DERP, apt, npm, AI APIs)
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

  outbound_rule {
    protocol              = "icmp"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }
}
