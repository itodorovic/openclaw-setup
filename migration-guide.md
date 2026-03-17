# Migration Guide: Cloudflare Tunnel → Tailscale + Ansible (Native OpenClaw)

## Overview

This guide migrates from the `itodorovic/openclaw-setup` deployment (Dockerized OpenClaw behind Cloudflare Tunnel on DigitalOcean) to a native OpenClaw install with Tailscale VPN, reusing the existing Terraform for droplet provisioning only.

### What changes

| Component | Before (itodorovic) | After (this guide) |
|-----------|--------------------|--------------------|
| OpenClaw runtime | Docker container (2048 MB) | Native on host (systemd user service) |
| Network access | Cloudflare Tunnel + Zero Trust | Tailscale VPN (no public ports) |
| Provisioning | Terraform + cloud-init (full stack) | Terraform (droplet only) + Ansible + manual onboard |
| Reverse proxy | Caddy container | Not needed (Tailscale handles encryption) |
| Monitoring | Dozzle container | `journalctl` / `openclaw status --deep` |
| Auto-updates | Watchtower container | `openclaw update` via admin console or cron |
| Backups | volume-backup container → R2 | Your choice (restic, rclone, cron — outside this guide) |
| Containers running | 7 | 0 (Docker available but idle) |

### What you keep

- DigitalOcean Terraform provider and droplet resource
- SSH key management
- Firewall resource (modified)
- Your existing OpenClaw agent state (backup/restore)

---

## Phase 0: Destroy the current deployment

The existing deployment was never properly onboarded due to the container-based architecture and the issues described in this guide. There's no agent state worth preserving — we start clean.

```bash
cd terraform
terraform destroy
```

This removes everything: droplet, firewall, Cloudflare tunnel, DNS records, Access apps, R2 bucket. Confirm when prompted.

---

## Phase 1: Strip Terraform down to droplet-only

You're keeping Terraform for what it's good at — creating and destroying cloud resources. Everything else moves to Ansible.

### 1.1 Files to delete

Remove all Cloudflare-related Terraform files. The exact filenames depend on how the repo is structured, but remove any file or resource block that references:

- `cloudflare_tunnel`
- `cloudflare_tunnel_config`
- `cloudflare_access_application`
- `cloudflare_access_policy`
- `cloudflare_record` (DNS records for ai/admin/status subdomains)
- `cloudflare_email_routing_rule` (if present)
- `cloudflare_r2_bucket` (if present)
- `random_id.tunnel_secret`
- `random_password.gateway_token`

Also remove:
- `Caddyfile` (root of repo)
- `Dockerfile` (root of repo — this was for the admin container)
- `docker-compose.yml` (root of repo)
- `scripts/` directory (cloud-init helper scripts)

### 1.2 Simplify `variables.tf`

Keep only the variables needed for a plain droplet. Your new `variables.tf`:

```hcl
# --- DigitalOcean ---
variable "do_token" {
  description = "DigitalOcean API token"
  type        = string
  sensitive   = true
}

variable "droplet_region" {
  description = "DigitalOcean region"
  type        = string
  default     = "fra1"
}

variable "droplet_size" {
  description = "Droplet size (2 GB minimum for native OpenClaw)"
  type        = string
  default     = "s-1vcpu-2gb"
}

variable "ssh_key_path" {
  description = "Path to your SSH public key"
  type        = string
  default     = "~/.ssh/id_ed25519.pub"
}

variable "droplet_name" {
  description = "Droplet hostname"
  type        = string
  default     = "openclaw"
}
```

### 1.3 Simplify `providers.tf`

```hcl
terraform {
  required_version = ">= 1.5"

  required_providers {
    digitalocean = {
      source  = "digitalocean/digitalocean"
      version = "~> 2.0"
    }
  }
}

provider "digitalocean" {
  token = var.do_token
}
```

Remove the entire `cloudflare` provider block.

### 1.4 Rewrite `main.tf`

This creates a plain Ubuntu droplet with your SSH key and a minimal cloud-init that only does base system prep — no OpenClaw, no Docker, no Cloudflare.

