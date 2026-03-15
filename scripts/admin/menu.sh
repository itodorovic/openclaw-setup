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
  echo "  3) Backups (list, status, backup, restore)"
  echo "  4) Restart gateway"
  echo "  5) OpenAI Codex OAuth login"
  echo "  6) Update OpenClaw"
  echo "  7) Lazydocker (logs + monitor)"
  echo "  8) OpenClaw CLI shell"
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

# ── Backups Submenu ──────────────────────────────────────

COMPOSE_FILE="/root/openclaw-setup/docker-compose.yml"

_fetch_r2_env() {
  # Read S3 + GPG credentials from the volume-backup container (once per call)
  if [ -z "${_R2_ENV_LOADED:-}" ]; then
    eval "$(docker exec volume-backup env 2>/dev/null \
      | grep -E '^(AWS_|GPG_PASSPHRASE=)' \
      | sed "s/'/'\\\\''/g; s/=\(.*\)/='\1'/")"
    _R2_ENV_LOADED=1
  fi
}

backups_menu() {
  if ! ensure_docker; then return; fi
  _R2_ENV_LOADED=""
  while true; do
    echo ""
    echo "  ── Backups ──────────────────────"
    echo ""
    echo "  1) List backups (remote)"
    echo "  2) Last backup status"
    echo "  3) Backup now"
    echo "  4) Restore from backup"
    echo "  b) Back to main menu"
    echo ""
    printf "  Choice: "
    read -r bchoice
    case "$bchoice" in
      1) list_backups ;;
      2) last_backup_status ;;
      3) manual_backup ;;
      4) restore_backup ;;
      b) return ;;
      *) echo "  Invalid choice." ;;
    esac
  done
}

list_backups() {
  echo ""
  echo "  Remote backups (R2):"
  echo "  ────────────────────"
  _fetch_r2_env
  OUTPUT=$(docker run --rm \
    -e "MC_HOST_r2=${AWS_ENDPOINT_PROTO:-https}://${AWS_ACCESS_KEY_ID}:${AWS_SECRET_ACCESS_KEY}@${AWS_ENDPOINT}" \
    minio/mc ls "r2/${AWS_S3_BUCKET_NAME}/" 2>&1)
  if [ -z "$OUTPUT" ]; then
    echo "  No backups found."
    return
  fi
  echo "$OUTPUT" | sed 's/^/  /'
}

last_backup_status() {
  echo ""
  echo "  Last backup log:"
  echo "  ────────────────"
  docker logs volume-backup 2>&1 | tail -25 | sed 's/^/  /'
}

manual_backup() {
  echo ""
  printf "  Run backup now? (y/N): "
  read -r confirm
  case "$confirm" in
    y|Y)
      echo "  Starting backup..."
      docker exec volume-backup backup 2>&1 | sed 's/^/  /'
      echo ""
      echo "  Done."
      ;;
    *) echo "  Cancelled." ;;
  esac
}

