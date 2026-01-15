#!/usr/bin/env bash
# Merge origin/main into custom branch
# Run from aeo-archon/scripts/ - operates on archon-src repo
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARCHON_SRC_DIR="${ARCHON_SRC_DIR:-$SCRIPT_DIR/../archon-src}"
TARGET_BRANCH="${TARGET_BRANCH:-aeyeops/custom-main}"

if [[ ! -d "$ARCHON_SRC_DIR/.git" ]]; then
  echo "Error: $ARCHON_SRC_DIR is not a git repository" >&2
  exit 1
fi

cd "$ARCHON_SRC_DIR"

if ! git show-ref --quiet refs/heads/"$TARGET_BRANCH"; then
  echo "Branch $TARGET_BRANCH does not exist locally" >&2
  exit 1
fi

echo "Ensuring origin/main is current..."
git fetch origin

# optional ensure local main up to date
if git show-ref --quiet refs/heads/main; then
  git checkout main
  git pull origin main
else
  git checkout -b main origin/main
fi

echo "Merging origin/main into $TARGET_BRANCH..."
git checkout "$TARGET_BRANCH"
git pull origin "$TARGET_BRANCH"
git merge origin/main

git push origin "$TARGET_BRANCH"

echo "$TARGET_BRANCH now includes the latest origin/main changes."
