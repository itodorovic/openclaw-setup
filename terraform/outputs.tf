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

    2. Onboard (as openclaw user — use tmux!):
       ssh openclaw@${digitalocean_droplet.openclaw.ipv4_address}
       tmux
       openclaw onboard --install-daemon

    3. Run post-Ansible setup (as root):
       ssh root@${digitalocean_droplet.openclaw.ipv4_address}
       bash <(curl -fsSL https://raw.githubusercontent.com/itodorovic/openclaw-setup/main/scripts/post-ansible.sh) \
         <tailscale-authkey> <machine-name>.<tailnet>.ts.net

    4. Access the dashboard (from any Tailscale device):
       https://<machine-name>.<tailnet>.ts.net

  EOT
}
