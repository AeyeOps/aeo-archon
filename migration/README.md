# Migration Directory

This directory contains the migration runner script and runtime migration files.

## Migration Source of Truth

All SQL migration files are maintained in `/opt/aeo/archon-src/migration/`

## Running Migrations

Migrations are automatically run when you use `./archon-up.sh`

The script:
1. Copies fresh SQL files from `archon-src/migration/` to this directory
2. Executes migrations via `run_migrations.py`
3. SQL files are not tracked in git (see `.gitignore`)

To skip migrations, use: `./archon-up.sh --no-migrations`

## Migration Structure

After `archon-up.sh` runs, this directory will contain:
- `complete_setup.sql` - Initial database setup (runs first)
- `0.1.0/*.sql` - Version-specific migrations (numbered 001-008)
- `RESET_DB.sql` - Database reset utility
- `backup_database.sql` - Backup utility

## Notes

- SQL files are copied from archon-src at runtime and are untracked
- Single source of truth is maintained in archon-src repository
- Migration tracking uses `archon_migrations` table to ensure idempotency
