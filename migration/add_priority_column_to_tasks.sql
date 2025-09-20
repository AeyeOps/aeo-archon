-- =====================================================
-- Add priority column to archon_tasks table (idempotent)
-- =====================================================

-- Ensure task_priority enum exists
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_type WHERE typname = 'task_priority'
    ) THEN
        CREATE TYPE task_priority AS ENUM ('low', 'medium', 'high', 'critical');
        RAISE NOTICE 'Created task_priority enum.';
    ELSE
        RAISE NOTICE 'task_priority enum already exists; skipping creation.';
    END IF;
END
$$;

-- Main migration guarded by table existence
DO $$
DECLARE
    updated_count INTEGER;
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = 'public' AND table_name = 'archon_tasks'
    ) THEN
        RAISE NOTICE 'Table archon_tasks not found; skipping priority column migration.';
        RETURN;
    END IF;

    -- Add column (nullable) if missing
    BEGIN
        ALTER TABLE archon_tasks ADD COLUMN IF NOT EXISTS priority task_priority;
        RAISE NOTICE 'Ensured archon_tasks.priority column exists.';
    EXCEPTION
        WHEN OTHERS THEN
            RAISE NOTICE 'Unable to ensure priority column: %', SQLERRM;
            RETURN;
    END;

    -- Ensure default and NOT NULL constraints
    UPDATE archon_tasks SET priority = 'medium' WHERE priority IS NULL;
    BEGIN
        ALTER TABLE archon_tasks ALTER COLUMN priority SET DEFAULT 'medium';
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'priority column already has default or could not set default: %', SQLERRM;
    END;
    BEGIN
        ALTER TABLE archon_tasks ALTER COLUMN priority SET NOT NULL;
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'priority column already NOT NULL or constraint unchanged: %', SQLERRM;
    END;

    GET DIAGNOSTICS updated_count = ROW_COUNT;
    RAISE NOTICE 'Updated % tasks with default medium priority.', updated_count;
END
$$;

-- Index creation guarded separately
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = 'public' AND table_name = 'archon_tasks'
    ) THEN
        EXECUTE 'CREATE INDEX IF NOT EXISTS idx_archon_tasks_priority ON archon_tasks(priority)';
        RAISE NOTICE 'Ensured idx_archon_tasks_priority index exists.';
        EXECUTE 'COMMENT ON COLUMN archon_tasks.priority IS ''Task priority level independent of visual ordering - used for semantic importance (low, medium, high, critical)''';
    ELSE
        RAISE NOTICE 'Table archon_tasks not found; skipping priority index/comment.';
    END IF;
END
$$;
