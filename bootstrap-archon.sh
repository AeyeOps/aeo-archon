#!/usr/bin/env bash
# Bootstrap Archon: install prerequisites, clone/update repo, and launch
# Usage:
#   sudo ./bootstrap-archon.sh [--repo <url>] [--branch <name>] [--dir <path>] [--no-start]
# Defaults:
#   repo: https://github.com/coleam00/archon.git
#   branch: aeyeops/custom-main
#   dir: /opt/aeo/archon-src

set -Eeuo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

ok(){ echo -e "${GREEN}✓${NC} $1"; }
warn(){ echo -e "${YELLOW}!${NC} $1"; }
err(){ echo -e "${RED}✗${NC} $1"; }

# Configuration
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARCHON_REPO_URL="${ARCHON_REPO_URL:-https://github.com/coleam00/archon.git}"
ARCHON_BRANCH="${ARCHON_BRANCH:-aeyeops/custom-main}"
ARCHON_SRC_DIR_DEFAULT="${ARCHON_SRC_DIR_OVERRIDE:-/opt/aeo/archon-src}"
ARCHON_SRC_DIR="$ARCHON_SRC_DIR_DEFAULT"
NODE_VERSION_REQUIRED="${NODE_VERSION_REQUIRED:-lts/*}"
DO_START=1
FRESH_INSTALL=0

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) ARCHON_REPO_URL="${2:-}"; shift 2;;
    --branch) ARCHON_BRANCH="${2:-}"; shift 2;;
    --dir) ARCHON_SRC_DIR="${2:-}"; shift 2;;
    --no-start) DO_START=0; shift;;
    --fresh) FRESH_INSTALL=1; shift;;
    -h|--help)
      cat <<EOF
Usage: $(basename "$0") [--repo <url>] [--branch <name>] [--dir <path>] [--no-start] [--fresh]

Bootstrap Archon by installing system prerequisites, cloning/updating repository, and launching.

