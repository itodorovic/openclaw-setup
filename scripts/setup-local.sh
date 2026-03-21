#!/usr/bin/env bash
# setup-local.sh — Prepare a local Ubuntu 24.04 server for OpenClaw.
#
# Run as ROOT on the target machine (e.g., ssh root@192.168.88.19 'bash -s' < setup-local.sh)
#
# This script is idempotent — safe to re-run. It combines:
#   - Base machine setup (SSH hardening, lid close, static IP, Docker, dev tools)
#   - OpenClaw layer (swap, ufw, packages, openclaw user)
#
# After this script completes, follow the README for:
#   1. Install OpenClaw via Ansible (as root)
#   2. Onboard (as openclaw user)
#   3. Run post-ansible.sh (as root)
#
# Usage:
#   bash setup-local.sh [options]
#
# Options (all optional — skipped if not provided):
#   --ssh-pubkey <path>       SSH public key to authorize (default: ~/.ssh/id_ed25519.pub from deployer)
#   --admin-user <user>       Existing admin user on the machine (default: itod)
#   --git-name <name>         Git user.name for admin user
#   --git-email <email>       Git user.email for admin user
#   --static-ip <ip/cidr>     Static IP in CIDR notation (e.g., 192.168.88.19/24)
#   --gateway <ip>            Default gateway (e.g., 192.168.88.1)
#   --wifi-iface <iface>      WiFi interface name (default: auto-detected)
#   --wifi-ssid <ssid>        WiFi SSID (skips static IP if not provided)
#   --wifi-password <pass>    WiFi password
#   --skip-base               Skip base machine setup (sections 1-7), only do OpenClaw layer
#   --skip-openclaw           Skip OpenClaw layer, only do base machine setup

set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────

ADMIN_USER="itod"
SSH_PUBKEY=""
GIT_NAME=""
GIT_EMAIL=""
STATIC_IP=""
GATEWAY="192.168.88.1"
WIFI_IFACE=""
WIFI_SSID=""
WIFI_PASSWORD=""
SKIP_BASE=false
SKIP_OPENCLAW=false
DNS_SERVERS="1.1.1.1 8.8.8.8"

# ── Parse args ────────────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ssh-pubkey)     SSH_PUBKEY="$2"; shift 2 ;;
    --admin-user)     ADMIN_USER="$2"; shift 2 ;;
    --git-name)       GIT_NAME="$2"; shift 2 ;;
    --git-email)      GIT_EMAIL="$2"; shift 2 ;;
    --static-ip)      STATIC_IP="$2"; shift 2 ;;
    --gateway)        GATEWAY="$2"; shift 2 ;;
    --wifi-iface)     WIFI_IFACE="$2"; shift 2 ;;
    --wifi-ssid)      WIFI_SSID="$2"; shift 2 ;;
    --wifi-password)  WIFI_PASSWORD="$2"; shift 2 ;;
    --skip-base)      SKIP_BASE=true; shift ;;
    --skip-openclaw)  SKIP_OPENCLAW=true; shift ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# ── Checks ────────────────────────────────────────────────────────────────────

if [[ "$EUID" -ne 0 ]]; then
  echo "Error: run this script as root"
  exit 1
fi

source /etc/os-release
if [[ "${VERSION_ID:-}" != "24.04" ]]; then
  echo "Warning: this script is designed for Ubuntu 24.04, detected $VERSION_ID"
fi

# Auto-detect WiFi interface if not provided
if [[ -z "$WIFI_IFACE" ]]; then
  WIFI_IFACE=$(iw dev 2>/dev/null | awk '/Interface/{print $2}' | head -1 || true)
fi

echo "============================================"
echo " OpenClaw Local Server Setup"
echo "============================================"
echo " Admin user:    $ADMIN_USER"
echo " WiFi iface:    ${WIFI_IFACE:-not detected}"
echo " Static IP:     ${STATIC_IP:-skip}"
echo " Skip base:     $SKIP_BASE"
echo " Skip openclaw: $SKIP_OPENCLAW"
echo "============================================"
echo ""

