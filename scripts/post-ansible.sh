#!/usr/bin/env bash
# post-ansible.sh — Run as ROOT after Ansible install + openclaw onboard.
#
# Usage:
#   bash post-ansible.sh <tailscale-authkey>
#
# Example:
#   bash post-ansible.sh tskey-auth-xxx...
#
# What it does:
#   1. Fixes home directory ownership (Ansible creates dirs as root)
#   2. Reinstalls OpenClaw via npm under ~/.local (user-writable prefix)
#   3. Updates the systemd service to use the user-local binary
#   4. Installs Tailscale and connects to your tailnet
#   5. Auto-detects the Tailscale hostname
#   6. Grants openclaw user Tailscale operator rights (required for serve)
#   7. Configures the OpenClaw gateway for Tailscale Serve + identity auth
#
# Note: Both npm and pnpm remain available after this script:
#   - npm: manages the OpenClaw install under ~/.local (GUI self-updates work)
#   - pnpm: manages plugin installation (nodeManager: "pnpm" in openclaw.json)
#
# After this script:
#   - Open https://<machine>.<tailnet>.ts.net (use https:// explicitly!)
#   - Approve device pairing: openclaw devices approve (as openclaw user)

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

echo "==> [1/5] Fixing home directory ownership..."
chown -R openclaw:openclaw "$OPENCLAW_HOME"
echo "    Done."

# ── Reinstall OpenClaw via npm under user-local prefix ────────────────────────
# The Ansible playbook installs OpenClaw globally via pnpm under /usr, but the
# GUI's "Update now" button runs `npm install -g` which fails with EACCES on
# system-owned directories. By setting npm prefix to ~/.local, the openclaw
# user can self-update without sudo.
# pnpm remains available for plugin installation (nodeManager: "pnpm").

echo "==> [2/5] Reinstalling OpenClaw under ~/.local (user-writable, GUI updates work)..."

# Ensure npm is available (Node.js from Ansible should include it)
if ! command -v npm &>/dev/null; then
  echo "    Error: npm not found. Node.js may not have been installed correctly by Ansible."
  exit 1
fi

# Get current version before reinstall
CURRENT_VERSION=$(openclaw --version 2>/dev/null | awk '{print $2}' || echo "unknown")
echo "    Current version: $CURRENT_VERSION (installed via pnpm)"

# Set npm prefix to ~/.local for the openclaw user and install
su - openclaw -s /bin/bash -c "npm config set prefix ~/.local && npm install -g openclaw"
echo "    Installed under ~/.local: $(su - openclaw -s /bin/bash -c '~/.local/bin/openclaw --version' 2>/dev/null)"

# Remove the pnpm global install to avoid confusion
if pnpm list -g openclaw &>/dev/null 2>&1; then
  pnpm remove -g openclaw 2>/dev/null || true
  echo "    Removed pnpm global install."
fi

# Remove system-wide npm install if present
if [[ -d /usr/lib/node_modules/openclaw ]]; then
  npm rm -g openclaw 2>/dev/null || true
  echo "    Removed system-wide npm install."
fi

echo "    Done."

# ── Fix systemd service to use user-local binary path ─────────────────────────
echo "==> [3/5] Updating systemd service to use user-local binary..."

OPENCLAW_SERVICE="$OPENCLAW_HOME/.config/systemd/user/openclaw-gateway.service"
if [[ -f "$OPENCLAW_SERVICE" ]]; then
  LOCAL_INDEX="$OPENCLAW_HOME/.local/lib/node_modules/openclaw/dist/index.js"
  # Replace ExecStart to use the user-local path
  if ! grep -q "$LOCAL_INDEX" "$OPENCLAW_SERVICE"; then
    sed -i "s|^ExecStart=.*|ExecStart=/usr/bin/node $LOCAL_INDEX gateway --port 18789|" "$OPENCLAW_SERVICE"
    echo "    Service updated to use $LOCAL_INDEX."
  else
    echo "    Service already uses the correct binary path."
  fi

  # Add EnvironmentFile for secrets (.env) if not already present
  ENV_FILE="$OPENCLAW_HOME/.config/openclaw/.env"
  if [[ -f "$ENV_FILE" ]] && ! grep -q "EnvironmentFile=" "$OPENCLAW_SERVICE"; then
    sed -i "/^\[Service\]/a EnvironmentFile=$ENV_FILE" "$OPENCLAW_SERVICE"
    echo "    Added EnvironmentFile for $ENV_FILE."
  fi

  # Reload systemd for the openclaw user
  su - openclaw -s /bin/bash -c "XDG_RUNTIME_DIR=/run/user/\$(id -u openclaw) systemctl --user daemon-reload"
else
  echo "    Service file not found yet (will be created during onboard)."
fi

echo "    Done."

echo "==> [4/5] Installing Tailscale..."
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

echo "==> [5/5] Configuring OpenClaw gateway for Tailscale..."
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
echo "    (Use https:// explicitly — Android Chrome defaults to http!)"
echo "    (Requires HTTPS Certificates enabled in Tailscale admin DNS settings)"
echo "    https://login.tailscale.com/admin/dns"
echo ""
echo "    To approve device pairing (as openclaw user):"
echo "      openclaw devices approve"
