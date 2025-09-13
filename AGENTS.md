## Beta Development Guidelines

**Local-only deployment** - each user runs their own instance.

### Core Principles

- **No backwards compatibility** - remove deprecated code immediately
- **Detailed errors over graceful failures** - we want to identify and fix issues fast
- **Break things to improve them** - beta is for rapid iteration

### Error Handling

**Core Principle**: In beta, we need to intelligently decide when to fail hard and fast to quickly address issues, and when to allow processes to complete in critical services despite failures. Read below carefully and make intelligent decisions on a case-by-case basis.

#### When to Fail Fast and Loud (Let it Crash!)

These errors should stop execution and bubble up immediately: (except for crawling flows)

- **Service startup failures** - If credentials, database, or any service can't initialize, the system should crash with a clear error
- **Missing configuration** - Missing environment variables or invalid settings should stop the system
- **Database connection failures** - Don't hide connection issues, expose them
- **Authentication/authorization failures** - Security errors must be visible and halt the operation
- **Data corruption or validation errors** - Never silently accept bad data, Pydantic should raise
- **Critical dependencies unavailable** - If a required service is down, fail immediately
- **Invalid data that would corrupt state** - Never store zero embeddings, null foreign keys, or malformed JSON

#### When to Complete but Log Detailed Errors

These operations should continue but track and report failures clearly:

- **Batch processing** - When crawling websites or processing documents, complete what you can and report detailed failures for each item
- **Background tasks** - Embedding generation, async jobs should finish the queue but log failures
- **WebSocket events** - Don't crash on a single event failure, log it and continue serving other clients
- **Optional features** - If projects/tasks are disabled, log and skip rather than crash
- **External API calls** - Retry with exponential backoff, then fail with a clear message about what service failed and why

#### Critical Nuance: Never Accept Corrupted Data

When a process should continue despite failures, it must **skip the failed item entirely** rather than storing corrupted data:

**❌ WRONG - Silent Corruption:**

```python
try:
    embedding = create_embedding(text)
except Exception as e:
    embedding = [0.0] * 1536  # NEVER DO THIS - corrupts database
    store_document(doc, embedding)
```

**✅ CORRECT - Skip Failed Items:**

```python
try:
    embedding = create_embedding(text)
    store_document(doc, embedding)  # Only store on success
except Exception as e:
    failed_items.append({'doc': doc, 'error': str(e)})
    logger.error(f"Skipping document {doc.id}: {e}")
    # Continue with next document, don't store anything
```

**✅ CORRECT - Batch Processing with Failure Tracking:**

```python
def process_batch(items):
    results = {'succeeded': [], 'failed': []}

    for item in items:
        try:
            result = process_item(item)
            results['succeeded'].append(result)
        except Exception as e:
            results['failed'].append({
                'item': item,
                'error': str(e),
                'traceback': traceback.format_exc()
            })
            logger.error(f"Failed to process {item.id}: {e}")

    # Always return both successes and failures
    return results
```

#### Error Message Guidelines

- Include context about what was being attempted when the error occurred
- Preserve full stack traces with `exc_info=True` in Python logging
- Use specific exception types, not generic Exception catching
- Include relevant IDs, URLs, or data that helps debug the issue
- Never return None/null to indicate failure - raise an exception with details
- For batch operations, always report both success count and detailed failure list

### Code Quality

- Remove dead code immediately rather than maintaining it - no backward compatibility or legacy functions
- Prioritize functionality over production-ready patterns
- Focus on user experience and feature completeness
- When updating code, don't reference what is changing (avoid keywords like LEGACY, CHANGED, REMOVED), instead focus on comments that document just the functionality of the code
- When commenting on code in the codebase, only comment on the functionality and reasoning behind the code. Refrain from speaking to Archon being in "beta" or referencing anything else that comes from these global rules.

## Development Commands

### Frontend (archon-ui-main/)

