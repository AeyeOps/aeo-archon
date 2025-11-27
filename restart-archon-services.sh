#!/usr/bin/env bash
# Restart Archon: stop all services, then start
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
ok(){ echo -e "${GREEN}✓${NC} $1"; }
err(){ echo -e "${RED}✗${NC} $1"; }

main(){
  "$ROOT_DIR/stop-archon.sh"
  "$ROOT_DIR/archon-up.sh" "$@"
  ok "Restart complete"
}

main "$@"
