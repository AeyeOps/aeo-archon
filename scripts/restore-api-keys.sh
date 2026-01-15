#!/usr/bin/env bash
# Restore API keys from environment to archon_settings database
#
# Usage:
#   OPENAI_API_KEY="sk-..." ./restore-api-keys.sh
#
# Or source your keys first:
#   source ~/.archon-keys  # file with export OPENAI_API_KEY=...
#   ./restore-api-keys.sh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/.env" 2>/dev/null || true

# Get SUPABASE_SERVICE_KEY
SUPABASE_SERVICE_KEY_VAL="${SUPABASE_SERVICE_KEY:-}"
if [[ -z "$SUPABASE_SERVICE_KEY_VAL" ]]; then
  echo "✗ SUPABASE_SERVICE_KEY not set"
  exit 1
fi

# Database connection (defaults for local Supabase)
DB_HOST="${DB_HOST:-localhost}"
DB_PORT="${DB_PORT:-5432}"
DB_USER="${DB_USER:-postgres}"
DB_PASSWORD="${DB_PASSWORD:-postgres}"
DB_NAME="${DB_NAME:-postgres}"

echo "Injecting API keys from environment..."

docker run --rm --network supabase_network_supabase \
  -e DB_HOST="$DB_HOST" \
  -e DB_PORT="$DB_PORT" \
  -e DB_USER="$DB_USER" \
  -e DB_PASSWORD="$DB_PASSWORD" \
  -e DB_NAME="$DB_NAME" \
  -e SUPABASE_SERVICE_KEY="$SUPABASE_SERVICE_KEY_VAL" \
  -e OPENAI_API_KEY="${OPENAI_API_KEY:-}" \
  -e GEMINI_API_KEY="${GEMINI_API_KEY:-}" \
  -e GROK_API_KEY="${GROK_API_KEY:-}" \
  -e ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-}" \
  -e OPENROUTER_API_KEY="${OPENROUTER_API_KEY:-}" \
  -e GITHUB_TOKEN="${GITHUB_TOKEN:-}" \
  -e PIP_ROOT_USER_ACTION=ignore \
  -e PIP_DISABLE_PIP_VERSION_CHECK=1 \
  -v "$ROOT_DIR":/work -w /work \
  python:3.12-slim bash -lc "pip install -q psycopg2-binary cryptography && python scripts/inject-api-keys.py"

echo "Done."
