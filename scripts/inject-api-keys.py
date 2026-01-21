#!/usr/bin/env python3
"""
Inject API keys from environment variables into archon_settings.

Reads API keys from environment and inserts/updates them in the database
using the same encryption as credential_service.py.

Usage:
    OPENAI_API_KEY=sk-xxx CREDENTIAL_ENCRYPTION_KEY=xxx python inject-api-keys.py

Environment variables for keys (all optional):
    OPENAI_API_KEY, GEMINI_API_KEY, GROK_API_KEY, GITHUB_TOKEN,
    ANTHROPIC_API_KEY, OPENROUTER_API_KEY

Required (one of):
    CREDENTIAL_ENCRYPTION_KEY - Stable Fernet key (preferred)
    SUPABASE_SERVICE_KEY - Legacy fallback (volatile across restarts)
    DB_HOST, DB_PORT, DB_USER, DB_PASSWORD, DB_NAME - Database connection
"""

import base64
import os
import sys

try:
    import psycopg2
    from cryptography.fernet import Fernet
    from cryptography.hazmat.primitives import hashes
    from cryptography.hazmat.primitives.kdf.pbkdf2 import PBKDF2HMAC
except ImportError:
    print("Installing dependencies...")
    import subprocess
    subprocess.check_call([sys.executable, "-m", "pip", "install", "-q", "psycopg2-binary", "cryptography"])
    import psycopg2
    from cryptography.fernet import Fernet
    from cryptography.hazmat.primitives import hashes
    from cryptography.hazmat.primitives.kdf.pbkdf2 import PBKDF2HMAC


# API keys to check for in environment
API_KEYS = [
    ("OPENAI_API_KEY", "api_keys", "OpenAI API key for embeddings and LLM"),
    ("GEMINI_API_KEY", "api_keys", "Google Gemini API key"),
    ("GROK_API_KEY", "api_keys", "xAI Grok API key"),
    ("ANTHROPIC_API_KEY", "api_keys", "Anthropic Claude API key"),
    ("OPENROUTER_API_KEY", "api_keys", "OpenRouter API key"),
    ("GITHUB_TOKEN", "api_keys", "GitHub personal access token"),
]


def get_encryption_key() -> bytes:
    """Generate encryption key - mirrors credential_service.py"""
    # Check for stable dedicated encryption key first (recommended)
    stable_key = os.getenv("CREDENTIAL_ENCRYPTION_KEY")
    if stable_key:
        # Fernet keys are already valid base64-encoded 32-byte keys
        return stable_key.encode()

    # Fall back to SUPABASE_SERVICE_KEY derivation (legacy - volatile!)
    print("! Warning: CREDENTIAL_ENCRYPTION_KEY not set, using legacy SUPABASE_SERVICE_KEY")
    service_key = os.getenv("SUPABASE_SERVICE_KEY")
    if not service_key:
        raise ValueError("CREDENTIAL_ENCRYPTION_KEY or SUPABASE_SERVICE_KEY required")

    kdf = PBKDF2HMAC(
        algorithm=hashes.SHA256(),
        length=32,
        salt=b"static_salt_for_credentials",  # Must match credential_service.py
        iterations=100000,
    )
    key = base64.urlsafe_b64encode(kdf.derive(service_key.encode()))
    return key


def encrypt_value(value: str, fernet: Fernet) -> str:
    """Encrypt a value and return base64-encoded string."""
    encrypted_bytes = fernet.encrypt(value.encode("utf-8"))
    return base64.urlsafe_b64encode(encrypted_bytes).decode("utf-8")


def main():
    # Database connection from environment
    db_config = {
        "host": os.getenv("DB_HOST", "localhost"),
        "port": int(os.getenv("DB_PORT", "5432")),
        "user": os.getenv("DB_USER", "postgres"),
        "password": os.getenv("DB_PASSWORD", "postgres"),
        "dbname": os.getenv("DB_NAME", "postgres"),
    }

    # Create encryption cipher
    try:
        encryption_key = get_encryption_key()
        fernet = Fernet(encryption_key)
    except ValueError as e:
        print(f"✗ {e}")
        return 1

    # Connect to database
    try:
        conn = psycopg2.connect(**db_config)
        conn.autocommit = True
        cursor = conn.cursor()
    except Exception as e:
        print(f"✗ Could not connect to database: {e}")
        return 1

    # Check if table exists
    cursor.execute("""
        SELECT EXISTS (
            SELECT FROM information_schema.tables
            WHERE table_name = 'archon_settings'
        );
    """)
    if not cursor.fetchone()[0]:
        print("✗ archon_settings table doesn't exist - run migrations first")
        conn.close()
        return 1

    # Process each API key
    injected = 0
    skipped = 0

    for key_name, category, description in API_KEYS:
        value = os.getenv(key_name)

        if not value:
            skipped += 1
            continue

        # Encrypt the value
        encrypted_value = encrypt_value(value, fernet)

        # Upsert into archon_settings
        cursor.execute("""
            INSERT INTO archon_settings (key, encrypted_value, is_encrypted, category, description)
            VALUES (%s, %s, true, %s, %s)
            ON CONFLICT (key) DO UPDATE SET
                encrypted_value = EXCLUDED.encrypted_value,
                is_encrypted = true,
                updated_at = NOW()
        """, (key_name, encrypted_value, category, description))

        print(f"✓ Injected {key_name}")
        injected += 1

    conn.close()

    print(f"\nSummary: {injected} keys injected, {skipped} skipped (not in env)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
