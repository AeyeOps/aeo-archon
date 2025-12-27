#!/usr/bin/env bash
# Standalone E2E test runner for Archon stack
# Run this script to validate that all services are healthy

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source the E2E test library
if [[ -f "$ROOT_DIR/lib/e2e-tests.sh" ]]; then
  source "$ROOT_DIR/lib/e2e-tests.sh"
else
  echo "Error: lib/e2e-tests.sh not found"
  exit 1
fi

# Run all tests
run_e2e_tests
exit $?