```bash
npm run dev              # Start development server on port 3737
npm run build            # Build for production
npm run lint             # Run ESLint on legacy code (excludes /features)
npm run lint:files path/to/file.tsx  # Lint specific files

# Biome for /src/features directory only
npm run biome            # Check features directory
npm run biome:fix        # Auto-fix issues
npm run biome:format     # Format code (120 char lines)
npm run biome:ai         # Machine-readable JSON output for AI
npm run biome:ai-fix     # Auto-fix with JSON output

# Testing
npm run test             # Run all tests in watch mode
npm run test:ui          # Run with Vitest UI interface
npm run test:coverage:stream  # Run once with streaming output
vitest run src/features/projects  # Test specific directory

# TypeScript
npx tsc --noEmit         # Check all TypeScript errors
npx tsc --noEmit 2>&1 | grep "src/features"  # Check features only
```

### Backend (python/)

```bash
# Using uv package manager (preferred)
uv sync --group all      # Install all dependencies
uv run python -m src.server.main  # Run server locally on 8181
uv run pytest            # Run all tests
uv run pytest tests/test_api_essentials.py -v  # Run specific test
uv run ruff check        # Run linter
uv run ruff check --fix  # Auto-fix linting issues
uv run mypy src/         # Type check

# Docker operations
docker compose up --build -d       # Start all services
docker compose --profile backend up -d  # Backend only (for hybrid dev)
docker compose logs -f archon-server   # View server logs
docker compose logs -f archon-mcp      # View MCP server logs
docker compose restart archon-server   # Restart after code changes
docker compose down      # Stop all services
docker compose down -v   # Stop and remove volumes
```

### Quick Workflows

```bash
# Hybrid development (recommended) - backend in Docker, frontend local
make dev                 # Or manually: docker compose --profile backend up -d && cd archon-ui-main && npm run dev

# Full Docker mode
make dev-docker          # Or: docker compose up --build -d

# Run linters before committing
make lint                # Runs both frontend and backend linters
make lint-fe             # Frontend only (ESLint + Biome)
make lint-be             # Backend only (Ruff + MyPy)

# Testing
make test                # Run all tests
make test-fe             # Frontend tests only
make test-be             # Backend tests only
```

## Architecture Overview

Archon Beta is a microservices-based knowledge management system with MCP (Model Context Protocol) integration:

### Service Architecture

- **Frontend (port 3737)**: React + TypeScript + Vite + TailwindCSS
  - **Dual UI Strategy**:
    - `/features` - Modern vertical slice with Radix UI primitives + TanStack Query
    - `/components` - Legacy custom components (being migrated)
  - **State Management**: TanStack Query for all data fetching (no prop drilling)
  - **Styling**: Tron-inspired glassmorphism with Tailwind CSS
  - **Linting**: Biome for `/features`, ESLint for legacy code

- **Main Server (port 8181)**: FastAPI with HTTP polling for updates
  - Handles all business logic, database operations, and external API calls
  - WebSocket support removed in favor of HTTP polling with ETag caching

- **MCP Server (port 8051)**: Lightweight HTTP-based MCP protocol server
  - Provides tools for AI assistants (Claude, Cursor, Windsurf)
  - Exposes knowledge search, task management, and project operations

- **Agents Service (port 8052)**: PydanticAI agents for AI/ML operations
  - Handles complex AI workflows and document processing

- **Database**: Supabase (PostgreSQL + pgvector for embeddings)
  - Cloud or local Supabase both supported
  - pgvector for semantic search capabilities

### Frontend Architecture Details

#### Vertical Slice Architecture (/features)

Features are organized by domain hierarchy with self-contained modules:

```
src/features/
├── ui/
│   ├── primitives/    # Radix UI base components
│   ├── hooks/         # Shared UI hooks (useSmartPolling, etc)
│   └── types/         # UI type definitions
├── projects/
│   ├── components/    # Project UI components
│   ├── hooks/         # Project hooks (useProjectQueries, etc)
│   ├── services/      # Project API services
│   ├── types/         # Project type definitions
│   ├── tasks/         # Tasks sub-feature (nested under projects)
│   │   ├── components/
│   │   ├── hooks/     # Task-specific hooks
│   │   ├── services/  # Task API services
│   │   └── types/
│   └── documents/     # Documents sub-feature
│       ├── components/
│       ├── services/
│       └── types/
```

#### TanStack Query Patterns

All data fetching uses TanStack Query with consistent patterns:

