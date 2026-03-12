#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 3 ]]; then
  echo "Usage: $0 <server_ip_or_host> <dashboard_domain> <status_domain>"
  exit 1
fi

SERVER="$1"
DASHBOARD_DOMAIN="$2"
STATUS_DOMAIN="$3"

echo "== Remote container status (${SERVER}) =="
ssh -o BatchMode=yes "root@${SERVER}" 'cd /root/openclaw-setup && docker compose ps'

echo
echo "== Dashboard edge response (${DASHBOARD_DOMAIN}) =="
curl -I -sS "https://${DASHBOARD_DOMAIN}" | head -n 8

echo
echo "== Status edge response (${STATUS_DOMAIN}) =="
curl -I -sS "https://${STATUS_DOMAIN}" | head -n 8

echo
echo "Verification completed."
