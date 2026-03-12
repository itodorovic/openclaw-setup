# ── DigitalOcean ────────────────────────────────────────────────────────────

variable "do_token" {
  description = "DigitalOcean API token."
  type        = string
  sensitive   = true
}

variable "ssh_key_path" {
  description = "Path to local SSH public key."
  type        = string
  default     = "~/.ssh/id_ed25519.pub"
}

variable "droplet_name" {
  description = "Name for the DigitalOcean Droplet."
  type        = string
  default     = "openclaw-agent"
}

variable "droplet_region" {
  description = "DigitalOcean region slug."
  type        = string
  default     = "fra1"
}

variable "droplet_size" {
  description = "Droplet size slug."
  type        = string
  default     = "s-1vcpu-2gb"
}

variable "allowed_ssh_cidrs" {
  description = "CIDR blocks allowed to SSH into the Droplet. Auto-detected from your current IP if left empty."
  type        = list(string)
  default     = []
}

# ── Cloudflare ──────────────────────────────────────────────────────────────

variable "cloudflare_api_token" {
  description = "Cloudflare API token. Required permissions: Account > Cloudflare Tunnel > Edit, Account > Access: Apps and Policies > Edit, Zone > DNS > Edit, Zone > Zone > Read."
  type        = string
  sensitive   = true
}

variable "cloudflare_account_id" {
  description = "Cloudflare account ID (visible in the dashboard URL)."
  type        = string
}

variable "cloudflare_zone_id" {
  description = "Cloudflare Zone ID for your domain (shown on the zone Overview page)."
  type        = string
}

# ── Domains ─────────────────────────────────────────────────────────────────

variable "domain_name" {
  description = "FQDN for the OpenClaw dashboard (e.g., ai.example.com)."
  type        = string
}

variable "status_domain" {
  description = "FQDN for the Uptime Kuma status page (e.g., status.example.com)."
  type        = string
}

# ── Access Control ──────────────────────────────────────────────────────────

variable "allowed_emails" {
  description = "Email addresses allowed through Cloudflare Zero Trust Access."
  type        = list(string)
}

variable "access_session_duration" {
  description = "How long a Zero Trust session lasts before re-authentication."
  type        = string
  default     = "24h"
}

variable "email_forward_to" {
  description = "Personal email to forward domain mail to (e.g., your Gmail). When set, Terraform creates Cloudflare Email Routing: allowed_emails[0] → this address. Your API token needs Zone > Email Routing Rules > Edit."
  type        = string
  default     = ""
}

# ── Repository ──────────────────────────────────────────────────────────────

variable "repo_clone_url" {
  description = "Git HTTPS URL to clone on first boot."
  type        = string
}

# ── Backups (optional — requires R2 API token from Cloudflare dashboard) ───

variable "r2_backup_access_key_id" {
  description = "Cloudflare R2 Access Key ID. Create once at: Cloudflare Dashboard → R2 → Manage R2 API Tokens."
  type        = string
  sensitive   = true
  default     = ""
}

variable "r2_backup_secret_access_key" {
  description = "Cloudflare R2 Secret Access Key."
  type        = string
  sensitive   = true
  default     = ""
}

# ── OpenClaw ────────────────────────────────────────────────────────────────

variable "openclaw_model" {
  description = "Default AI model for the agent (e.g., openai-codex/gpt-5.4, openai/gpt-5.4, anthropic/claude-opus-4-6)."
  type        = string
  default     = "openai-codex/gpt-5.4"
}

variable "browser_enabled" {
  description = "Enable the browser control tool in OpenClaw."
  type        = bool
  default     = true
}

variable "extra_apt_packages" {
  description = "Space-separated list of extra apt packages to install in the gateway container (e.g., ffmpeg build-essential jq)."
  type        = string
  default     = "git curl jq"
}
