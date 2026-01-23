# Repository Guidelines

## Project Structure & Module Organization

This repository is an **operational wrapper** for Archon (the application code lives in the bootstrap-managed `archon-src/` clone, typically at `/opt/aeo/archon-src`).

- `bootstrap-archon.sh`: installs prerequisites, clones/updates `archon-src`, and launches the stack (idempotent)
- `archon-up.sh`: starts/reconciles Supabase + Archon services and runs migrations
- `lib/`: shared shell libraries (`supabase-utils.sh`, `e2e-tests.sh`)
- `migration/`: `run_migrations.py` plus runtime-copied SQL (most `migration/*.sql` is git-ignored)
- `supabase/`: local Supabase project used by `npx supabase`
- `docker-compose*.yml`, `dashboards/`, `docs/`, `scripts/`: operational tooling and assets

## Build, Test, and Development Commands

```bash
sudo ./bootstrap-archon.sh              # bootstrap + start (recommended entry point)
sudo ./bootstrap-archon.sh --stop       # stop services (no restart)
./archon-up.sh                          # start/reconcile after bootstrap
./archon-up.sh --fresh                  # wipe DB + reinstall schema
./lib/e2e-tests.sh                      # run E2E health checks
python3 scripts/diagnose.py             # quick triage (containers, env, logs, health)
```

## Coding Style & Naming Conventions

- **Bash**: `#!/usr/bin/env bash`, `set -Eeuo pipefail`, 2-space indent, quote variables, prefer `[[ ... ]]`, functions `lowercase_with_underscores()`.
- **SQL**: uppercase keywords, `snake_case` identifiers, prefer idempotent changes; avoid committing runtime-copied migration SQL under `migration/`.
- **Python**: use type hints and `logging` (not `print`) for scripts like `migration/run_migrations.py`.

## Testing Guidelines

Primary validation is the script-based E2E suite in `lib/e2e-tests.sh` (database, storage, API, observability). When changing bootstrap/startup/migrations, extend the relevant checks and run the suite locally before opening a PR.

## Commit & Pull Request Guidelines

- **Commits**: follow Conventional Commits used in repo history: `feat(scope): ...`, `fix(scope): ...`, `docs: ...`, `refactor: ...`, `chore: ...`.
- **PRs**: include a clear summary, the commands you ran (e.g., `./lib/e2e-tests.sh`), and call out any configuration changes.

## Security & Configuration Tips

Do not commit secrets. In particular, `SUPABASE_SERVICE_KEY` must be a `service_role` key and should only live in local `.env` files (use `.env.sample` for non-secret defaults).
