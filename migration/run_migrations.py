#!/usr/bin/env python3
"""
Database Migration Runner for Archon
Tracks and executes database migrations in order
"""

import os
import sys
import hashlib
import psycopg2
from psycopg2.extensions import ISOLATION_LEVEL_AUTOCOMMIT
from pathlib import Path
import logging
import argparse

logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
logger = logging.getLogger(__name__)

class MigrationRunner:
    def __init__(self, db_config, fresh=False):
        self.db_config = db_config
        self.conn = None
        self.fresh = fresh
        # Use local migration directory (files copied from archon-src at runtime)
        self.migrations_dir = Path(__file__).parent
        # Utility scripts that should not auto-run (unless --fresh mode)
        self.utility_scripts = {'RESET_DB.sql', 'backup_database.sql'}
        
    def connect(self):
        """Connect to the database"""
        try:
            self.conn = psycopg2.connect(**self.db_config)
            self.conn.set_isolation_level(ISOLATION_LEVEL_AUTOCOMMIT)
            logger.info("Connected to database successfully")
            return True
        except Exception as e:
            logger.error(f"Failed to connect to database: {e}")
            return False
    
    def create_migrations_table(self):
        """Create the migrations tracking table if it doesn't exist (upstream schema)"""
        with self.conn.cursor() as cur:
            # Use upstream archon-src schema
            cur.execute("""
                CREATE TABLE IF NOT EXISTS archon_migrations (
                    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
                    version VARCHAR(20) NOT NULL,
                    migration_name VARCHAR(255) NOT NULL,
                    applied_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
                    checksum VARCHAR(32),
                    UNIQUE(version, migration_name)
                );
            """)

            cur.execute("""
                CREATE INDEX IF NOT EXISTS idx_archon_migrations_version
                ON archon_migrations(version);
            """)

            cur.execute("""
                CREATE INDEX IF NOT EXISTS idx_archon_migrations_applied_at
                ON archon_migrations(applied_at DESC);
            """)

            logger.info("Migrations table ready")
    
    def get_file_checksum(self, filepath):
        """Calculate MD5 checksum of a file (upstream uses MD5)"""
        md5_hash = hashlib.md5()
        with open(filepath, "rb") as f:
            for byte_block in iter(lambda: f.read(4096), b""):
                md5_hash.update(byte_block)
        return md5_hash.hexdigest()

    def get_version_from_path(self, filepath):
        """Extract version from file path (e.g., '0.1.0' from 0.1.0/001_*.sql)"""
        path_parts = filepath.parts
        # Check if file is in a versioned subdirectory
        for part in path_parts:
            if part and part[0].isdigit() and '.' in part:
                return part
        return 'base'  # For files like complete_setup.sql not in versioned dirs
    
    def is_migration_executed(self, version, migration_name):
        """Check if a migration has already been executed (upstream schema)"""
        with self.conn.cursor() as cur:
            cur.execute("""
                SELECT checksum FROM archon_migrations
                WHERE version = %s AND migration_name = %s
            """, (version, migration_name))
            result = cur.fetchone()
            return result is not None
    
    def execute_reset(self):
        """Execute RESET_DB.sql for fresh install"""
        reset_file = self.migrations_dir / "RESET_DB.sql"
        if not reset_file.exists():
            logger.error("RESET_DB.sql not found - cannot perform fresh install")
            return False

        logger.warning("FRESH INSTALL MODE: Dropping all existing Archon tables!")
        logger.info("Executing RESET_DB.sql...")

        try:
            with open(reset_file, 'r') as f:
                sql_content = f.read()

            with self.conn.cursor() as cur:
                cur.execute(sql_content)

            logger.info("Database reset completed successfully")
            return True

        except Exception as e:
            logger.error(f"Failed to reset database: {e}")
            return False

    def execute_migration(self, filepath, skip_tracking=False):
        """Execute a single migration file (upstream schema)"""
        migration_name = filepath.name
        version = self.get_version_from_path(filepath)
        checksum = self.get_file_checksum(filepath)

        # Skip if already executed (unless skip_tracking)
        if not skip_tracking and self.is_migration_executed(version, migration_name):
            logger.info(f"Skipping {migration_name} - already executed")
            return True

        logger.info(f"Executing migration: {migration_name}")

        try:
            with open(filepath, 'r') as f:
                sql_content = f.read()

            with self.conn.cursor() as cur:
                # Execute the migration
                cur.execute(sql_content)

                # Record successful execution (unless skip_tracking)
                if not skip_tracking:
                    cur.execute("""
                        INSERT INTO archon_migrations (version, migration_name, checksum)
                        VALUES (%s, %s, %s)
                        ON CONFLICT (version, migration_name) DO NOTHING
                    """, (version, migration_name, checksum))

                    logger.info(f"Successfully executed {migration_name}")
                else:
                    logger.info(f"Successfully executed {migration_name}")
                return True

        except Exception as e:
            logger.error(f"Failed to execute {migration_name}: {e}")
            return False
    
    def run_migrations(self):
        """Run all pending migrations in order"""
        if not self.connect():
            return False

        try:
            # If fresh mode, run RESET_DB.sql first
            if self.fresh:
                if not self.execute_reset():
                    logger.error("Fresh install failed during database reset")
                    return False

            # Create migrations tracking table
            self.create_migrations_table()

            # Get all SQL files in migrations directory and subdirectories
            def sort_key(path: Path):
                name = path.name
                # complete_setup.sql runs first
                if name == "complete_setup.sql":
                    return (0, "", name)
                # Then numbered migrations in 0.1.0 subdirectory
                if "0.1.0" in str(path):
                    return (1, str(path.parent), name)
                # Everything else alphabetically
                return (2, str(path.parent), name)

            # Collect all migration files, avoiding duplicates
            all_files = set()
            # Add root-level SQL files (like complete_setup.sql)
            all_files.update(self.migrations_dir.glob("*.sql"))
            # Add subdirectory SQL files (like 0.1.0/001_*.sql)
            for subdir in self.migrations_dir.iterdir():
                if subdir.is_dir():
                    all_files.update(subdir.glob("*.sql"))

            # Filter out utility scripts (unless in fresh mode where they've already been handled)
            migration_files = [
                f for f in sorted(all_files, key=sort_key)
                if f.name not in self.utility_scripts
            ]

            if not migration_files:
                logger.info("No migration files found")
                return True

            logger.info(f"Found {len(migration_files)} migration files")

            success_count = 0
            fail_count = 0

            for migration_file in migration_files:
                if self.execute_migration(migration_file):
                    success_count += 1
                else:
                    fail_count += 1

            if success_count > 0:
                with self.conn.cursor() as cur:
                    cur.execute("NOTIFY pgrst, 'reload schema';")
                logger.info("Requested PostgREST schema reload")

            logger.info(f"Migration summary: {success_count} successful, {fail_count} failed")

            return fail_count == 0

        finally:
            if self.conn:
                self.conn.close()
                logger.info("Database connection closed")

def main():
    parser = argparse.ArgumentParser(
        description='Database Migration Runner for Archon',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Normal migration (skip utility scripts)
  python run_migrations.py

  # Fresh install (wipe database and reinstall)
  python run_migrations.py --fresh

Notes:
  - Normal mode skips RESET_DB.sql and backup_database.sql
  - Fresh mode runs RESET_DB.sql first, then all migrations
  - Use --fresh for clean reinstall or when base schema is corrupted
        """
    )
    parser.add_argument(
        '--fresh',
        action='store_true',
        help='Perform fresh install: wipe database and run all migrations from scratch'
    )

    args = parser.parse_args()

    # Database configuration from environment or defaults
    db_config = {
        'host': os.getenv('DB_HOST', 'localhost'),
        'port': int(os.getenv('DB_PORT', '54322')),
        'database': os.getenv('DB_NAME', 'postgres'),
        'user': os.getenv('DB_USER', 'postgres'),
        'password': os.getenv('DB_PASSWORD', 'postgres')
    }

    runner = MigrationRunner(db_config, fresh=args.fresh)
    success = runner.run_migrations()

    sys.exit(0 if success else 1)

if __name__ == "__main__":
    main()
