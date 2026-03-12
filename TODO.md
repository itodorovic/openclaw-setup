# Deployment TODO

Delete this file once everything is running.

## Goals

- Fully automated OpenClaw on DigitalOcean + Cloudflare Zero Trust
- OpenAI Codex (ChatGPT Plus) via OAuth — not API key
- Domain: your domain subdomains for dashboard and status page
- Zero manual intervention on the Droplet (SSH to troubleshoot OK, manual fixes NOT OK)
- Optional encrypted R2 backups (free tier)

## Pre-deploy checklist

1. **Push repo to GitHub** so the Droplet can clone it via `repo_clone_url`
2. **Switch to WSL Ubuntu** — Terraform is installed there, not on Windows
3. **Create terraform.tfvars**:
   ```bash
   cd /mnt/c/Users/itod/repos/openclaw-setup/terraform
   cp terraform.tfvars.example terraform.tfvars
   ```
4. **Fill in terraform.tfvars** — 8 required values:
   - `do_token` — DigitalOcean API token
   - `cloudflare_api_token` — scoped token (Tunnel Edit, Access Edit, DNS Edit, Zone Read)
   - `cloudflare_account_id` — from dashboard URL
   - `cloudflare_zone_id` — from zone Overview page
   - `domain_name` — your dashboard subdomain (e.g. `ai.example.com`)
   - `status_domain` — your status subdomain (e.g. `status.example.com`)
   - `allowed_emails` — your email(s) for Zero Trust access
   - `repo_clone_url` — GitHub HTTPS URL for this repo
5. **Optional**: uncomment `r2_backup_access_key_id` / `r2_backup_secret_access_key` for encrypted backups

## Deploy

```bash
cd /mnt/c/Users/itod/repos/openclaw-setup/terraform
terraform init
terraform apply
```

## Post-deploy (two manual steps)

### 1. OpenAI Codex OAuth (one-time)
Wait ~3 min for cloud-init, then:
```bash
ssh root@$(terraform output -raw server_ip) \
  "cd /root/openclaw-setup && docker compose run --rm openclaw-cli models auth login --provider openai-codex"
```
- Opens a URL — open it in your browser, sign in with ChatGPT Plus
- Browser redirects to `localhost:1455/...` which fails — **that's expected**
- Copy the full redirect URL from the browser address bar, paste into terminal
- Tokens auto-refresh after this — never need to redo it

### 2. Device pairing
- Open `https://<your-domain>` — Cloudflare Access prompts email verification
- Dashboard asks for gateway token — get it with `terraform output gateway_token`
- Paste token, browser is paired

## Verify

```bash
# Check model auth status
ssh root@<ip> "cd /root/openclaw-setup && docker compose run --rm -T openclaw-cli models status"

# List paired devices
ssh root@<ip> "cd /root/openclaw-setup && docker compose run --rm -T openclaw-cli devices list"

# Smoke test
./scripts/verify-remote-deployment.sh <server_ip> <dashboard_domain> <status_domain>
```
