-- =====================================================================
-- ARCHON PRE-MIGRATION BACKUP SCRIPT (idempotent)
-- =====================================================================

DO $$
DECLARE
    _table text;
    tables_missing boolean := false;
    backup_suffix text;
    crawled_count bigint;
    code_count bigint;
    sources_count bigint;
BEGIN
    FOR _table IN SELECT unnest(ARRAY['archon_crawled_pages','archon_code_examples','archon_sources']) LOOP
        IF NOT EXISTS (
            SELECT 1 FROM information_schema.tables
            WHERE table_schema = 'public' AND table_name = _table
        ) THEN
            tables_missing := true;
            RAISE NOTICE 'Table % not found; skipping backup.', _table;
        END IF;
    END LOOP;

    IF tables_missing THEN
        RAISE NOTICE 'One or more required tables missing. Backup script skipped.';
        RETURN;
    END IF;

    backup_suffix := to_char(now(), 'YYYYMMDD_HH24MISS');

    EXECUTE format('CREATE TABLE IF NOT EXISTS archon_crawled_pages_backup_%s AS SELECT * FROM archon_crawled_pages', backup_suffix);
    EXECUTE format('CREATE TABLE IF NOT EXISTS archon_code_examples_backup_%s AS SELECT * FROM archon_code_examples', backup_suffix);
    EXECUTE format('CREATE TABLE IF NOT EXISTS archon_sources_backup_%s AS SELECT * FROM archon_sources', backup_suffix);

    EXECUTE format('SELECT COUNT(*) FROM archon_crawled_pages_backup_%s', backup_suffix) INTO crawled_count;
    EXECUTE format('SELECT COUNT(*) FROM archon_code_examples_backup_%s', backup_suffix) INTO code_count;
    EXECUTE format('SELECT COUNT(*) FROM archon_sources_backup_%s', backup_suffix) INTO sources_count;

    RAISE NOTICE 'Created backup tables with suffix %.', backup_suffix;
    RAISE NOTICE 'archon_crawled_pages_backup_%', backup_suffix;
    RAISE NOTICE 'archon_code_examples_backup_%', backup_suffix;
    RAISE NOTICE 'archon_sources_backup_%', backup_suffix;
    RAISE NOTICE 'Backup counts: crawled=% sources=% sources=%', crawled_count, code_count, sources_count;
END
$$;
