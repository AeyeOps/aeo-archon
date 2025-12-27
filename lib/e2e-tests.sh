#!/usr/bin/env bash
# E2E validation tests for Archon stack
# Source this file or run standalone via test-archon.sh

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

# Load environment variables
if [[ -f "$ROOT_DIR/.env" ]]; then
  set -a
  source "$ROOT_DIR/.env"
  set +a
fi

# Test Category 1: Database Health
test_database_health(){
  local failures=0
  echo "==> Testing Database Health"

  # Test 1: DB container running
  if docker ps --format '{{.Names}}' | grep -q supabase_db_supabase; then
    ok "DB container running"
  else
    err "DB container not running"; ((failures++))
    return $failures
  fi

  # Test 2: DB accepting connections
  if docker exec supabase_db_supabase pg_isready -U postgres >/dev/null 2>&1; then
    ok "DB accepting connections"
  else
    err "DB not accepting connections"; ((failures++))
  fi

  # Test 3: Archon tables exist
  local table_count=$(docker exec supabase_db_supabase psql -U postgres -t -c \
    "SELECT COUNT(*) FROM pg_tables WHERE schemaname='public' AND tablename LIKE 'archon_%';" 2>/dev/null | tr -d ' ')
  if [[ "$table_count" -ge 10 ]]; then
    ok "Archon tables present ($table_count tables)"
  else
    err "Archon tables missing (found ${table_count:-0})"; ((failures++))
  fi

  # Test 4: Data integrity check
  local row_count=$(docker exec supabase_db_supabase psql -U postgres -t -c \
    "SELECT COUNT(*) FROM public.archon_crawled_pages;" 2>/dev/null | tr -d ' ')
  if [[ "${row_count:-0}" -gt 0 ]]; then
    ok "Archon data intact ($row_count crawled pages)"
  else
    warn "No crawled pages found (may be expected for fresh install)"
  fi

  return $failures
}

# Test Category 2: Storage Service
test_storage_health(){
  local failures=0
  echo "==> Testing Storage Service"

  # Test 1: Storage container running
  if docker ps --format '{{.Names}}' | grep -q supabase_storage_supabase; then
    ok "Storage container running"
  else
    err "Storage container not running"; ((failures++))
    return $failures
  fi

  # Test 2: Storage container healthy
  local health=$(docker inspect supabase_storage_supabase --format '{{.State.Health.Status}}' 2>/dev/null)
  if [[ "$health" == "healthy" ]]; then
    ok "Storage container healthy"
  else
    err "Storage container unhealthy ($health)"; ((failures++))
  fi

  # Test 3: Migrations table valid
  local migration_count=$(docker exec supabase_db_supabase psql -U postgres -t -c \
    "SELECT COUNT(*) FROM storage.migrations;" 2>/dev/null | tr -d ' ')
  if [[ "${migration_count:-0}" -gt 0 ]]; then
    ok "Storage migrations applied ($migration_count migrations)"
  else
    err "Storage migrations missing"; ((failures++))
  fi

  # Test 4: No duplicate migrations
  local dupe_count=$(docker exec supabase_db_supabase psql -U postgres -t -c \
    "SELECT COUNT(*) FROM (SELECT name FROM storage.migrations GROUP BY name HAVING COUNT(*) > 1) x;" 2>/dev/null | tr -d ' ')
  if [[ "${dupe_count:-0}" -eq 0 ]]; then
    ok "No duplicate migrations"
  else
    err "Duplicate migrations detected ($dupe_count)"; ((failures++))
  fi

  return $failures
}

# Test Category 3: API Health
test_api_health(){
  local failures=0
  echo "==> Testing API Services"

  local API_PORT=${ARCHON_SERVER_PORT:-8181}
  local MCP_PORT=${ARCHON_MCP_PORT:-8051}
  local AGENTS_PORT_VAL=${ARCHON_AGENTS_PORT:-8052}
  local UI_PORT=${ARCHON_UI_PORT:-3737}

  # Test 1: Archon Server health
  local status=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://localhost:$API_PORT/health" 2>/dev/null)
  if [[ "$status" == "200" ]]; then
    ok "Archon Server healthy (port $API_PORT)"
  else
    err "Archon Server not responding (HTTP $status)"; ((failures++))
  fi

  # Test 2: Archon MCP health
  status=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://localhost:$MCP_PORT/health" 2>/dev/null)
  if [[ "$status" == "200" || "$status" == "404" ]]; then
    ok "Archon MCP responding (port $MCP_PORT)"
  else
    err "Archon MCP not responding (HTTP $status)"; ((failures++))
  fi

  # Test 3: Archon UI
  status=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://localhost:$UI_PORT" 2>/dev/null)
  if [[ "$status" == "200" ]]; then
    ok "Archon UI healthy (port $UI_PORT)"
  else
    err "Archon UI not responding (HTTP $status)"; ((failures++))
  fi

  # Test 4: Agents (if enabled)
  if [[ "${AGENTS_ENABLED:-false}" == "true" ]]; then
    status=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://localhost:$AGENTS_PORT_VAL/health" 2>/dev/null)
    if [[ "$status" == "200" ]]; then
      ok "Archon Agents healthy (port $AGENTS_PORT_VAL)"
    else
      err "Archon Agents not responding (HTTP $status)"; ((failures++))
    fi
  fi

  # Test 5: Work Orders (if running)
  local WORK_ORDERS_PORT=${AGENT_WORK_ORDERS_PORT:-8053}
  if docker ps --format '{{.Names}}' | grep -q archon-agent-work-orders; then
    status=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://localhost:$WORK_ORDERS_PORT/health" 2>/dev/null)
    if [[ "$status" == "200" ]]; then
      ok "Archon Work Orders healthy (port $WORK_ORDERS_PORT)"
    else
      warn "Archon Work Orders not responding (HTTP $status)"
    fi
  fi

  return $failures
}

