#!/usr/bin/env bash
# Bootstrap Archon: install prerequisites, clone/update repo, and launch
# Usage:
#   sudo ./bootstrap-archon.sh [--repo <url>] [--branch <name>] [--dir <path>] [--no-start]
# Defaults:
#   repo: https://github.com/aeyeops/archon.git
#   branch: aeyeops-custom-main
#   dir: ./archon-src (relative to script location)

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
ARCHON_REPO_URL="${ARCHON_REPO_URL:-https://github.com/aeyeops/archon.git}"
ARCHON_BRANCH="${ARCHON_BRANCH:-aeyeops-custom-main}"
ARCHON_SRC_DIR_DEFAULT="${ARCHON_SRC_DIR_OVERRIDE:-$ROOT_DIR/archon-src}"
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
  --repo <url>    Git repository URL (default: https://github.com/aeyeops/archon.git)
  --branch <name> Git branch name (default: aeyeops-custom-main)
  --dir <path>    Installation directory (default: ./archon-src)
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
# PHASE 1.5: Stop Running Services (if any)
# ============================================================================

echo ""
echo "==> Phase 1.5: Stopping running services"

if [[ -x "$ROOT_DIR/stop-archon.sh" ]]; then
  # Run as CURRENT_USER so NVM/npx is available for Supabase CLI
  # Export ARCHON_SRC_DIR so stop script uses correct path
  su - "$CURRENT_USER" -c "export ARCHON_SRC_DIR_OVERRIDE='$ARCHON_SRC_DIR'; cd '$ROOT_DIR' && bash ./stop-archon.sh"
else
  warn "stop-archon.sh not found; skipping service shutdown"
fi

# ============================================================================
# PHASE 1.6: Sync Fork with Upstream (if repo exists)
# ============================================================================

echo ""
echo "==> Phase 1.6: Syncing fork with upstream"

if [[ -d "$ARCHON_SRC_DIR/.git" ]]; then
  # Clean root-owned untracked files from previous Docker runs
  # These prevent git operations like checkout and pull
  CLEANUP_DIRS=(
    ".claude"
    "archon-example-workflow"
    "archon-ui-main/src/features/agent-work-orders"
    "archon-ui-main/src/features/progress"
    "archon-ui-main/src/features/projects"
    "archon-ui-main/src/features/style-guide"
    "python/.claude"
    "python/src/agent_work_orders"
    "python/tests/agent_work_orders"
    "PRPs"
  )

  for dir in "${CLEANUP_DIRS[@]}"; do
    target="$ARCHON_SRC_DIR/$dir"
    if [[ -d "$target" ]]; then
      rm -rf "$target" 2>/dev/null || true
    fi
  done

  # Restore any deleted tracked files
  git -C "$ARCHON_SRC_DIR" checkout -- . 2>/dev/null || true

  # Run sync-main.sh if available to sync fork with upstream
  SYNC_SCRIPT="$ROOT_DIR/scripts/sync-main.sh"
  if [[ -x "$SYNC_SCRIPT" ]]; then
    echo "Running sync-main.sh to sync fork with upstream..."
    if su - "$CURRENT_USER" -c "ARCHON_SRC_DIR='$ARCHON_SRC_DIR' bash '$SYNC_SCRIPT'"; then
      ok "Fork synced with upstream"
    else
      warn "Fork sync failed - continuing with existing code"
      warn "You may need to run: $SYNC_SCRIPT"
    fi
  else
    warn "sync-main.sh not found at $SYNC_SCRIPT; skipping upstream sync"
  fi
else
  ok "Repository not yet cloned; sync will happen after clone"
fi

# ============================================================================
# PHASE 2: Repository Setup (can be done as non-root)
# ============================================================================

echo ""
echo "==> Phase 2: Setting up Archon repository"

# Clone or update repository
if [[ -d "$ARCHON_SRC_DIR/.git" ]]; then
  echo "Repository exists at $ARCHON_SRC_DIR; ensuring branch $ARCHON_BRANCH..."

  # Ensure origin points to the correct repository (fork, not upstream)
  CURRENT_ORIGIN=$(git -C "$ARCHON_SRC_DIR" remote get-url origin 2>/dev/null || true)
  if [[ -n "$CURRENT_ORIGIN" && "$CURRENT_ORIGIN" != "$ARCHON_REPO_URL" ]]; then
    warn "Origin points to $CURRENT_ORIGIN (expected $ARCHON_REPO_URL)"
    git -C "$ARCHON_SRC_DIR" remote set-url origin "$ARCHON_REPO_URL"
    ok "Fixed origin remote URL"
  fi

  CURRENT_BRANCH=$(git -C "$ARCHON_SRC_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
  if [[ "$CURRENT_BRANCH" != "$ARCHON_BRANCH" ]]; then
    git -C "$ARCHON_SRC_DIR" fetch --all --prune || warn "Fetch failed; continuing with existing refs"
    # Clean untracked files that may conflict with branch checkout
    git -C "$ARCHON_SRC_DIR" clean -fd 2>/dev/null || true
    if ! git -C "$ARCHON_SRC_DIR" checkout "$ARCHON_BRANCH"; then
      err "Unable to checkout $ARCHON_BRANCH"; exit 1
    fi
    CURRENT_BRANCH="$ARCHON_BRANCH"
  fi
  if git -C "$ARCHON_SRC_DIR" diff --quiet --ignore-submodules && [[ -z "$(git -C "$ARCHON_SRC_DIR" status --porcelain)" ]]; then
    git -C "$ARCHON_SRC_DIR" fetch origin "$ARCHON_BRANCH" --prune || { err "Origin fetch failed - check network"; exit 1; }
    if ! git -C "$ARCHON_SRC_DIR" pull --ff-only origin "$ARCHON_BRANCH"; then
      err "Fast-forward pull failed. Upstream may have rebased."
      err "To force update: cd $ARCHON_SRC_DIR && git reset --hard origin/$ARCHON_BRANCH"
      exit 1
    fi
    ok "Repository updated"
  else
    warn "Local changes detected in $ARCHON_SRC_DIR; skipping auto-update"
    warn "To force update: cd $ARCHON_SRC_DIR && git stash && git pull"
  fi
else
  echo "Cloning $ARCHON_REPO_URL into $ARCHON_SRC_DIR..."
  git clone --depth 1 --branch "$ARCHON_BRANCH" "$ARCHON_REPO_URL" "$ARCHON_SRC_DIR"
  ok "Repository cloned"
fi

# Ensure upstream remote exists for sync-main.sh workflow
# (origin = fork, upstream = coleam00/archon for syncing)
UPSTREAM_URL="https://github.com/coleam00/archon.git"
if [[ -d "$ARCHON_SRC_DIR/.git" ]]; then
  CURRENT_UPSTREAM=$(git -C "$ARCHON_SRC_DIR" remote get-url upstream 2>/dev/null || true)
  if [[ -z "$CURRENT_UPSTREAM" ]]; then
    git -C "$ARCHON_SRC_DIR" remote add upstream "$UPSTREAM_URL"
    ok "Added upstream remote (coleam00/archon)"
  elif [[ "$CURRENT_UPSTREAM" != "$UPSTREAM_URL" ]]; then
    git -C "$ARCHON_SRC_DIR" remote set-url upstream "$UPSTREAM_URL"
    ok "Fixed upstream remote URL"
  fi
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

# Ensure launcher scripts are executable
chmod +x "$ROOT_DIR/archon-up.sh" "$ROOT_DIR/stop-archon.sh" "$ROOT_DIR/restart-archon-services.sh" 2>/dev/null || true

# Restore user ownership after root git operations
if [[ "$CURRENT_USER" != "root" ]]; then
  chown -R "$CURRENT_USER:$CURRENT_USER" "$ARCHON_SRC_DIR"
fi

# ============================================================================
# PHASE 3: Launch Archon Stack
# ============================================================================

if [[ $DO_START -eq 1 ]]; then
  echo ""
  echo "==> Phase 3: Starting Archon stack"
  ARCHON_UP_ARGS=""
  [[ $FRESH_INSTALL -eq 1 ]] && ARCHON_UP_ARGS="--fresh"
  su - "$CURRENT_USER" -c "export ARCHON_SRC_DIR_OVERRIDE='$ARCHON_SRC_DIR'; cd '$ROOT_DIR' && bash ./archon-up.sh $ARCHON_UP_ARGS"
else
  echo ""
  FRESH_MSG=""
  [[ $FRESH_INSTALL -eq 1 ]] && FRESH_MSG=" --fresh"
  ok "Bootstrap complete. To start: (cd $ROOT_DIR && bash ./archon-up.sh$FRESH_MSG)"
fi
