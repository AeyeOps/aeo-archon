#!/usr/bin/env bash

# OpenObserve-only local observability setup for Archon
# - Non-interactive, idempotent
# - Fails fast on critical errors

set -Eeuo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}================================================${NC}"
echo -e "${GREEN}Setting up OpenObserve for Archon${NC}"
echo -e "${GREEN}================================================${NC}"

trap 'echo -e "${RED}Error on line ${LINENO}. Aborting.${NC}" >&2' ERR

ENV_FILE="/opt/archon/.env"
CONTAINER_NAME="openobserve"
VOLUME_NAME="openobserve-data"
IMAGE_NAME="public.ecr.aws/zinclabs/openobserve:latest"

ensure_docker() {
  if ! docker info >/dev/null 2>&1; then
    echo -e "${RED}Docker is not running. Start Docker Desktop and retry.${NC}"
    exit 1
  fi
  echo -e "${GREEN}✓ Docker is running${NC}"
}

remove_existing_container() {
  if docker ps -a --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
    echo -e "${YELLOW}Removing existing $CONTAINER_NAME container...${NC}"
    docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
  fi
}

create_volume() {
  docker volume create "$VOLUME_NAME" >/dev/null 2>&1 || true
}

run_openobserve() {
  echo -e "${YELLOW}Starting OpenObserve container...${NC}"
  docker run -d --name "$CONTAINER_NAME" \
    -v "$VOLUME_NAME":/data \
    -p 5080:5080 \
    -p 4317:4317 \
    -p 4318:4318 \
    -e ZO_ROOT_USER_EMAIL="admin@archon.local" \
    -e ZO_ROOT_USER_PASSWORD="archon-admin" \
    -e ZO_DATA_DIR="/data" \
    "$IMAGE_NAME"

  echo -e "${GREEN}✓ Container starting${NC}"

  # Wait for UI to respond
  echo -e "${YELLOW}Waiting for OpenObserve UI on http://localhost:5080 ...${NC}"
  for i in {1..60}; do
    if curl -fsS http://localhost:5080/ >/dev/null 2>&1; then
      echo -e "${GREEN}✓ OpenObserve UI is reachable${NC}"
      break
    fi
    sleep 1
    if [ "$i" -eq 60 ]; then
      echo -e "${RED}OpenObserve did not become ready within 60s.${NC}"
      exit 1
    fi
  done

  echo -e "  UI: ${GREEN}http://localhost:5080${NC}"
  echo -e "  Username: admin@archon.local"
  echo -e "  Password: archon-admin"
  echo -e "  OTLP: localhost:4317 (gRPC), localhost:4318 (HTTP)"
}

upsert_env() {
  local var="$1"; shift
  local val="$1"; shift
  if grep -q "^${var}=" "$ENV_FILE"; then
    sed -i "s|^${var}=.*|${var}=${val}|" "$ENV_FILE"
  else
    printf '%s\n' "${var}=${val}" >> "$ENV_FILE"
  fi
}

update_env_file() {
  echo -e "${YELLOW}Updating .env configuration...${NC}"

  if [ ! -f "$ENV_FILE" ]; then
    echo -e "${RED}.env not found at $ENV_FILE${NC}"
    exit 1
  fi

  cp "$ENV_FILE" "$ENV_FILE.backup"
  echo "Created backup: $ENV_FILE.backup"

  if ! grep -Eq 'OTEL_EXPORTER_OTLP_ENDPOINT|OTEL_EXPORTER_OTLP_PROTOCOL|LOGFIRE_SEND_TO_CLOUD' "$ENV_FILE"; then
    printf '\n# Local Observability Configuration (OpenObserve)\n' >> "$ENV_FILE"
    printf '# Comment these to revert to cloud Logfire\n' >> "$ENV_FILE"
  fi

  upsert_env OTEL_EXPORTER_OTLP_ENDPOINT "http://localhost:4318"
  upsert_env OTEL_EXPORTER_OTLP_PROTOCOL "http/protobuf"
  upsert_env LOGFIRE_SEND_TO_CLOUD "false"
  # Provide a container-aware endpoint for docker-compose
  upsert_env OTEL_EXPORTER_OTLP_ENDPOINT_CONTAINER "http://host.docker.internal:4318"

  echo -e "${GREEN}✓ .env updated for local OTLP exporter${NC}"
}

test_basic_connectivity() {
  echo -e "${YELLOW}Verifying OTLP HTTP port (4318) is accepting connections...${NC}"
  if curl -fsS http://localhost:4318/ >/dev/null 2>&1; then
    echo -e "${GREEN}✓ OTLP HTTP endpoint reachable${NC}"
  else
    echo -e "${YELLOW}Warning: OTLP HTTP root path did not respond (some exporters post to /v1/*).${NC}"
  fi
}

# Execute
ensure_docker
remove_existing_container
create_volume
run_openobserve
update_env_file
test_basic_connectivity

echo -e "\n${GREEN}Setup complete! OpenObserve is ready.${NC}"
echo "Dashboard: http://localhost:5080"
echo "Login: admin@archon.local / archon-admin"

echo -e "\n${YELLOW}Next steps:${NC}"
echo "1. Restart your Archon services to use the new configuration"
echo "2. Check the observability UI to see incoming traces"
echo "3. To revert to cloud Logfire, comment out the OTEL_* variables in .env"
