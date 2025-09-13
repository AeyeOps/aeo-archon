#!/usr/bin/env bash
set -Eeuo pipefail
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$ROOT_DIR/.env"
COMPOSE_FILES="-f docker-compose.images.yml"

default_observability="compose"
default_agents=1
default_single_port=1
skip_verify=0

if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  COMPOSE="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
  COMPOSE="docker-compose"
else
  echo -e "${RED}Docker Compose not found.${NC}" >&2; exit 1
fi

ok(){ echo -e "${GREEN}✓${NC} $1"; }
warn(){ echo -e "${YELLOW}!${NC} $1"; }
err(){ echo -e "${RED}✗${NC} $1"; }
container_exists(){ docker ps -a --format '{{.Names}}' | grep -qx "$1"; }

HOST_OVERRIDE=""; observability="$default_observability"; enable_agents=$default_agents; enable_single_port=$default_single_port

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host) HOST_OVERRIDE="${2:-}"; shift 2;;
    --observability) observability="${2:-}"; shift 2;;
    --agents) enable_agents=1; shift;;
    --no-agents) enable_agents=0; shift;;
    --single-port) enable_single_port=1; shift;;
    --no-single-port) enable_single_port=0; shift;;
    --no-verify) skip_verify=1; shift;;
    -h|--help)
      cat <<EOF
Usage: $(basename "$0") [--host <ip>] [--observability compose|script|none] [--no-agents] [--no-single-port] [--no-verify]
EOF
      exit 0;;
    *) err "Unknown option: $1"; exit 1;;
  esac
done

[ -f "$ENV_FILE" ] || { cp "$ROOT_DIR/.env.sample" "$ENV_FILE"; ok ".env created from .env.sample"; }

upsert_env(){ local k="$1"; local v="$2"; local tmp="$ENV_FILE.tmp"; awk -v k="$k" -v v="$v" 'BEGIN{done=0}{ if(!done && $0 ~ "^" k "=") { print k"="v; done=1 } else { print $0 } } END{ if(!done) print k"="v }' "$ENV_FILE" > "$tmp"; mv "$tmp" "$ENV_FILE"; }
merge_csv_unique(){ local csv="$1"; local item="$2"; awk -v csv="$csv" -v item="$item" 'BEGIN{ n=split(csv,a,/[ ,]+/); for(i=1;i<=n;i++) if(length(a[i])) { if(!s[a[i]]) { s[a[i]]=1; o[++m]=a[i] } } if(length(item)&&!s[item]) o[++m]=item; for(i=1;i<=m;i++){ if(i>1) printf ","; printf "%s", o[i] } printf "\n" }'; }

# Required images
req=(ARCHON_SERVER_IMAGE ARCHON_MCP_IMAGE ARCHON_FRONTEND_IMAGE)
[[ $enable_agents -eq 1 ]] && req+=(ARCHON_AGENTS_IMAGE)
for v in "${req[@]}"; do
  if ! grep -q "^$v=" "$ENV_FILE" || grep -q "^$v=\s*$" "$ENV_FILE"; then err "$v not set in .env"; exit 1; fi
done
# Required Supabase
for v in SUPABASE_URL SUPABASE_SERVICE_KEY; do
  if ! grep -q "^$v=" "$ENV_FILE" || grep -q "^$v=\s*$" "$ENV_FILE"; then err "$v missing in .env"; exit 1; fi
done

# Host handling
if [[ -n "$HOST_OVERRIDE" ]]; then upsert_env HOST "$HOST_OVERRIDE"; fi
HOST_VAL=$(grep -E '^HOST=' "$ENV_FILE" | sed 's/^HOST=//;s/\r$//'); HOST_VAL=${HOST_VAL:-localhost}
existing=$(grep -E '^VITE_ALLOWED_HOSTS=' "$ENV_FILE" | sed 's/^VITE_ALLOWED_HOSTS=//;s/\r$//') || existing=""
upsert_env VITE_ALLOWED_HOSTS "$(merge_csv_unique "$existing" "$HOST_VAL")"
# Single-port toggle
if [[ $enable_single_port -eq 1 ]]; then upsert_env PROD true; else upsert_env PROD false; fi