```typescript
// Query keys factory pattern
export const projectKeys = {
  all: ["projects"] as const,
  lists: () => [...projectKeys.all, "list"] as const,
  detail: (id: string) => [...projectKeys.all, "detail", id] as const,
};

// Smart polling with visibility awareness
const { refetchInterval } = useSmartPolling(10000); // Pauses when tab inactive

// Optimistic updates with rollback
useMutation({
  onMutate: async (data) => {
    await queryClient.cancelQueries(key);
    const previous = queryClient.getQueryData(key);
    queryClient.setQueryData(key, optimisticData);
    return { previous };
  },
  onError: (err, vars, context) => {
    if (context?.previous) {
      queryClient.setQueryData(key, context.previous);
    }
  },
});
```

### Backend Architecture Details

#### Service Layer Pattern

```python
# API Route -> Service -> Database
# src/server/api_routes/projects.py
@router.get("/{project_id}")
async def get_project(project_id: str):
    return await project_service.get_project(project_id)

# src/server/services/project_service.py
async def get_project(project_id: str):
    # Business logic here
    return await db.fetch_project(project_id)
```

#### Error Handling Patterns

```python
# Use specific exceptions
class ProjectNotFoundError(Exception): pass
class ValidationError(Exception): pass

# Rich error responses
@app.exception_handler(ProjectNotFoundError)
async def handle_not_found(request, exc):
    return JSONResponse(
        status_code=404,
        content={"detail": str(exc), "type": "not_found"}
    )
```

## Polling Architecture

### HTTP Polling (replaced Socket.IO)

- **Polling intervals**: 1-2s for active operations, 5-10s for background data
- **ETag caching**: Reduces bandwidth by ~70% via 304 Not Modified responses
- **Smart pausing**: Stops polling when browser tab is inactive
- **Progress endpoints**: `/api/progress/{id}` for operation tracking

### Key Polling Hooks

- `useSmartPolling` - Adjusts interval based on page visibility/focus
- `useCrawlProgressPolling` - Specialized for crawl progress with auto-cleanup
- `useProjectTasks` - Smart polling for task lists

## Database Schema

Key tables in Supabase:

- `sources` - Crawled websites and uploaded documents
  - Stores metadata, crawl status, and configuration
- `documents` - Processed document chunks with embeddings
  - Text chunks with vector embeddings for semantic search
- `projects` - Project management (optional feature)
  - Contains features array, documents, and metadata
- `tasks` - Task tracking linked to projects
  - Status: todo, doing, review, done
  - Assignee: User, Archon, AI IDE Agent
- `code_examples` - Extracted code snippets
  - Language, summary, and relevance metadata

## API Naming Conventions

### Task Status Values

Use database values directly (no UI mapping):

- `todo`, `doing`, `review`, `done`

### Service Method Patterns

- `get[Resource]sByProject(projectId)` - Scoped queries
- `get[Resource](id)` - Single resource
- `create[Resource](data)` - Create operations
- `update[Resource](id, updates)` - Updates
- `delete[Resource](id)` - Soft deletes

### State Naming

- `is[Action]ing` - Loading states (e.g., `isSwitchingProject`)
- `[resource]Error` - Error messages
- `selected[Resource]` - Current selection

## Environment Variables

Required in `.env`:

```bash
SUPABASE_URL=https://your-project.supabase.co  # Or http://host.docker.internal:8000 for local
SUPABASE_SERVICE_KEY=your-service-key-here      # Use legacy key format for cloud Supabase
```

Optional:

```bash
LOGFIRE_TOKEN=your-logfire-token      # For observability
LOG_LEVEL=INFO                         # DEBUG, INFO, WARNING, ERROR
ARCHON_SERVER_PORT=8181               # Server port
ARCHON_MCP_PORT=8051                 # MCP server port
ARCHON_UI_PORT=3737                  # Frontend port
```

## Common Development Tasks

### Add a new API endpoint

1. Create route handler in `python/src/server/api_routes/`
2. Add service logic in `python/src/server/services/`
3. Include router in `python/src/server/main.py`
4. Update frontend service in `archon-ui-main/src/features/[feature]/services/`

