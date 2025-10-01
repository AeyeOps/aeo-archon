#!/usr/bin/env bash
set -Eeuo pipefail
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$ROOT_DIR/.env"
COMPOSE_FILES="-f docker-compose.images.yml"
SUPABASE_DIR="$ROOT_DIR/supabase"
ARCHON_SRC_DIR_DEFAULT="${ARCHON_SRC_DIR_OVERRIDE:-/opt/aeo/archon-src}"
ARCHON_SRC_BRANCH_DEFAULT="${ARCHON_SRC_BRANCH_OVERRIDE:-aeyeops/custom-main}"
ARCHON_SRC_DIR="$ARCHON_SRC_DIR_DEFAULT"
ARCHON_SRC_BRANCH="$ARCHON_SRC_BRANCH_DEFAULT"

default_observability="compose"
default_agents=1
default_single_port=1
skip_verify=0
run_migrations=1

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
    --no-migrations) run_migrations=0; shift;;
    -h|--help)
      cat <<EOF
Usage: $(basename "$0") [--host <ip>] [--observability compose|script|none] [--no-agents] [--no-single-port] [--no-verify] [--no-migrations]
EOF
      exit 0;;
    *) err "Unknown option: $1"; exit 1;;
  esac
done

[ -f "$ENV_FILE" ] || { cp "$ROOT_DIR/.env.sample" "$ENV_FILE"; ok ".env created from .env.sample"; }

upsert_env(){ local k="$1"; local v="$2"; local tmp="$ENV_FILE.tmp"; awk -v k="$k" -v v="$v" 'BEGIN{done=0}{ if(!done && $0 ~ "^" k "=") { print k"="v; done=1 } else { print $0 } } END{ if(!done) print k"="v }' "$ENV_FILE" > "$tmp"; mv "$tmp" "$ENV_FILE"; }
merge_csv_unique(){ local csv="$1"; local item="$2"; awk -v csv="$csv" -v item="$item" 'BEGIN{ n=split(csv,a,/[ ,]+/); for(i=1;i<=n;i++) if(length(a[i])) { if(!s[a[i]]) { s[a[i]]=1; o[++m]=a[i] } } if(length(item)&&!s[item]) o[++m]=item; for(i=1;i<=m;i++){ if(i>1) printf ","; printf "%s", o[i] } printf "\n" }'; }
upsert_if_empty(){ local k="$1"; local v="$2"; if ! grep -q "^${k}=" "$ENV_FILE" || grep -q "^${k}=\s*$" "$ENV_FILE"; then upsert_env "$k" "$v"; fi }

wait_for_supabase_ready(){
  local kong_container="$1"
  local attempts=30
  local url="http://${kong_container}:8000/rest/v1/?select=*"
  for attempt in $(seq 1 $attempts); do
    # Use lightweight curl container to avoid relying on host binaries
    status=$(docker run --rm --network supabase_network_supabase curlimages/curl:8.8.0 -s -o /dev/null -w '%{http_code}' "$url" 2>/dev/null || true)
    if [[ -n "$status" && "$status" != "000" ]]; then
      ok "Supabase API reachable (HTTP $status)"
      return 0
    fi
    sleep 2
  done
  err "Supabase API not reachable at $url after $attempts attempts"; exit 1
}

wait_for_supabase_table(){
  local kong_container="$1"
  local table="$2"
  local api_key="$3"
  local attempts=30
  local url="http://${kong_container}:8000/rest/v1/${table}?select=*"
  for attempt in $(seq 1 $attempts); do
    status=$(docker run --rm --network supabase_network_supabase \
      curlimages/curl:8.8.0 -s -o /dev/null -w '%{http_code}' -H "apikey: $api_key" "$url" 2>/dev/null || true)
    if [[ "$status" == "200" ]]; then
      ok "Supabase table ${table} reachable"
      return 0
    fi
    sleep 2
  done
  err "Supabase table ${table} not reachable at $url"; exit 1
}

