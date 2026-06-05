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
- Sessions use 3-second dwell time and 1-minute capture windows (`-t 3 --tot=1`), producing `.pcapng` files on USB
- Converts pcapng → `.hc2200` (PMKID hashes) + CSV via `hcxpcapngtool`
- Merges hashes into `master.hc2200` with `sort -u` dedup
- Inserts network metadata into SQLite (`/mnt/wardriving/wardriving.db`)
- Manages GPS via virtual PTY (`socat` → `/tmp/vGPS` → `hcxdumptool --nmea_dev`)

### Layer 2: GPS Bridge (Built-in + Browser)
- **NMEA path**: browser HTML5 Geolocation → JS generates synthetic NMEA → POST to CGI → `/tmp/vGPS_fifo` → `socat` virtual PTY (`/tmp/vGPS`) → hcxdumptool
- NMEA data is saved alongside captures for replay/map features

### Layer 3: API (`wardriving_api` CGI)
- Shell CGI under uhttpd at `/cgi-bin/wardriving_api`
- Dispatcher sources shared modules from `/usr/lib/wardriving/` and grouped handlers from `/usr/lib/wardriving/handlers/`
- Token-authenticated for write operations and sensitive read/export operations (read from `/etc/wardriving_api_token`)
- Public endpoint: status
- Sensitive read/export endpoints: map_data, heatmap_data, scored_networks, history, list_files, cracked_networks, export_*.
- Write endpoints: start, stop, delete_file, set_hw, set_processing, wigle_upload, upload_tiles, upload_potfile, pwnagotchi_sync.
- Remote GPU processing uses authenticated JSONL only. The router validates each row before SQLite insert.

### Layer 4: Web Dashboard (`index.html`, `app.css`, `app.js`)
- Single-page app, 4-column responsive layout (car head unit optimized)
- No build step: HTML shell, CSS, and vanilla JS are split into static files deployed directly
- Leaflet.js maps with offline/online tile toggle
- Live spectrum analyzer (accordion tree view)
- Real-time stats via polling (status every 3s, map every 4s, scores every 5s)

### Layer 5: Init & Install
- `/etc/init.d/wardriving`: OpenWrt init script (START=99)
- `install.sh`: Auto-detects apk/opkg, installs capture tools plus `openssh-sftp-server`, configures USB fstab, WiFi AP, cron sync
- `uninstall.sh`: Clean removal with config wipe

### Test Router Operations
- OpenWrt 24/25 images can use `apk` instead of `opkg`; use `apk update` / `apk add` when `opkg` is absent.
- Modern `scp` requires the router-side SFTP subsystem. Install `openssh-sftp-server` so file copies work without `scp -O`.
- In the current test topology, WireGuard is only needed for GPU access at `10.128.128.254`. Route/allow `10.128.128.254/32`; do not route all of `10.128.128.0/24` through WireGuard if WAN also uses that subnet, or package updates and default routing can break.

### Data Flow
```
Browser GPS → CGI gps_push → /tmp/vGPS_fifo → socat PTY /tmp/vGPS → hcxdumptool
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

# Sensitive endpoint smoke test
QUERY_STRING='action=history&token=YOUR_TOKEN' sh /www/cgi-bin/wardriving_api

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
- **Auth**: Extract token, check against `/etc/wardriving_api_token` for write actions and sensitive read/export actions. `action=status` is the **only** public (token-free) endpoint — explicitly documented to clarify attack surface.
- **Dispatcher**: Keep `/www/cgi-bin/wardriving_api` thin. Add endpoint behavior to the grouped handler modules under `/usr/lib/wardriving/handlers/`.
- **Shared helpers**: Put query/auth/JSON helpers in `common.sh`, SQLite/hash helpers in `db.sh`, and GPU upload/status helpers in `remote.sh`.
- **Response**: Always emit `Content-Type` header + blank line before body
- **JSON**: Build manually with `cat << JSON` heredocs. Validate with `python3 -m json.tool`
- **NMEA parsing**: Extract to shared `parse_nmea()` function. Do NOT copy-paste the awk block.

### JavaScript (Dashboard)
- **No build step**: Vanilla JS only. No npm, no bundler.
- **Static split**: Keep behavior in `app.js`, styles in `app.css`, and the DOM shell in `index.html`.
- **localStorage**: Only for UI preferences (night mode, map toggle, audio). Never for secrets.
- **Polling**: `setInterval` for status(3s), map(4s), scores(5s). Respect router CPU.
- **Fetch override**: Monkey-patched with auth token injection. All `fetch()` calls auto-include token.
- **Escaping**: Any SSID, filename, target, exclusion, or remote status shown via `innerHTML` must pass through the dashboard `esc()` helper or be inserted with DOM text APIs.

### Git Hygiene
- **No large binaries**: `oui.csv` (3.7MB) is source; `oui.json` (869KB) is the deployed artifact
- **Commit messages**: English, conventional commits: `fix:`, `feat:`, `docs:`, `security:`
- **Beads sync**: Run `bd dolt push` after `git push`
