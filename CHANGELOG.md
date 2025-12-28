# Changelog

All notable changes to AeyeOps Archon are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.8.0] - 2025-12-27

### Added
- OpenObserve OTEL integration with automatic docker-compose.override.yml generation
- Dynamic authentication header generation for OpenObserve telemetry ingestion
- OTEL environment variable configuration for all Archon services (server, mcp, agents)
- OpenObserve service configuration in docker-compose override
- Support for local observability without Logfire cloud (OTEL export mode)

### Changed
- archon-up.sh now generates docker-compose.override.yml dynamically
- OTEL endpoints corrected to use OpenObserve port 5080 (not 4317/4318)
- Environment variables added: OPENOBSERVE_USER, OPENOBSERVE_PASSWORD

### Fixed
- OpenObserve telemetry collection (traces now properly ingested)
- Logfire OTEL export configuration (works without LOGFIRE_TOKEN)
- FastAPI instrumentation timing (configure before instrument)

## [0.7.0] - 2025-12-27

### Added
- Supabase recovery library (`lib/supabase-recovery.sh`) with automatic storage migration recovery
- E2E validation test suite (`lib/e2e-tests.sh`) with 19 automated tests across 5 categories
- Standalone test runner (`test-archon.sh`)
- Version pinning for Supabase CLI (2.70.5) to prevent migration drift
- Version drift detection with `.supabase-version-lock` tracking
- `--clean-images` flag for bootstrap to handle CLI version upgrades
- Pre-start container cleanup to prevent orphaned container conflicts
- Automatic retry loop (3 attempts) for Supabase storage migration failures
- CHANGELOG.md with full version history
- Professional README.md for public repository
- Comprehensive AGENTS.md as AI assistant guide

### Fixed
- Storage migration unique constraint violations during bootstrap
- Stale container conflicts preventing clean restarts
- OpenObserve integration with LOGFIRE_ENABLED setting

### Changed
- Consolidated all recovery functions into shared library
- Improved documentation for public release

## [0.6.0] - 2025-12-20

### Added
- Work-orders profile support in archon-up.sh
- Agent Work Orders service integration (port 8053)
- `--force` flag for stop-archon.sh to clean stale containers

### Fixed
- Bootstrap script preventing stale containers and root ownership issues
- Container cleanup during service lifecycle management

## [0.5.0] - 2025-11-27

### Added
- Upstream sync capability in bootstrap (`scripts/sync-main.sh`)
- Service lifecycle management with proper start/stop sequencing
- SUPABASE_URL configuration in .env

### Changed
- Bootstrap now syncs fork with upstream before starting services

### Removed
- Outdated pdi-insights-report.md documentation

## [0.4.0] - 2025-10-03

### Added
- Comprehensive diagnostic script (`diagnostics/check-archon.sh`) for system health checks
- Fresh database install support with `--fresh` flag
- Runtime migration file copying from archon-src

### Changed
- Migration runner now points to archon-src for SQL files
- Migrations are copied at runtime and kept untracked locally

### Removed
- Duplicate migration files (now sourced from upstream)

## [0.3.0] - 2025-09-20

### Added
- Restart script (`restart-archon-services.sh`) for Archon services with Supabase integration
- Hybrid search with tsvector support
- Multi-dimensional embedding support (384, 768, 1024, 1536, 3072 dimensions)

### Changed
- Enhanced SQL migrations for multi-dimensional embedding columns
- Improved setup scripts for better repository management

## [0.2.0] - 2025-09-17

### Added
- Fork workflow documentation
- Sync helper script (`scripts/sync-main.sh`) for upstream updates
- Automated Supabase setup in bootstrap

### Changed
- Default WSL host handling improvements
- Polished bootstrap output with better status messages

## [0.1.0] - 2025-09-13

### Added
- Initial AeyeOps Archon minimal stack
- Docker Compose configuration for images-based deployment
- Bootstrap script for source-based deployment
- Migration runner (`migration/run_migrations.py`) with idempotent execution
- Complete database setup SQL (`migration/complete_setup.sql`)
- OpenObserve integration for observability
- AGENTS.md with repository guidelines
- Professional README with dual workflow documentation
- Archon visual assets (stack diagram, emblem)

### Changed
- Simplified Docker Compose to use images with sensible defaults
- Made agents service optional via profile

### Security
- Service role key validation (fail-fast on anon key)
- Environment variable protection (never overwrite existing keys)

---

[Unreleased]: https://github.com/AeyeOps/aeo-archon/compare/v0.8.0...HEAD
[0.8.0]: https://github.com/AeyeOps/aeo-archon/compare/v0.7.0...v0.8.0
[0.7.0]: https://github.com/AeyeOps/aeo-archon/compare/v0.6.0...v0.7.0
[0.6.0]: https://github.com/AeyeOps/aeo-archon/compare/v0.5.0...v0.6.0
[0.5.0]: https://github.com/AeyeOps/aeo-archon/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/AeyeOps/aeo-archon/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/AeyeOps/aeo-archon/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/AeyeOps/aeo-archon/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/AeyeOps/aeo-archon/releases/tag/v0.1.0
