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
  description = "Dozzle container log viewer URL."
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
    All 3 domains should be live within ~1 minute of apply completing.

    1. Open https://${var.admin_domain} to access the admin console.

    2. Use option 5 (OpenAI Codex OAuth login) and follow the URL.

    3. Use option 4 to restart the gateway.

    4. Use option 1 to generate a dashboard URL, then open it in your browser.
       The tokenized URL auto-pairs your browser, so no manual device approval is needed.

    Gateway token (for reference): terraform output gateway_token
  EOT
}