```hcl
# --- SSH Key ---
resource "digitalocean_ssh_key" "default" {
  name       = "${var.droplet_name}-key"
  public_key = file(var.ssh_key_path)
}

# --- Droplet ---
resource "digitalocean_droplet" "openclaw" {
  name     = var.droplet_name
  region   = var.droplet_region
  size     = var.droplet_size
  image    = "ubuntu-24-04-x64"
  ssh_keys = [digitalocean_ssh_key.default.fingerprint]

  user_data = <<-CLOUD_INIT
    #cloud-config
    package_update: true
    package_upgrade: true
    packages:
      - curl
      - git
      - jq
      - ufw
      - unattended-upgrades

    # Enable automatic security updates
    write_files:
      - path: /etc/apt/apt.conf.d/20auto-upgrades
        content: |
          APT::Periodic::Update-Package-Lists "1";
          APT::Periodic::Unattended-Upgrade "1";

    runcmd:
      # Basic firewall: allow SSH only, deny everything else
      - ufw default deny incoming
      - ufw default allow outgoing
      - ufw allow 22/tcp
      - ufw --force enable

      # Create openclaw user with SSH access and passwordless sudo
      - useradd -m -s /bin/bash openclaw
      - usermod -aG sudo openclaw
      - echo 'openclaw ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/openclaw
      - chmod 440 /etc/sudoers.d/openclaw
      - mkdir -p /home/openclaw/.ssh
      - cp /root/.ssh/authorized_keys /home/openclaw/.ssh/authorized_keys
      - chown -R openclaw:openclaw /home/openclaw/.ssh
      - chmod 700 /home/openclaw/.ssh
      - chmod 600 /home/openclaw/.ssh/authorized_keys

      # Enable lingering so systemd user services survive logout
      - loginctl enable-linger openclaw

      # Signal that cloud-init is done
      - touch /var/lib/cloud/instance/boot-finished
  CLOUD_INIT

  connection {
    type        = "ssh"
    user        = "root"
    private_key = file(replace(var.ssh_key_path, ".pub", ""))
    host        = self.ipv4_address
  }

  # Wait for cloud-init to finish
  provisioner "remote-exec" {
    inline = [
      "cloud-init status --wait > /dev/null 2>&1 || true",
      "echo 'Cloud-init complete.'"
    ]
  }
}

# --- Firewall ---
resource "digitalocean_firewall" "openclaw" {
  name        = "${var.droplet_name}-fw"
  droplet_ids = [digitalocean_droplet.openclaw.id]

  # SSH from anywhere (or restrict to your IP if you prefer)
  inbound_rule {
    protocol         = "tcp"
    port_range       = "22"
    source_addresses = ["0.0.0.0/0", "::/0"]
  }

  # Tailscale WireGuard (UDP 41641)
  inbound_rule {
    protocol         = "udp"
    port_range       = "41641"
    source_addresses = ["0.0.0.0/0", "::/0"]
  }

  # All outbound (needed for Tailscale DERP, apt, npm, AI APIs)
  outbound_rule {
    protocol              = "tcp"
    port_range            = "1-65535"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }

  outbound_rule {
    protocol              = "udp"
    port_range            = "1-65535"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }

  outbound_rule {
    protocol              = "icmp"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }
}
```

### 1.5 Rewrite `outputs.tf`

```hcl
output "droplet_ip" {
  description = "Droplet public IPv4 address"
  value       = digitalocean_droplet.openclaw.ipv4_address
}

output "ssh_command_root" {
  description = "SSH as root (for Ansible)"
  value       = "ssh root@${digitalocean_droplet.openclaw.ipv4_address}"
}

output "ssh_command_openclaw" {
  description = "SSH as openclaw user (for onboarding)"
  value       = "ssh openclaw@${digitalocean_droplet.openclaw.ipv4_address}"
}

output "next_steps" {
  description = "What to do after terraform apply"
  value       = <<-EOT

    === NEXT STEPS ===

    1. Run the Ansible playbook:
       cd ../ansible
       ansible-playbook -i '${digitalocean_droplet.openclaw.ipv4_address},' \
         -u root playbook.yml \
         -e "clawdbot_ssh_keys=['$(cat ${var.ssh_key_path})']"

    2. SSH in as openclaw and run onboarding:
       ssh openclaw@${digitalocean_droplet.openclaw.ipv4_address}
       openclaw onboard --install-daemon

    3. Access the dashboard via SSH tunnel:
       ssh -L 18789:127.0.0.1:18789 openclaw@${digitalocean_droplet.openclaw.ipv4_address}
       Then open: http://localhost:18789

  EOT
}
```

