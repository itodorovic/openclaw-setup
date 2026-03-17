output "droplet_ip" {
  description = "Droplet public IPv4 address."
  value       = digitalocean_droplet.openclaw.ipv4_address
}

output "ssh_command" {
  description = "SSH into the droplet as root."
  value       = "ssh root@${digitalocean_droplet.openclaw.ipv4_address}"
}

output "next_steps" {
  description = "What to do after terraform apply."
  value       = <<-EOT

    === NEXT STEPS ===

    1. Run the Ansible playbook:
       cd ../ansible
       ansible-playbook -i '${digitalocean_droplet.openclaw.ipv4_address},' playbook.yml

    2. SSH in as openclaw and run onboarding:
       ssh openclaw@${digitalocean_droplet.openclaw.ipv4_address}
       openclaw onboard --install-daemon

    3. Access the dashboard via Tailscale:
       ssh -L 18789:127.0.0.1:18789 openclaw@<tailscale-ip>
       Then open: http://localhost:18789

  EOT
}
