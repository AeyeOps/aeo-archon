# Repository Guidelines

## Project Structure & Module Organization
- `archon-src/python/src` houses the FastAPI server, MCP adapters, and agents; pytest fixtures live in `archon-src/python/tests`.
- `archon-src/archon-ui-main/src/features` delivers modern React slices, while `/components` retains legacy widgets slated for migration.
- `migration/` stores SQL files alongside `run_migrations.py`; scripts like `archon-up.sh` and `setup-local-observability.sh` boot the stack and telemetry.
- Compose manifests (`docker-compose*.yml`) plus `.env.sample` document service profiles and required environment keys.

## Build, Test, and Development Commands
- `./archon-up.sh [--host <ip>]` launches Supabase, writes `.env`, applies migrations, and executes health checks.
- `docker compose up --build -d` brings core services online; append `--profile agents` or `--profile observability` as needed.
- Backend workflow: `uv sync --group all`, `uv run python -m src.server.main`, and `uv run pytest` for install, run, and tests.
- Frontend workflow (inside `archon-src/archon-ui-main`): `npm run dev`, `npm run build`, `npm run test`, and `npm run biome`.
- Repo-wide linting shortcuts: `make lint`, `make lint-fe`, and `make lint-be`.

## Coding Style & Naming Conventions
- Bash: `#!/usr/bin/env bash`, `set -euo pipefail`, two-space indent, POSIX-friendly tooling.
- SQL: uppercase keywords, `snake_case` identifiers, single idempotent change per file.
- Python: PEP 8 with 120-character lines, typed functions, Ruff and Mypy enforcement, and small service-layer helpers.
- TypeScript: strict mode; Biome governs `/features` (120-char lines, double quotes, trailing commas) while ESLint covers legacy paths.

## Testing Guidelines
- Run `uv run pytest` for backend suites and `npm run test` or `vitest run <path>` for frontend coverage.
- After migrations, verify readiness via `curl http://$HOST:8181/health` and `curl http://$HOST:8051/health`.
- Store tests beside their feature (`src/features/<slice>/__tests__`) or under `python/tests`, naming cases after the behavior verified.

## Commit & Pull Request Guidelines
- Commits use imperative subjects with concise rationale (e.g., `Harden Supabase auth checks`); keep diffs focused and reversible.
- PRs describe purpose, scope, rollback plan, linked issues, and attach logs or screenshots when helpful; update `.env.sample` and docs after config shifts.
- Run `make lint` (or equivalent) before review and record validation steps—stack boot, health checks, targeted tests—in the PR summary.

## Security & Configuration Tips
- Always use the Supabase `service_role` key in `.env`; treat missing or invalid credentials as fatal and fail fast.
- Set `HOST` to a reachable address and mirror it in `VITE_ALLOWED_HOSTS`; enable single-port mode with `PROD=true` when proxying through the UI.
- Never commit secrets or fallback defaults; log configuration errors with actionable context.