# ==============================================================================
# BASE MACHINE SETUP (Sections 1-7 from ubuntu-server-setup-guide.md)
# ==============================================================================

if [[ "$SKIP_BASE" == false ]]; then

  # ── Section 1: SSH Access ──────────────────────────────────────────────────

  echo "==> [1/7] SSH access and security..."

  # Passwordless sudo for admin user
  if [[ -f "/etc/sudoers.d/$ADMIN_USER" ]]; then
    echo "    Passwordless sudo already configured for $ADMIN_USER, skipping."
  else
    echo "$ADMIN_USER ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/$ADMIN_USER"
    chmod 440 "/etc/sudoers.d/$ADMIN_USER"
    echo "    Passwordless sudo configured for $ADMIN_USER."
  fi

  # Authorize SSH key for admin user if provided
  if [[ -n "$SSH_PUBKEY" && -f "$SSH_PUBKEY" ]]; then
    ADMIN_HOME=$(eval echo "~$ADMIN_USER")
    mkdir -p "$ADMIN_HOME/.ssh"
    if ! grep -qF "$(cat "$SSH_PUBKEY")" "$ADMIN_HOME/.ssh/authorized_keys" 2>/dev/null; then
      cat "$SSH_PUBKEY" >> "$ADMIN_HOME/.ssh/authorized_keys"
      echo "    SSH key added for $ADMIN_USER."
    else
      echo "    SSH key already present for $ADMIN_USER."
    fi
    chown -R "$ADMIN_USER:$ADMIN_USER" "$ADMIN_HOME/.ssh"
    chmod 700 "$ADMIN_HOME/.ssh"
    chmod 600 "$ADMIN_HOME/.ssh/authorized_keys"

    # Copy to root as well
    mkdir -p /root/.ssh
    cp "$ADMIN_HOME/.ssh/authorized_keys" /root/.ssh/authorized_keys
    chmod 700 /root/.ssh
    chmod 600 /root/.ssh/authorized_keys
    echo "    SSH key copied to root."
  fi

  # Disable password authentication
  sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
  if [[ -f /etc/ssh/sshd_config.d/50-cloud-init.conf ]]; then
    sed -i 's/^PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config.d/50-cloud-init.conf
  fi
  systemctl restart ssh
  echo "    SSH password authentication disabled."

  # ── Section 2: Prevent Lid Close from Suspending ───────────────────────────

  echo "==> [2/7] Lid close handling..."

  if grep -q "^HandleLidSwitch=ignore" /etc/systemd/logind.conf 2>/dev/null; then
    echo "    Already configured, skipping."
  else
    sed -i 's/^#HandleLidSwitch=suspend/HandleLidSwitch=ignore/' /etc/systemd/logind.conf
    sed -i 's/^#HandleLidSwitchExternalPower=suspend/HandleLidSwitchExternalPower=ignore/' /etc/systemd/logind.conf
    sed -i 's/^#HandleLidSwitchDocked=ignore/HandleLidSwitchDocked=ignore/' /etc/systemd/logind.conf
    systemctl restart systemd-logind
    echo "    Lid close set to ignore."
  fi

  # ── Section 3: Static IP Address ──────────────────────────────────────────

  echo "==> [3/7] Static IP..."

  if [[ -n "$STATIC_IP" && -n "$WIFI_SSID" && -n "$WIFI_IFACE" ]]; then
    cat > /etc/netplan/50-cloud-init.yaml <<NETPLAN
network:
  version: 2
  wifis:
    $WIFI_IFACE:
      dhcp4: false
      addresses:
        - $STATIC_IP
      routes:
        - to: default
          via: $GATEWAY
      nameservers:
        addresses:
          - ${DNS_SERVERS// /
          - }
      access-points:
        "$WIFI_SSID":
          auth:
            key-management: "psk"
            password: "$WIFI_PASSWORD"
