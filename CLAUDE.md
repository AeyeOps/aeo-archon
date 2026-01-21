# Claude Code Instructions for aeo-archon

Project-specific instructions for AI assistants working in this repository.

## Critical: Single Entry Point

`bootstrap-archon.sh` is the **sole entry point** for spinning up the stack.

```
bootstrap-archon.sh
    └── calls → archon-up.sh (internally)
                    └── starts Supabase, migrations, Archon, OpenObserve
```

- DO NOT suggest running `archon-up.sh` after bootstrap - it already ran
- Bootstrap is idempotent: safe to re-run anytime
- When user says "I ran bootstrap" - the stack is already up

## Critical: Fork Maintenance

Branch `fix/docker-deployment-improvements` in `/opt/aeo/archon-src` carries critical bug fixes NOT merged upstream.

**DO NOT:**
- Suggest rebasing onto upstream/main
- Suggest switching to main branch
- Cherry-pick from upstream without review

**WHY:** PRs submitted to coleam00/archon are not being merged. Rebasing loses our fixes. We are 300+ commits behind upstream but cannot safely catch up.

The fork sync (`scripts/sync-main.sh`) only syncs the `main` branch, not the working branch.

## Repository Structure

```
/opt/aeo/aeo-archon/     # This repo - operational wrapper
/opt/aeo/archon-src/     # Fork of coleam00/archon (actively used)
```

## Key Configuration

| File | Purpose |
|------|---------|
| `.archon-state` | Persisted config: repo URL, branch, versions |
| `.env` | Runtime config: ports, keys, feature flags |
| `docker-compose.openobserve.yml` | Canonical OpenObserve definition (overlay) |

## Common Mistakes to Avoid

1. Suggesting `archon-up.sh` after bootstrap completes
2. Suggesting rebasing the fork onto upstream
3. Defining OpenObserve in multiple compose files (use overlay only)
4. Using `santonakakis` git credential for AeyeOps repos (use `steveant`)

## See Also

- `AGENTS.md` - Comprehensive documentation for AI assistants
- `README.md` - User-facing documentation
