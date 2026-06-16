# Agent Instructions

This project uses **bd** (beads) for issue tracking. Run `bd prime` for full workflow context.

## Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --claim  # Claim work atomically
bd close <id>         # Complete work
bd dolt push          # Push beads data to remote
```

## Non-Interactive Shell Commands

**ALWAYS use non-interactive flags** with file operations to avoid hanging on confirmation prompts.

Shell commands like `cp`, `mv`, and `rm` may be aliased to include `-i` (interactive) mode on some systems, causing the agent to hang indefinitely waiting for y/n input.

**Use these forms instead:**
```bash
# Force overwrite without prompting
cp -f source dest           # NOT: cp source dest
mv -f source dest           # NOT: mv source dest
rm -f file                  # NOT: rm file

# For recursive operations
rm -rf directory            # NOT: rm -r directory
cp -rf source dest          # NOT: cp -r source dest
```

**Other commands that may prompt:**
- `scp` - use `-o BatchMode=yes` for non-interactive
- `ssh` - use `-o BatchMode=yes` to fail instead of prompting
- `apt-get` - use `-y` flag
- `brew` - use `HOMEBREW_NO_AUTO_UPDATE=1` env var

<!-- BEGIN BEADS INTEGRATION v:1 profile:minimal hash:ca08a54f -->
## Beads Issue Tracker

This project uses **bd (beads)** for issue tracking. Run `bd prime` to see full workflow context and commands.

### Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --claim  # Claim work
bd close <id>         # Complete work
```

### Rules

- Use `bd` for ALL task tracking — do NOT use TodoWrite, TaskCreate, or markdown TODO lists
- Run `bd prime` for detailed command reference and session close protocol
- Use `bd remember` for persistent knowledge — do NOT use MEMORY.md files

## Session Completion

**When ending a work session**, you MUST complete ALL steps below. Work is NOT complete until `git push` succeeds.

**MANDATORY WORKFLOW:**

1. **File issues for remaining work** - Create issues for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **PUSH TO REMOTE** - This is MANDATORY:
   ```bash
   git pull --rebase
   bd dolt push
   git push
   git status  # MUST show "up to date with origin"
   ```
5. **Clean up** - Clear stashes, prune remote branches
6. **Verify** - All changes committed AND pushed
7. **Hand off** - Provide context for next session

**CRITICAL RULES:**
- Work is NOT complete until `git push` succeeds
- NEVER stop before pushing - that leaves work stranded locally
- NEVER say "ready to push when you are" - YOU must push
- If push fails, resolve and retry until it succeeds
<!-- END BEADS INTEGRATION -->

## API and Security
**CRITICAL: ALWAYS include the `API_TOKEN`** in frontend dashboard requests and API interactions.
This is a recurring mistake. When adding new endpoints or `fetch` calls in the dashboard, you MUST use the `apiUrl(action, params)` wrapper (or ensure `token` is appended appropriately if constructing raw URLs). 
Failing to include the API token results in silent 401 Unauthorized errors that break UI state and dashboard features like stop/start toggle, history loading, or target exclusions.

### Auth: Bearer header preferred
The CGI accepts `Authorization: Bearer <token>` (case-insensitive) and falls back to `?token=...` for backward compatibility. The dashboard's `withApiAuth()` and `apiUrl()` helpers attach the header automatically. New clients should use the header; the query string path is kept for `window.open()` downloads and old scripts.

### Test env vars for files normally under /etc
The test runner runs as a non-root user (CI), so handlers that write to `/etc/...` need env-var overrides to land in `/tmp` instead. The supported overrides:
- `WARDRIVING_TOKEN_FILE`
- `WARDRIVING_MODE_FILE`
- `WARDRIVING_KEEP_PCAP_FILE`
- `WARDRIVING_EXCLUDED_FILE`
- `WARDRIVING_REMOVED_FILE`
- `WARDRIVING_EXTRACTION_MODE_FILE`
- `WARDRIVING_GPU_CRACKING_FILE`
- `WARDRIVING_REMOTE_ENABLED_FILE`
- `WARDRIVING_REMOTE_URL_FILE`
- `WARDRIVING_REMOTE_SECRET_FILE`
- `WARDRIVING_API_CACHE_DIR`
- `WARDRIVING_MNT`
- `WARDRIVING_LIB_DIR`
- `WARDRIVING_TARGETS_FILE`
- `WARDRIVING_WIGLE_TOKEN_FILE`
- `WARDRIVING_PWN_HOST`

When adding a new handler that writes to a fixed path, also add a `${WARDRIVING_X_FILE:-/etc/...}` wrapper in `common.sh` so the handler can be unit-tested without root.

### BusyBox applet compatibility
OpenWrt's BusyBox build does not include `mountpoint` or `findmnt`. Always use `/proc/mounts` for mountpoint checks. The CI does not catch this — only deployment does.

### Service worker cache bumps
The service worker (sw.js) uses `CACHE_NAME = 'owrt-store-vN'`. To force a fresh install on all clients, bump the version. `skipWaiting()` is only called from the `message` handler (not from `install`); do not move it back to install without good reason.