NETPLAN
    netplan apply
    echo "    Static IP $STATIC_IP configured on $WIFI_IFACE."
  else
    echo "    Skipped (--static-ip, --wifi-ssid, or interface not provided)."
  fi

  # ── Section 4: Update System ──────────────────────────────────────────────

  echo "==> [4/7] System update..."
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq
  echo "    Done."

  # ── Section 5: Install Docker ─────────────────────────────────────────────

  echo "==> [5/7] Docker..."

  if command -v docker &>/dev/null; then
    echo "    Docker already installed ($(docker --version)), skipping."
  else
    # Remove conflicting packages
    for pkg in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do
      apt-get remove -y "$pkg" 2>/dev/null || true
    done

    # Add Docker repo
    apt-get install -y -qq ca-certificates curl
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    echo "Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc" > /etc/apt/sources.list.d/docker.sources
    apt-get update -qq

    # Install
    apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    systemctl enable docker containerd
    echo "    Docker installed."
  fi

  # Add admin user to docker group
  if id -nG "$ADMIN_USER" | grep -qw docker; then
    echo "    $ADMIN_USER already in docker group."
  else
    usermod -aG docker "$ADMIN_USER"
    echo "    $ADMIN_USER added to docker group."
  fi

  # ── Section 6: Development Tools ──────────────────────────────────────────

  echo "==> [6/7] Development tools..."

  # Build essentials
  apt-get install -y -qq build-essential

  # Node.js (via NodeSource)
  if command -v node &>/dev/null; then
    echo "    Node.js already installed ($(node --version)), skipping."
  else
    curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
    apt-get install -y -qq nodejs
    echo "    Node.js installed."
  fi

  # pnpm
  if command -v pnpm &>/dev/null; then
    echo "    pnpm already installed ($(pnpm --version)), skipping."
  else
    npm install -g pnpm
    echo "    pnpm installed."
  fi

  # Go
  if [[ -x /usr/local/go/bin/go ]]; then
    echo "    Go already installed ($(/usr/local/go/bin/go version)), skipping."
  else
    curl -fsSL https://go.dev/dl/go1.23.7.linux-amd64.tar.gz | tar -C /usr/local -xz
    echo 'export PATH=$PATH:/usr/local/go/bin' > /etc/profile.d/go.sh
    echo "    Go installed."
  fi

  # GitHub CLI
  if command -v gh &>/dev/null; then
    echo "    GitHub CLI already installed ($(gh --version | head -1)), skipping."
  else
    mkdir -p /etc/apt/keyrings
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | tee /etc/apt/keyrings/githubcli-archive-keyring.gpg > /dev/null
    chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | tee /etc/apt/sources.list.d/github-cli.list > /dev/null
    apt-get update -qq
    apt-get install -y -qq gh
    echo "    GitHub CLI installed."
  fi

  # Other tools
  apt-get install -y -qq unzip python3-pip btop
  echo "    Dev tools done."

  # ── Section 7: Git Config ─────────────────────────────────────────────────

  echo "==> [7/7] Git config..."

  if [[ -n "$GIT_NAME" && -n "$GIT_EMAIL" ]]; then
    su - "$ADMIN_USER" -c "git config --global user.name '$GIT_NAME'"
    su - "$ADMIN_USER" -c "git config --global user.email '$GIT_EMAIL'"
    echo "    Git configured for $ADMIN_USER ($GIT_NAME <$GIT_EMAIL>)."
  else
    echo "    Skipped (--git-name and --git-email not provided)."
  fi

  echo ""
  echo ">>> Base machine setup complete."
  echo ">>> NOTE: Run 'gh auth login' and 'docker login' as $ADMIN_USER interactively."
  echo ""

fi # SKIP_BASE

# ==============================================================================
# OPENCLAW LAYER (equivalent to cloud-init.yaml)
# ==============================================================================

