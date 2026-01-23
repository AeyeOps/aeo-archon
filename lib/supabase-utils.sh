#!/usr/bin/env bash
# Supabase utility functions for lifecycle management, health checks, and configuration
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
# Last verified: 2026-01-16 with Archon commit $(git -C /opt/aeo/archon-src rev-parse --short HEAD 2>/dev/null || echo 'unknown')
SUPABASE_VERSION="${SUPABASE_VERSION:-2.72.7}"

# Parse port from TOML section
# Usage: get_toml_port "config.toml" "api"
get_toml_port(){
  local config_file="$1" section="$2"
  [[ -f "$config_file" ]] || return 1
  awk -v section="$section" '
    /^\[/ { in_section = 0 }
    $0 ~ "^\\[" section "\\]" { in_section = 1; next }
    in_section && /^port[[:space:]]*=/ { gsub(/[^0-9]/, ""); print; exit }
  ' "$config_file"
}

# Load Supabase ports from config.toml with fallbacks
load_supabase_ports(){
  local config="${SUPABASE_CONFIG:-$ROOT_DIR/supabase/supabase/config.toml}"
  SUPABASE_PORT_API=$(get_toml_port "$config" api) || SUPABASE_PORT_API=54321
  SUPABASE_PORT_DB=$(get_toml_port "$config" db) || SUPABASE_PORT_DB=54322
  SUPABASE_PORT_STUDIO=$(get_toml_port "$config" studio) || SUPABASE_PORT_STUDIO=54323
  SUPABASE_PORT_INBUCKET=$(get_toml_port "$config" inbucket) || SUPABASE_PORT_INBUCKET=54324
  SUPABASE_PORT_ANALYTICS=$(get_toml_port "$config" analytics) || SUPABASE_PORT_ANALYTICS=54327
}

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

# Build port verification array from config.toml
# Internal ports are fixed by Supabase docker images
build_expected_ports(){
  load_supabase_ports
  SUPABASE_EXPECTED_PORTS=(
    "${SUPABASE_PORT_API}:8000:supabase_kong_supabase"
    "${SUPABASE_PORT_DB}:5432:supabase_db_supabase"
    "${SUPABASE_PORT_STUDIO}:3000:supabase_studio_supabase"
    "${SUPABASE_PORT_INBUCKET}:8025:supabase_inbucket_supabase"
    "${SUPABASE_PORT_ANALYTICS}:4000:supabase_analytics_supabase"
  )
}

# Initialize on source (replaces old hardcoded array)
build_expected_ports

# Verify ALL Supabase ports are properly bound to host
# Returns 0 if all ports bound, 1 if any missing
# This detects when containers were restarted by Docker (not Supabase CLI)
# which causes port bindings to be lost
verify_supabase_port_bindings(){
  local failures=0
  local checked=0

  for spec in "${SUPABASE_EXPECTED_PORTS[@]}"; do
    local host_port="${spec%%:*}"
    local rest="${spec#*:}"
    local container_port="${rest%%:*}"
    local container_name="${rest#*:}"

    # Handle mailpit/inbucket naming variation
    local actual_container="$container_name"
    if [[ "$container_name" == "supabase_inbucket_supabase" ]]; then
      # Check both possible names
      if docker ps --format '{{.Names}}' | grep -q "^supabase_mailpit_supabase$"; then
        actual_container="supabase_mailpit_supabase"
      fi
    fi

    # Skip if container doesn't exist (optional services)
    if ! docker ps --format '{{.Names}}' | grep -q "^${actual_container}$"; then
      continue
    fi

    ((checked++))
    local bound=$(docker port "$actual_container" "$container_port" 2>/dev/null)

    if [[ -z "$bound" ]]; then
      err "Port binding missing: $actual_container:$container_port (expected host:$host_port)"
      ((failures++))
    elif [[ "$bound" != *":$host_port" ]]; then
      warn "Port mismatch: $actual_container bound to $bound (expected :$host_port)"
      ((failures++))
    fi
  done

  if [[ $failures -gt 0 ]]; then
    err "$failures of $checked port bindings missing or incorrect"
    warn "Containers may have been restarted by Docker outside of Supabase CLI"
    return 1
  fi

  if [[ $checked -gt 0 ]]; then
    ok "All $checked Supabase port bindings verified"
  fi
  return 0
}

# Force cleanup of all supabase containers
cleanup_stale_containers(){
  echo "Cleaning up stale Supabase containers..."
  # Force remove any supabase containers regardless of state
  docker ps -a --format '{{.Names}}' | grep -E '^supabase_' | xargs -r docker rm -f 2>/dev/null || true
  ok "Stale containers cleaned"
}

# Stop all Archon and Supabase services
stop_all_services(){
  local archon_dir="${1:-${ARCHON_SRC_DIR:-$ROOT_DIR/archon-src}}"
  local supabase_dir="${2:-$ROOT_DIR/supabase}"

  echo "Stopping running services..."
  # Stop archon-src containers
  if [[ -f "$archon_dir/docker-compose.yml" ]]; then
    ( cd "$archon_dir" && docker compose --profile agents --profile work-orders down --remove-orphans 2>/dev/null ) && ok "Archon containers stopped" || true
  fi
  # Stop Supabase via CLI
  if [[ -d "$supabase_dir" ]] && command -v npx >/dev/null 2>&1; then
    ( cd "$supabase_dir" && npx -y supabase@${SUPABASE_VERSION} stop 2>/dev/null ) && ok "Supabase stopped" || true
  fi
  # Force cleanup stale containers
  cleanup_stale_containers
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
  local ports=($SUPABASE_PORT_API $SUPABASE_PORT_DB $SUPABASE_PORT_STUDIO $SUPABASE_PORT_INBUCKET $SUPABASE_PORT_ANALYTICS)
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

# Enforce shm_size on Postgres container after Supabase provisions it
# Supabase CLI ignores Docker daemon defaults, so we must modify post-creation
# Uses hostconfig.json edit on native Docker; recreates container on Docker Desktop
recreate_container_with_shm_size(){
  local container_name="$1"
  local desired_shm_bytes="$2"

  if ! command -v jq >/dev/null 2>&1; then
    err "jq is required to recreate $container_name with a new shm_size"
    return 1
  fi

  local tmp_json
  tmp_json="$(mktemp)"
  docker inspect "$container_name" > "$tmp_json"

  local image entrypoint0 working_dir user hostname stop_signal stop_timeout restart_policy log_driver
  image=$(jq -r '.[0].Config.Image // empty' "$tmp_json")
  entrypoint0=$(jq -r '.[0].Config.Entrypoint[0] // empty' "$tmp_json")
  working_dir=$(jq -r '.[0].Config.WorkingDir // empty' "$tmp_json")
  user=$(jq -r '.[0].Config.User // empty' "$tmp_json")
  hostname=$(jq -r '.[0].Config.Hostname // empty' "$tmp_json")
  stop_signal=$(jq -r '.[0].Config.StopSignal // empty' "$tmp_json")
  stop_timeout=$(jq -r '.[0].Config.StopTimeout // empty' "$tmp_json")
  restart_policy=$(jq -r '.[0].HostConfig.RestartPolicy.Name // empty' "$tmp_json")
  log_driver=$(jq -r '.[0].HostConfig.LogConfig.Type // empty' "$tmp_json")
  local network_mode
  network_mode=$(jq -r '.[0].HostConfig.NetworkMode // empty' "$tmp_json")

  mapfile -t envs < <(jq -r '.[0].Config.Env[]?' "$tmp_json")
  mapfile -t binds < <(jq -r '.[0].HostConfig.Binds[]?' "$tmp_json")
  mapfile -t labels < <(jq -r '.[0].Config.Labels | to_entries[]? | "\(.key)=\(.value)"' "$tmp_json")
  mapfile -t extra_hosts < <(jq -r '.[0].HostConfig.ExtraHosts[]?' "$tmp_json")
  mapfile -t port_bindings < <(jq -r '.[0].HostConfig.PortBindings | to_entries[]? | .key as $cport | .value[0] | if .HostIp == "" then "\(.HostPort):\($cport)" else "\(.HostIp):\(.HostPort):\($cport)" end' "$tmp_json")
  mapfile -t net_aliases < <(jq -r --arg net "$network_mode" '.[0].NetworkSettings.Networks[$net].Aliases[]?' "$tmp_json")
  local entrypoint_arg1 entrypoint_arg2
  entrypoint_arg1=$(jq -r '.[0].Config.Entrypoint[1] // empty' "$tmp_json")
  entrypoint_arg2=$(jq -r '.[0].Config.Entrypoint[2] // empty' "$tmp_json")
  local entrypoint_args=()
  local entrypoint_extra=()
  [[ -n "$entrypoint_arg1" ]] && entrypoint_args+=("$entrypoint_arg1")
  [[ -n "$entrypoint_arg2" ]] && entrypoint_args+=("$entrypoint_arg2")
  mapfile -t entrypoint_extra < <(jq -r '.[0].Config.Entrypoint[3:][]?' "$tmp_json")
  for arg in "${entrypoint_extra[@]}"; do
    entrypoint_args+=("$arg")
  done
  mapfile -t cmd_args < <(jq -r '.[0].Config.Cmd[]?' "$tmp_json")

  local health_cmd health_interval health_timeout health_retries
  health_cmd=$(jq -r '.[0].Config.Healthcheck.Test[1:]? // [] | join(" ")' "$tmp_json")
  health_interval=$(jq -r '.[0].Config.Healthcheck.Interval // 0' "$tmp_json")
  health_timeout=$(jq -r '.[0].Config.Healthcheck.Timeout // 0' "$tmp_json")
  health_retries=$(jq -r '.[0].Config.Healthcheck.Retries // 0' "$tmp_json")

  ns_to_duration(){
    local ns="$1"
    if [[ -z "$ns" || "$ns" == "0" ]]; then
      echo ""
      return 0
    fi
    local seconds=$((ns/1000000000))
    if (( seconds > 0 )); then
      echo "${seconds}s"
    else
      echo "${ns}ns"
    fi
  }

  echo "Recreating $container_name with shm_size=${desired_shm_bytes} bytes..."
  docker stop "$container_name" >/dev/null 2>&1 || true
  docker rm -f "$container_name" >/dev/null 2>&1 || true

  local create_cmd=(docker create --name "$container_name" --shm-size "$desired_shm_bytes")
  [[ -n "$restart_policy" && "$restart_policy" != "no" ]] && create_cmd+=(--restart "$restart_policy")
  [[ -n "$log_driver" ]] && create_cmd+=(--log-driver "$log_driver")
  [[ -n "$working_dir" ]] && create_cmd+=(--workdir "$working_dir")
  [[ -n "$user" ]] && create_cmd+=(--user "$user")
  [[ -n "$hostname" ]] && create_cmd+=(--hostname "$hostname")
  [[ -n "$stop_signal" ]] && create_cmd+=(--stop-signal "$stop_signal")
  [[ -n "$stop_timeout" ]] && create_cmd+=(--stop-timeout "$stop_timeout")
  [[ -n "$network_mode" && "$network_mode" != "default" ]] && create_cmd+=(--network "$network_mode")

  for alias in "${net_aliases[@]}"; do
    create_cmd+=(--network-alias "$alias")
  done
  for env in "${envs[@]}"; do
    create_cmd+=(--env "$env")
  done
  for bind in "${binds[@]}"; do
    create_cmd+=(-v "$bind")
  done
  for label in "${labels[@]}"; do
    create_cmd+=(--label "$label")
  done
  for host in "${extra_hosts[@]}"; do
    create_cmd+=(--add-host "$host")
  done
  for port in "${port_bindings[@]}"; do
    create_cmd+=(-p "$port")
  done

  if [[ -n "$health_cmd" ]]; then
    create_cmd+=(--health-cmd "$health_cmd")
    local interval_str timeout_str
    interval_str="$(ns_to_duration "$health_interval")"
    timeout_str="$(ns_to_duration "$health_timeout")"
    [[ -n "$interval_str" ]] && create_cmd+=(--health-interval "$interval_str")
    [[ -n "$timeout_str" ]] && create_cmd+=(--health-timeout "$timeout_str")
    [[ -n "$health_retries" && "$health_retries" != "0" ]] && create_cmd+=(--health-retries "$health_retries")
  fi

  if [[ -n "$entrypoint0" ]]; then
    create_cmd+=(--entrypoint "$entrypoint0")
  fi
  create_cmd+=("$image")
  if [[ ${#entrypoint_args[@]} -gt 0 ]]; then
    create_cmd+=("${entrypoint_args[@]}")
  fi
  if [[ ${#cmd_args[@]} -gt 0 ]]; then
    create_cmd+=("${cmd_args[@]}")
  fi

  rm -f "$tmp_json"

  if ! "${create_cmd[@]}"; then
    err "Failed to recreate $container_name with shm_size"
    return 1
  fi

  docker start "$container_name" >/dev/null 2>&1
  return 0
}

enforce_postgres_shm_size(){
  local container_name="${1:-supabase_db_supabase}"
  local desired_shm_bytes="${2:-4294967296}"  # 4GB default
  local desired_shm_human
  desired_shm_human="$(numfmt --to=iec "$desired_shm_bytes" 2>/dev/null || echo "${desired_shm_bytes} bytes")"

  # Check if container exists
  if ! docker ps -a --format '{{.Names}}' | grep -q "^${container_name}$"; then
    warn "Container $container_name not found, skipping shm_size enforcement"
    return 0
  fi

  # Get current shm_size
  local current_shm
  current_shm=$(docker inspect -f '{{.HostConfig.ShmSize}}' "$container_name" 2>/dev/null || echo "0")

  if [[ "$current_shm" -ge "$desired_shm_bytes" ]]; then
    ok "Postgres shm_size already adequate: $(numfmt --to=iec $current_shm 2>/dev/null || echo "${current_shm} bytes")"
    return 0
  fi

  echo "Enforcing shm_size=$desired_shm_human on $container_name (current: $(numfmt --to=iec $current_shm 2>/dev/null || echo "${current_shm} bytes"))..."

  # Get container ID
  local container_id
  container_id=$(docker inspect -f '{{.Id}}' "$container_name" 2>/dev/null)
  if [[ -z "$container_id" ]]; then
    err "Failed to get container ID for $container_name"
    return 1
  fi

  local docker_root_dir
  docker_root_dir="$(docker info -f '{{.DockerRootDir}}' 2>/dev/null || echo "/var/lib/docker")"
  local host_config="${docker_root_dir}/containers/${container_id}/hostconfig.json"

  # Docker Desktop uses containerd snapshotter/image store and does not expose
  # per-container hostconfig.json on the WSL host filesystem.
  local docker_os
  docker_os="$(docker info -f '{{.OperatingSystem}}' 2>/dev/null || true)"
  if [[ "$docker_os" == *"Docker Desktop"* ]]; then
    warn "Docker Desktop detected; recreating $container_name with shm_size=${desired_shm_human}"
    if recreate_container_with_shm_size "$container_name" "$desired_shm_bytes"; then
      ok "Postgres container recreated with shm_size=${desired_shm_human}"
      return 0
    fi
    err "Failed to recreate $container_name with shm_size on Docker Desktop"
    return 1
  fi

  if [[ ! -f "$host_config" ]]; then
    err "hostconfig.json not found at $host_config (DockerRootDir=$docker_root_dir)"
    return 1
  fi

  # Check if we have access (need root)
  if [[ ! -w "$host_config" ]] && [[ $EUID -ne 0 ]]; then
    warn "Cannot modify hostconfig.json without root privileges"
    warn "Run with sudo: sudo enforce_postgres_shm_size $container_name $desired_shm_bytes"
    return 1
  fi

  # Update hostconfig.json
  if [[ -f "$host_config" ]]; then
    # Stop the container first
    echo "Stopping $container_name..."
    docker stop "$container_name" >/dev/null 2>&1 || true

    # Backup
    cp "$host_config" "${host_config}.backup" 2>/dev/null || true

    # Update ShmSize using sed (jq may not be available)
    if sed -i "s/\"ShmSize\":[0-9]*/\"ShmSize\":${desired_shm_bytes}/" "$host_config" 2>/dev/null; then
      ok "Updated hostconfig.json with ShmSize=${desired_shm_bytes}"
    else
      err "Failed to update hostconfig.json"
      docker start "$container_name" >/dev/null 2>&1 || true
      return 1
    fi
  else
    err "hostconfig.json not found at $host_config (DockerRootDir=$docker_root_dir)"
    return 1
  fi

  # Restart the container
  echo "Starting $container_name with new shm_size..."
  docker start "$container_name" >/dev/null 2>&1

  # Verify
  sleep 2
  local new_shm
  new_shm=$(docker inspect -f '{{.HostConfig.ShmSize}}' "$container_name" 2>/dev/null || echo "0")
  if [[ "$new_shm" -ge "$desired_shm_bytes" ]]; then
    ok "Postgres shm_size enforced: $(numfmt --to=iec $new_shm 2>/dev/null || echo "${new_shm} bytes")"
    return 0
  else
    err "shm_size enforcement failed (got: $new_shm, expected: $desired_shm_bytes)"
    return 1
  fi
}
