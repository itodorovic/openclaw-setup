#!/usr/bin/env bash
# Admin shell menu — served by ttyd at admin.streamcg.dev
set -euo pipefail

DEVICES_DIR="/home/node/.openclaw/devices"

# ── Main Menu ────────────────────────────────────────────

show_menu() {
  echo ""
  echo "========================================="
  echo "  OpenClaw Admin Console"
  echo "========================================="
  echo ""
  echo "  1) Dashboard URL (connect browser)"
  echo "  2) Devices (pair, list, remove)"
  echo "  3) Restart gateway"
  echo "  4) OpenAI Codex OAuth login"
  echo "  5) Lazydocker (logs + monitor)"
  echo "  6) OpenClaw CLI shell"
  echo "  s) System shell (bash)"
  echo "  0) Exit"
  echo ""
  printf "  Choice: "
}

# ── Devices Submenu ──────────────────────────────────────

devices_menu() {
  while true; do
    echo ""
    echo "  ── Devices ──────────────────────"
    echo ""
    echo "  1) List paired devices"
    echo "  2) Approve pending device"
    echo "  3) Remove paired device"
    echo "  b) Back to main menu"
    echo ""
    printf "  Choice: "
    read -r dchoice
    case "$dchoice" in
      1) list_paired ;;
      2) approve_device ;;
      3) remove_device ;;
      b) return ;;
      *) echo "  Invalid choice." ;;
    esac
  done
}

list_paired() {
  echo ""
  if [ ! -f "$DEVICES_DIR/paired.json" ] || [ "$(cat "$DEVICES_DIR/paired.json")" = "{}" ]; then
    echo "  No paired devices."
    return
  fi
  echo "  Paired devices:"
  echo "  ────────────────"
  node -e "
    const d = require('$DEVICES_DIR/paired.json');
    const entries = Object.values(d);
    if (!entries.length) { console.log('  No paired devices.'); process.exit(); }
    entries.forEach((e, i) => {
      console.log('  ' + (i+1) + ') ID:     ' + e.deviceId.slice(0,16) + '...');
      console.log('     Client: ' + (e.clientId || 'unknown') + ' (' + (e.clientMode || '?') + ')');
      console.log('     Role:   ' + (e.role || '?'));
      const ts = e.createdAtMs || e.approvedAtMs || e.ts;
      console.log('     Added:  ' + (ts ? new Date(ts).toISOString() : 'unknown'));
      console.log('');
    });
  "
}

approve_device() {
  echo ""
  echo "  Approve pending device"
  echo "  ──────────────────────"

  node -e "
    const fs = require('fs');
    const pPath = '$DEVICES_DIR/pending.json';
    const aPath = '$DEVICES_DIR/paired.json';
    const pending = JSON.parse(fs.readFileSync(pPath, 'utf8'));
    const keys = Object.keys(pending);
    if (!keys.length) {
      console.log('  No pending devices.');
      console.log('  (Click Connect in the dashboard first, then quickly run approve)');
      process.exit(0);
    }
    console.log('');
    keys.forEach((k, i) => {
      const d = pending[k];
      const id = d.deviceId || k;
      console.log('  ' + (i+1) + ') ' + id.slice(0,16) + '...  [' + (d.clientMode||'?') + ', ' + (d.platform||'?') + ']');
    });
    console.log('');
    fs.writeFileSync('/tmp/.pending_keys.json', JSON.stringify(keys));
  "

  if [ ! -f /tmp/.pending_keys.json ]; then return; fi

  printf "  Enter number to approve (or 'a' for all): "
  read -r choice
  [ -z "$choice" ] && return

  node -e "
    const fs = require('fs');
    const pPath = '$DEVICES_DIR/pending.json';
    const aPath = '$DEVICES_DIR/paired.json';
    const pending = JSON.parse(fs.readFileSync(pPath, 'utf8'));
    const paired = JSON.parse(fs.readFileSync(aPath, 'utf8'));
    const keys = JSON.parse(fs.readFileSync('/tmp/.pending_keys.json', 'utf8'));
    const choice = '$choice';

    let toApprove = [];
    if (choice === 'a' || choice === 'all') {
      toApprove = keys;
    } else {
      const num = parseInt(choice, 10);
      if (num >= 1 && num <= keys.length) {
        toApprove = [keys[num - 1]];
      } else {
        console.log('  Invalid choice.');
        process.exit(1);
      }
    }

    toApprove.forEach(id => {
      const dev = pending[id];
      if (!dev) return;
      const deviceId = dev.deviceId || id;
      dev.role = dev.role || 'operator';
      dev.approvedAtMs = Date.now();
      dev.approvedScopes = dev.scopes || ['operator.admin','operator.read','operator.write','operator.approvals','operator.pairing'];
      paired[deviceId] = dev;
      delete pending[id];
      console.log('  Approved: ' + deviceId.slice(0,16) + '...');
    });

    fs.writeFileSync(aPath, JSON.stringify(paired, null, 2));
    fs.writeFileSync(pPath, JSON.stringify(pending, null, 2));
    fs.unlinkSync('/tmp/.pending_keys.json');
    console.log('  Done. Restart gateway (main menu → 2) for changes to take effect.');
  "
}

