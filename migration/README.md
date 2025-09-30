# Migration Directory

This directory contains the migration runner script that executes SQL migrations
from the source repository.

## Migration Source

All SQL migration files are located in `/opt/aeo/archon-src/migration/`

The `run_migrations.py` script automatically discovers and executes migrations from there.

## Running Migrations

Migrations are automatically run when you use `./archon-up.sh`

To skip migrations, use: `./archon-up.sh --no-migrations`

## Migration Structure

- `/opt/aeo/archon-src/migration/complete_setup.sql` - Initial database setup (runs first)
- `/opt/aeo/archon-src/migration/0.1.0/` - Version-specific migrations (numbered 001-008)
- `/opt/aeo/archon-src/migration/RESET_DB.sql` - Database reset utility
- `/opt/aeo/archon-src/migration/backup_database.sql` - Backup utility

## Notes

- This directory used to contain duplicate migration files - those have been removed
- All migrations are now maintained in the archon-src repository
- The `run_migrations.py` script points to archon-src for single source of truth
