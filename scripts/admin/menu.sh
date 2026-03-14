#!/usr/bin/env bash
# Admin shell menu — served by ttyd at admin.streamcg.dev
set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
DEVICES_DIR="/home/node/.openclaw/devices"

show_menu() {
  echo ""
  echo "========================================="
  echo "  OpenClaw Admin Console"
  echo "========================================="
  echo ""
  echo "  1) List paired devices"
  echo "  2) List pending devices"
  echo "  3) Approve pending device"
  echo "  4) Remove paired device"
  echo "  5) Clear all devices"
  echo "  6) Restart gateway"
  echo "  7) Gateway logs (last 50 lines)"
  echo "  8) Container status"
  echo "  9) OpenClaw CLI shell"
  echo " 10) OpenAI Codex OAuth login"
  echo " 11) Lazydocker (container monitor TUI)"
  echo "  s) System shell (bash)"
  echo "  0) Exit"
  echo ""
  printf "  Choice: "
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

list_pending() {
  echo ""
  if [ ! -f "$DEVICES_DIR/pending.json" ] || [ "$(cat "$DEVICES_DIR/pending.json")" = "{}" ]; then
    echo "  No pending devices."
    return
  fi
  echo "  Pending devices:"
  echo "  ────────────────"
  node -e "
    const d = require('$DEVICES_DIR/pending.json');
    const entries = Object.values(d);
    if (!entries.length) { console.log('  No pending devices.'); process.exit(); }
    entries.forEach((e, i) => {
      console.log('  ' + (i+1) + ') ID:     ' + e.deviceId.slice(0,16) + '...');
      console.log('     Client: ' + (e.clientId || 'unknown') + ' (' + (e.clientMode || '?') + ')');
      console.log('     Full:   ' + e.deviceId);
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
    // Write keys to temp file for the shell to read
    fs.writeFileSync('/tmp/.pending_keys.json', JSON.stringify(keys));
  "

  if [ ! -f /tmp/.pending_keys.json ]; then return; fi

  printf "  Enter number to approve (or 'a' for all): "
  read -r choice
  [ -z "\$choice" ] && return

  node -e "
    const fs = require('fs');
    const pPath = '$DEVICES_DIR/pending.json';
    const aPath = '$DEVICES_DIR/paired.json';
    const pending = JSON.parse(fs.readFileSync(pPath, 'utf8'));
    const paired = JSON.parse(fs.readFileSync(aPath, 'utf8'));
    const keys = JSON.parse(fs.readFileSync('/tmp/.pending_keys.json', 'utf8'));
    const choice = '\$choice';

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
    console.log('  Done. Restart gateway (option 6) for changes to take effect.');
  "
}

remove_device() {
  list_paired
  echo ""
  printf "  Enter device ID prefix to remove: "
  read -r prefix
  [ -z "$prefix" ] && return

  node -e "
    const fs = require('fs');
    const aPath = '$DEVICES_DIR/paired.json';
    const paired = JSON.parse(fs.readFileSync(aPath, 'utf8'));
    const prefix = '$prefix';

    const matches = Object.keys(paired).filter(k => k.startsWith(prefix));
    if (!matches.length) { console.log('  No matching paired devices.'); process.exit(1); }

    matches.forEach(id => {
      delete paired[id];
      console.log('  Removed: ' + id.slice(0,16) + '...');
    });

    fs.writeFileSync(aPath, JSON.stringify(paired, null, 2));
    console.log('  Done. Restart gateway for changes to take effect.');
  "
}

clear_all() {
  printf "  Are you sure? This removes ALL paired and pending devices. [y/N]: "
  read -r confirm
  if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
    echo '{}' > "$DEVICES_DIR/paired.json"
    echo '{}' > "$DEVICES_DIR/pending.json"
    echo "  All devices cleared. Restart gateway for changes to take effect."
  else
    echo "  Cancelled."
  fi
}

ensure_docker() {
  if ! command -v docker &>/dev/null; then
    echo "  Docker CLI not available. Check volume mounts."
    return 1
  fi
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

gateway_logs() {
  echo ""
  echo "  Gateway logs (last 50 lines):"
  echo "  ──────────────────────────────"
  # Read from the gateway's log file inside the shared volume
  LOG_FILE=$(find /tmp/openclaw/ -name "openclaw-*.log" -type f 2>/dev/null | sort | tail -1)
  if [ -n "$LOG_FILE" ]; then
    tail -50 "$LOG_FILE"
  else
    echo "  No log file found. Trying container logs..."
    echo "  (Container logs require docker access — use 'System shell' instead)"
  fi
}

container_status() {
  echo ""
  echo "  Container status:"
  echo "  ──────────────────"
  if command -v docker &>/dev/null; then
    docker ps --format 'table {{.Names}}\t{{.Status}}'
  else
    printf "  Gateway health: "
    node -e "fetch('http://127.0.0.1:18789/healthz').then(r=>r.json()).then(j=>console.log(JSON.stringify(j))).catch(e=>console.log('unreachable: '+e.message))"
  fi
}

cli_shell() {
  echo ""
  echo "  Starting OpenClaw CLI... (type 'exit' to return to menu)"
  echo "  ──────────────────────────────────────────────────────────"
  NODE_OPTIONS='--max-old-space-size=768' node /app/dist/index.js "$@" || echo "  CLI exited with error."
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
  echo "  Done. Restart gateway for the new credentials to take effect."
}

lazydocker_tui() {
  if command -v lazydocker &>/dev/null; then
    lazydocker
  else
    echo "  lazydocker not found. Check volume mount."
  fi
}

# Main loop
while true; do
  show_menu
  read -r choice
  case "$choice" in
    1) list_paired ;;
    2) list_pending ;;
    3) approve_device ;;
    4) remove_device ;;
    5) clear_all ;;
    6) restart_gateway ;;
    7) gateway_logs ;;
    8) container_status ;;
    9) cli_shell ;;
    10) openai_login ;;
    11) lazydocker_tui ;;
    s) echo "  Type 'exit' to return to menu."; bash ;;
    0) echo "  Goodbye."; exit 0 ;;
    *) echo "  Invalid choice." ;;
  esac
done
