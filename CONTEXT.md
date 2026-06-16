# OpenWardRivingT Context

This file provides architectural context for AI agents working on the OpenWardRivingT project, preventing the need to analyze the entire codebase from scratch.

## 🎯 Project Overview
OpenWardRivingT is a headless active wardriving suite built for low-resource OpenWrt routers (typically 600MHz MIPS processors, 64-128MB RAM, 16MB Flash).
It uses a completely serverless backend approach: the "backend" is a collection of POSIX `ash` shell scripts exposed via OpenWrt's `uhttpd` CGI gateway, and the frontend is a vanilla HTML/JS/CSS Single Page Application (SPA).

## 📂 Core Architecture & Files

- **`openwrt_files/www/wardriving/index.html` + `app.css` + `app.js`**: The Frontend SPA.
  - **No Build Step**: It uses raw vanilla JS, CSS variables, and HTML. No React, no Webpack.
  - **Static Split**: `index.html` carries the DOM shell, `app.css` carries styles, and `app.js` carries dashboard behavior plus the `API_TOKEN_PLACEHOLDER` that `install.sh` replaces.
  - **Theme**: "Cyberpunk" aesthetic. High-contrast colors (green, cyan, magenta) meant to be viewed from a car's Android head unit.
  - **Logic**: Uses `setInterval` to periodically poll the backend via `fetch()`. Polling intervals are carefully tuned (5-20 seconds) to avoid crashing the router's CPU, and pause when the tab is hidden via `pollVisible()`.
  - **Auth in requests**: `app.js` monkey-patches `fetch` with `withApiAuth()` which adds the `Authorization: Bearer <token>` header. `apiUrl()` also appends `?token=…` as a fallback for `window.open()` downloads (which can't set headers). The CGI accepts both methods, header first.

- **`openwrt_files/www/cgi-bin/wardriving_api`**: The Backend API.
  - **Pure Shell**: Written in busybox `ash`.
  - **Stateless CGI Dispatcher**: Every HTTP request forks `/bin/sh` to run this script. It sources `/usr/lib/wardriving/common.sh`, `db.sh`, `remote.sh`, and grouped handler modules under `/usr/lib/wardriving/handlers/`.
  - **Authentication**: Prefers `Authorization: Bearer <token>` header (avoids token in access logs and Referer); falls back to `?token=…` query string for backward compat. `status` is the only public (token-free) endpoint, documented explicitly to clarify attack surface.
  - **Security headers** (all responses): `X-Content-Type-Options: nosniff`, `X-Frame-Options: DENY`, `Referrer-Policy: no-referrer`, plus `Cache-Control: no-store` for JSON. CORS is same-origin — no `Access-Control-Allow-Origin: *`.
  - **JSON Generation**: Uses extensive `awk` scripting to parse logs, SQLite databases, and `hc2200` hash files into raw JSON strings.

- **`openwrt_files/usr/bin/wardriving_core.sh`**: The Capture Daemon.
  - Runs a continuous loop launching `hcxdumptool` in 1-minute capture windows (`--tot=1`).
  - Upon exiting, it uses `hcxpcapngtool` to extract handshakes and GPS tracks.
  - Integrates with `sqlite3` to push captured networks into `/mnt/wardriving/wardriving.db`.
  - Dedupes hashes into `/mnt/wardriving/master.hc2200`.
  - Supports configurable extraction and cracking:
    - `extraction_mode=local`: the router runs `hcxpcapngtool`, updates local SQLite, merges `master.hc2200`, then optionally uploads hashes to the GPU for cracking.
    - `extraction_mode=remote`: the router sends the `.pcapng` to the GPU `/extract` endpoint, imports the returned `networks.jsonl`, `clients.jsonl`, and `capture.hc2200` bundle locally, and falls back to local extraction on timeout/error/invalid bundles.
    - `gpu_cracking_enabled=0|1`: controls only hashcat enqueueing; SQLite, map, history, and live network views remain local sources of truth.
  - New router flows use `/extract` for extraction bundles and `/upload_hc2200` for cracking hashes. The GPU's legacy `/upload` endpoint has been removed (was only kept for compat).
  - Shares SQLite and remote upload helpers with replay/API through `/usr/lib/wardriving/db.sh` and `/usr/lib/wardriving/remote.sh`.
  - When WireGuard is used to reach the GPU, route only the GPU host as `/32` (e.g. `<GPU_WG_HOST>/32`); never the whole WireGuard subnet, especially when WAN also lives in that range.
  - **Performance Note**: Capture rollover is CPU-heavy. We run these heavy tasks with `nice -n 10` so they don't freeze the router's UI. Handshake count is cached in `/tmp/wardriving_handshake_count` (refreshed on each `merge_hash_file`, read every 5s by the dashboard) to avoid running `wc -l` on the full hash file on every poll.

- **`openwrt_files/etc/init.d/wardriving`**: The Service Manager.
  - Standard OpenWrt `init.d` script. Starts/Stops `wardriving_core.sh` and manages the `socat` PTY lifecycle.

## 📡 The GPS Pipeline (Important!)
Feeding GPS from the browser to `hcxdumptool` is non-trivial and relies on a delicate pipeline:
1. The browser gets GPS via HTML5 Geolocation (`watchPosition`).
2. JS converts coordinates to NMEA strings (`$GPRMC`, `$GPGGA`).
3. JS buffers these strings in `window.nmeaBuffer` (bounded to `GPS_BUFFER_MAX=32` entries; drop-oldest on overflow) and `POST`s them to `action=gps_push` every 4 seconds (to avoid CGI fork overload). The buffer is only cleared after a successful push response.
4. `wardriving_api` receives the POST and validates each NMEA line against a strict regex `^\$[A-Z]{2}(RMC|GGA|WPL),[^*]*\*[0-9A-Fa-f]{2}$` (rejects anything else as `invalid NMEA format`), then writes to `/tmp/vGPS_fifo` (a named pipe) AND `/tmp/vGPS_last`.
5. A background `socat` instance continuously reads `/tmp/vGPS_fifo` and pushes data into a Virtual PTY (`/tmp/vGPS`).
6. `hcxdumptool` reads from `--nmea_dev=/tmp/vGPS` to tag captured WiFi packets with location data.

## 🛑 Known Quirks & Strange Behaviors
- **Rollover CPU Spikes**: The core script periodically stops capture to process the `.pcapng` file. This can take several seconds of high CPU. During this time, API responses might be slightly delayed. This is normal.
- **Ash vs Bash**: OpenWrt uses BusyBox `ash`. Scripts MUST be POSIX compliant. Do not use bash arrays (`()`) or bash substring replacements (`${var//...}`). Use `awk` or `sed` heavily.
- **BusyBox applet gaps**: OpenWrt's BusyBox build does NOT include `mountpoint` or `findmnt`. Use `/proc/mounts` (always present on Linux) for mountpoint checks. The CI does not catch this — only deployment does.
- **ShellCheck CI**: The GitHub Actions CI runs ShellCheck configured with specific exclusions (`-e SC3043,SC3048,SC2016,etc.`) because `ash` supports `local` and `SIGTERM`, even though pure POSIX `sh` does not. SC2016 (expressions in single quotes) is excluded because the test runner uses single quotes to send literal NMEA strings to the CGI.
- **Package Manager Drift**: OpenWrt 24/25 may use `apk` instead of `opkg`. Operational docs and install paths must mention both, and router package-update failures should include route/DNS checks before assuming feed errors.
- **Modern SCP**: New `scp` clients use SFTP by default. Routers should include `openssh-sftp-server`; otherwise deployments may need legacy `scp -O`.
- **Test runner permissions**: CI runs as non-root (`runner` user) so handlers that write to `/etc/wardriving_*` paths must respect `WARDRIVING_*_FILE` env-var overrides. Without the override, the test fails with "Permission denied" on a `touch`. The supported overrides (defined in `common.sh`) are: `WARDRIVING_TOKEN_FILE`, `MODE_FILE`, `KEEP_PCAP_FILE`, `EXCLUDED_FILE`, `REMOVED_FILE`, `EXTRACTION_MODE_FILE`, `GPU_CRACKING_FILE`, `REMOTE_ENABLED_FILE`, `REMOTE_URL_FILE`, `REMOTE_SECRET_FILE`, `API_CACHE_DIR`, `WARD_MNT`, `LIB_DIR`, `TARGETS_FILE`, `WIGLE_TOKEN_FILE`, `PWN_HOST`.

## 🔐 API and Security Patterns (CRITICAL)
- **API Token Requirement**: Almost all actions in `wardriving_api` are protected by `is_protected_action` and require auth. The CGI accepts `Authorization: Bearer <token>` header (preferred, case-insensitive) OR `?token=…` query string (fallback for `window.open()` downloads and external scripts).
- **Frontend Calls**: Any frontend interaction with the backend MUST be wrapped in the `apiUrl(action, params)` function or `apiJson(action, params)` wrapper provided in `app.js`. Both call `withApiAuth()` which adds the Bearer header.
- **The Recurring Mistake**: NEVER write raw `fetch('/cgi-bin/wardriving_api?action=...')` calls directly in the JavaScript. If you do, the request will lack the token, silently fail with `401 Unauthorized`, and create "frozen UI" symptoms (like the "Stop" button hanging). Always use `fetch(apiUrl('...'))`.
