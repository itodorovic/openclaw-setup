# OpenClaw Setup

Fully automated [OpenClaw](https://github.com/openclaw/openclaw) deployment on DigitalOcean with Cloudflare Zero Trust. Three API tokens in, production out.

## Architecture

| Layer | Component | Managed By |
|-------|-----------|------------|
| Compute | DigitalOcean Droplet (2 GB + 4 GB swap) | `digitalocean` provider |
| DNS + Security | Cloudflare Tunnel, CNAME records, Zero Trust Access | `cloudflare` provider |
| AI Agent | OpenClaw Gateway (Docker, runs as `node` uid 1000) | Docker Compose |
| Proxy | Caddy (internal HTTP routing) | Docker Compose |
| Updates | Watchtower (nightly pulls) | Docker Compose |
| Backups | Encrypted nightly S3 upload | Docker Compose |
| Monitoring | Uptime Kuma | Docker Compose |

No public ports. The Droplet IP is never exposed in DNS — all traffic flows through Cloudflare Tunnel.

## Prerequisites

1. [Terraform](https://developer.hashicorp.com/terraform/install) ≥ 1.5
2. A domain with DNS on Cloudflare
3. API tokens:

   | Token | Source |
   |-------|--------|
   | DigitalOcean | [API tokens](https://docs.digitalocean.com/reference/api/create-personal-access-token/) |
   | Cloudflare API Token | [Custom token](https://dash.cloudflare.com/profile/api-tokens) with: Account → Cloudflare Tunnel → Edit, Account → Access: Apps and Policies → Edit, Zone → DNS → Edit, Zone → Zone → Read. Add Zone → Email Routing Rules → Edit if using `email_forward_to`. |
   | Cloudflare Account ID | Dashboard URL: `https://dash.cloudflare.com/<account_id>` |
   | Cloudflare Zone ID | Domain Overview page |

## Deploy

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars   # fill in your values
terraform init
terraform apply
```

Wait ~3 min for cloud-init, then link your OpenAI Codex subscription (only manual step):

```bash
ssh root@$(terraform output -raw server_ip) \
  "cd /root/openclaw-setup && docker compose run --rm openclaw-cli models auth login --provider openai-codex"
```

This starts an OAuth flow. It will print a URL — open it in your local browser, sign in with your ChatGPT Plus account, then **copy the full redirect URL** from the browser address bar and paste it back into the SSH terminal (the localhost callback won't work on the remote server). Tokens auto-refresh after initial login.

Done. Open `terraform output dashboard_url` in your browser.

## Variables

| Variable | Required | Default | Description |
|----------|:--------:|---------|-------------|
| `do_token` | yes | | DigitalOcean API token |
| `cloudflare_api_token` | yes | | Cloudflare scoped API token |
| `cloudflare_account_id` | yes | | Cloudflare account ID |
| `cloudflare_zone_id` | yes | | Cloudflare Zone ID |
| `domain_name` | yes | | Dashboard FQDN (e.g. `ai.example.com`) |
| `status_domain` | yes | | Status page FQDN (e.g. `status.example.com`) |
| `allowed_emails` | yes | | Emails for Zero Trust access |
| `email_forward_to` | | | Personal email — enables Cloudflare Email Routing: `allowed_emails[0]` → here |
| `allowed_ssh_cidrs` | | auto-detected | CIDRs for SSH (auto-detects your IP if omitted) |
| `repo_clone_url` | yes | | Git HTTPS URL to clone on boot |
| `ssh_key_path` | | `~/.ssh/id_ed25519.pub` | SSH public key path |
| `droplet_region` | | `fra1` | DigitalOcean region |
| `droplet_size` | | `s-1vcpu-2gb` | Droplet size |
| `access_session_duration` | | `24h` | Zero Trust session lifetime |
| `openclaw_model` | | `openai-codex/gpt-5.4` | Default AI model |
| `browser_enabled` | | `true` | Enable browser tool + Chromium |
| `extra_apt_packages` | | `git curl jq` | System packages for gateway |
| `r2_backup_access_key_id` | | | R2 Access Key ID (enables backups) |
| `r2_backup_secret_access_key` | | | R2 Secret Access Key |

## Credential Rotation

All secrets are in Terraform state — rotate by tainting and reapplying:

```bash
# Tunnel token
terraform taint random_id.tunnel_secret && terraform apply

# Gateway token
terraform taint random_password.gateway_token && terraform apply

# Cloudflare or DO API token — update in terraform.tfvars, then:
terraform plan   # verify connectivity
```

## Remote State (Recommended)

```bash
cp terraform/backend.tf.example terraform/backend.tf
# Edit with your S3/Spaces bucket
terraform init -migrate-state
```

State contains tunnel + gateway tokens — treat it as secret.

## Operations

```bash
# Smoke test
./scripts/verify-remote-deployment.sh <server_ip> <dashboard_domain> <status_domain>

# SSH access (from allowed CIDRs only)
ssh root@$(terraform output -raw server_ip)

# Run CLI commands against the gateway
ssh root@<ip> "cd /root/openclaw-setup && docker compose run --rm openclaw-cli <command>"

# Update the stack after changing compose/Caddyfile
ssh root@<ip> "cd /root/openclaw-setup && git pull && docker compose up -d"
```

## Security

- Droplet reachable only via SSH (restricted CIDRs) and Cloudflare Tunnel
- Gateway runs token auth by default (defense in depth behind Zero Trust)
- Container runs as non-root `node` user (uid 1000)
- Cloud-init logs scrubbed of all secrets after startup
- Never commit `terraform.tfstate` or `terraform.tfvars` (gitignored)
- Container images pinned by digest — override in `.env` for planned upgrades
