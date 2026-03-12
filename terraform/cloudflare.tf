# ── Cloudflare Resources ────────────────────────────────────────────────────

# --- Tunnel (connects Droplet to Cloudflare edge — no public ports needed) ---

resource "cloudflare_zero_trust_tunnel_cloudflared" "openclaw" {
  account_id = var.cloudflare_account_id
  name       = "openclaw-tunnel"
  secret     = random_id.tunnel_secret.b64_std
}

resource "cloudflare_zero_trust_tunnel_cloudflared_config" "openclaw" {
  account_id = var.cloudflare_account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.openclaw.id

  config {
    ingress_rule {
      hostname = var.domain_name
      service  = "http://caddy-proxy:80"
    }
    ingress_rule {
      hostname = var.status_domain
      service  = "http://caddy-proxy:80"
    }
    # Catch-all (required by Cloudflare)
    ingress_rule {
      service = "http_status:404"
    }
  }
}

# --- DNS (CNAME to tunnel — Droplet IP never exposed) ---

resource "cloudflare_record" "dashboard" {
  zone_id = var.cloudflare_zone_id
  name    = var.domain_name
  type    = "CNAME"
  content = "${cloudflare_zero_trust_tunnel_cloudflared.openclaw.id}.cfargotunnel.com"
  proxied = true
}

resource "cloudflare_record" "status" {
  zone_id = var.cloudflare_zone_id
  name    = var.status_domain
  type    = "CNAME"
  content = "${cloudflare_zero_trust_tunnel_cloudflared.openclaw.id}.cfargotunnel.com"
  proxied = true
}

# --- Zero Trust Access (email-gated SSO before any request reaches server) ---

resource "cloudflare_zero_trust_access_application" "dashboard" {
  zone_id          = var.cloudflare_zone_id
  name             = "OpenClaw Dashboard"
  domain           = var.domain_name
  session_duration = var.access_session_duration
  type             = "self_hosted"
}

resource "cloudflare_zero_trust_access_application" "status" {
  zone_id          = var.cloudflare_zone_id
  name             = "OpenClaw Status"
  domain           = var.status_domain
  session_duration = var.access_session_duration
  type             = "self_hosted"
}

resource "cloudflare_zero_trust_access_policy" "dashboard_allow" {
  application_id = cloudflare_zero_trust_access_application.dashboard.id
  zone_id        = var.cloudflare_zone_id
  name           = "Allow Admin"
  precedence     = 1
  decision       = "allow"

  include {
    email = var.allowed_emails
  }
}

resource "cloudflare_zero_trust_access_policy" "status_allow" {
  application_id = cloudflare_zero_trust_access_application.status.id
  zone_id        = var.cloudflare_zone_id
  name           = "Allow Admin"
  precedence     = 1
  decision       = "allow"

  include {
    email = var.allowed_emails
  }
}

# --- Email Routing (free — forwards admin@domain → personal email) ---

resource "cloudflare_email_routing_settings" "zone" {
  count   = var.email_forward_to != "" ? 1 : 0
  zone_id = var.cloudflare_zone_id
}

resource "cloudflare_email_routing_dns" "zone" {
  count   = var.email_forward_to != "" ? 1 : 0
  zone_id = var.cloudflare_zone_id
}

resource "cloudflare_email_routing_address" "personal" {
  count      = var.email_forward_to != "" ? 1 : 0
  account_id = var.cloudflare_account_id
  email      = var.email_forward_to
}

resource "cloudflare_email_routing_rule" "admin_forward" {
  count   = var.email_forward_to != "" ? 1 : 0
  zone_id = var.cloudflare_zone_id
  name    = "Forward to personal email"
  enabled = true

  matchers {
    type  = "literal"
    field = "to"
    value = var.allowed_emails[0]
  }

  actions {
    type  = "forward"
    value = [var.email_forward_to]
  }
}

# --- R2 Backup Bucket (free tier: 10 GB) ---

resource "cloudflare_r2_bucket" "backups" {
  count      = var.r2_backup_access_key != "" ? 1 : 0
  account_id = var.cloudflare_account_id
  name       = "openclaw-backups"
  location   = "EEUR"
}
