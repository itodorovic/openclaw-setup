# ── Outputs ─────────────────────────────────────────────────────────────────

output "server_ip" {
  description = "Droplet public IP (SSH only — not exposed via DNS)."
  value       = digitalocean_droplet.openclaw.ipv4_address
}

output "dashboard_url" {
  description = "OpenClaw dashboard URL."
  value       = "https://${var.domain_name}"
}

output "status_url" {
  description = "Uptime Kuma status page URL."
  value       = "https://${var.status_domain}"
}

output "tunnel_id" {
  description = "Cloudflare Tunnel ID."
  value       = cloudflare_zero_trust_tunnel_cloudflared.openclaw.id
}

output "gateway_token" {
  description = "Generated gateway authentication token (defense in depth)."
  value       = random_password.gateway_token.result
  sensitive   = true
}

output "next_step" {
  description = "Post-deploy steps — OAuth login and device pairing."
  value       = <<-EOT
    Wait ~3 minutes for cloud-init, then:

    1. Link your OpenAI Codex subscription (one-time):
       ssh root@${digitalocean_droplet.openclaw.ipv4_address} "cd /root/openclaw-setup && docker compose run --rm openclaw-cli models auth login --provider openai-codex"
       (Copy the redirect URL from your browser and paste it back into the terminal.)

    2. Open https://${var.domain_name} and enter the gateway token to pair your browser:
       terraform output gateway_token
  EOT
}
