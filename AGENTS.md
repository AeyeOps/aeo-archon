# AI Assistant Guide

This document provides context and guidelines for AI assistants working in the AeyeOps Archon repository.

## Project Overview

AeyeOps Archon is a production wrapper around [Archon](https://github.com/coleam00/archon), providing:
- Automated bootstrap and deployment
- Database migration management
- Supabase recovery and health monitoring
- Observability integration

### Repository Relationship

```
aeo-archon (this repo)           # Wrapper with operational tooling
    └── manages → archon-src/    # Fork of upstream Archon
                      └── syncs with → coleam00/archon  # Upstream
```

### Single Entry Point Design

`bootstrap-archon.sh` is the **sole entry point** for spinning up the stack. It calls `archon-up.sh` internally.

- DO NOT suggest running `archon-up.sh` after bootstrap - it already ran
- Bootstrap is idempotent: safe to re-run anytime
- All setup flows through: `bootstrap-archon.sh` → `archon-up.sh`

### Fork Maintenance Warning

Branch `fix/docker-deployment-improvements` carries critical bug fixes NOT merged upstream.

**DO NOT:**
- Suggest rebasing onto upstream/main
- Suggest switching to main branch for "latest features"
- Cherry-pick from upstream without careful review

**WHY:** PRs submitted to coleam00/archon are not being merged. Rebasing would lose our fixes.

The fork sync (`scripts/sync-main.sh`) only syncs the `main` branch, not the working branch.

Key insight: This repo does NOT contain application code. It provides:
- Bootstrap scripts that set up the environment
- Migration tooling that syncs and applies database changes
- Recovery mechanisms for common failure modes
- E2E testing for deployment validation

## Directory Structure

```
/opt/aeo/aeo-archon/             # This repository (wrapper)
├── archon-up.sh                 # Main launcher script
├── stop-archon.sh               # Clean shutdown
├── bootstrap-archon.sh          # One-command setup
├── restart-archon-services.sh   # Service restart utility
├── test-archon.sh               # E2E test runner
├── lib/
│   ├── supabase-utils.sh        # Supabase lifecycle and utility functions
│   └── e2e-tests.sh             # Test suite library
├── migration/
│   ├── run_migrations.py        # Idempotent migration runner
│   └── *.sql                    # Copied from archon-src at runtime
├── scripts/
│   └── sync-main.sh             # Fork sync helper
├── diagnostics/
│   └── check-archon.sh          # System health diagnostics
├── supabase/                    # Local Supabase project
└── .env                         # Environment configuration

/opt/aeo/archon-src/             # Upstream Archon (auto-managed)
├── python/src/                  # FastAPI backend
├── archon-ui-main/src/          # React frontend
├── migration/                   # Source of truth for migrations
└── docker-compose.yml           # Archon services
```

## Key Files and Their Purpose

| File | Purpose |
|------|---------|
| `archon-up.sh` | Main orchestrator: starts Supabase, runs migrations, launches Archon |
| `bootstrap-archon.sh` | First-time setup: installs prerequisites, clones repo, configures env |
| `lib/supabase-utils.sh` | Supabase lifecycle management, health checks, port config, and recovery |
| `lib/e2e-tests.sh` | 19 automated tests for database, storage, API, and observability |
| `migration/run_migrations.py` | Applies SQL migrations idempotently via tracking table |
| `.env` | Configuration (ports, Supabase keys, feature flags) |

## Common Tasks

### Starting the Stack
```bash
./archon-up.sh                   # Normal start
./archon-up.sh --fresh           # Wipe database and reinstall
./archon-up.sh --no-migrations   # Skip migration step
./archon-up.sh --no-verify       # Skip health checks
```

### Stopping the Stack
```bash
./stop-archon.sh                 # Normal stop
./stop-archon.sh --force         # Force cleanup of stale containers
```

### Running Tests
```bash
./test-archon.sh                 # Full E2E validation
source lib/e2e-tests.sh && test_database_health  # Individual test
```

### Checking Supabase Status
```bash
cd supabase && npx supabase status
docker ps | grep supabase
```

### Applying Migrations Manually
```bash
# Migrations run automatically, but if needed:
docker exec supabase_db_supabase psql -U postgres -f /path/to/migration.sql
```

## Coding Standards

### Bash Scripts
- Shebang: `#!/usr/bin/env bash`
- Strict mode: `set -Eeuo pipefail`
- Indent: 2 spaces
- Functions: `lowercase_with_underscores()`
- Use `ok()`, `warn()`, `err()` helpers for colored output
- Quote all variables: `"$var"` not `$var`
- Use `[[ ]]` for conditionals, not `[ ]`

### SQL Migrations
- Uppercase keywords: `SELECT`, `CREATE TABLE`
- Snake case identifiers: `archon_migrations`, `source_id`
- One idempotent change per file
- Include `ON CONFLICT DO NOTHING` for inserts
- Add comments describing the migration purpose

### Python (migration runner)
- Type hints on all functions
- Docstrings for classes and public methods
- Use `logging` module, not print statements
- Handle exceptions with informative error messages

## Environment Variables

### Required
```bash
SUPABASE_SERVICE_KEY=<jwt>       # Must be service_role, NOT anon
```

### Important
```bash
SUPABASE_VERSION=2.70.5          # Pinned CLI version
SUPABASE_URL=http://127.0.0.1:54321
HOST=localhost                   # LAN IP for external access
PROD=true                        # Single-port mode
```

### Service Ports
```bash
ARCHON_SERVER_PORT=8181
ARCHON_MCP_PORT=8051
ARCHON_AGENTS_PORT=8052
ARCHON_UI_PORT=3737
AGENT_WORK_ORDERS_PORT=8053
```

## Testing Requirements

Before committing changes, ensure:
1. `./test-archon.sh` passes all 19 tests
2. Scripts have no shellcheck warnings: `shellcheck *.sh lib/*.sh`
3. Bootstrap is idempotent: can run twice without errors
4. Stop/start cycle works cleanly

### Test Categories
| Category | Tests | What It Validates |
|----------|-------|-------------------|
| Database | 4 | Container running, connections, tables, data integrity |
| Storage | 4 | Container health, migrations applied, no duplicates |
| API | 5 | Server, MCP, UI, Agents, Work Orders endpoints |
| Supabase | 3 | Kong gateway, REST API, Auth service |
| Observability | 3 | OpenObserve running, UI accessible, OTLP endpoint |

## Observability (OpenObserve + OTEL)

### Architecture

```
Claude Code ─────────────────────┐
                                 │
Archon Server ───────────────────┼──► OpenObserve (port 5080)
                                 │       └─► Web UI: http://localhost:5080
Archon MCP ──────────────────────┤       └─► API: /api/default/v1/{traces,logs,metrics}
                                 │
Archon Agents ───────────────────┘
```

### Environment Variables (Archon Services)

```bash
# Set in docker-compose.override.yml (auto-generated by archon-up.sh)
OTEL_EXPORTER_OTLP_ENDPOINT=http://openobserve:5080/api/default
OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf
OTEL_EXPORTER_OTLP_HEADERS=Authorization=Basic <base64(user:pass)>
OTEL_TRACES_EXPORTER=otlp
OTEL_LOGS_EXPORTER=otlp
OTEL_METRICS_EXPORTER=otlp
LOGFIRE_ENABLED=true
LOGFIRE_SEND_TO_CLOUD=false
```

### Claude Code OTEL Integration

Configure Claude Code CLI to send telemetry to OpenObserve:

```bash
# Linux/WSL2
./scripts/setup-claude-otel.sh           # Install configuration
./scripts/setup-claude-otel.sh --test    # Test connection
./scripts/setup-claude-otel.sh --show    # Show current config
./scripts/setup-claude-otel.sh --uninstall  # Remove config

# Windows PowerShell
.\scripts\setup-claude-otel.ps1           # Install configuration
.\scripts\setup-claude-otel.ps1 -Test     # Test connection
.\scripts\setup-claude-otel.ps1 -Show     # Show current config
.\scripts\setup-claude-otel.ps1 -Uninstall  # Remove config
```

The scripts update `~/.claude/settings.json` with OTEL environment variables.

### OpenObserve Credentials

Default credentials (configured in `.env`):
- **User**: `admin@archon.local`
- **Password**: `archon123`
- **Org**: `default`

### Verifying Telemetry

```bash
# Check OpenObserve is receiving data
docker logs openobserve 2>&1 | grep "v1/traces"

# View streams in OpenObserve
curl -u admin@archon.local:archon123 \
  http://localhost:5080/api/default/streams

# Access UI
open http://localhost:5080  # Login with credentials above
```

## Git Workflow

### Commit Messages
Use conventional commits:
```
feat(scope): Add new feature
fix(scope): Fix bug description
docs: Update documentation
refactor: Code restructuring
chore: Maintenance tasks
```

### Branches
- `main`: Production-ready code
- Feature branches: `feat/description` or `fix/description`

### Pull Requests
- Reference any related issues
- Include test results
- Document breaking changes

## Troubleshooting Guide

### Storage Migration Failures
**Symptom**: `duplicate key value violates unique constraint "migrations_name_key"`

**Cause**: Supabase CLI version changed, pulling different storage-api image

**Solution**:
```bash
./stop-archon.sh --force
sudo ./bootstrap-archon.sh --clean-images
```

**Prevention**: The system now auto-recovers with 3 retry attempts.

### Container Name Conflicts
**Symptom**: `container name already in use`

**Solution**:
```bash
./stop-archon.sh --force
# Or manually:
docker ps -a | grep supabase_ | awk '{print $1}' | xargs docker rm -f
```

### Permission Denied on Database
**Symptom**: `permission denied for table` or failed saves

**Cause**: Using anon key instead of service_role key

**Solution**: Check `.env` and ensure `SUPABASE_SERVICE_KEY` contains `"role":"service_role"` in its JWT payload.

### Health Checks Failing
```bash
# Check individual services
curl http://localhost:8181/health  # Server
curl http://localhost:8051/health  # MCP
curl http://localhost:3737         # UI

# Check container logs
docker logs archon-archon-server-1
docker logs supabase_storage_supabase
```

## Important Patterns

### Idempotency
All scripts are designed to be re-runnable:
- `archon-up.sh`: Reconciles state, doesn't duplicate
- `run_migrations.py`: Tracks applied migrations, skips duplicates
- `bootstrap-archon.sh`: Updates existing installs safely

### Version Pinning
```bash
SUPABASE_VERSION=2.70.5  # In .env and lib/supabase-utils.sh
```
Never use `@latest` for Supabase CLI in scripts.

### Utility Functions
Source `lib/supabase-utils.sh` to access:
- `cleanup_stale_containers()` - Remove orphaned containers
- `recover_storage_migrations()` - Reset migration tracking
- `check_storage_health()` - Verify storage container
- `preflight_checks()` - Validate prerequisites
- `auto_backup()` - Create database backup
- `enforce_postgres_shm_size()` - Set Postgres container shm_size to 4GB (requires root)

### Container Naming
Supabase containers follow the pattern: `supabase_<service>_supabase`
- `supabase_db_supabase`
- `supabase_storage_supabase`
- `supabase_kong_supabase`
- etc.

## Security Considerations

1. **Never commit secrets** - `.env` contains the service key
2. **Validate key type** - Scripts should fail-fast on anon key
3. **Backup before destructive ops** - `auto_backup()` before `--fresh`
4. **Use service_role for DB ops** - Not postgres superuser

## Related Documentation

- [Archon README](https://github.com/coleam00/archon/blob/main/README.md)
- [Supabase Local Development](https://supabase.com/docs/guides/local-development)
- [OpenObserve Docs](https://openobserve.ai/docs/)
