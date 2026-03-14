# OpenClaw Setup

Fully automated [OpenClaw](https://github.com/openclaw/openclaw) deployment on DigitalOcean with Cloudflare Zero Trust. Three API tokens in, production out.

## What You Get

| Domain | Service | Purpose |
|--------|---------|---------|
| `ai.example.com` | OpenClaw Dashboard | AI agent chat interface |
| `admin.example.com` | Admin Console | Device pairing, OAuth login, monitoring (ttyd web terminal) |
| `status.example.com` | Dozzle | Docker container logs & health viewer |

All domains are protected by Cloudflare Zero Trust (email-gated SSO). No public ports — traffic flows exclusively through a Cloudflare Tunnel.

## Architecture

| Layer | Component |
|-------|-----------|
| Compute | DigitalOcean Droplet (2 GB RAM + 4 GB swap) |
| Network | Cloudflare Tunnel + Zero Trust Access (3 domains) |
| AI Agent | OpenClaw Gateway (Docker, non-root) |
| Admin | Web terminal with device management, OAuth, lazydocker |
| Proxy | Caddy (internal HTTP routing) |
| Updates | Watchtower (nightly auto-pull) |
| Backups | Encrypted nightly to Cloudflare R2 (optional) |
| Monitoring | Dozzle (container logs) + lazydocker (TUI in admin) |

## Containers

| Container | Memory | Role |
|-----------|-------:|------|
| `openclaw-gateway` | 2048 MB | AI agent runtime — runs models, WebSocket API, dashboard backend, health endpoint |
| `openclaw-admin` | 256 MB | Web terminal (ttyd) serving the admin console menu — device pairing, OAuth, updates |
| `caddy-proxy` | 128 MB | Internal reverse proxy — routes `ai.*` → gateway, `admin.*` → ttyd, `status.*` → Dozzle |
| `cloudflared` | 128 MB | Cloudflare Tunnel client — connects all three domains to the droplet with no public ports |
| `dozzle` | 64 MB | Live container log viewer available at `status.*` — read-only Docker socket access |
| `watchtower` | 128 MB | Nightly auto-update for infrastructure containers (Caddy, cloudflared, Dozzle). OpenClaw excluded |
| `volume-backup` | 256 MB | Encrypted nightly backup of OpenClaw data volume to Cloudflare R2 (when configured) |

## Prerequisites

1. [Terraform](https://developer.hashicorp.com/terraform/install) ≥ 1.5
2. A domain with DNS on Cloudflare
3. An SSH key pair (`~/.ssh/id_ed25519` by default)
4. API tokens:

   | Token | Source |
   |-------|--------|
   | DigitalOcean | [API tokens](https://docs.digitalocean.com/reference/api/create-personal-access-token/) |
   | Cloudflare | [Custom token](https://dash.cloudflare.com/profile/api-tokens) with permissions below |

   **Cloudflare token permissions:**

   | Scope | Permission | When |
   |-------|-----------|------|
   | Zone > DNS | Edit | Always |
   | Zone > Zone | Read | Always |
   | Account > Cloudflare Tunnel | Edit | Always |
   | Account > Access: Apps and Policies | Edit | Always |
   | Account > Workers R2 Storage | Edit | If using R2 backups |
   | Zone > Email Routing Rules | Edit | If using `email_forward_to` |
   | Account > Email Routing Addresses | Edit | If using `email_forward_to` |

## Deploy

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars   # fill in your values
terraform init
terraform apply
```

Terraform creates the droplet, waits for cloud-init to finish, pushes the tunnel config, then restarts cloudflared — all three domains are live when `apply` completes.

## Post-Deploy (via Admin Console)

Open `https://admin.example.com` — the admin console handles all post-deploy actions:

1. **OpenAI Codex OAuth** — Option 5. Follow the URL, sign in, paste the redirect URL back.
2. **Restart gateway** — Option 4. Picks up the new OAuth credentials.
3. **Dashboard URL** — Option 1. Generates a tokenized URL to open in your browser (auto-pairs, no approval needed).
4. Open the dashboard URL from step 3. You're in.

## Admin Console

The admin console at `admin.example.com` provides:

```
1) Dashboard URL  — tokenized link to connect your browser
2) Devices        — list paired, approve pending, remove
3) Backups        — list remote backups, status, backup now, restore
4) Restart gateway
5) OpenAI Codex OAuth login
6) Update OpenClaw — pull latest image, restart, reinstall packages
7) Lazydocker     — live container CPU/memory/logs TUI
8) OpenClaw CLI shell
s) System shell
```

> **Updates:** Watchtower auto-updates infrastructure containers (Caddy, cloudflared, Dozzle) but **not** OpenClaw itself. Use option 6 to update OpenClaw on your own schedule. Ignore the "Update" button in the dashboard — it doesn't work in a containerized deployment.

## Multi-Agent Teams

This repo now supports **single-agent** and **multi-agent** OpenClaw deployments from the same Terraform code.

### What gets configured per agent

Each agent can have its own:

- workspace (`~/.openclaw/workspace-<agentId>` by default)
- `agentDir` (`~/.openclaw/agents/<agentId>/agent` by default)
- model and fallback models
- tool profile / tool allow / deny policy
- sandbox mode, scope, and workspace access
- identity metadata (name, theme, emoji)
- channel/account/peer routing bindings

Cloud-init seeds missing workspace files (`SOUL.md`, `AGENTS.md`, `USER.md`, `TOOLS.md`, `IDENTITY.md`) for every configured agent and creates the matching `agents/<id>/agent` and `sessions/` directories in `./data/`.

### Example team

```hcl
agent_team = [
  {
    id            = "main"
    default       = true
    name          = "Main"
    model         = "openai-codex/gpt-5.4"
    identity_name = "Djordje"
    identity_theme = "calm and reliable manager for coding agents"
    identity_emoji = "🛠️"
    bindings = [
      { channel = "webchat" },
    ]
  },
  {
    id                       = "reviewer"
    name                     = "Reviewer"
    model                    = "anthropic/claude-opus-4-6"
    tool_profile             = "coding"
    tools_deny               = ["exec"]
    sandbox_mode             = "all"
    sandbox_scope            = "agent"
    sandbox_workspace_access = "ro"
    persona                  = "You are a careful reviewer agent focused on critique, safety, and architecture."
    bindings = [
      { channel = "telegram", account_id = "reviewer" },
    ]
  },
]

enable_agent_to_agent = true
```

### Notes

- If `agent_team` is empty, deployment falls back to a normal single-agent `main` setup.
- `bindings` are written into `openclaw.json`, so routing hot-reloads inside OpenClaw without a full reprovision.
- Existing `./data/openclaw.json` is **not overwritten** on subsequent cloud-init replays; the seed file is only copied on first boot.
- If you later hand-edit `./data/openclaw.json`, that becomes the live source of truth until you intentionally replace it.

## Backups

When R2 credentials are configured, the `volume-backup` container creates a **GPG-encrypted** backup of the `data/` directory every night at 3 AM and uploads it to Cloudflare R2.

### Data directory

Agent state lives in `./data/` (bind-mounted into containers as `/home/node/.openclaw`). This is a host directory, not a Docker named volume — you can browse, edit, and git-track files directly:

```bash
ssh root@<droplet-ip>
ls /root/openclaw-setup/data/                           # browse agent state
cat /root/openclaw-setup/data/openclaw.json            # view config
vim /root/openclaw-setup/data/workspace/SOUL.md        # edit main-agent personality
vim /root/openclaw-setup/data/workspace-reviewer/SOUL.md # edit a secondary agent personality
```

### What's backed up

The backup contains the complete agent state:

| Path | What it is |
|------|------------|
| `openclaw.json` | Main configuration (agents, bindings, model, gateway settings, tools, sessions) |
| `agents/*/agent/auth-profiles.json` | OAuth credentials (e.g. OpenAI Codex tokens) |
| `agents/*/agent/models.json` | Provider and model configuration |
| `agents/*/sessions/` | Full chat session history |
| `devices/paired.json` | Paired browser/device tokens |
| `identity/device.json` | Gateway device identity key |
| `workspace*.md` / `workspace-*/` | Agent personality files and per-agent workspaces |
| `cron/jobs.json` | Scheduled jobs |
| `logs/config-audit.jsonl` | Configuration change audit log |

Restoring this backup to any OpenClaw instance gives you an **identical agent system** — same personalities, same OAuth tokens, same session history, same device pairings, same multi-agent layout. The only volume *not* backed up is `openclaw_home`, which contains only regenerable caches (Playwright browser, Node compile cache) and carries no durable state.

Use the **Backups** submenu (option 3) in the admin console to list remote backups, check the last backup status, trigger a manual backup, or restore from any previous backup.

## Variables

| Variable | Required | Default | Description |
|----------|:--------:|---------|-------------|
| `do_token` | ✓ | | DigitalOcean API token |
| `cloudflare_api_token` | ✓ | | Cloudflare scoped API token |
| `cloudflare_account_id` | ✓ | | Cloudflare account ID |
| `cloudflare_zone_id` | ✓ | | Cloudflare zone ID |
| `domain_name` | ✓ | | Dashboard FQDN |
| `admin_domain` | ✓ | | Admin console FQDN |
| `status_domain` | ✓ | | Log viewer FQDN |
| `allowed_emails` | ✓ | | Emails for Zero Trust access |
| `repo_clone_url` | ✓ | | Git HTTPS URL for this repo |
| `email_forward_to` | | `""` | Forward domain mail to personal email |
| `ssh_key_path` | | `~/.ssh/id_ed25519.pub` | SSH public key path |
| `droplet_region` | | `fra1` | DigitalOcean region |
| `droplet_size` | | `s-1vcpu-2gb` | Droplet size |
| `access_session_duration` | | `24h` | Zero Trust session lifetime |
| `openclaw_model` | | `openai-codex/gpt-5.4` | Default AI model |
| `browser_enabled` | | `true` | Enable Chromium browser tool |
| `extra_apt_packages` | | `git curl jq` | Extra packages in gateway container |
| `enable_agent_to_agent` | | `false` | Enable OpenClaw agent-to-agent messaging across the configured team |
| `agent_team` | | `[]` | Multi-agent team definition (workspaces, routing bindings, tools, sandbox, identity, personas) |
| `r2_backup_access_key_id` | | `""` | R2 key (enables encrypted backups) |
| `r2_backup_secret_access_key` | | `""` | R2 secret key |

## Tear Down

```bash
cd terraform
terraform destroy
```

Removes all cloud resources: droplet, firewall, tunnel, DNS records, Access apps, R2 bucket.

## Credential Rotation

```bash
# Rotate tunnel secret
terraform taint random_id.tunnel_secret && terraform apply

# Rotate gateway token
terraform taint random_password.gateway_token && terraform apply
```

## Security

- No public ports — SSH restricted to deployer IP, all web traffic via Cloudflare Tunnel
- Cloudflare Zero Trust email-gated access on all three domains
- Gateway token auth (defense in depth behind Zero Trust)
- Containers run as non-root (`node` uid 1000)
- Cloud-init scrubs all secrets from logs after boot
- Container images pinned by digest where practical
- Never commit `terraform.tfstate` or `terraform.tfvars` (gitignored)
