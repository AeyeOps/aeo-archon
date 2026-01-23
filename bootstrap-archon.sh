#!/usr/bin/env bash
# Bootstrap Archon: install prerequisites, clone/update repo, and launch
# Usage:
#   sudo ./bootstrap-archon.sh [--repo <url>] [--branch <name>] [--dir <path>] [--no-start]
# Configuration (via .archon-state or environment - no fallbacks):
#   ARCHON_REPO_URL: REQUIRED - git repository URL (fails if not set)
#   ARCHON_BRANCH: branch name (default: main)
#   ARCHON_SRC_DIR: /opt/aeo/archon-src
# Logs: Automatically written to bootstrap.log in script directory

set -Eeuo pipefail

# Auto-logging: tee all output to bootstrap.log
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="$SCRIPT_DIR/bootstrap.log"
if [[ -z "${BOOTSTRAP_LOGGING:-}" ]]; then
  export BOOTSTRAP_LOGGING=1
  exec > >(tee -a "$LOG_FILE") 2>&1
  echo ""
  echo "=========================================="
  echo "Bootstrap started: $(date -Iseconds)"
  echo "=========================================="
fi

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

ok(){ echo -e "${GREEN}✓${NC} $1"; }
warn(){ echo -e "${YELLOW}!${NC} $1"; }
err(){ echo -e "${RED}✗${NC} $1"; }

# Configuration
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source shared Supabase utility functions if available
if [[ -f "$ROOT_DIR/lib/supabase-utils.sh" ]]; then
  source "$ROOT_DIR/lib/supabase-utils.sh"
fi

# Source state file if it exists (for ARCHON_REPO_URL, ARCHON_BRANCH, etc.)
if [[ -f "$ROOT_DIR/.archon-state" ]]; then
  source "$ROOT_DIR/.archon-state"
fi

# Version pinning (inherit from recovery lib or set default)
SUPABASE_VERSION="${SUPABASE_VERSION:-2.72.7}"

# Repo URL must be explicitly set in .archon-state or environment - no fallback
# When ready to switch to upstream: set ARCHON_REPO_URL=https://github.com/coleam00/archon.git
if [[ -z "${ARCHON_REPO_URL:-}" ]]; then
  err "ARCHON_REPO_URL not set. Configure in .archon-state or pass --repo <url>"
  err "Current fork: https://github.com/AeyeOps/archon.git"
  err "Upstream: https://github.com/coleam00/archon.git"
  exit 1
fi
ARCHON_BRANCH="${ARCHON_BRANCH:-main}"
ARCHON_SRC_DIR_DEFAULT="${ARCHON_SRC_DIR_OVERRIDE:-/opt/aeo/archon-src}"
ARCHON_SRC_DIR="$ARCHON_SRC_DIR_DEFAULT"
NODE_VERSION_REQUIRED="${NODE_VERSION_REQUIRED:-lts/*}"
DO_START=1
FRESH_INSTALL=0
CLEAN_IMAGES=0
NO_PORT_CHECK=0
STOP_ONLY=0

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) ARCHON_REPO_URL="${2:-}"; shift 2;;
    --branch) ARCHON_BRANCH="${2:-}"; shift 2;;
    --dir) ARCHON_SRC_DIR="${2:-}"; shift 2;;
    --no-start) DO_START=0; shift;;
    --stop) DO_START=0; STOP_ONLY=1; shift;;
    --fresh) FRESH_INSTALL=1; shift;;
    --clean-images) CLEAN_IMAGES=1; shift;;
    --no-port-check) NO_PORT_CHECK=1; shift;;
    -h|--help)
      cat <<EOF
Usage: $(basename "$0") [--repo <url>] [--branch <name>] [--dir <path>] [--no-start] [--stop] [--fresh] [--clean-images] [--no-port-check]

Bootstrap Archon by installing system prerequisites, cloning/updating repository, and launching.

Options:
  --repo <url>    Git repository URL (REQUIRED if not in .archon-state)
  --branch <name> Git branch name (default: main)
  --dir <path>    Installation directory (default: /opt/aeo/archon-src)
  --no-start      Skip launching after bootstrap
  --stop          Stop services and exit (no restart)
  --fresh         Perform fresh database install (wipe and reinstall schema)
  --clean-images  Remove old Supabase Docker images (useful when upgrading CLI version)
  --no-port-check Skip port binding verification (for debugging)
  -h, --help      Show this help message

