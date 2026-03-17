# ── DigitalOcean Resources ──────────────────────────────────────────────────

resource "digitalocean_ssh_key" "default" {
  name       = "${var.droplet_name}-key"
  public_key = file(var.ssh_key_path)
}

locals {
  ssh_pubkey = trimspace(file(var.ssh_key_path))
}

resource "digitalocean_droplet" "openclaw" {
  image    = "ubuntu-24-04-x64"
  name     = var.droplet_name
  region   = var.droplet_region
  size     = var.droplet_size
  ssh_keys = [digitalocean_ssh_key.default.fingerprint]

  user_data = templatefile("${path.module}/cloud-init.yaml", {
    ssh_pubkey = local.ssh_pubkey
  })

  connection {
    type        = "ssh"
    user        = "root"
    private_key = file(local.ssh_private_key_path)
    host        = self.ipv4_address
  }

  # Wait for cloud-init to finish
  provisioner "remote-exec" {
    inline = [
      "echo 'Waiting for cloud-init...'",
      "cloud-init status --wait > /dev/null 2>&1 || true",
      "echo 'Cloud-init complete.'",
      "echo '--- Verification ---'",
      "swapon --show",
      "id openclaw 2>/dev/null && echo 'openclaw user: OK' || echo 'openclaw user: MISSING'",
      "cat /home/openclaw/.ssh/authorized_keys | head -1 | cut -c1-40",
      "loginctl show-user openclaw 2>/dev/null | grep Linger || echo 'linger: not set'",
      "cat /etc/sudoers.d/openclaw 2>/dev/null || echo 'sudoers: MISSING'",
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
