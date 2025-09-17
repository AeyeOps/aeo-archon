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
from datetime import datetime
from pathlib import Path
import logging

logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
logger = logging.getLogger(__name__)

class MigrationRunner:
    def __init__(self, db_config):
        self.db_config = db_config
        self.conn = None
        self.migrations_dir = Path(__file__).parent
        
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
        """Create the migrations tracking table if it doesn't exist"""
        with self.conn.cursor() as cur:
            cur.execute("""
                CREATE TABLE IF NOT EXISTS archon_migrations (
                    id SERIAL PRIMARY KEY,
                    filename VARCHAR(255) UNIQUE NOT NULL,
                    checksum VARCHAR(64) NOT NULL,
                    executed_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
                    executed_by VARCHAR(100) DEFAULT CURRENT_USER,
                    execution_time_ms INTEGER,
                    status VARCHAR(20) DEFAULT 'success',
                    error_message TEXT
                );
            """)
            
            cur.execute("""
                CREATE INDEX IF NOT EXISTS idx_archon_migrations_filename 
                ON archon_migrations(filename);
            """)
            
            cur.execute("""
                CREATE INDEX IF NOT EXISTS idx_archon_migrations_status 
                ON archon_migrations(status);
            """)
            
            logger.info("Migrations table ready")
    
    def get_file_checksum(self, filepath):
        """Calculate SHA256 checksum of a file"""
        sha256_hash = hashlib.sha256()
        with open(filepath, "rb") as f:
            for byte_block in iter(lambda: f.read(4096), b""):
                sha256_hash.update(byte_block)
        return sha256_hash.hexdigest()
    
    def is_migration_executed(self, filename, checksum):
        """Check if a migration has already been executed"""
        with self.conn.cursor() as cur:
            cur.execute("""
                SELECT checksum, status FROM archon_migrations 
                WHERE filename = %s
            """, (filename,))
            result = cur.fetchone()
            
            if result:
                stored_checksum, status = result
                if stored_checksum != checksum:
                    logger.warning(f"Migration {filename} has changed since last execution")
                    return False
                if status != 'success':
                    logger.warning(f"Migration {filename} previously failed, will retry")
                    return False
                return True
            return False
    
    def execute_migration(self, filepath):
        """Execute a single migration file"""
        filename = filepath.name
        checksum = self.get_file_checksum(filepath)
        
        if self.is_migration_executed(filename, checksum):
            logger.info(f"Skipping {filename} - already executed")
            return True
        
        logger.info(f"Executing migration: {filename}")
        start_time = datetime.now()
        
        try:
            with open(filepath, 'r') as f:
                sql_content = f.read()
            
            with self.conn.cursor() as cur:
                # Execute the migration
                cur.execute(sql_content)
                
                # Record successful execution
                execution_time_ms = int((datetime.now() - start_time).total_seconds() * 1000)
                cur.execute("""
                    INSERT INTO archon_migrations (filename, checksum, execution_time_ms, status)
                    VALUES (%s, %s, %s, 'success')
                    ON CONFLICT (filename) 
                    DO UPDATE SET 
                        checksum = EXCLUDED.checksum,
                        executed_at = NOW(),
                        execution_time_ms = EXCLUDED.execution_time_ms,
                        status = 'success',
                        error_message = NULL
                """, (filename, checksum, execution_time_ms))
                
            logger.info(f"Successfully executed {filename} in {execution_time_ms}ms")
            return True
            
        except Exception as e:
            logger.error(f"Failed to execute {filename}: {e}")
            
            # Record failure
            with self.conn.cursor() as cur:
                cur.execute("""
                    INSERT INTO archon_migrations (filename, checksum, status, error_message)
                    VALUES (%s, %s, 'failed', %s)
                    ON CONFLICT (filename) 
                    DO UPDATE SET 
                        checksum = EXCLUDED.checksum,
                        executed_at = NOW(),
                        status = 'failed',
                        error_message = EXCLUDED.error_message
                """, (filename, checksum, str(e)))
            
            return False
    
    def run_migrations(self):
        """Run all pending migrations in order"""
        if not self.connect():
            return False

        try:
            self.create_migrations_table()

            # Get all SQL files in migrations directory
            def sort_key(path: Path):
                name = path.name
                if name == "complete_setup.sql":
                    return (0, name)
                return (1, name)

            migration_files = sorted(self.migrations_dir.glob("*.sql"), key=sort_key)
            
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
    # Database configuration from environment or defaults
    db_config = {
        'host': os.getenv('DB_HOST', 'localhost'),
        'port': int(os.getenv('DB_PORT', '54322')),
        'database': os.getenv('DB_NAME', 'postgres'),
        'user': os.getenv('DB_USER', 'postgres'),
        'password': os.getenv('DB_PASSWORD', 'postgres')
    }
    
    runner = MigrationRunner(db_config)
    success = runner.run_migrations()
    
    sys.exit(0 if success else 1)

if __name__ == "__main__":
    main()
