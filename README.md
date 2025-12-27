# AeyeOps Archon

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Supabase](https://img.shields.io/badge/Supabase-Local%20%7C%20Cloud-3ECF8E)](https://supabase.com)

A production-ready wrapper for [Archon](https://github.com/coleam00/archon) that provides automated bootstrap, migration management, and operational tooling for self-hosted deployments.

## Features

- **One-Command Bootstrap**: Install prerequisites, clone upstream, and launch the full stack
- **Automatic Migrations**: Pull and apply database migrations from upstream on every update
- **Supabase Recovery**: Automatic detection and recovery from storage migration conflicts
- **E2E Validation**: 19 automated health checks across database, storage, API, and observability
- **Version Pinning**: Prevent CLI version drift with locked Supabase CLI versions
- **Observability**: Integrated OpenObserve for traces, logs, and metrics

## Quick Start

### Prerequisites

- Linux (Ubuntu 22.04+ recommended) or WSL2
- Docker and Docker Compose
- sudo access for initial setup

### Bootstrap (Recommended)

```bash
# Clone this repository
git clone https://github.com/AeyeOps/aeo-archon.git
cd aeo-archon

# Run bootstrap (installs Docker, Node.js, clones Archon, starts everything)
sudo ./bootstrap-archon.sh
```

The bootstrap script:
1. Installs system prerequisites (Docker, NVM, Node.js)
2. Clones/updates the Archon fork from upstream
3. Starts local Supabase (PostgreSQL, Auth, Storage, Kong)
4. Applies database migrations automatically
5. Launches the Archon stack (Server, MCP, UI, Agents)
6. Starts OpenObserve for observability

### Manual Start (After Bootstrap)

```bash
# Start all services
./archon-up.sh

# Stop all services
./stop-archon.sh

# Restart specific services
./restart-archon-services.sh
```

## Architecture

```
aeo-archon/                     # This wrapper repository
├── bootstrap-archon.sh         # One-command setup script
├── archon-up.sh                # Service launcher with health checks
├── stop-archon.sh              # Clean shutdown with container cleanup
├── lib/
│   ├── supabase-recovery.sh    # Automatic storage migration recovery
│   └── e2e-tests.sh            # Comprehensive validation suite
├── migration/
│   └── run_migrations.py       # Idempotent migration runner
└── supabase/                   # Local Supabase project

/opt/aeo/archon-src/            # Upstream Archon (auto-managed)
├── python/                     # FastAPI backend
├── archon-ui-main/             # React frontend
└── migration/                  # Database migrations
```

## Endpoints

| Service | Port | URL |
|---------|------|-----|
| UI | 3737 | http://localhost:3737 |
| API | 8181 | http://localhost:8181 (or /api on 3737 with PROD=true) |
| MCP | 8051 | http://localhost:8051 |
| Agents | 8052 | http://localhost:8052 |
| Work Orders | 8053 | http://localhost:8053 |
| Supabase | 54321 | http://localhost:54321 |
| Studio | 54323 | http://localhost:54323 |
| OpenObserve | 5080 | http://localhost:5080 |

## Configuration

Key environment variables in `.env`:

```bash
# Supabase connection (auto-configured by bootstrap)
SUPABASE_URL=http://127.0.0.1:54321
SUPABASE_SERVICE_KEY=<service_role_key>  # NOT the anon key!

# Service ports
ARCHON_SERVER_PORT=8181
ARCHON_MCP_PORT=8051
ARCHON_AGENTS_PORT=8052
ARCHON_UI_PORT=3737

# Features
PROD=true                       # Single-port mode (API at /api on UI port)
AGENTS_ENABLED=true             # Enable agents service
LOGFIRE_ENABLED=true            # Enable OpenObserve telemetry
```

## Operations

### Updating from Upstream

```bash
# Re-run bootstrap to pull latest and apply migrations
sudo ./bootstrap-archon.sh
```

### Fresh Install (Wipe Database)

```bash
# Warning: This deletes all data!
sudo ./bootstrap-archon.sh --fresh
```

### Upgrading Supabase CLI Version

```bash
# Clean old images when changing CLI versions
sudo ./bootstrap-archon.sh --clean-images
```

### Running Tests

```bash
# Run E2E validation suite
./test-archon.sh
```

### Diagnostics

```bash
# Full system health check
./diagnostics/check-archon.sh
```

## Troubleshooting

### Storage Migration Errors

If you see `duplicate key value violates unique constraint "migrations_name_key"`:

```bash
# The system auto-recovers, but if manual intervention needed:
./stop-archon.sh --force
sudo ./bootstrap-archon.sh --clean-images
```

### Permission Denied Errors

Ensure you're using the `service_role` key, not the `anon` key:
- The service_role key contains `"role":"service_role"` in its JWT payload
- The anon key will cause all database writes to fail

### Container Conflicts

```bash
# Force cleanup of stale containers
./stop-archon.sh --force
```

## Contributing

1. Fork this repository
2. Create a feature branch
3. Make your changes
4. Run `./test-archon.sh` to validate
5. Submit a pull request

See [AGENTS.md](AGENTS.md) for coding standards and guidelines.

## License

MIT License - see [LICENSE](LICENSE) for details.

## Acknowledgments

- [Archon](https://github.com/coleam00/archon) by Cole Medin
- [Supabase](https://supabase.com) for the backend infrastructure
- [OpenObserve](https://openobserve.ai) for observability

---

<p align="center">
  <img src="images/archon-emblem.webp" alt="Archon Emblem" width="120">
</p>
