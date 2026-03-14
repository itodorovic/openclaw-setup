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
  echo "  6) Gateway logs (last 50 lines)"
  echo "  7) Container status"
  echo "  8) OpenClaw CLI shell"
  echo "  9) System shell (bash)"
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
      console.log('     Added:  ' + new Date(e.createdAtMs).toISOString());
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
  printf "  Reading pending devices and approving in one step...\n"
  printf "  Enter device ID prefix to approve (or 'all', or empty to list first): "
  read -r prefix

  if [ -z "$prefix" ]; then
    list_pending
    echo ""
    printf "  Enter device ID prefix to approve (or 'all'): "
    read -r prefix
    [ -z "$prefix" ] && return
  fi

  node -e "
    const fs = require('fs');
    const pPath = '$DEVICES_DIR/pending.json';
    const aPath = '$DEVICES_DIR/paired.json';
    // Read both files atomically in one step
    const pending = JSON.parse(fs.readFileSync(pPath, 'utf8'));
    const paired = JSON.parse(fs.readFileSync(aPath, 'utf8'));
    const prefix = '$prefix';

    const matches = prefix === 'all'
      ? Object.keys(pending)
      : Object.keys(pending).filter(k => k.startsWith(prefix));

    if (!matches.length) {
      console.log('  No matching pending devices.');
      console.log('  (The gateway may have cleared the request — try clicking Connect in the dashboard first, then immediately run approve with \"all\")');
      process.exit(1);
    }

    matches.forEach(id => {
      const dev = pending[id];
      dev.role = dev.role || 'operator';
      dev.approvedAtMs = Date.now();
      dev.approvedScopes = dev.scopes || ['operator.admin','operator.read','operator.write','operator.approvals','operator.pairing'];
      paired[id] = dev;
      delete pending[id];
      console.log('  Approved: ' + id.slice(0,16) + '...');
    });

    fs.writeFileSync(aPath, JSON.stringify(paired, null, 2));
    fs.writeFileSync(pPath, JSON.stringify(pending, null, 2));
    console.log('  Done. Restart gateway for changes to take effect.');
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
  # Use the healthz endpoint since we share the gateway network
  printf "  Gateway health: "
  node -e "fetch('http://127.0.0.1:18789/healthz').then(r=>r.json()).then(j=>console.log(JSON.stringify(j))).catch(e=>console.log('unreachable: '+e.message))"
  echo ""
  echo "  Volume files:"
  ls -la /home/node/.openclaw/ 2>/dev/null || echo "  (volume not accessible)"
}

cli_shell() {
  echo ""
  echo "  Starting OpenClaw CLI... (type 'exit' to return to menu)"
  echo "  ──────────────────────────────────────────────────────────"
  node /app/dist/index.js "$@" || echo "  CLI exited with error."
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
    6) gateway_logs ;;
    7) container_status ;;
    8) cli_shell ;;
    9) echo "  Type 'exit' to return to menu."; bash ;;
    0) echo "  Goodbye."; exit 0 ;;
    *) echo "  Invalid choice." ;;
  esac
done