# Populate essential defaults non-interactively (idempotent)
upsert_if_empty HOST "localhost"
upsert_if_empty ARCHON_SERVER_PORT "8181"
upsert_if_empty ARCHON_MCP_PORT "8051"
upsert_if_empty ARCHON_AGENTS_PORT "8052"
upsert_if_empty ARCHON_UI_PORT "3737"
upsert_if_empty VITE_SHOW_DEVTOOLS "false"
upsert_if_empty OTEL_EXPORTER_OTLP_ENDPOINT "http://localhost:4318"
upsert_if_empty OTEL_EXPORTER_OTLP_PROTOCOL "http/protobuf"
upsert_if_empty OTEL_EXPORTER_OTLP_ENDPOINT_CONTAINER "http://openobserve:4318"
upsert_if_empty OTEL_TRACES_EXPORTER "otlp"
upsert_if_empty OTEL_LOGS_EXPORTER "otlp"
upsert_if_empty OTEL_METRICS_EXPORTER "otlp"
upsert_if_empty OTEL_TRACES_SAMPLER "always_on"
upsert_if_empty OTEL_SERVICE_NAME_ARCHON_SERVER "archon-server"
upsert_if_empty OTEL_SERVICE_NAME_ARCHON_MCP "archon-mcp"
upsert_if_empty OTEL_SERVICE_NAME_ARCHON_AGENTS "archon-agents"
[[ $enable_agents -eq 1 ]] && upsert_env AGENTS_ENABLED true || upsert_env AGENTS_ENABLED false

# Default images (idempotent). Compose fails fast if not present locally or pullable.
upsert_if_empty ARCHON_SERVER_IMAGE "archon-archon-server:latest"
upsert_if_empty ARCHON_MCP_IMAGE "archon-archon-mcp:latest"
upsert_if_empty ARCHON_FRONTEND_IMAGE "archon-archon-frontend:latest"
[[ $enable_agents -eq 1 ]] && upsert_if_empty ARCHON_AGENTS_IMAGE "archon-archon-agents:latest" || true

# Ensure Supabase via Supabase CLI (npx) and populate .env. Fail fast if unavailable.
ensure_supabase_env(){
  command -v npx >/dev/null 2>&1 || { err "npx not found. Install Node.js (>=18) to use supabase CLI"; exit 1; }
  mkdir -p "$SUPABASE_DIR"
  pushd "$SUPABASE_DIR" >/dev/null
  # Supabase CLI keeps config under ./supabase/config.toml
  if [[ ! -f "supabase/config.toml" ]]; then
    npx -y supabase@latest init || { err "Failed to initialize Supabase CLI project"; exit 1; }
  fi
  npx -y supabase@latest start || { err "Failed to start local Supabase via CLI"; exit 1; }
  # Query status in env format and parse required values
  STATUS_ENV=$(npx -y supabase@latest status -o env) || { err "Failed to get Supabase status"; exit 1; }
  SERVICE_ROLE_KEY=$(echo "$STATUS_ENV" | awk -F'=' '/^SERVICE_ROLE_KEY/{gsub(/"/,"",$2); print $2}')
  API_URL=$(echo "$STATUS_ENV" | awk -F'=' '/^API_URL/{gsub(/"/,"",$2); print $2}')
  popd >/dev/null
  if [[ -z "$SERVICE_ROLE_KEY" || -z "$API_URL" ]]; then
    err "Supabase status missing SERVICE_ROLE_KEY or API_URL; cannot continue"; exit 1
  fi
  upsert_env SUPABASE_URL "$API_URL"
  SUPABASE_KONG=$(docker ps --format '{{.Names}}' | grep -m1 'supabase_kong' || true)
  if [[ -n "$SUPABASE_KONG" ]]; then
    upsert_env SUPABASE_URL_CONTAINER "http://$SUPABASE_KONG:8000"
    wait_for_supabase_ready "$SUPABASE_KONG"
  else
    upsert_env SUPABASE_URL_CONTAINER "http://host.docker.internal:54321"
  fi
  upsert_env SUPABASE_SERVICE_KEY "$SERVICE_ROLE_KEY"
  ok "Supabase configured via supabase CLI"
}

ensure_supabase_env

# Host handling
IS_WSL=0
if [[ -f /proc/sys/kernel/osrelease ]] && grep -qi "microsoft" /proc/sys/kernel/osrelease 2>/dev/null; then
  IS_WSL=1
fi

CURRENT_HOST=$(grep -E '^HOST=' "$ENV_FILE" | sed 's/^HOST=//;s/\r$//' || true)
if [[ -n "$HOST_OVERRIDE" ]]; then
  upsert_env HOST "$HOST_OVERRIDE"
elif [[ $IS_WSL -eq 1 ]]; then
  if [[ -z "$CURRENT_HOST" || "$CURRENT_HOST" =~ ^172\. ]]; then
    upsert_env HOST "localhost"
  fi
fi

