# AEO Archon Minimal Setup

Two ways to run Archon:

1) From images (no source):
   - Copy `.env.sample` to `.env`, set images + Supabase keys
   - `bash ./archon-up.sh`

2) From source (auto-clone repo):
   - `bash ./bootstrap-from-source.sh`
   - If using Supabase CLI locally, run inside the repo:
     - `npx supabase@latest init`
     - `npx supabase start`
   - The bootstrap attempts to auto-populate `.env` with Supabase settings from `supabase/.env` when present.

Endpoints:
- UI: `http://HOST:3737`
- API: `http://HOST:3737/api` (single-port) or `http://HOST:8181`
- MCP: `http://HOST:8051`
- Agents: `http://HOST:8052`
- Observability: `http://HOST:5080`