### Add a new UI component in features directory

1. Use Radix UI primitives from `src/features/ui/primitives/`
2. Create component in relevant feature folder under `src/features/[feature]/components/`
3. Define types in `src/features/[feature]/types/`
4. Use TanStack Query hook from `src/features/[feature]/hooks/`
5. Apply Tron-inspired glassmorphism styling with Tailwind

### Debug MCP connection issues

1. Check MCP health: `curl http://localhost:8051/health`
2. View MCP logs: `docker compose logs archon-mcp`
3. Test tool execution via UI MCP page
4. Verify Supabase connection and credentials

### Fix TypeScript/Linting Issues

```bash
# TypeScript errors in features
npx tsc --noEmit 2>&1 | grep "src/features"

# Biome auto-fix for features
npm run biome:fix

# ESLint for legacy code
npm run lint:files src/components/SomeComponent.tsx
```

## Code Quality Standards

### Frontend

- **TypeScript**: Strict mode enabled, no implicit any
- **Biome** for `/src/features/`: 120 char lines, double quotes, trailing commas
- **ESLint** for legacy code: Standard React rules
- **Testing**: Vitest with React Testing Library

### Backend

- **Python 3.12** with 120 character line length
- **Ruff** for linting - checks for errors, warnings, unused imports
- **Mypy** for type checking - ensures type safety
- **Pytest** for testing with async support

## MCP Tools Available

When connected to Client/Cursor/Windsurf:

- `archon:perform_rag_query` - Search knowledge base
- `archon:search_code_examples` - Find code snippets
- `archon:create_project` - Create new project
- `archon:list_projects` - List all projects
- `archon:create_task` - Create task in project
- `archon:list_tasks` - List and filter tasks
- `archon:update_task` - Update task status/details
- `archon:get_available_sources` - List knowledge sources

## Important Notes

- Projects feature is optional - toggle in Settings UI
- All services communicate via HTTP, not gRPC
- HTTP polling handles all updates
- Frontend uses Vite proxy for API calls in development
- Python backend uses `uv` for dependency management
- Docker Compose handles service orchestration
- TanStack Query for all data fetching - NO PROP DRILLING
- Vertical slice architecture in `/features` - features own their sub-features

## End-to-End Launch (Docker Compose)

Quick start (single command)

```bash
./archon-up.sh               # auto-detect HOST, enable single-port, start observability (compose) + agents, verify
# Options:
#   --host <ip>            Manually set HOST
#   --observability <compose|script|none>
#   --no-agents            Skip agents service
#   --no-single-port       Keep API on its own port (8181)
#   --no-build             Faster subsequent starts
```

Follow these steps for a complete local or LAN-accessible deployment with Supabase and observability.

1) Configure .env

```bash
# Supabase (choose one)
# Local Supabase CLI
SUPABASE_URL=http://127.0.0.1:54321
SUPABASE_URL_CONTAINER=http://host.docker.internal:54321
# OR Cloud Supabase
# SUPABASE_URL=https://<project>.supabase.co
# SUPABASE_URL_CONTAINER=https://<project>.supabase.co

# Always use the Supabase service_role key (not anon)
SUPABASE_SERVICE_KEY=<service_role_key>

# External access host (IP or domain your users will hit)
# For local LAN: set to your machine IP, e.g., 192.168.1.50
# For public DNS: set to your domain, e.g., archon.example.com
HOST=<your_external_host>

# Frontend host allowlist for the dev server (comma-separated)
VITE_ALLOWED_HOSTS=<your_external_host,optional_additional_hosts>

# Optional: expose API via UI port (single-port access)
# When true, UI serves on 3737 and proxies /api to the backend.
PROD=false

# Observability (choose one)
# A) Using docker compose profile "observability"
OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4318
OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf
OTEL_EXPORTER_OTLP_ENDPOINT_CONTAINER=http://openobserve:4318

# B) Using setup-local-observability.sh (runs a standalone OpenObserve)
# OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4318
# OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf
# OTEL_EXPORTER_OTLP_ENDPOINT_CONTAINER=http://host.docker.internal:4318
```

2) Start services