Environment Variables:
  ARCHON_REPO_URL           Override default repository URL
  ARCHON_BRANCH             Override default branch
  ARCHON_SRC_DIR_OVERRIDE   Override default installation directory
  NODE_VERSION_REQUIRED     Override Node.js version (default: lts/*)
  SUPABASE_VERSION          Override Supabase CLI version (default: 2.72.7)
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
basic_packages=(curl ca-certificates gnupg lsb-release git jq)
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

# Note: Postgres shm_size is enforced post-provisioning via enforce_postgres_shm_size()
# in lib/supabase-utils.sh, called from archon-up.sh after Supabase start completes.

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
  su - "$CURRENT_USER" -c "bash -lc \"curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash\""
  ok "NVM installed"
else
  ok "NVM already installed"
fi

su - "$CURRENT_USER" -c "bash -lc \"export NVM_DIR='$NVM_DIR'; [ -s '$NVM_DIR/nvm.sh' ] && . '$NVM_DIR/nvm.sh' && nvm install '$NODE_VERSION_REQUIRED' >/dev/null\""
ok "Node.js $(su - "$CURRENT_USER" -c "bash -lc \"export NVM_DIR='$NVM_DIR'; [ -s '$NVM_DIR/nvm.sh' ] && . '$NVM_DIR/nvm.sh' && nvm current\"") ensured"

su - "$CURRENT_USER" -c "export NVM_DIR='$NVM_DIR'; [ -s \"$NVM_DIR/nvm.sh\" ] && . \"$NVM_DIR/nvm.sh\" && npx --yes supabase@$SUPABASE_VERSION --help >/dev/null"
ok "npx supabase@$SUPABASE_VERSION available"

# ============================================================================
# PHASE 1.5: Stop Running Services (if any)
# ============================================================================

echo ""
echo "==> Phase 1.5: Stopping running services"

# Use stop_all_services from lib/supabase-utils.sh
su - "$CURRENT_USER" -c "source '$ROOT_DIR/lib/supabase-utils.sh' && stop_all_services '$ARCHON_SRC_DIR' '$ROOT_DIR/supabase'"

# Exit early if --stop flag was passed
if [[ $STOP_ONLY -eq 1 ]]; then
  ok "Services stopped. Exiting (--stop flag)."
  exit 0
fi

# Clean old Supabase images if requested (prevents version drift issues)
if [[ $CLEAN_IMAGES -eq 1 ]]; then
  echo "Cleaning old Supabase Docker images..."
  if type -t cleanup_old_supabase_images >/dev/null 2>&1; then
    cleanup_old_supabase_images
  else
    # Inline cleanup if function not available
    docker image prune -f 2>/dev/null || true
    docker images --format '{{.Repository}}:{{.Tag}}' | grep -E 'supabase/' | while read img; do
      docker rmi "$img" 2>/dev/null || true
    done
  fi
  ok "Old Supabase images cleaned"
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
chmod +x "$ROOT_DIR/archon-up.sh" 2>/dev/null || true

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
  [[ $FRESH_INSTALL -eq 1 ]] && ARCHON_UP_ARGS="$ARCHON_UP_ARGS --fresh"
  [[ $NO_PORT_CHECK -eq 1 ]] && ARCHON_UP_ARGS="$ARCHON_UP_ARGS --no-port-check"
  su - "$CURRENT_USER" -c "export ARCHON_SRC_DIR_OVERRIDE='$ARCHON_SRC_DIR'; cd '$ROOT_DIR' && bash ./archon-up.sh $ARCHON_UP_ARGS"
else
  echo ""
  FRESH_MSG=""
  [[ $FRESH_INSTALL -eq 1 ]] && FRESH_MSG=" --fresh"
  ok "Bootstrap complete. To start: (cd $ROOT_DIR && bash ./archon-up.sh$FRESH_MSG)"
fi

echo ""
echo "=========================================="
echo "Bootstrap finished: $(date -Iseconds)"
echo "Log: $LOG_FILE"
echo "=========================================="