restore_backup() {
  echo ""
  echo "  ⚠ Restore will REPLACE current OpenClaw data."
  echo ""

  # List available backups from R2
  echo "  Fetching backup list..."
  _fetch_r2_env
  BACKUP_LIST=$(docker run --rm \
    -e "MC_HOST_r2=${AWS_ENDPOINT_PROTO:-https}://${AWS_ACCESS_KEY_ID}:${AWS_SECRET_ACCESS_KEY}@${AWS_ENDPOINT}" \
    minio/mc ls "r2/${AWS_S3_BUCKET_NAME}/" 2>&1 \
    | awk '{print $NF}' | grep -E '\.tar\.(gz|zst)(\.gpg)?$' | sort)

  if [ -z "$BACKUP_LIST" ]; then
    echo "  No backups found in logs. Enter filename manually."
    printf "  Filename (e.g. backup-2026-03-14T21-00-37.tar.gz.gpg): "
    read -r BACKUP_FILE
    [ -z "$BACKUP_FILE" ] && echo "  Cancelled." && return
  else
    echo ""
    IDX=0
    declare -a BACKUP_ARRAY=()
    while IFS= read -r line; do
      IDX=$((IDX + 1))
      BACKUP_ARRAY+=("$line")
      echo "  $IDX) $line"
    done <<< "$BACKUP_LIST"
    echo ""
    printf "  Enter number (or filename): "
    read -r pick
    [ -z "$pick" ] && echo "  Cancelled." && return
    if [[ "$pick" =~ ^[0-9]+$ ]] && [ "$pick" -ge 1 ] && [ "$pick" -le "${#BACKUP_ARRAY[@]}" ]; then
      BACKUP_FILE="${BACKUP_ARRAY[$((pick - 1))]}"
    else
      BACKUP_FILE="$pick"
    fi
  fi

  echo ""
  echo "  Selected: $BACKUP_FILE"
  printf "  Confirm restore? This will stop the gateway. (yes/N): "
  read -r confirm
  [ "$confirm" != "yes" ] && echo "  Cancelled." && return

  echo ""
  echo "  [1/5] Stopping gateway + admin..."
  docker compose -f "$COMPOSE_FILE" stop openclaw-gateway openclaw-admin

  echo "  [2/5] Downloading backup from R2..."
  docker volume create restore_tmp >/dev/null 2>&1 || true
  docker run --rm \
    -e MC_HOST_r2="${AWS_ENDPOINT_PROTO:-https}://${AWS_ACCESS_KEY_ID}:${AWS_SECRET_ACCESS_KEY}@${AWS_ENDPOINT}" \
    -v restore_tmp:/tmp/restore \
    minio/mc cp "r2/${AWS_S3_BUCKET_NAME}/${BACKUP_FILE}" /tmp/restore/backup.archive 2>&1 | sed 's/^/  /'

  IS_GPG=false
  case "$BACKUP_FILE" in *.gpg) IS_GPG=true ;; esac

  echo "  [3/5] Decrypting and extracting..."
  if [ "$IS_GPG" = "true" ]; then
    docker run --rm \
      -e GPG_PASSPHRASE="$GPG_PASSPHRASE" \
      -v restore_tmp:/tmp/restore \
      -v /root/openclaw-setup/data:/data \
      alpine sh -c '
        apk add --no-cache gnupg >/dev/null 2>&1
        gpg --batch --yes --passphrase "$GPG_PASSPHRASE" \
          -d /tmp/restore/backup.archive | tar xzf - -C /
        chown -R 1000:1000 /data
      ' 2>&1 | sed 's/^/  /'
  else
    docker run --rm \
      -v restore_tmp:/tmp/restore \
      -v /root/openclaw-setup/data:/data \
      alpine sh -c '
        tar xzf /tmp/restore/backup.archive -C /
        chown -R 1000:1000 /data
      ' 2>&1 | sed 's/^/  /'
  fi

  echo "  [4/5] Cleaning up..."
  docker volume rm restore_tmp >/dev/null 2>&1 || true

  echo "  [5/5] Starting gateway + admin..."
  docker compose -f "$COMPOSE_FILE" up -d openclaw-gateway openclaw-admin
  sleep 5
  for i in $(seq 1 12); do
    status=$(docker inspect openclaw-gateway --format '{{.State.Health.Status}}' 2>/dev/null)
    [ "$status" = "healthy" ] && break
    sleep 5
  done
  echo ""
  echo "  Restore complete. Gateway status: $(docker inspect openclaw-gateway --format '{{.State.Health.Status}}' 2>/dev/null)"
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
  echo "  Done. Restart gateway (option 4) for the new credentials to take effect."
}

lazydocker_tui() {
  if command -v lazydocker &>/dev/null; then
    lazydocker
  else
    echo "  lazydocker not found. Check volume mount."
  fi
}

update_openclaw() {
  echo ""
  echo "  Update OpenClaw"
  echo "  ────────────────"
  if ! ensure_docker; then return; fi

  CURRENT=$(docker inspect openclaw-gateway --format '{{.Image}}' 2>/dev/null | cut -c1-19)
  echo "  Current image: $CURRENT"
  echo ""
  printf "  Pull latest and restart? (y/N): "
  read -r confirm
  case "$confirm" in
    y|Y)
      echo "  Pulling latest image..."
      docker compose -f /root/openclaw-setup/docker-compose.yml pull openclaw-gateway
      echo "  Recreating gateway + admin..."
      docker compose -f /root/openclaw-setup/docker-compose.yml up -d openclaw-gateway openclaw-admin
      echo "  Waiting for health..."
      sleep 10
      for i in $(seq 1 12); do
        status=$(docker inspect openclaw-gateway --format '{{.State.Health.Status}}' 2>/dev/null)
        echo "  [$i] $status"
        [ "$status" = "healthy" ] && break
        sleep 5
      done
      echo "  Reinstalling packages..."
      /root/.openclaw-init-packages.sh 2>&1 || true
      NEW=$(docker inspect openclaw-gateway --format '{{.Image}}' 2>/dev/null | cut -c1-19)
      echo ""
      echo "  Done. Image: $NEW"
      ;;
    *) echo "  Cancelled." ;;
  esac
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
    3) backups_menu ;;
    4) restart_gateway ;;
    5) openai_login ;;
    6) update_openclaw ;;
    7) lazydocker_tui ;;
    8) cli_shell ;;
    s) echo "  Type 'exit' to return to menu."; bash ;;
    0) echo "  Goodbye."; exit 0 ;;
    *) echo "  Invalid choice." ;;
  esac
done
