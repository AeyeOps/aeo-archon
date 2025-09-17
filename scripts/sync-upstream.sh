#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")"/.. && pwd)"
cd "$ROOT_DIR"

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "This script must be run from inside the git repository." >&2
  exit 1
fi

if ! git remote get-url upstream >/dev/null 2>&1; then
  echo "No 'upstream' remote configured. Add it with:\n  git remote add upstream https://github.com/coleam00/archon.git" >&2
  exit 1
fi

branch="${1:-main}"

echo "Fetching latest upstream commits..."
git fetch upstream

echo "Rebasing ${branch} onto upstream/${branch}"
git checkout "$branch"
git pull --rebase upstream "$branch"

echo "Pushing rebased branch to origin"
git push --force-with-lease origin "$branch"

echo "Done."