### 1.6 Simplify `terraform.tfvars`

```hcl
do_token       = "dop_v1_your_digitalocean_token"
droplet_region = "fra1"
droplet_size   = "s-1vcpu-2gb"
ssh_key_path   = "~/.ssh/id_ed25519.pub"
droplet_name   = "openclaw"
```

That's it. No Cloudflare tokens, no account IDs, no zone IDs, no allowed_emails.

### 1.7 Clean up Terraform state

The old infrastructure was already destroyed in Phase 0. Now clear the state so Terraform starts fresh:

```bash
cd terraform

# Remove old state
rm -f terraform.tfstate terraform.tfstate.backup

# Remove the lock file if provider versions changed
rm -f .terraform.lock.hcl
rm -rf .terraform/

# Reinitialize with only the digitalocean provider
terraform init

# Create the new plain droplet
terraform apply
```

---

## Phase 2: Run the Ansible playbook

After `terraform apply` completes, you have a plain Ubuntu droplet with an `openclaw` user and SSH access. Now Ansible installs the stack.

### 2.1 Clone the official Ansible repo

```bash
# On your laptop, alongside the terraform directory
git clone https://github.com/openclaw/openclaw-ansible.git
cd openclaw-ansible
```

### 2.2 Install Ansible dependencies

```bash
# Install Ansible if you don't have it
pip install ansible

# Install required collections
ansible-galaxy collection install -r requirements.yml
```

### 2.3 Create a simple inventory

Create `inventory.ini`:

```ini
[openclaw]
<droplet-ip> ansible_user=root
```

Replace `<droplet-ip>` with the output from `terraform output droplet_ip`.

### 2.4 Run the playbook

```bash
ansible-playbook -i inventory.ini playbook.yml \
  -e "clawdbot_ssh_keys=['$(cat ~/.ssh/id_ed25519.pub)']" \
  -e "tailscale_authkey=tskey-auth-your-tailscale-key"
```

**Getting the Tailscale auth key:** Go to https://login.tailscale.com/admin/settings/keys, generate a one-time auth key (reusable if you plan to rebuild often), and paste it above.

This playbook installs:
- Node.js 22.x + pnpm
- OpenClaw (native, via pnpm)
- Tailscale (auto-joined to your tailnet)
- Docker CE (available but idle — for future use)
- UFW firewall (SSH + Tailscale only)
- The `openclaw` system user with your SSH key

### 2.5 Verify Ansible completed

```bash
# Check Tailscale is connected
ssh root@<droplet-ip> "tailscale status"

# You should see the droplet in your tailnet
# Note its Tailscale IP (e.g. 100.x.y.z)
```

---

## Phase 3: Onboard OpenClaw

Now SSH in as the `openclaw` user and run the onboarding wizard.

### 3.1 Option A: Non-interactive onboard (recommended for automation)

```bash
# SSH as openclaw user — use the Tailscale IP from now on
ssh openclaw@<tailscale-ip>

# Run onboard non-interactively
openclaw onboard --non-interactive \
  --mode local \
  --auth-choice openai-codex-oauth \
  --gateway-port 18789 \
  --gateway-bind loopback \
  --install-daemon \
  --daemon-runtime node \
  --skip-skills
```

**Note on OpenAI OAuth:** The non-interactive flag sets up the config, but the OAuth browser flow still requires manual interaction. After onboard completes, you'll need to:

1. Run the OAuth login flow (the CLI will print a URL).
2. Open that URL in your browser, sign in with your OpenAI account.
3. Paste the redirect URL (containing `code#state`) back into the terminal.

This is unavoidable — OAuth by design requires a browser. The advantage over API keys is that your OpenAI subscription usage limits apply (significantly more generous than API credits).

If the non-interactive onboard doesn't fully handle the OAuth handshake, fall back to the interactive wizard (Option B below) and choose "OpenAI Code (Codex) subscription (OAuth)" when prompted for auth.

### 3.2 Option B: Interactive onboard (recommended for OpenAI OAuth)