if [[ "$SKIP_OPENCLAW" == false ]]; then

  echo "==> [OC 1/6] OpenClaw packages..."
  apt-get install -y -qq \
    curl git jq ufw unattended-upgrades \
    ansible python3 python-is-python3 \
    tmux ffmpeg
  echo "    Done."

  # ── Swap ───────────────────────────────────────────────────────────────────

  echo "==> [OC 2/6] Swap (4 GB)..."

  if swapon --show | grep -q /swapfile; then
    echo "    Swap already active, skipping."
  else
    if [[ ! -f /swapfile ]]; then
      fallocate -l 4G /swapfile
      chmod 600 /swapfile
      mkswap /swapfile
    fi
    swapon /swapfile
    if ! grep -q '/swapfile' /etc/fstab; then
      echo '/swapfile none swap sw 0 0' >> /etc/fstab
    fi
    echo "    4 GB swap enabled."
  fi

  # ── UFW Firewall ──────────────────────────────────────────────────────────

  echo "==> [OC 3/6] UFW firewall..."

  if ufw status | grep -q "Status: active"; then
    echo "    UFW already active, skipping."
  else
    ufw default deny incoming
    ufw default allow outgoing
    ufw allow 22/tcp
    ufw --force enable
    echo "    UFW enabled (SSH only)."
  fi

  # ── Auto-upgrades + needrestart ────────────────────────────────────────────

  echo "==> [OC 4/6] Unattended upgrades..."

  cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF

  mkdir -p /etc/needrestart/conf.d
  cat > /etc/needrestart/conf.d/no-prompt.conf <<'EOF'
$nrconf{restart} = 'a';
EOF
  echo "    Done."

  # ── Create openclaw user ──────────────────────────────────────────────────

  echo "==> [OC 5/6] Creating openclaw user..."

  if id openclaw &>/dev/null; then
    echo "    User openclaw already exists, skipping creation."
  else
    useradd -m -s /bin/bash openclaw
    echo "    User openclaw created."
  fi

  # Sudo
  echo 'openclaw ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/openclaw
  chmod 440 /etc/sudoers.d/openclaw

  # SSH access — copy admin user's authorized_keys
  ADMIN_HOME=$(eval echo "~$ADMIN_USER")
  mkdir -p /home/openclaw/.ssh
  if [[ -f "$ADMIN_HOME/.ssh/authorized_keys" ]]; then
    cp "$ADMIN_HOME/.ssh/authorized_keys" /home/openclaw/.ssh/authorized_keys
  fi
  chown -R openclaw:openclaw /home/openclaw/.ssh
  chmod 700 /home/openclaw/.ssh
  chmod 600 /home/openclaw/.ssh/authorized_keys 2>/dev/null || true

  # Add openclaw to docker group
  usermod -aG docker openclaw 2>/dev/null || true

  # Enable lingering (systemd user services survive logout)
  loginctl enable-linger openclaw
  echo "    openclaw user configured (sudo, SSH, docker, linger)."

  # ── Git config for openclaw ───────────────────────────────────────────────

  echo "==> [OC 6/6] Git config for openclaw..."

  if [[ -n "$GIT_NAME" && -n "$GIT_EMAIL" ]]; then
    su - openclaw -c "git config --global user.name '$GIT_NAME'"
    su - openclaw -c "git config --global user.email '$GIT_EMAIL'"
    echo "    Git configured for openclaw."
  else
    echo "    Skipped (--git-name and --git-email not provided)."
  fi

  echo ""
  echo ">>> OpenClaw layer complete."
  echo ""

fi # SKIP_OPENCLAW

# ==============================================================================
# Summary
# ==============================================================================

echo "============================================"
echo " Setup complete!"
echo "============================================"
echo ""
echo " Next steps:"
echo ""
echo "   1. If not done: run 'gh auth login' and 'docker login' as $ADMIN_USER"
echo ""
echo "   2. Install OpenClaw (as root):"
echo "      curl -fsSL https://raw.githubusercontent.com/openclaw/openclaw-ansible/main/install.sh | bash"
echo ""
echo "   3. Onboard (SSH as openclaw — never sudo su):"
echo "      ssh openclaw@<this-machine>"
echo "      tmux"
echo "      openclaw onboard --install-daemon"
echo ""
echo "   4. Run post-ansible.sh (as root):"
echo "      bash scripts/post-ansible.sh <tailscale-authkey>"
echo ""
echo "============================================"
