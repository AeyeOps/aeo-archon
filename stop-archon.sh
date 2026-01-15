#!/usr/bin/env bash
# Stop all Archon services (containers + Supabase)
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUPABASE_DIR="$ROOT_DIR/supabase"
ARCHON_SRC_DIR="${ARCHON_SRC_DIR_OVERRIDE:-$ROOT_DIR/archon-src}"

# Source shared recovery functions if available
if [[ -f "$ROOT_DIR/lib/supabase-recovery.sh" ]]; then
  source "$ROOT_DIR/lib/supabase-recovery.sh"
else
  # Fallback definitions
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
  ok(){ echo -e "${GREEN}+${NC} $1"; }
  warn(){ echo -e "${YELLOW}!${NC} $1"; }
  err(){ echo -e "${RED}x${NC} $1"; }
  SUPABASE_VERSION="${SUPABASE_VERSION:-latest}"
  cleanup_stale_containers(){ docker ps -a --format '{{.Names}}' | grep -E '^supabase_' | xargs -r docker rm -f 2>/dev/null || true; }
fi

# Parse arguments
FORCE_CLEANUP=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --force) FORCE_CLEANUP=1; shift;;
    *) shift;;
  esac
done

stop_archon_containers(){
  # Stop archon-src containers if running
  if [[ -f "$ARCHON_SRC_DIR/docker-compose.yml" ]]; then
    echo "Stopping Archon containers..."
    ( cd "$ARCHON_SRC_DIR" && docker compose --profile agents --profile work-orders down --remove-orphans 2>/dev/null ) && ok "Archon containers stopped" || warn "No Archon containers to stop"
  fi
  # Stop local compose services (openobserve, etc.)
  if [[ -f "$ROOT_DIR/docker-compose.images.yml" ]]; then
    ( cd "$ROOT_DIR" && docker compose -f docker-compose.images.yml down --remove-orphans 2>/dev/null ) || true
  fi
}

stop_supabase(){
  if [[ ! -d "$SUPABASE_DIR" ]]; then
    return
  fi
  if ! command -v npx >/dev/null 2>&1; then
    warn "npx not available; cannot stop Supabase CLI"
    return
  fi
  echo "Stopping Supabase..."
  pushd "$SUPABASE_DIR" >/dev/null
  npx -y supabase@${SUPABASE_VERSION} stop 2>/dev/null && ok "Supabase stopped" || warn "Supabase was not running"
  popd >/dev/null
}

main(){
  echo "==> Stopping Archon services"
  stop_archon_containers
  stop_supabase

  # Force cleanup stale containers if requested or if normal stop failed
  if [[ $FORCE_CLEANUP -eq 1 ]]; then
    echo "Force cleaning stale containers..."
    cleanup_stale_containers
  fi

  ok "All services stopped"
}

main "$@"