# Test Category 4: Supabase API
test_supabase_api(){
  local failures=0
  echo "==> Testing Supabase API"

  # Test 1: Kong gateway responding
  local status=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://localhost:54321" 2>/dev/null)
  if [[ "$status" != "000" ]]; then
    ok "Supabase gateway responding (HTTP $status)"
  else
    err "Supabase gateway not responding"; ((failures++))
  fi

  # Test 2: REST API accessible (with service key)
  if [[ -n "${SUPABASE_SERVICE_KEY:-}" ]]; then
    status=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
      -H "apikey: $SUPABASE_SERVICE_KEY" \
      "http://localhost:54321/rest/v1/archon_settings?select=*&limit=1" 2>/dev/null)
    if [[ "$status" == "200" ]]; then
      ok "Supabase REST API accessible"
    else
      err "Supabase REST API failed (HTTP $status)"; ((failures++))
    fi
  else
    warn "SUPABASE_SERVICE_KEY not found, skipping REST API test"
  fi

  # Test 3: Auth service healthy
  if docker ps --format '{{.Names}}' | grep -q supabase_auth_supabase; then
    local health=$(docker inspect supabase_auth_supabase --format '{{.State.Health.Status}}' 2>/dev/null)
    if [[ "$health" == "healthy" ]]; then
      ok "Auth service healthy"
    else
      warn "Auth service status: $health"
    fi
  fi

  return $failures
}

# Test Category 5: Observability
test_observability(){
  local failures=0
  echo "==> Testing Observability"

  # Test 1: OpenObserve running
  if docker ps --format '{{.Names}}' | grep -q openobserve; then
    ok "OpenObserve container running"
  else
    warn "OpenObserve not running (optional)"
    return 0
  fi

  # Test 2: OpenObserve UI accessible (accept 2xx, 3xx as valid)
  local status=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://localhost:5080" 2>/dev/null)
  if [[ "$status" =~ ^[23][0-9][0-9]$ ]]; then
    ok "OpenObserve UI accessible (port 5080, HTTP $status)"
  else
    err "OpenObserve UI not responding (HTTP $status)"; ((failures++))
  fi

  # Test 3: OTLP endpoint accepting connections
  if command -v nc >/dev/null 2>&1; then
    if nc -z localhost 4318 2>/dev/null; then
      ok "OTLP HTTP endpoint open (port 4318)"
    else
      warn "OTLP HTTP endpoint not reachable"
    fi
  elif timeout 1 bash -c 'cat < /dev/null > /dev/tcp/localhost/4318' 2>/dev/null; then
    ok "OTLP HTTP endpoint open (port 4318)"
  else
    warn "OTLP HTTP endpoint not reachable (or nc not installed)"
  fi

  return $failures
}

# Master Test Runner
run_e2e_tests(){
  echo ""
  echo "================================================================"
  echo "                   E2E VALIDATION TESTS                        "
  echo "================================================================"
  echo ""

  local total_failures=0

  test_database_health
  ((total_failures+=$?))
  echo ""

  test_storage_health
  ((total_failures+=$?))
  echo ""

  test_api_health
  ((total_failures+=$?))
  echo ""

  test_supabase_api
  ((total_failures+=$?))
  echo ""

  test_observability
  ((total_failures+=$?))

  echo ""
  echo "================================================================"
  if [[ $total_failures -eq 0 ]]; then
    echo -e "${GREEN}+ ALL TESTS PASSED${NC}"
  else
    echo -e "${RED}x $total_failures TEST(S) FAILED${NC}"
  fi
  echo "================================================================"

  return $total_failures
}

# Run if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  run_e2e_tests
  exit $?
fi
