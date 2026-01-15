#!/usr/bin/env bash
# Supabase recovery and cleanup functions
# Source this file from other scripts for shared functionality

# Auto-detect ROOT_DIR if not set
ROOT_DIR="${ROOT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

# Colors (inherit from parent or define)
RED="${RED:-\033[0;31m}"
GREEN="${GREEN:-\033[0;32m}"
YELLOW="${YELLOW:-\033[1;33m}"
NC="${NC:-\033[0m}"

ok(){ echo -e "${GREEN}+${NC} $1"; }
warn(){ echo -e "${YELLOW}!${NC} $1"; }
err(){ echo -e "${RED}x${NC} $1"; }

# Version configuration
# Pin to a known-good version. Update when Archon upstream is tested with newer CLI.
# Check https://github.com/supabase/cli/releases for changelog
# Last verified: 2025-12-27 with Archon commit $(git -C /opt/aeo/archon-src rev-parse --short HEAD 2>/dev/null || echo 'unknown')
SUPABASE_VERSION="${SUPABASE_VERSION:-2.70.5}"

# Version lock file for tracking what version was used successfully
VERSION_LOCK_FILE="${ROOT_DIR:-.}/.supabase-version-lock"

# Record successful version (call after successful start)
record_supabase_version(){
  local archon_commit=$(git -C "${ARCHON_SRC_DIR:-/opt/aeo/archon-src}" rev-parse --short HEAD 2>/dev/null || echo 'unknown')
  {
    echo "# Supabase CLI version lock - auto-generated"
    echo "# Last successful start: $(date -Iseconds)"
    echo "SUPABASE_CLI_VERSION=$SUPABASE_VERSION"
    echo "ARCHON_COMMIT=$archon_commit"
    echo "STORAGE_MIGRATIONS=$(docker exec supabase_db_supabase psql -U postgres -t -c "SELECT COUNT(*) FROM storage.migrations;" 2>/dev/null | tr -d ' ')"
  } > "$VERSION_LOCK_FILE"
}

# Check if version changed since last successful run
check_version_drift(){
  if [[ -f "$VERSION_LOCK_FILE" ]]; then
    local locked_version=$(grep '^SUPABASE_CLI_VERSION=' "$VERSION_LOCK_FILE" | cut -d= -f2)
    if [[ -n "$locked_version" && "$locked_version" != "$SUPABASE_VERSION" ]]; then
      warn "Supabase CLI version changed: $locked_version -> $SUPABASE_VERSION"
      warn "Consider running with --clean-images to prevent migration conflicts"
      return 1
    fi
  fi
  return 0
}

# Supabase container names pattern
SUPABASE_CONTAINERS=(
  supabase_db_supabase
  supabase_storage_supabase
  supabase_auth_supabase
  supabase_kong_supabase
  supabase_studio_supabase
  supabase_realtime_supabase
  supabase_meta_supabase
  supabase_vector_supabase
  supabase_analytics_supabase
  supabase_edge_runtime_supabase
  supabase_imgproxy_supabase
  supabase_mailpit_supabase
)

# Force cleanup of all supabase containers
cleanup_stale_containers(){
  echo "Cleaning up stale Supabase containers..."
  # Force remove any supabase containers regardless of state
  docker ps -a --format '{{.Names}}' | grep -E '^supabase_' | xargs -r docker rm -f 2>/dev/null || true
  ok "Stale containers cleaned"
}

# Clean old supabase images to prevent version drift
# This forces the CLI to pull the correct version for the pinned CLI
cleanup_old_supabase_images(){
  echo "Cleaning old Supabase images (keeping only in-use)..."
  # Remove dangling images first
  docker image prune -f 2>/dev/null || true
  # Remove old storage-api images not currently in use
  docker images --format '{{.Repository}}:{{.Tag}} {{.ID}}' | grep 'supabase/storage-api' | while read img id; do
    # Only remove if not used by a running container
    if ! docker ps -q --filter "ancestor=$img" 2>/dev/null | grep -q .; then
      docker rmi "$img" 2>/dev/null || true
    fi
  done
  ok "Old images cleaned"
}

# Remove specific container if it exists
remove_container(){
  local container_name="$1"
  if docker ps -a --format '{{.Names}}' | grep -q "^${container_name}$"; then
    docker rm -f "$container_name" 2>/dev/null || true
  fi
}

# Pre-start cleanup - remove containers that may conflict
pre_start_cleanup(){
  echo "Performing pre-start cleanup..."
  for container in "${SUPABASE_CONTAINERS[@]}"; do
    remove_container "$container"
  done
  ok "Pre-start cleanup complete"
}

# Create backup before risky operations
auto_backup(){
  local reason="${1:-manual}"
  if docker ps --format '{{.Names}}' | grep -q supabase_db_supabase; then
    local backup_dir="$ROOT_DIR/backups"
    local backup_file="$backup_dir/supabase_backup_${reason}_$(date +%Y%m%d_%H%M%S).sql"
    mkdir -p "$backup_dir"
    echo "Creating backup: $backup_file"
    if docker exec supabase_db_supabase pg_dumpall -U postgres > "$backup_file" 2>/dev/null; then
      ok "Backup created: $(du -h "$backup_file" | cut -f1)"
    else
      warn "Backup failed (DB may not be ready)"
    fi
  else
    warn "Cannot backup - DB container not running"
  fi
}

