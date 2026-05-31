# Project Instructions for AI Agents

This file provides instructions and context for AI coding agents working on this project.

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


## Architecture Overview

**OpenWardRivingT** is a headless autonomous wardriving suite for OpenWrt routers. It has 5 layers:

### Layer 1: Core Capture (`wardriving_core.sh`)
- Infinite loop: mount check → hcxdumptool capture → hcxpcapngtool conversion → SQLite insert
- Sessions are 3s (`-t 3 --tot=5`), producing `.pcapng` files on USB
- Converts pcapng → `.hc2200` (PMKID hashes) + CSV via `hcxpcapngtool`
- Merges hashes into `master.hc2200` with `sort -u` dedup
- Inserts network metadata into SQLite (`/mnt/wardriving/wardriving.db`)
- Manages GPS via virtual PTY (`socat` → `/tmp/vGPS` → `hcxdumptool --nmea_dev`)

### Layer 2: GPS Bridge (Built-in + Browser)
- **NMEA hardware path**: USB/Serial GPS → `socat` TCP:2947 → virtual PTY → hcxdumptool
- **Browser GPS path**: HTML5 Geolocation → JS generates synthetic NMEA → POST to CGI → forward to TCP:2947
- NMEA data is saved alongside captures for replay/map features

### Layer 3: API (`wardriving_api` CGI)
- Shell CGI under uhttpd at `/cgi-bin/wardriving_api`
- Token-authenticated for write operations (read from `/etc/wardriving_api_token`)
- Read endpoints: status, map_data, heatmap_data, scored_networks, history
- Write endpoints: start, stop, delete_file, set_hw, wigle_upload, upload_tiles

### Layer 4: Web Dashboard (`index.html`)
- Single-page app, 4-column responsive layout (car head unit optimized)
- Leaflet.js maps with offline/online tile toggle
- Live spectrum analyzer (accordion tree view)
- Real-time stats via polling (status every 3s, map every 4s, scores every 5s)

### Layer 5: Init & Install
- `/etc/init.d/wardriving`: OpenWrt init script (START=99)
- `install.sh`: Auto-detects apk/opkg, configures USB fstab, WiFi AP, cron sync
- `uninstall.sh`: Clean removal with config wipe

### Data Flow
```
GPS Device → NMEA serial → socat TCP:2947 → /tmp/vGPS → hcxdumptool
                                                      ↓
wlan0mon → hcxdumptool → .pcapng → hcxpcapngtool → .hc2200 → master.hc2200
                                    ↓                ↓
                                  .csv → sqlite3 → wardriving.db
                                    ↓
                            master_essid.txt
```

## Build & Test

No build step required — this is pure shell + vanilla JS. Files are deployed directly by `install.sh`.

### Testing manually:
```bash
# CGI smoke test (from router shell)
QUERY_STRING='action=status' sh /www/cgi-bin/wardriving_api

# Core script dry-run (will fail without monitor interface)
bash -x /usr/bin/wardriving_core.sh

# Init script
/etc/init.d/wardriving start
/etc/init.d/wardriving stop

# NMEA parse test
echo '$GPRMC,123519,A,4807.038,N,01131.000,E,022.4,084.4,230394,003.1,W*6A' | awk '{...}'
```

## Conventions & Patterns

### Shell Scripting (OpenWrt BusyBox)
- **Shebang**: `#!/bin/sh` (NOT bash — OpenWrt uses BusyBox ash)
- **No bashisms**: No arrays `()`, no `[[` (use `[`), no `&>` (use `>file 2>&1`), no `source` (use `.`)
- **PID tracking**: Always write PIDs to `/var/run/` for clean shutdown
- **Signal traps**: Every infinite-loop script MUST have `trap cleanup SIGTERM SIGINT SIGHUP`
- **Temp files**: Use `mktemp` for atomic writes. Never write directly to system config paths.
- **Logging**: Use `logger -t "openwardrivingt"` for syslog. Write runtime logs to `/tmp/` (tmpfs).
- **USB safety**: Always check `mount | grep /mnt/wardriving` before writing to flash.

### CGI Patterns
- **Auth**: Extract token, check against `/etc/wardriving_api_token` for write actions
- **Response**: Always emit `Content-Type` header + blank line before body
- **JSON**: Build manually with `cat << JSON` heredocs. Validate with `python3 -m json.tool`
- **NMEA parsing**: Extract to shared `parse_nmea()` function. Do NOT copy-paste the awk block.

### JavaScript (Dashboard)
- **No build step**: Vanilla JS only. No npm, no bundler.
- **localStorage**: Only for UI preferences (night mode, map toggle, audio). Never for secrets.
- **Polling**: `setInterval` for status(3s), map(4s), scores(5s). Respect router CPU.
- **Fetch override**: Monkey-patched with auth token injection. All `fetch()` calls auto-include token.

### Git Hygiene
- **No large binaries**: `oui.csv` (3.7MB) is source; `oui.json` (869KB) is the deployed artifact
- **Commit messages**: English, conventional commits: `fix:`, `feat:`, `docs:`, `security:`
- **Beads sync**: Run `bd dolt push` after `git push`
