#!/usr/bin/env bash
# Sync fork's main branch with upstream
# Run from aeo-archon/scripts/ - operates on archon-src repo
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARCHON_SRC_DIR="${ARCHON_SRC_DIR:-$SCRIPT_DIR/../archon-src}"

if [[ ! -d "$ARCHON_SRC_DIR/.git" ]]; then
  echo "Error: $ARCHON_SRC_DIR is not a git repository" >&2
  exit 1
fi

cd "$ARCHON_SRC_DIR"

echo "Updating main from upstream..."

git fetch upstream

git checkout main

git pull --rebase upstream main

git push origin main

echo "main is now up to date with upstream/main."