# Reset storage migrations (fixes version drift)
recover_storage_migrations(){
  echo "Attempting storage migration recovery..."
  if docker ps --format '{{.Names}}' | grep -q supabase_db_supabase; then
    if docker exec supabase_db_supabase bash -c \
      'PGPASSWORD=postgres psql -U supabase_admin -d postgres -c "TRUNCATE storage.migrations RESTART IDENTITY CASCADE;"' 2>/dev/null; then
      ok "Storage migrations reset"
      return 0
    else
      err "Storage migration reset failed"
      return 1
    fi
  else
    err "Cannot recover - DB container not running"
    return 1
  fi
}

# Check if storage container is healthy
check_storage_health(){
  if docker ps --format '{{.Names}}' | grep -q supabase_storage_supabase; then
    local health=$(docker inspect supabase_storage_supabase --format '{{.State.Health.Status}}' 2>/dev/null)
    if [[ "$health" == "healthy" ]]; then
      return 0
    fi
  fi
  return 1
}

# Health check with automatic recovery
check_supabase_health_with_recovery(){
  local max_attempts="${1:-3}"
  local supabase_dir="${2:-$ROOT_DIR/supabase}"

  for i in $(seq 1 $max_attempts); do
    if check_storage_health; then
      ok "Storage container healthy"
      return 0
    fi

    warn "Storage unhealthy, attempt $i/$max_attempts"

    if [[ $i -lt $max_attempts ]]; then
      # Try recovery
      recover_storage_migrations

      # Restart supabase
      pushd "$supabase_dir" >/dev/null
      npx -y supabase@${SUPABASE_VERSION} stop 2>/dev/null || true
      npx -y supabase@${SUPABASE_VERSION} start
      popd >/dev/null

      # Wait for health check
      sleep 10
    fi
  done

  err "Storage container failed after $max_attempts attempts"
  return 1
}

# Track versions used for debugging
record_versions(){
  local state_file="$ROOT_DIR/.archon-state"
  local archon_src_dir="${ARCHON_SRC_DIR:-/opt/aeo/archon-src}"

  # Preserve ARCHON_REPO_URL from existing state (required, no fallback)
  local repo_url="${ARCHON_REPO_URL:-}"
  if [[ -z "$repo_url" && -f "$state_file" ]]; then
    repo_url=$(grep -E '^ARCHON_REPO_URL=' "$state_file" | sed 's/^ARCHON_REPO_URL=//' || true)
  fi

  {
    echo "# Archon state - generated $(date -Iseconds)"
    echo "SUPABASE_CLI_VERSION=$(npx -y supabase@${SUPABASE_VERSION} --version 2>/dev/null | head -1)"
    echo "STARTED_AT=$(date -Iseconds)"
    if [[ -d "$archon_src_dir/.git" ]]; then
      echo "ARCHON_COMMIT=$(git -C "$archon_src_dir" rev-parse HEAD 2>/dev/null)"
    fi
    [[ -n "$repo_url" ]] && echo "ARCHON_REPO_URL=$repo_url"
    if [[ -d "$archon_src_dir/.git" ]]; then
      echo "ARCHON_BRANCH=$(git -C "$archon_src_dir" rev-parse --abbrev-ref HEAD 2>/dev/null)"
    fi
    echo "STORAGE_MIGRATIONS=$(docker exec supabase_db_supabase psql -U postgres -t -c "SELECT COUNT(*) FROM storage.migrations;" 2>/dev/null | tr -d ' ')"
  } > "$state_file"

  ok "State recorded: $state_file"
}

# Check for potential issues before starting
preflight_checks(){
  local failures=0
  echo "Running preflight checks..."

  # Check Docker is running
  if ! docker info >/dev/null 2>&1; then
    err "Docker daemon not running"
    ((failures++))
  else
    ok "Docker daemon running"
  fi

  # Check for port conflicts (Supabase ports)
  local ports=(54321 54322 54323 54324)
  for port in "${ports[@]}"; do
    if command -v nc >/dev/null 2>&1; then
      if nc -z localhost "$port" 2>/dev/null; then
        # Check if it's a supabase container
        if ! docker ps --format '{{.Ports}}' | grep -q ":${port}->"; then
          warn "Port $port in use by non-Supabase process"
        fi
      fi
    elif timeout 1 bash -c "cat < /dev/null > /dev/tcp/localhost/$port" 2>/dev/null; then
      if ! docker ps --format '{{.Ports}}' | grep -q ":${port}->"; then
        warn "Port $port in use by non-Supabase process"
      fi
    fi
  done

  # Check disk space (need at least 5GB)
  local available_gb=$(df -BG "$ROOT_DIR" | tail -1 | awk '{print $4}' | tr -d 'G')
  if [[ "$available_gb" -lt 5 ]]; then
    err "Low disk space: ${available_gb}GB available (need 5GB+)"
    ((failures++))
  else
    ok "Disk space OK: ${available_gb}GB available"
  fi

  return $failures
}
