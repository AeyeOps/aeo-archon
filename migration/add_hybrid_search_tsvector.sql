-- =====================================================
-- Add Hybrid Search with ts_vector Support (idempotent)
-- =====================================================

CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- Update archon_crawled_pages if it exists
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = 'public' AND table_name = 'archon_crawled_pages'
    ) THEN
        RAISE NOTICE 'Updating archon_crawled_pages for hybrid search support.';
        EXECUTE '
            ALTER TABLE archon_crawled_pages
            ADD COLUMN IF NOT EXISTS content_search_vector tsvector
            GENERATED ALWAYS AS (to_tsvector(''english'', content)) STORED
        ';
        EXECUTE 'CREATE INDEX IF NOT EXISTS idx_archon_crawled_pages_content_search ON archon_crawled_pages USING GIN (content_search_vector)';
        EXECUTE 'CREATE INDEX IF NOT EXISTS idx_archon_crawled_pages_content_trgm ON archon_crawled_pages USING GIN (content gin_trgm_ops)';
    ELSE
        RAISE NOTICE 'Table archon_crawled_pages not found; skipping crawled-page hybrid search updates.';
    END IF;
END
$$;

-- Update archon_code_examples if it exists
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = 'public' AND table_name = 'archon_code_examples'
    ) THEN
        RAISE NOTICE 'Updating archon_code_examples for hybrid search support.';
        EXECUTE '
            ALTER TABLE archon_code_examples
            ADD COLUMN IF NOT EXISTS content_search_vector tsvector
            GENERATED ALWAYS AS (to_tsvector(''english'', content || '' '' || COALESCE(summary, ''''))) STORED
        ';
        EXECUTE 'CREATE INDEX IF NOT EXISTS idx_archon_code_examples_content_search ON archon_code_examples USING GIN (content_search_vector)';
        EXECUTE 'CREATE INDEX IF NOT EXISTS idx_archon_code_examples_content_trgm ON archon_code_examples USING GIN (content gin_trgm_ops)';
        EXECUTE 'CREATE INDEX IF NOT EXISTS idx_archon_code_examples_summary_trgm ON archon_code_examples USING GIN (summary gin_trgm_ops)';
    ELSE
        RAISE NOTICE 'Table archon_code_examples not found; skipping code-example hybrid search updates.';
    END IF;
END
$$;

-- Hybrid search function for crawled pages
CREATE OR REPLACE FUNCTION hybrid_search_archon_crawled_pages(
    query_embedding vector(1536),
    query_text TEXT,
    match_count INT DEFAULT 10,
    filter JSONB DEFAULT '{}'::jsonb,
    source_filter TEXT DEFAULT NULL
)
RETURNS TABLE (
    id BIGINT,
    url VARCHAR,
    chunk_number INTEGER,
    content TEXT,
    metadata JSONB,
    source_id TEXT,
    similarity FLOAT,
    match_type TEXT
)
AS $$
BEGIN
    RETURN QUERY
    WITH vector_results AS (
        SELECT
            cp.id,
            cp.url,
            cp.chunk_number,
            cp.content,
            cp.metadata,
            cp.source_id,
            1 - (cp.embedding <=> query_embedding) AS vector_sim
        FROM archon_crawled_pages cp
        WHERE cp.metadata @> filter
          AND (source_filter IS NULL OR cp.source_id = source_filter)
          AND cp.embedding IS NOT NULL
        ORDER BY cp.embedding <=> query_embedding
        LIMIT match_count
    ),
    text_results AS (
        SELECT
            cp.id,
            cp.url,
            cp.chunk_number,
            cp.content,
            cp.metadata,
            cp.source_id,
            ts_rank_cd(cp.content_search_vector, plainto_tsquery('english', query_text)) AS text_sim
        FROM archon_crawled_pages cp
        WHERE cp.metadata @> filter
          AND (source_filter IS NULL OR cp.source_id = source_filter)
          AND cp.content_search_vector @@ plainto_tsquery('english', query_text)
        ORDER BY text_sim DESC
        LIMIT match_count
    ),
    combined_results AS (
        SELECT
            COALESCE(v.id, t.id) AS id,
            COALESCE(v.url, t.url) AS url,
            COALESCE(v.chunk_number, t.chunk_number) AS chunk_number,
            COALESCE(v.content, t.content) AS content,
            COALESCE(v.metadata, t.metadata) AS metadata,
            COALESCE(v.source_id, t.source_id) AS source_id,
            COALESCE(v.vector_sim, t.text_sim, 0)::float8 AS similarity,
            CASE
                WHEN v.id IS NOT NULL AND t.id IS NOT NULL THEN 'hybrid'
                WHEN v.id IS NOT NULL THEN 'vector'
                ELSE 'keyword'
            END AS match_type
        FROM vector_results v
        FULL OUTER JOIN text_results t ON v.id = t.id
    )
    SELECT *
    FROM combined_results
    ORDER BY similarity DESC
    LIMIT match_count;
END;
$$ LANGUAGE plpgsql;

-- Hybrid search function for code examples
CREATE OR REPLACE FUNCTION hybrid_search_archon_code_examples(
    query_embedding vector(1536),
    query_text TEXT,
    match_count INT DEFAULT 10,
    filter JSONB DEFAULT '{}'::jsonb,
    source_filter TEXT DEFAULT NULL
)
RETURNS TABLE (
    id BIGINT,
    url VARCHAR,
    chunk_number INTEGER,
    content TEXT,
    summary TEXT,
    metadata JSONB,
    source_id TEXT,
    similarity FLOAT,
    match_type TEXT
)
AS $$
BEGIN
    RETURN QUERY
    WITH vector_results AS (
        SELECT
            ce.id,
            ce.url,
            ce.chunk_number,
            ce.content,
            ce.summary,
            ce.metadata,
            ce.source_id,
            1 - (ce.embedding <=> query_embedding) AS vector_sim
        FROM archon_code_examples ce
        WHERE ce.metadata @> filter
          AND (source_filter IS NULL OR ce.source_id = source_filter)
          AND ce.embedding IS NOT NULL
        ORDER BY ce.embedding <=> query_embedding
        LIMIT match_count
    ),
    text_results AS (
        SELECT
            ce.id,
            ce.url,
            ce.chunk_number,
            ce.content,
            ce.summary,
            ce.metadata,
            ce.source_id,
            ts_rank_cd(ce.content_search_vector, plainto_tsquery('english', query_text)) AS text_sim
        FROM archon_code_examples ce
        WHERE ce.metadata @> filter
          AND (source_filter IS NULL OR ce.source_id = source_filter)
          AND ce.content_search_vector @@ plainto_tsquery('english', query_text)
        ORDER BY text_sim DESC
        LIMIT match_count
    ),
    combined_results AS (
        SELECT
            COALESCE(v.id, t.id) AS id,
            COALESCE(v.url, t.url) AS url,
            COALESCE(v.chunk_number, t.chunk_number) AS chunk_number,
            COALESCE(v.content, t.content) AS content,
            COALESCE(v.summary, t.summary) AS summary,
            COALESCE(v.metadata, t.metadata) AS metadata,
            COALESCE(v.source_id, t.source_id) AS source_id,
            COALESCE(v.vector_sim, t.text_sim, 0)::float8 AS similarity,
            CASE
                WHEN v.id IS NOT NULL AND t.id IS NOT NULL THEN 'hybrid'
                WHEN v.id IS NOT NULL THEN 'vector'
                ELSE 'keyword'
            END AS match_type
        FROM vector_results v
        FULL OUTER JOIN text_results t ON v.id = t.id
    )
    SELECT *
    FROM combined_results
    ORDER BY similarity DESC
    LIMIT match_count;
END;
$$ LANGUAGE plpgsql;
