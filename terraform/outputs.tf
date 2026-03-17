output "droplet_ip" {
  description = "Droplet public IPv4 address."
  value       = digitalocean_droplet.openclaw.ipv4_address
}

output "ssh_root" {
  description = "SSH as root (for system admin)."
  value       = "ssh root@${digitalocean_droplet.openclaw.ipv4_address}"
}

output "ssh_openclaw" {
  description = "SSH as openclaw user (for installation and onboarding)."
  value       = "ssh openclaw@${digitalocean_droplet.openclaw.ipv4_address}"
}

output "next_steps" {
  description = "What to do after terraform apply."
  value       = <<-EOT

    === NEXT STEPS ===

    1. Install OpenClaw (as root):
       ssh root@${digitalocean_droplet.openclaw.ipv4_address}
       curl -fsSL https://raw.githubusercontent.com/openclaw/openclaw-ansible/main/install.sh | bash

    2. Fix pnpm permissions (as root, after Ansible):
       chown -R openclaw:openclaw /home/openclaw/.local

    3. SSH as openclaw user and onboard (use tmux!):
       ssh openclaw@${digitalocean_droplet.openclaw.ipv4_address}
       tmux
       openclaw onboard --install-daemon

    4. Access the dashboard:
       ssh -L 18789:127.0.0.1:18789 openclaw@${digitalocean_droplet.openclaw.ipv4_address}
       Then open: http://localhost:18789

  EOT
}