# Observability config
SKIP_COMPOSE_OBS=0
case "$observability" in
  compose)
    upsert_env OTEL_EXPORTER_OTLP_ENDPOINT_CONTAINER "http://openobserve:4318"
    if container_exists openobserve; then SKIP_COMPOSE_OBS=1; ok "Reusing existing openobserve"; fi
    ;;
  script)
    upsert_env OTEL_EXPORTER_OTLP_ENDPOINT_CONTAINER "http://host.docker.internal:4318"
    if [[ -x "$ROOT_DIR/setup-local-observability.sh" ]]; then "$ROOT_DIR/setup-local-observability.sh"; else warn "setup-local-observability.sh not found"; fi
    ;;
  none) warn "Observability disabled" ;;
  *) err "Invalid observability: $observability"; exit 1;;
 esac

# Start services
$COMPOSE $COMPOSE_FILES up -d
[[ "$observability" == "compose" && $SKIP_COMPOSE_OBS -eq 0 ]] && $COMPOSE $COMPOSE_FILES --profile observability up -d || true
[[ $enable_agents -eq 1 ]] && $COMPOSE $COMPOSE_FILES --profile agents up -d || true

# Attach existing openobserve to network if needed
if [[ "$observability" == "compose" && $SKIP_COMPOSE_OBS -eq 1 ]]; then
  docker start openobserve >/dev/null 2>&1 || true
  NET_NAME="$(docker network ls --format '{{.Name}}' | grep -E '_app-network$' | head -n1 || true)"; NET_NAME=${NET_NAME:-aeo-archon_app-network}
  docker network connect "$NET_NAME" openobserve >/dev/null 2>&1 || true
fi

# Verify
check(){ curl -fsS -o /dev/null -m 5 "$1" >/dev/null 2>&1; }
if [[ $skip_verify -eq 0 ]]; then
  UI_PORT=$(grep -E '^ARCHON_UI_PORT=' "$ENV_FILE" | sed 's/^ARCHON_UI_PORT=//;s/\r$//'); UI_PORT=${UI_PORT:-3737}
  API_PORT=$(grep -E '^ARCHON_SERVER_PORT=' "$ENV_FILE" | sed 's/^ARCHON_SERVER_PORT=//;s/\r$//'); API_PORT=${API_PORT:-8181}
  MCP_PORT=$(grep -E '^ARCHON_MCP_PORT=' "$ENV_FILE" | sed 's/^ARCHON_MCP_PORT=//;s/\r$//'); MCP_PORT=${MCP_PORT:-8051}
  AGENTS_PORT=$(grep -E '^ARCHON_AGENTS_PORT=' "$ENV_FILE" | sed 's/^ARCHON_AGENTS_PORT=//;s/\r$//'); AGENTS_PORT=${AGENTS_PORT:-8052}
  PROD=$(grep -E '^PROD=' "$ENV_FILE" | sed 's/^PROD=//;s/\r$//')
  check "http://$HOST_VAL:$UI_PORT" && ok "UI ready" || warn "UI not ready"
  check "http://$HOST_VAL:$API_PORT/health" && ok "API ready" || warn "API not ready"
  [[ "$PROD" == "true" ]] && check "http://$HOST_VAL:$UI_PORT/api/health" && ok "API via UI ready" || true
  check "http://$HOST_VAL:$MCP_PORT/health" && ok "MCP ready" || warn "MCP not ready"
  [[ $enable_agents -eq 1 ]] && check "http://$HOST_VAL:$AGENTS_PORT/health" && ok "Agents ready" || true
  check "http://$HOST_VAL:5080/" && ok "OpenObserve UI reachable" || warn "OpenObserve UI not reachable (optional)"
fi

echo -e "${GREEN}Done. Access:${NC}"
echo "- UI:  http://$HOST_VAL:$UI_PORT"
if [[ "${PROD:-true}" == "true" ]]; then echo "- API: http://$HOST_VAL:$UI_PORT/api (single-port)"; else echo "- API: http://$HOST_VAL:$API_PORT"; fi
echo "- MCP: http://$HOST_VAL:$MCP_PORT"
[[ $enable_agents -eq 1 ]] && echo "- Agents: http://$HOST_VAL:$AGENTS_PORT" || true
[[ "$observability" != "none" ]] && echo "- Observability: http://$HOST_VAL:5080" || true