Given that OAuth requires browser interaction anyway, the interactive wizard is the smoother path:

```bash
ssh openclaw@<tailscale-ip>
openclaw onboard --install-daemon
```

Walk through the wizard:
- Choose "Local Gateway on loopback" for gateway type.
- Choose **"OpenAI Code (Codex) subscription (OAuth)"** for authentication.
- Follow the browser URL, sign in, paste the redirect URL back.
- The wizard sets `agents.defaults.model` to the appropriate OpenAI Codex model automatically.

### 3.3 Verify the gateway is running

```bash
# Still as openclaw user
openclaw status
openclaw gateway status
openclaw health
```

You should see the gateway running as a systemd user service on port 18789, bound to 127.0.0.1.

---

## Phase 4: Access the dashboard

### 5.1 Via SSH tunnel (works immediately)

From your laptop:

```bash
ssh -L 18789:127.0.0.1:18789 openclaw@<tailscale-ip>
```

Then open http://localhost:18789 in your browser. The gateway token is in `~/.openclaw/openclaw.json` under `gateway.auth.token`.

### 5.2 Via Tailscale directly (if you use Tailscale on your laptop too)

If your laptop is also on your tailnet, you can configure the gateway to bind to the Tailscale interface:

```bash
ssh openclaw@<tailscale-ip>
openclaw configure
# Set gateway.bind to "tailnet"
openclaw gateway restart
```

Then access `http://<tailscale-ip>:18789` directly from your laptop browser — no SSH tunnel needed. The traffic is encrypted end-to-end by WireGuard.

---

## Phase 5: Tear down

When you want to destroy everything:

```bash
cd terraform
terraform destroy
```

This removes the droplet and firewall. Tailscale will show the node as offline; remove it from https://login.tailscale.com/admin/machines if you want a clean tailnet.

---

## Final directory structure

```
openclaw-setup/
├── terraform/
│   ├── main.tf              # Droplet + firewall only
│   ├── variables.tf          # DO token, region, size, SSH key
│   ├── outputs.tf            # IP + next-steps instructions
│   ├── providers.tf          # digitalocean provider only
│   ├── terraform.tfvars      # Your values (gitignored)
│   └── .gitignore
├── openclaw-ansible/         # Cloned official repo (or git submodule)
│   ├── playbook.yml
│   ├── roles/
│   ├── requirements.yml
│   └── ...
├── inventory.ini             # Ansible inventory (gitignored)
└── README.md                 # Updated project README
```

---

## Security comparison (before → after)

| Aspect | Before | After |
|--------|--------|-------|
| Public attack surface | 3 HTTPS endpoints (ai/admin/status) | Zero (nothing publicly reachable) |
| TLS termination | Cloudflare edge (sees plaintext) | WireGuard end-to-end (no middleman) |
| Authentication | Cloudflare Access (email SSO) | Tailscale device auth (WireGuard keys) |
| Web terminal exposure | Public URL behind email gate | Not exposed (SSH only) |
| Container overhead | ~2.8 GB across 7 containers | 0 (Docker idle) |
| Third-party dependency | Cloudflare (outage = total blackout) | Tailscale (existing connections survive outages) |
| Credential count | DO token + CF token + CF account/zone IDs | DO token + Tailscale auth key |

---

## Troubleshooting

**"systemctl --user unavailable: Permission denied"**
You're running commands as root or via `sudo su`. SSH in directly as the `openclaw` user instead.

**Gateway won't start after restore**
The Docker-era `openclaw.json` may have incompatible settings. Run `openclaw doctor` to diagnose, or `openclaw onboard --reset` to start fresh and re-import workspace files manually.

**Tailscale not connecting**
Check `tailscale status` as root. If the auth key expired, generate a new one and run `tailscale up --auth-key=tskey-auth-new-key`. Ensure UFW allows UDP 41641.

**Can't SSH as openclaw user**
Verify the key was deployed: `cat /home/openclaw/.ssh/authorized_keys` as root. Check ownership: `ls -la /home/openclaw/.ssh/` should show `openclaw:openclaw` on all files.

**Lingering not enabled**
If `systemctl --user` commands fail after SSH logout/reconnect: `sudo loginctl enable-linger openclaw` and reconnect.
