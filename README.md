# OpenClaw Setup

[OpenClaw](https://github.com/openclaw/openclaw) native deployment on DigitalOcean with Tailscale VPN. Terraform provisions the droplet; the official Ansible playbook installs OpenClaw natively (no Docker).

## Architecture

| Layer | Component |
|-------|-----------|
| Compute | DigitalOcean Droplet (1 vCPU, 2 GB RAM + 4 GB swap) |
| Network | Tailscale VPN (replaces public ports) |
| AI Agent | OpenClaw native install via pnpm (systemd user service) |
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

This script fixes pnpm permissions, installs Tailscale, and configures the gateway in one shot.

**Before running:** enable HTTPS Certificates in [Tailscale admin DNS settings](https://login.tailscale.com/admin/dns) and generate an auth key from [tailscale.com/admin/settings/keys](https://login.tailscale.com/admin/settings/keys).

```bash
ssh root@<droplet-ip>
bash <(curl -fsSL https://raw.githubusercontent.com/itodorovic/openclaw-setup/ansible/scripts/post-ansible.sh) \
  <tailscale-authkey> \
  <machine-name>.<tailnet>.ts.net
```

The Tailscale domain (e.g. `openclaw.tail51e710.ts.net`) is shown in `tailscale status` after connecting.
If you don't know it yet, run `tailscale up --authkey <key>` first, then `tailscale status` to get it,
then re-run the full script.

### 5. Access the dashboard

Open in any browser on your Tailscale network — no token or pairing needed:

```
https://<machine-name>.<tailnet>.ts.net
```

## Variables

| Variable | Required | Default | Description |
|----------|:--------:|---------|-------------|
| `do_token` | yes | | DigitalOcean API token |
| `ssh_key_path` | yes | `~/.ssh/id_ed25519.pub` | SSH public key path |
| `droplet_name` | yes | | Droplet name |
| `droplet_region` | | `fra1` | DigitalOcean region |
| `droplet_size` | | `s-1vcpu-2gb` | Droplet size |
| `allowed_ssh_cidrs` | | auto-detected | IPs allowed SSH access (defaults to your current IP) |

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
