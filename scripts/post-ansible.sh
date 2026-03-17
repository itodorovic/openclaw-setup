#!/usr/bin/env bash
# post-ansible.sh — Run as ROOT on the droplet after the Ansible playbook completes.
#
# Usage:
#   bash post-ansible.sh <tailscale-authkey> <tailscale-domain>
#
# Example:
#   bash post-ansible.sh tskey-auth-xxx...  openclaw.tail51e710.ts.net
#
# What it does:
#   1. Fixes pnpm directory ownership (Ansible creates them as root)
#   2. Installs Tailscale and connects to your tailnet
#   3. Configures the OpenClaw gateway for Tailscale Serve + identity auth

set -euo pipefail

AUTHKEY="${1:-}"
TAILSCALE_DOMAIN="${2:-}"

# ── Validate args ──────────────────────────────────────────────────────────────
if [[ -z "$AUTHKEY" || -z "$TAILSCALE_DOMAIN" ]]; then
  echo "Usage: $0 <tailscale-authkey> <tailscale-domain>"
  echo ""
  echo "  tailscale-authkey:  from https://login.tailscale.com/admin/settings/keys"
  echo "  tailscale-domain:   e.g. openclaw.tail51e710.ts.net"
  echo "                      (check after connecting: tailscale status)"
  exit 1
fi

if [[ "$EUID" -ne 0 ]]; then
  echo "Error: run this script as root"
  exit 1
fi

OPENCLAW_HOME="/home/openclaw"
OPENCLAW_CONFIG="$OPENCLAW_HOME/.openclaw/openclaw.json"

echo "==> [1/3] Fixing pnpm directory ownership..."
chown -R openclaw:openclaw "$OPENCLAW_HOME/.local"
echo "    Done."

echo "==> [2/3] Installing Tailscale..."
if command -v tailscale &>/dev/null; then
  echo "    Tailscale already installed, skipping."
else
  curl -fsSL https://tailscale.com/install.sh | sh
fi
tailscale up --authkey "$AUTHKEY"
echo "    Connected. Status:"
tailscale status

echo "==> [3/3] Configuring OpenClaw gateway for Tailscale..."
if [[ ! -f "$OPENCLAW_CONFIG" ]]; then
  echo "    Error: $OPENCLAW_CONFIG not found. Run openclaw onboard first."
  exit 1
fi

# Patch the config as the openclaw user
su - openclaw -s /bin/bash -c "python3 - <<'PYEOF'
import json, sys

config_path = '$OPENCLAW_CONFIG'

with open(config_path) as f:
    d = json.load(f)

gw = d.setdefault('gateway', {})
gw.setdefault('auth', {})['allowTailscale'] = True
gw.setdefault('tailscale', {})['mode'] = 'serve'
gw['trustedProxies'] = ['127.0.0.1']
gw.setdefault('controlUi', {})['allowedOrigins'] = ['https://$TAILSCALE_DOMAIN']

with open(config_path, 'w') as f:
    json.dump(d, f, indent=2)

print('    Gateway config updated.')
PYEOF
"

echo "    Restarting openclaw-gateway service..."
su - openclaw -s /bin/bash -c "XDG_RUNTIME_DIR=/run/user/\$(id -u openclaw) systemctl --user restart openclaw-gateway"
sleep 3
su - openclaw -s /bin/bash -c "XDG_RUNTIME_DIR=/run/user/\$(id -u openclaw) systemctl --user status openclaw-gateway --no-pager | grep -E 'Active|Main PID'"

echo ""
echo "==> All done!"
echo ""
echo "    Dashboard: https://$TAILSCALE_DOMAIN"
echo "    (Requires HTTPS Certificates enabled in Tailscale admin DNS settings)"
echo "    https://login.tailscale.com/admin/dns"
