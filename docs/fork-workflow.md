# Archon Fork Workflow (AeyeOps)

This repository (`AeyeOps/aeo-archon`) tracks the upstream project at
[`coleam00/archon`](https://github.com/coleam00/archon) and carries our local
changes.  The goal is to keep our fork rebased onto upstream so that we can
retire patches as the community adopts them, while still iterating rapidly.

## Remote layout

Clone the repo and configure the remotes once:

```bash
# inside /opt/aeo/aeo-archon
git remote -v
# origin   https://github.com/AeyeOps/aeo-archon.git

# the embedded `archon-src` checkout keeps the upstream codebase
cd archon-src
git remote rename origin upstream                          # upstream = coleam00/archon
git remote add origin https://github.com/AeyeOps/Archon.git  # our fork
```

After configuring remotes you should see something like:

```
origin   https://github.com/AeyeOps/Archon.git (fetch/push)
upstream https://github.com/coleam00/archon.git (fetch/push)
```

## Daily development flow

1. **Sync with upstream** before starting work:
   ```bash
   cd /opt/aeo/aeo-archon/archon-src
   ../../scripts/sync-upstream.sh          # defaults to `main`
   ```

2. **Create a feature branch** from our fork’s `main`:
   ```bash
   git checkout -b feature/my-change origin/main
   ```

3. **Make changes & commit locally.** Keep commits focused; run formatting or
tests as required.

4. **Push the branch to our fork** and open a pull request _into our fork’s
`main`_.
   ```bash
   git push -u origin feature/my-change
   # then open a PR on github.com/AeyeOps/Archon
   ```

5. **Review & merge** the PR into `AeyeOps/Archon:main`.

6. **Optionally refresh the outer repo** (`/opt/aeo/aeo-archon`) with the same
branch name so helper scripts (`archon-up.sh`, docs, etc.) stay aligned.

7. **When upstream catches up,** use `scripts/sync-upstream.sh` again to rebase
our fork and drop any local patches that upstream replaced.

## Helper scripts

- `scripts/sync-upstream.sh` — fetches upstream, rebases our `main`, and pushes
  it back to `origin`. Supply a branch name to rebase something other than
  `main`.

Feel free to add additional helper scripts (e.g., branch creation, lint/test
wrappers) as the workflow evolves.

## Default credentials/config

- Git user name: `Steve Antonakakis`
- Git email: `steve.antonakakis@gmail.com`
- GitHub account: `steveant`

Ensure the same identity is configured in other checkouts:

```bash
git config --global user.name "Steve Antonakakis"
git config --global user.email "steve.antonakakis@gmail.com"
```

## Upstream PRs

When our `main` accumulates fixes worth sharing upstream:

1. Make sure `main` is rebased onto `upstream/main`.
2. Open a PR from `AeyeOps/Archon:main` to `coleam00/archon:main`.
3. Once merged upstream, rerun `scripts/sync-upstream.sh` to drop the fork-side
   delta if the change is now upstream.

This keeps our fork clean and makes periodic upstream contributions painless.