remove_device() {
  list_paired
  echo ""
  printf "  Enter device number to remove (or 'a' for all): "
  read -r choice
  [ -z "$choice" ] && return

  node -e "
    const fs = require('fs');
    const aPath = '$DEVICES_DIR/paired.json';
    const paired = JSON.parse(fs.readFileSync(aPath, 'utf8'));
    const keys = Object.keys(paired);
    const choice = '$choice';

    let toRemove = [];
    if (choice === 'a' || choice === 'all') {
      toRemove = keys;
    } else {
      const num = parseInt(choice, 10);
      if (num >= 1 && num <= keys.length) {
        toRemove = [keys[num - 1]];
      } else {
        console.log('  Invalid choice.');
        process.exit(1);
      }
    }

    toRemove.forEach(id => {
      delete paired[id];
      console.log('  Removed: ' + id.slice(0,16) + '...');
    });

    fs.writeFileSync(aPath, JSON.stringify(paired, null, 2));
    console.log('  Done. Restart gateway for changes to take effect.');
  "
}

# ── Core Functions ───────────────────────────────────────

ensure_docker() {
  if ! command -v docker &>/dev/null; then
    echo "  Docker CLI not available. Check volume mounts."
    return 1
  fi
}

dashboard_url() {
  echo ""
  if ! ensure_docker; then return; fi
  # Extract the token from the CLI's dashboard output
  URL=$(docker exec openclaw-gateway node /app/dist/index.js dashboard --no-open 2>&1 \
    | grep -oP 'http://[^#]+#token=\K.*' || true)
  if [ -z "$URL" ]; then
    echo "  Could not retrieve gateway token."
    return
  fi
  echo "  Open this URL in your browser:"
  echo ""
  echo "  https://ai.streamcg.dev/#token=$URL"
  echo ""
  echo "  (The token auto-pairs your browser — no approval needed.)"
}

restart_gateway() {
  echo ""
  echo "  Restarting gateway..."
  if ! ensure_docker; then return; fi
  docker restart openclaw-gateway
  echo "  Gateway restarted. Waiting for health..."
  sleep 10
  for i in $(seq 1 12); do
    status=$(docker inspect openclaw-gateway --format '{{.State.Health.Status}}' 2>/dev/null)
    echo "  [$i] $status"
    if [ "$status" = "healthy" ]; then
      echo "  Gateway is healthy."
      echo "  Restarting admin container (shared network)..."
      docker restart openclaw-admin
      echo "  Admin container restarted."
      return
    fi
    sleep 5
  done
  echo "  Gateway did not become healthy in time."
}

openai_login() {
  echo ""
  echo "  OpenAI Codex OAuth Login"
  echo "  ────────────────────────"
  echo "  This will open an OAuth flow. Follow the URL to authenticate."
  echo ""
  if ! ensure_docker; then return; fi
  docker exec -it openclaw-gateway node /app/dist/index.js models auth login --provider openai-codex
  echo ""
  echo "  Done. Restart gateway (option 2) for the new credentials to take effect."
}

lazydocker_tui() {
  if command -v lazydocker &>/dev/null; then
    lazydocker
  else
    echo "  lazydocker not found. Check volume mount."
  fi
}

cli_shell() {
  echo ""
  echo "  Starting OpenClaw CLI... (type 'exit' to return to menu)"
  echo "  ──────────────────────────────────────────────────────────"
  NODE_OPTIONS='--max-old-space-size=768' node /app/dist/index.js "$@" || echo "  CLI exited with error."
}

# ── Main Loop ────────────────────────────────────────────

while true; do
  show_menu
  read -r choice
  case "$choice" in
    1) dashboard_url ;;
    2) devices_menu ;;
    3) restart_gateway ;;
    4) openai_login ;;
    5) lazydocker_tui ;;
    6) cli_shell ;;
    s) echo "  Type 'exit' to return to menu."; bash ;;
    0) echo "  Goodbye."; exit 0 ;;
    *) echo "  Invalid choice." ;;
  esac
done
