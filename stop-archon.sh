#!/usr/bin/env bash
# Stop all Archon services (containers + Supabase)
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUPABASE_DIR="$ROOT_DIR/supabase"
ARCHON_SRC_DIR="${ARCHON_SRC_DIR_OVERRIDE:-$ROOT_DIR/archon-src}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

ok(){ echo -e "${GREEN}✓${NC} $1"; }
warn(){ echo -e "${YELLOW}!${NC} $1"; }
err(){ echo -e "${RED}✗${NC} $1"; }

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
  npx -y supabase@latest stop 2>/dev/null && ok "Supabase stopped" || warn "Supabase was not running"
  popd >/dev/null
}

main(){
  echo "==> Stopping Archon services"
  stop_archon_containers
  stop_supabase
  ok "All services stopped"
}

main "$@"
