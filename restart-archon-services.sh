#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUPABASE_DIR="$ROOT_DIR/supabase"
COMPOSE_FILES=("-f" "$ROOT_DIR/docker-compose.images.yml")

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

log_info(){ echo -e "${YELLOW}•${NC} $1"; }
ok(){ echo -e "${GREEN}✓${NC} $1"; }
warn(){ echo -e "${YELLOW}!${NC} $1"; }
err(){ echo -e "${RED}✗${NC} $1"; }

if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  COMPOSE=(docker compose)
elif command -v docker-compose >/dev/null 2>&1; then
  COMPOSE=(docker-compose)
else
  err "Docker Compose not found."; exit 1
fi

stop_compose_services(){
  if [[ ! -f "${COMPOSE_FILES[1]}" ]]; then
    warn "docker-compose.images.yml not found; skipping container shutdown"
    return
  fi
  log_info "Stopping Archon containers"
  "${COMPOSE[@]}" "${COMPOSE_FILES[@]}" down --remove-orphans || warn "Failed to stop docker compose stack"
  ok "Archon containers stopped"
}

stop_supabase(){
  if [[ ! -d "$SUPABASE_DIR" ]]; then
    warn "Supabase directory not found; skipping supabase shutdown"
    return
  fi
  if ! command -v npx >/dev/null 2>&1; then
    warn "npx not available; cannot control Supabase CLI"
    return
  fi
  log_info "Stopping Supabase local stack"
  pushd "$SUPABASE_DIR" >/dev/null
  npx -y supabase@latest stop >/dev/null 2>&1 && ok "Supabase stopped" || warn "Supabase stop reported issues"
  popd >/dev/null
}

start_stack(){
  log_info "Restarting Archon stack via archon-up.sh"
  "$ROOT_DIR/archon-up.sh" "$@"
}

main(){
  stop_compose_services
  stop_supabase
  start_stack "$@"
  ok "Restart sequence complete"
}

main "$@"