```bash
# Full stack (server, MCP, frontend)
docker compose up --build -d

# Include agents
docker compose --profile agents up -d

# Option A: Observability via compose
docker compose --profile observability up -d

# Option B: Observability via standalone helper
./setup-local-observability.sh
```

3) Verify health

```bash
# API health
curl http://$HOST:${ARCHON_SERVER_PORT:-8181}/health

# MCP health
curl http://$HOST:${ARCHON_MCP_PORT:-8051}/health

# Agents (if enabled)
curl http://$HOST:${ARCHON_AGENTS_PORT:-8052}/health

# UI
open http://$HOST:${ARCHON_UI_PORT:-3737}

# Observability UI (OpenObserve)
open http://$HOST:5080
```

4) Common URLs & Ports

- UI: `http://$HOST:3737`
- API: `http://$HOST:8181` (proxied under `/api` on port 3737 if `PROD=true`)
- MCP: `http://$HOST:8051`
- Agents: `http://$HOST:8052`
- OpenObserve UI: `http://$HOST:5080`
- OTLP inside Docker network: `http://openobserve:4318` (no public exposure required)

## External Access & Networking

- Set `HOST` in `.env` to a reachable address (LAN IP or public domain). The frontend uses this to build `VITE_API_URL` and allowed hosts.
- Add any external hostnames/IPs to `VITE_ALLOWED_HOSTS`. Vite’s dev server verifies the Host header, and this allowlist ensures requests are accepted.
- The backend enables permissive CORS for development (`allow_origins=["*"]`). If you harden CORS later, include your public origin(s).
- Open firewall/NAT for required ports (at minimum 3737 for UI; 8181 if not using `PROD=true`; optionally 8051/8052 if you access MCP/Agents directly; 5080 for observability UI).
- Single-port mode: set `PROD=true` to serve the API under the UI port (3737) at `/api`, simplifying reverse-proxy and external access.

Examples

```bash
# LAN access example
HOST=192.168.1.50
VITE_ALLOWED_HOSTS=192.168.1.50,myhost.local

docker compose up -d
# UI at: http://192.168.1.50:3737
# API at: http://192.168.1.50:8181  (or http://192.168.1.50:3737/api if PROD=true)
```

## Supabase Setup

- Use the service role key only. The anon key will fail writes with permissions errors.
- For local development using Supabase CLI, defaults are:
  - Host access: `SUPABASE_URL=http://127.0.0.1:54321`
  - Container access: `SUPABASE_URL_CONTAINER=http://host.docker.internal:54321`
- For cloud projects, set both URLs to your `https://<project>.supabase.co` endpoint.
- Initialize schema by running `migration/complete_setup.sql` in the Supabase SQL editor.

## Observability (OpenObserve)

Two supported paths:

- Docker Compose profile:
  - Start: `docker compose --profile observability up -d`
  - UI: `http://$HOST:5080`
  - Containers export to `OTEL_EXPORTER_OTLP_ENDPOINT_CONTAINER=http://openobserve:4318` on the compose network.

- Standalone script (idempotent):
  - Run: `./setup-local-observability.sh`
  - Publishes ports: 5080 (UI), 4317/4318 (OTLP). Sets `.env` for local + container OTLP endpoints.
  - After changes to `.env`, restart services to pick up telemetry settings.

Troubleshooting

- No traces/metrics: ensure `OTEL_EXPORTER_OTLP_ENDPOINT_CONTAINER` matches your chosen path (compose vs script) and restart containers.
- UI loads but API fails: confirm `HOST` and `VITE_ALLOWED_HOSTS` include your external hostname/IP. With `PROD=true`, hit `/api` via port 3737.
- Supabase 401/permission denied: verify you’re using the `service_role` key and the correct `SUPABASE_URL`.

## Agent Ops (Behavior Protocol)

Use this lightweight protocol (from AGENTS-BEHAVIOR.md) when proposing or applying changes:

- Status Block: Plan, Actions, Results, Next (concise, evidence-based)
- Modes: Explore (read), Propose (options), Apply (smallest safe diff), Validate (checks)
- Edit Output Template: list files changed, include a diff, rationale, verification commands, and undo steps
- Safety: reversible steps, limited scope, no secrets in outputs
