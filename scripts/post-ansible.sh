#!/usr/bin/env bash
# post-ansible.sh — Run as ROOT on the droplet after the Ansible playbook completes.
#
# Usage:
#   bash post-ansible.sh <tailscale-authkey>
#
# Example:
#   bash post-ansible.sh tskey-auth-xxx...
#
# What it does:
#   1. Fixes pnpm directory ownership (Ansible creates them as root)
#   2. Installs Tailscale and connects to your tailnet
#   3. Auto-detects the Tailscale hostname
#   4. Grants openclaw user Tailscale operator rights (required for serve)
#   5. Configures the OpenClaw gateway for Tailscale Serve + identity auth

set -euo pipefail

AUTHKEY="${1:-}"

# ── Validate args ──────────────────────────────────────────────────────────────
if [[ -z "$AUTHKEY" ]]; then
  echo "Usage: $0 <tailscale-authkey>"
  echo ""
  echo "  tailscale-authkey:  from https://login.tailscale.com/admin/settings/keys"
  exit 1
fi

if [[ "$EUID" -ne 0 ]]; then
  echo "Error: run this script as root"
  exit 1
fi

OPENCLAW_HOME="/home/openclaw"
OPENCLAW_CONFIG="$OPENCLAW_HOME/.openclaw/openclaw.json"

echo "==> [1/3] Fixing home directory ownership..."
chown -R openclaw:openclaw "$OPENCLAW_HOME"
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

# Auto-detect Tailscale hostname
TAILSCALE_DOMAIN=$(tailscale status --json | python3 -c "
import json, sys
d = json.load(sys.stdin)
self = d.get('Self', {})
dns = self.get('DNSName', '').rstrip('.')
print(dns)
")
if [[ -z "$TAILSCALE_DOMAIN" ]]; then
  echo "    Error: could not detect Tailscale domain. Check tailscale status."
  exit 1
fi
echo "    Tailscale domain: $TAILSCALE_DOMAIN"

# Grant openclaw operator rights so it can manage tailscale serve
tailscale set --operator=openclaw

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
