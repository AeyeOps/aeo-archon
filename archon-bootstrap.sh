#!/usr/bin/env bash
# Bootstrap script for setting up prerequisites and launching Archon stack idempotently.

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

ok(){ echo -e "${GREEN}✓${NC} $1"; }
warn(){ echo -e "${YELLOW}!${NC} $1"; }
err(){ echo -e "${RED}✗${NC} $1"; }

require_root_context(){
  if [[ $EUID -ne 0 ]]; then
    if command -v sudo >/dev/null 2>&1; then
      warn "Elevated privileges required. Re-run with sudo: sudo ./archon-bootstrap.sh"
      exit 1
    else
      err "Script needs root privileges and sudo is unavailable. Run as root."
      exit 1
    fi
  fi
}

require_root_context

APT_STAMP="/var/lib/apt/periodic/update-success-stamp"
need_update=0
if [[ ! -f "$APT_STAMP" ]]; then
  need_update=1
else
  last_update=$(stat -c %Y "$APT_STAMP" 2>/dev/null || echo 0)
  now=$(date +%s)
  if (( now - last_update > 86400 )); then
    need_update=1
  fi
fi

if [[ $need_update -eq 1 ]]; then
  apt-get update -y
fi

basic_packages=(curl ca-certificates gnupg lsb-release)
missing_basic=()
for pkg in "${basic_packages[@]}"; do
  if ! dpkg -s "$pkg" >/dev/null 2>&1; then
    missing_basic+=("$pkg")
  fi

done
if [[ ${#missing_basic[@]} -gt 0 ]]; then
  apt-get install -y "${missing_basic[@]}"
fi

if ! command -v docker >/dev/null 2>&1; then
  curl -fsSL https://get.docker.com | sh
  ok "Docker Engine installed"
else
  ok "Docker already installed"
fi

if ! command -v docker >/dev/null 2>&1; then
  err "Docker installation failed."; exit 1
fi

if ! docker info >/dev/null 2>&1; then
  systemctl enable docker >/dev/null 2>&1 || true
  systemctl start docker
  sleep 2
fi

docker info >/dev/null 2>&1 && ok "Docker daemon active" || { err "Docker daemon not running"; exit 1; }

if ! docker compose version >/dev/null 2>&1; then
  warn "docker compose plugin missing; installing"
  apt-get install -y docker-compose-plugin
fi

docker compose version >/dev/null 2>&1 && ok "docker compose plugin available"

CURRENT_USER=${SUDO_USER:-root}
if [[ "$CURRENT_USER" != "root" ]]; then
  if ! id -nG "$CURRENT_USER" | grep -qw docker; then
    warn "Adding $CURRENT_USER to docker group"
    usermod -aG docker "$CURRENT_USER"
    warn "User added to docker group. Log out/in to apply or run 'newgrp docker'."
  else
    ok "User $CURRENT_USER already in docker group"
  fi
fi

NODE_VERSION_REQUIRED="${NODE_VERSION_REQUIRED:-lts/*}"
if [[ "$CURRENT_USER" == "root" ]]; then
  USER_HOME="/root"
else
  USER_HOME=$(eval echo "~$CURRENT_USER")
fi
NVM_DIR="$USER_HOME/.nvm"

if [[ ! -d "$NVM_DIR" ]]; then
  su - "$CURRENT_USER" -c "curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash"
  ok "NVM installed"
else
  ok "NVM already installed"
fi

su - "$CURRENT_USER" -c "export NVM_DIR='$NVM_DIR'; [ -s \"$NVM_DIR/nvm.sh\" ] && . \"$NVM_DIR/nvm.sh\" && nvm install $NODE_VERSION_REQUIRED > /dev/null"
ok "Node.js $(su - "$CURRENT_USER" -c "export NVM_DIR='$NVM_DIR'; [ -s \"$NVM_DIR/nvm.sh\" ] && . \"$NVM_DIR/nvm.sh\" && nvm current") ensured"

su - "$CURRENT_USER" -c "export NVM_DIR='$NVM_DIR'; [ -s \"$NVM_DIR/nvm.sh\" ] && . \"$NVM_DIR/nvm.sh\" && npx --yes supabase@latest --help >/dev/null"
ok "npx supabase@latest available"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
su - "$CURRENT_USER" -c "cd '$SCRIPT_DIR' && ./archon-up.sh"