HOST_VAL=$(grep -E '^HOST=' "$ENV_FILE" | sed 's/^HOST=//;s/\r$//'); HOST_VAL=${HOST_VAL:-localhost}
existing=$(grep -E '^VITE_ALLOWED_HOSTS=' "$ENV_FILE" | sed 's/^VITE_ALLOWED_HOSTS=//;s/\r$//') || existing=""
upsert_env VITE_ALLOWED_HOSTS "$(merge_csv_unique "$existing" "$HOST_VAL")"
# Single-port toggle: only set if missing; otherwise preserve
if ! grep -q '^PROD=' "$ENV_FILE" || grep -q '^PROD=\s*$' "$ENV_FILE"; then
  if [[ $enable_single_port -eq 1 ]]; then upsert_env PROD true; else upsert_env PROD false; fi
fi

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

# Start services (prefer building from upstream source if available)
if [[ ! -f "$ARCHON_SRC_DIR/docker-compose.yml" ]]; then
  if [[ -x "$ROOT_DIR/bootstrap-archon.sh" ]]; then
    bash "$ROOT_DIR/bootstrap-archon.sh" --dir "$ARCHON_SRC_DIR" --branch "$ARCHON_SRC_BRANCH" --no-start
  else
    err "archon-src not found and bootstrap-archon.sh missing"; exit 1
  fi
fi

