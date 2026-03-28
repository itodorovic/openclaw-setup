# OpenClaw Setup

[OpenClaw](https://github.com/openclaw/openclaw) native deployment on DigitalOcean with Tailscale VPN. Terraform provisions the droplet; the official Ansible playbook installs OpenClaw natively (no Docker).

## Architecture

| Layer | Component |
|-------|-----------|
| Compute | DigitalOcean Droplet (1 vCPU, 2 GB RAM + 4 GB swap) |
| Network | Tailscale VPN (replaces public ports) |
| AI Agent | OpenClaw native install via npm (systemd user service) |
| Security | UFW + fail2ban + unattended-upgrades |

## Prerequisites

1. [Terraform](https://developer.hashicorp.com/terraform/install) >= 1.5
2. An SSH key pair (`~/.ssh/id_ed25519` by default)
3. A [DigitalOcean API token](https://docs.digitalocean.com/reference/api/create-personal-access-token/)
4. A [Tailscale account](https://tailscale.com) (free tier works)

## Deploy

### 1. Provision the droplet

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars   # fill in do_token, ssh_key_path, droplet_name
terraform init
terraform apply
```

Terraform creates the droplet and waits for cloud-init to finish. Verified on completion:
- 4 GB swap active
- `openclaw` user with your SSH key and passwordless sudo
- systemd lingering enabled
- UFW enabled (SSH only)

### 2. Install OpenClaw (as root)

```bash
ssh root@<droplet-ip>
curl -fsSL https://raw.githubusercontent.com/openclaw/openclaw-ansible/main/install.sh | bash
```

### 3. Onboard (as openclaw user)

**Always SSH directly as openclaw — never `sudo su - openclaw` (breaks systemd user services).**

```bash
ssh openclaw@<droplet-ip>
tmux                              # protects against SSH disconnects
openclaw onboard --install-daemon
```

If disconnected, reconnect and run `tmux attach`.

### 4. Run post-Ansible setup (as root)

This script fixes permissions, reinstalls OpenClaw via npm (required for GUI updates), installs Tailscale, and configures the gateway in one shot.

**Before running:** enable HTTPS Certificates in [Tailscale admin DNS settings](https://login.tailscale.com/admin/dns) and generate an auth key from [tailscale.com/admin/settings/keys](https://login.tailscale.com/admin/settings/keys).

```bash
ssh root@<droplet-ip>
bash <(curl -fsSL https://raw.githubusercontent.com/itodorovic/openclaw-setup/main/scripts/post-ansible.sh) \
  <tailscale-authkey>
```

The script auto-detects the Tailscale hostname — no need to pass it manually.

### 5. Access the dashboard

Open in any browser on your Tailscale network:

```
https://<machine-name>.<tailnet>.ts.net
```

On first visit the browser will be blocked with **"pairing required"**. This is a one-time device registration. Approve it from the droplet (as root):

```bash
ssh root@<droplet-ip>
python3 -c "
import json, time
with open('/home/openclaw/.openclaw/devices/pending.json') as f:
    pending = json.load(f)
with open('/home/openclaw/.openclaw/devices/paired.json') as f:
    paired = json.load(f)
now = int(time.time() * 1000)
for req in pending.values():
    did = req['deviceId']
    paired[did] = {'deviceId': did, 'publicKey': req['publicKey'], 'platform': req['platform'], 'clientId': req['clientId'], 'clientMode': req['clientMode'], 'role': req['role'], 'roles': req['roles'], 'scopes': req['scopes'], 'approvedScopes': req['scopes'], 'tokens': {}, 'createdAtMs': req['ts'], 'approvedAtMs': now}
    print('Approved:', did)
with open('/home/openclaw/.openclaw/devices/paired.json', 'w') as f:
    json.dump(paired, f, indent=2)
with open('/home/openclaw/.openclaw/devices/pending.json', 'w') as f:
    json.dump({}, f)
"
# Restart to pick up the approved device
su - openclaw -s /bin/bash -c "XDG_RUNTIME_DIR=/run/user/\$(id -u openclaw) systemctl --user restart openclaw-gateway"
```

Refresh the browser — it will connect. Each new browser profile needs this once.

## Variables

| Variable | Required | Default | Description |
|----------|:--------:|---------|-------------|
| `do_token` | yes | | DigitalOcean API token |
| `ssh_key_path` | yes | `~/.ssh/id_ed25519.pub` | SSH public key path |
| `droplet_name` | yes | | Droplet name |
| `droplet_region` | | `fra1` | DigitalOcean region |
| `droplet_size` | | `s-1vcpu-2gb` | Droplet size |
| `allowed_ssh_cidrs` | | auto-detected | IPs allowed SSH access (defaults to your current IP) |

## Web Search

OpenClaw's built-in web search (Grok) requires paid xAI credits. A free alternative is the [DuckDuckGo search skill](https://clawhub.io) from clawhub, which uses the droplet's native internet connectivity — no API key needed.

Install it once after onboarding (as the openclaw user):

```bash
pnpm add -g clawhub
pnpx clawhub install duckduckgo-search
```

When prompted during onboarding to configure web search, skip the Grok API key step.

## WhatsApp Group Setup

To add the agent to a WhatsApp group, you need the group's JID (unique identifier). Since the agent runs as a linked device on your WhatsApp account, it already sees all your groups — you just need to find the JID and allowlist it.

### 1. Temporarily open group policy

Set `groupPolicy` to `"open"` in `~/.openclaw/openclaw.json` so the message isn't silently dropped:

```json
"channels": {
  "whatsapp": {
    "groupPolicy": "open",
    "groups": { "*": { "requireMention": false } }
  }
}
```

Restart the gateway:

```bash
restart-gateway
```

### 2. Watch the logs and send a message in the target group

```bash
ssh openclaw@<droplet-ip>
XDG_RUNTIME_DIR=/run/user/$(id -u) journalctl --user -u openclaw-gateway -f
```

Send any message in the WhatsApp group. The logs will show:

```
[whatsapp] Inbound message 120363XXXXXXXXXX@g.us -> +XXXXXXXXXXX (group, NN chars)
```

The `120363XXXXXXXXXX@g.us` part is your group JID. Copy it.

### 3. Lock down to that group

Update `~/.openclaw/openclaw.json` with the JID:

```json
"channels": {
  "whatsapp": {
    "groupPolicy": "allowlist",
    "groupAllowFrom": ["*"],
    "groups": {
      "120363XXXXXXXXXX@g.us": { "requireMention": true }
    }
  }
}
```

Restart the gateway again. The agent will now only respond in that group, and only when mentioned.

### 4. Set up mention patterns

Add a mention trigger to `agents.list` in `openclaw.json` so group members can invoke the agent by name:

```json
"agents": {
  "list": [{
    "id": "main",
    "groupChat": {
      "mentionPatterns": ["@djordje"]
    }
  }]
}
```

Restart the gateway. Group members can now type `@djordje` to get a response, or reply to one of the agent's messages.

## Semantic Memory

OpenClaw's semantic memory search requires an embedding provider. The Codex OAuth subscription covers chat completions but **not** the embeddings API. You need a separate OpenAI platform API key.

### Setup

1. Add API credits at [platform.openai.com/settings/billing](https://platform.openai.com/settings/billing) ($5 is plenty)
2. **Disable auto-recharge** and set a **monthly budget cap** at [platform.openai.com/settings/limits](https://platform.openai.com/settings/limits)
3. Create a **restricted API key** at [platform.openai.com/api-keys](https://platform.openai.com/api-keys) with only the **Embeddings** permission
4. Add the key to the agent-level auth profiles (as openclaw user):

```bash
python3 -c "
import json
path = '/home/openclaw/.openclaw/agents/main/agent/auth-profiles.json'
with open(path) as f:
    d = json.load(f)
d['profiles']['openai:default'] = {
    'type': 'api_key',
    'provider': 'openai',
    'key': '<YOUR_OPENAI_API_KEY>'
}
with open(path, 'w') as f:
    json.dump(d, f, indent=2)
"
```

5. Also set it as an environment variable for the gateway service:

```bash
echo 'OPENAI_API_KEY=<YOUR_OPENAI_API_KEY>' > ~/.secrets/openclaw-gateway.env
chmod 600 ~/.secrets/openclaw-gateway.env
```

Add `EnvironmentFile=/home/openclaw/.secrets/openclaw-gateway.env` to the `[Service]` section of `~/.config/systemd/user/openclaw-gateway.service`, then reload and restart.

6. Index and verify:

```bash
openclaw memory index --force
openclaw memory status --deep
openclaw memory search "test query"
```

Expected: `Provider: openai`, `Model: text-embedding-3-small`, `Embeddings: ready`, indexed files/chunks > 0.

### Cost

`text-embedding-3-small` costs ~$0.02 per million tokens. With auto-recharge off and a $5 budget cap, runaway costs are impossible.

## Cron Jobs

When adding cron jobs to a multi-channel gateway (e.g. both WhatsApp and Telegram enabled), you must either:
- set an explicit delivery channel: `--channel telegram --to <chatId>`
- or disable delivery: `--no-deliver`

Without this, jobs will error with _"Channel is required when multiple channels are configured"_ even though the agent work completes successfully. For watchdog-style jobs that don't need to message anyone, use `--no-deliver`.

Example:
```bash
# Create a watchdog job with no delivery
openclaw cron add --name my-watchdog --every 2h --session isolated --no-deliver --message "Check system health"

# Fix an existing job that's failing on delivery
openclaw cron edit <job-id> --no-deliver
```

## Tear Down

```bash
cd terraform
terraform destroy
```

## Security Notes

- SSH restricted to deployer IP via DigitalOcean firewall (auto-detected)
- UFW default deny incoming, allow outgoing
- fail2ban protects SSH
- Ansible scopes openclaw sudoers to service management only (intentional)
- Never commit `terraform.tfstate` or `terraform.tfvars` (gitignored)
- Dashboard access via Tailscale Serve only — no public web ports
- `allowTailscale: true` trusts Tailscale identity headers — only safe because the VPS is a trusted host
- `gateway.nodes.denyCommands` uses **exact command-name matching** — entries must match real command IDs (e.g. `camera.list`, `sms.search`), not shell-text patterns. Run `openclaw security audit --deep` to check for ineffective entries
- The trust model warning about multi-user access is expected for a WhatsApp group setup — this is a single-operator gateway behind Tailscale, not a multi-tenant system