Options:
  --repo <url>    Git repository URL (default: https://github.com/coleam00/archon.git)
  --branch <name> Git branch name (default: aeyeops/custom-main)
  --dir <path>    Installation directory (default: /opt/aeo/archon-src)
  --no-start      Skip launching after bootstrap
  --fresh         Perform fresh database install (wipe and reinstall schema)
  -h, --help      Show this help message

Environment Variables:
  ARCHON_REPO_URL           Override default repository URL
  ARCHON_BRANCH             Override default branch
  ARCHON_SRC_DIR_OVERRIDE   Override default installation directory
  NODE_VERSION_REQUIRED     Override Node.js version (default: lts/*)
EOF
      exit 0;;
    *) err "Unknown option: $1"; exit 1;;
  esac
done

# ============================================================================
# PHASE 1: System Prerequisites (requires root)
# ============================================================================

echo "==> Phase 1: Installing system prerequisites"

require_root_context(){
  if [[ $EUID -ne 0 ]]; then
    if command -v sudo >/dev/null 2>&1; then
      warn "Elevated privileges required. Re-run with sudo: sudo ./bootstrap-archon.sh"
      exit 1
    else
      err "Script needs root privileges and sudo is unavailable. Run as root."
      exit 1
    fi
  fi
}

require_root_context

# Update apt if needed (idempotent check)
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

# Install basic packages
basic_packages=(curl ca-certificates gnupg lsb-release git)
missing_basic=()
for pkg in "${basic_packages[@]}"; do
  if ! dpkg -s "$pkg" >/dev/null 2>&1; then
    missing_basic+=("$pkg")
  fi
done
if [[ ${#missing_basic[@]} -gt 0 ]]; then
  apt-get install -y "${missing_basic[@]}"
fi

command -v git >/dev/null 2>&1 || { err "git not found after installation"; exit 1; }

# Install Docker
if ! command -v docker >/dev/null 2>&1; then
  curl -fsSL https://get.docker.com | sh
  ok "Docker Engine installed"
else
  ok "Docker already installed"
fi

if ! command -v docker >/dev/null 2>&1; then
  err "Docker installation failed."; exit 1
fi

# Start Docker daemon if needed
if ! docker info >/dev/null 2>&1; then
  systemctl enable docker >/dev/null 2>&1 || true
  systemctl start docker
  sleep 2
fi

docker info >/dev/null 2>&1 && ok "Docker daemon active" || { err "Docker daemon not running"; exit 1; }

# Install docker compose plugin
if ! docker compose version >/dev/null 2>&1; then
  warn "docker compose plugin missing; installing"
  apt-get install -y docker-compose-plugin
fi

docker compose version >/dev/null 2>&1 && ok "docker compose plugin available"

# Add user to docker group
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

# Setup NVM and Node.js
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

# ============================================================================
# PHASE 2: Repository Setup (can be done as non-root)
# ============================================================================

echo ""
echo "==> Phase 2: Setting up Archon repository"

# Clone or update repository
if [[ -d "$ARCHON_SRC_DIR/.git" ]]; then
  echo "Repository exists at $ARCHON_SRC_DIR; ensuring branch $ARCHON_BRANCH..."
  CURRENT_BRANCH=$(git -C "$ARCHON_SRC_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
  if [[ "$CURRENT_BRANCH" != "$ARCHON_BRANCH" ]]; then
    git -C "$ARCHON_SRC_DIR" fetch --all --prune || warn "Fetch failed; continuing with existing refs"
    if ! git -C "$ARCHON_SRC_DIR" checkout "$ARCHON_BRANCH"; then
      err "Unable to checkout $ARCHON_BRANCH"; exit 1
    fi
    CURRENT_BRANCH="$ARCHON_BRANCH"
  fi
  if git -C "$ARCHON_SRC_DIR" diff --quiet --ignore-submodules && [[ -z "$(git -C "$ARCHON_SRC_DIR" status --porcelain)" ]]; then
    git -C "$ARCHON_SRC_DIR" fetch origin "$ARCHON_BRANCH" --prune || warn "Origin fetch failed"
    git -C "$ARCHON_SRC_DIR" pull --ff-only origin "$ARCHON_BRANCH" || warn "Fast-forward pull skipped (non-FF or network issue)"
    ok "Repository updated"
  else
    warn "Local changes detected in $ARCHON_SRC_DIR; skipping auto-update"
  fi
else
  echo "Cloning $ARCHON_REPO_URL into $ARCHON_SRC_DIR..."
  git clone --depth 1 --branch "$ARCHON_BRANCH" "$ARCHON_REPO_URL" "$ARCHON_SRC_DIR"
  ok "Repository cloned"
fi

# Prepare .env in repository
REPO_ENV="$ARCHON_SRC_DIR/.env"
if [[ ! -f "$REPO_ENV" ]]; then
  if [[ -f "$ARCHON_SRC_DIR/.env.example" ]]; then
    cp "$ARCHON_SRC_DIR/.env.example" "$REPO_ENV"
    ok ".env created from .env.example"
  elif [[ -f "$ARCHON_SRC_DIR/.env.sample" ]]; then
    cp "$ARCHON_SRC_DIR/.env.sample" "$REPO_ENV"
    ok ".env created from .env.sample"
  else
    echo "# Generated by bootstrap-archon.sh" > "$REPO_ENV"
    ok ".env initialized"
  fi
fi

# Ensure launcher script is executable
chmod +x "$ARCHON_SRC_DIR/archon-up.sh" 2>/dev/null || true

# ============================================================================
# PHASE 3: Launch Archon Stack
# ============================================================================

if [[ $DO_START -eq 1 ]]; then
  echo ""
  echo "==> Phase 3: Starting Archon stack"
  ARCHON_UP_ARGS=""
  [[ $FRESH_INSTALL -eq 1 ]] && ARCHON_UP_ARGS="--fresh"
  su - "$CURRENT_USER" -c "cd '$ROOT_DIR' && bash ./archon-up.sh $ARCHON_UP_ARGS"
else
  echo ""
  FRESH_MSG=""
  [[ $FRESH_INSTALL -eq 1 ]] && FRESH_MSG=" --fresh"
  ok "Bootstrap complete. To start: (cd $ROOT_DIR && bash ./archon-up.sh$FRESH_MSG)"
fi