if [[ -d "$ARCHON_SRC_DIR/.git" ]]; then
  CURRENT_BRANCH=$(git -C "$ARCHON_SRC_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
  if [[ "$CURRENT_BRANCH" != "$ARCHON_SRC_BRANCH" ]]; then
    warn "archon-src checked out to $CURRENT_BRANCH (expected $ARCHON_SRC_BRANCH). Using current branch."
  else
    ok "archon-src on $ARCHON_SRC_BRANCH"
  fi
else
  warn "archon-src does not appear to be a git repository; continuing"
fi

# Sync Supabase settings into archon-src/.env
SRC_ENV="$ARCHON_SRC_DIR/.env"
upsert_src_env(){ local k="$1"; local v="$2"; local tmp="$SRC_ENV.tmp"; awk -v k="$k" -v v="$v" 'BEGIN{done=0}{ if(!done && $0 ~ "^" k "=") { print k"="v; done=1 } else { print $0 } } END{ if(!done) print k"="v }' "$SRC_ENV" > "$tmp"; mv "$tmp" "$SRC_ENV"; }
CONTAINER_SUPABASE_URL=$(grep -E '^SUPABASE_URL_CONTAINER=' "$ENV_FILE" | sed 's/^SUPABASE_URL_CONTAINER=//' | tr -d '\r')
if [[ -n "$CONTAINER_SUPABASE_URL" ]]; then
  upsert_src_env SUPABASE_URL "$CONTAINER_SUPABASE_URL"
else
  upsert_src_env SUPABASE_URL "$(grep -E '^SUPABASE_URL=' "$ENV_FILE" | sed 's/^SUPABASE_URL=//' | tr -d '\r')"
fi
SUPABASE_SERVICE_KEY_VAL="$(grep -E '^SUPABASE_SERVICE_KEY=' "$ENV_FILE" | sed 's/^SUPABASE_SERVICE_KEY=//')"
upsert_src_env SUPABASE_SERVICE_KEY "$SUPABASE_SERVICE_KEY_VAL"
upsert_src_env HOST "$(grep -E '^HOST=' "$ENV_FILE" | sed 's/^HOST=//')"
upsert_src_env ARCHON_SERVER_PORT "$(grep -E '^ARCHON_SERVER_PORT=' "$ENV_FILE" | sed 's/^ARCHON_SERVER_PORT=//')"
upsert_src_env ARCHON_MCP_PORT "$(grep -E '^ARCHON_MCP_PORT=' "$ENV_FILE" | sed 's/^ARCHON_MCP_PORT=//')"
upsert_src_env ARCHON_AGENTS_PORT "$(grep -E '^ARCHON_AGENTS_PORT=' "$ENV_FILE" | sed 's/^ARCHON_AGENTS_PORT=//')"
upsert_src_env ARCHON_UI_PORT "$(grep -E '^ARCHON_UI_PORT=' "$ENV_FILE" | sed 's/^ARCHON_UI_PORT=//')"

# Run database migrations (idempotent, optional) before starting services
if [[ $run_migrations -eq 1 ]]; then
  echo "Running database migrations..."

  # Copy fresh migration files from archon-src
  if [[ -d "$ROOT_DIR/../archon-src/migration" ]]; then
    echo "Copying migration files from archon-src..."
    mkdir -p "$ROOT_DIR/migration/0.1.0"
    cp -f "$ROOT_DIR/../archon-src/migration"/*.sql "$ROOT_DIR/migration/" 2>/dev/null || true
    cp -f "$ROOT_DIR/../archon-src/migration/0.1.0"/*.sql "$ROOT_DIR/migration/0.1.0/" 2>/dev/null || true
    ok "Migration files copied"
  else
    warn "archon-src not found, using existing migration files"
  fi

  DB_CONTAINER=$(docker ps --format '{{.Names}}' | grep -m1 'supabase_db' || true)
  DB_HOST=${DB_CONTAINER:-supabase_db_supabase}
  DB_PORT=5432; DB_USER=postgres; DB_PASSWORD=postgres; DB_NAME=postgres
  for i in {1..30}; do
    if docker run --rm --network supabase_network_supabase -e PGPASSWORD="$DB_PASSWORD" postgres:15-alpine pg_isready -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" >/dev/null 2>&1; then
      ok "Database reachable"
      break
    fi
    sleep 2
    [[ $i -eq 30 ]] && err "Database not reachable on $DB_HOST:$DB_PORT; failing fast" && exit 1
  done
  docker run --rm --network supabase_network_supabase \
    -e DB_HOST="$DB_HOST" -e DB_PORT="$DB_PORT" -e DB_USER="$DB_USER" -e DB_PASSWORD="$DB_PASSWORD" -e DB_NAME="$DB_NAME" \
    -e PIP_ROOT_USER_ACTION=ignore -e PIP_DISABLE_PIP_VERSION_CHECK=1 \
    -v "$ROOT_DIR":/work -w /work \
    python:3.12-slim bash -lc "pip install -q --upgrade pip && pip install -q psycopg2-binary && python migration/run_migrations.py" \
    && ok "Migrations applied"
  if [[ -n "$SUPABASE_KONG" ]]; then
    wait_for_supabase_table "$SUPABASE_KONG" "archon_settings" "$SUPABASE_SERVICE_KEY_VAL"
  fi
fi

# Bring up upstream Archon stack
( cd "$ARCHON_SRC_DIR" && docker compose up --build -d ) || { err "Failed to build or start archon from source"; exit 1; }

if [[ $enable_agents -eq 1 ]]; then
  ( cd "$ARCHON_SRC_DIR" && docker compose --profile agents up -d ) || warn "Agents profile failed to start"
fi

# Start observability locally (separate compose)
if [[ "$observability" == "compose" ]]; then
  if [[ $SKIP_COMPOSE_OBS -eq 0 ]]; then
    $COMPOSE $COMPOSE_FILES up -d openobserve || warn "OpenObserve failed to start"
  else
    docker start openobserve >/dev/null 2>&1 || true
  fi
  NET_NAME="$(docker network ls --format '{{.Name}}' | grep -E 'archon-src_app-network$' | head -n1 || true)"
  if [[ -n "$NET_NAME" ]]; then
    docker network connect "$NET_NAME" openobserve >/dev/null 2>&1 || true
  fi
fi

# Verify
check(){ curl -fsS -o /dev/null -m 5 "$1" >/dev/null 2>&1; }
check_service(){
  local label="$1"; local url="$2"; local attempts=${3:-10}; local delay=${4:-3}; local success_codes="${5:-200}"
  for attempt in $(seq 1 "$attempts"); do
    status=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$url" 2>/dev/null || echo "000")
    if [[ " $success_codes " == *" $status "* ]]; then
      ok "$label ready"
      return 0
    fi
    sleep "$delay"
  done
  warn "$label not ready"
  return 1
}
if [[ $skip_verify -eq 0 ]]; then
  UI_PORT=$(grep -E '^ARCHON_UI_PORT=' "$ENV_FILE" | sed 's/^ARCHON_UI_PORT=//;s/\r$//'); UI_PORT=${UI_PORT:-3737}
  API_PORT=$(grep -E '^ARCHON_SERVER_PORT=' "$ENV_FILE" | sed 's/^ARCHON_SERVER_PORT=//;s/\r$//'); API_PORT=${API_PORT:-8181}
  MCP_PORT=$(grep -E '^ARCHON_MCP_PORT=' "$ENV_FILE" | sed 's/^ARCHON_MCP_PORT=//;s/\r$//'); MCP_PORT=${MCP_PORT:-8051}
  AGENTS_PORT=$(grep -E '^ARCHON_AGENTS_PORT=' "$ENV_FILE" | sed 's/^ARCHON_AGENTS_PORT=//;s/\r$//'); AGENTS_PORT=${AGENTS_PORT:-8052}
  PROD=$(grep -E '^PROD=' "$ENV_FILE" | sed 's/^PROD=//;s/\r$//')
  CHECK_HOST="localhost"
  check_service "UI" "http://$CHECK_HOST:$UI_PORT"
  check_service "API" "http://$CHECK_HOST:$API_PORT/health"
  if [[ "$PROD" == "true" ]]; then
    check_service "API via UI" "http://$CHECK_HOST:$UI_PORT/api/health"
  fi
  check_service "MCP" "http://$CHECK_HOST:$MCP_PORT/health" 20 3 "200 404"
  if [[ $enable_agents -eq 1 ]]; then
    check_service "Agents" "http://$CHECK_HOST:$AGENTS_PORT/health" 20 3
  fi
  if [[ "$observability" != "none" ]]; then
    check_service "OpenObserve UI" "http://$CHECK_HOST:5080/" 24 5 "200 201 204 301 302 303 307 308"
  fi
fi

UI_PORT=${UI_PORT:-$(grep -E '^ARCHON_UI_PORT=' "$ENV_FILE" | sed 's/^ARCHON_UI_PORT=//;s/\r$//')}
UI_PORT=${UI_PORT:-3737}
API_PORT=${API_PORT:-$(grep -E '^ARCHON_SERVER_PORT=' "$ENV_FILE" | sed 's/^ARCHON_SERVER_PORT=//;s/\r$//')}
API_PORT=${API_PORT:-8181}
MCP_PORT=${MCP_PORT:-$(grep -E '^ARCHON_MCP_PORT=' "$ENV_FILE" | sed 's/^ARCHON_MCP_PORT=//;s/\r$//')}
MCP_PORT=${MCP_PORT:-8051}
AGENTS_PORT=${AGENTS_PORT:-$(grep -E '^ARCHON_AGENTS_PORT=' "$ENV_FILE" | sed 's/^ARCHON_AGENTS_PORT=//;s/\r$//')}
AGENTS_PORT=${AGENTS_PORT:-8052}
PROD=${PROD:-$(grep -E '^PROD=' "$ENV_FILE" | sed 's/^PROD=//;s/\r$//')}

ALT_HOST=""
if [[ -f /proc/sys/kernel/osrelease ]] && grep -qi "microsoft" /proc/sys/kernel/osrelease 2>/dev/null; then
  ALT_HOST="localhost"
fi

echo -e "${GREEN}Done. Access:${NC}"
echo "- UI:  http://$HOST_VAL:$UI_PORT"
if [[ -n "$ALT_HOST" && "$ALT_HOST" != "$HOST_VAL" ]]; then
  echo "  (WSL) http://$ALT_HOST:$UI_PORT"
fi

if [[ "${PROD:-true}" == "true" ]]; then
  echo "- API: http://$HOST_VAL:$UI_PORT/api (single-port)"
  if [[ -n "$ALT_HOST" && "$ALT_HOST" != "$HOST_VAL" ]]; then
    echo "  (WSL) http://$ALT_HOST:$UI_PORT/api (single-port)"
  fi
else
  echo "- API: http://$HOST_VAL:$API_PORT"
  if [[ -n "$ALT_HOST" && "$ALT_HOST" != "$HOST_VAL" ]]; then
    echo "  (WSL) http://$ALT_HOST:$API_PORT"
  fi
fi

echo "- MCP: http://$HOST_VAL:$MCP_PORT"
if [[ -n "$ALT_HOST" && "$ALT_HOST" != "$HOST_VAL" ]]; then
  echo "  (WSL) http://$ALT_HOST:$MCP_PORT"
fi

if [[ $enable_agents -eq 1 ]]; then
  echo "- Agents: http://$HOST_VAL:$AGENTS_PORT"
  if [[ -n "$ALT_HOST" && "$ALT_HOST" != "$HOST_VAL" ]]; then
    echo "  (WSL) http://$ALT_HOST:$AGENTS_PORT"
  fi
fi

if [[ "$observability" != "none" ]]; then
  echo "- Observability: http://$HOST_VAL:5080"
  if [[ -n "$ALT_HOST" && "$ALT_HOST" != "$HOST_VAL" ]]; then
    echo "  (WSL) http://$ALT_HOST:5080"
  fi
  echo "  (OpenObserve login: admin@archon.local / archon-admin)"
fi
