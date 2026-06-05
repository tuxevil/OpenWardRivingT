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
  - **Logic**: Uses `setInterval` to periodically poll the backend via `fetch()`. Polling intervals are carefully tuned (4-10 seconds) to avoid crashing the router's CPU.

- **`openwrt_files/www/cgi-bin/wardriving_api`**: The Backend API.
  - **Pure Shell**: Written in busybox `ash`.
  - **Stateless CGI Dispatcher**: Every HTTP request forks `/bin/sh` to run this script. It sources `/usr/lib/wardriving/common.sh`, `db.sh`, `remote.sh`, and grouped handler modules under `/usr/lib/wardriving/handlers/`.
  - **Authentication**: Requires a `token=` URL parameter on all state-changing endpoints and sensitive read/export endpoints. `status` remains a lightweight public health endpoint. The frontend intercepts `fetch` calls to automatically append `window.API_TOKEN` (which is injected by `install.sh`), and export buttons use the same tokenized URL helper.
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
  - Legacy `/upload` JSONL is kept on the GPU server for compatibility, but new router flows use `/extract` for extraction bundles and `/upload_hc2200` for cracking hashes.
  - Shares SQLite and remote upload helpers with replay/API through `/usr/lib/wardriving/db.sh` and `/usr/lib/wardriving/remote.sh`.
  - In the test topology, the GPU is reached at `10.128.128.254`; if WireGuard is used, route that host as `10.128.128.254/32` rather than the whole `10.128.128.0/24` when WAN also lives on `10.128.128.0/24`.
  - **Performance Note**: Capture rollover is CPU-heavy. We run these heavy tasks with `nice -n 10` so they don't freeze the router's UI.

- **`openwrt_files/etc/init.d/wardriving`**: The Service Manager.
  - Standard OpenWrt `init.d` script. Starts/Stops `wardriving_core.sh` and manages the `socat` PTY lifecycle.

## 📡 The GPS Pipeline (Important!)
Feeding GPS from the browser to `hcxdumptool` is non-trivial and relies on a delicate pipeline:
1. The browser gets GPS via HTML5 Geolocation (`watchPosition`).
2. JS converts coordinates to NMEA strings (`$GPRMC`, `$GPGGA`).
3. JS buffers these strings and `POST`s them to `action=gps_push` every 4 seconds (to avoid CGI fork overload).
4. `wardriving_api` receives the POST and writes it to `/tmp/vGPS_fifo` (a named pipe) AND `/tmp/vGPS_last`.
5. A background `socat` instance continuously reads `/tmp/vGPS_fifo` and pushes data into a Virtual PTY (`/tmp/vGPS`).
6. `hcxdumptool` reads from `--nmea_dev=/tmp/vGPS` to tag captured WiFi packets with location data.

## 🛑 Known Quirks & Strange Behaviors
- **Rollover CPU Spikes**: The core script periodically stops capture to process the `.pcapng` file. This can take several seconds of high CPU. During this time, API responses might be slightly delayed. This is normal.
- **Ash vs Bash**: OpenWrt uses BusyBox `ash`. Scripts MUST be POSIX compliant. Do not use bash arrays (`()`) or bash substring replacements (`${var//...}`). Use `awk` or `sed` heavily.
- **ShellCheck CI**: The GitHub Actions CI runs ShellCheck configured with specific exclusions (`-e SC3043,SC3048,etc.`) because `ash` supports `local` and `SIGTERM`, even though pure POSIX `sh` does not.
- **Package Manager Drift**: OpenWrt 24/25 may use `apk` instead of `opkg`. Operational docs and install paths must mention both, and router package-update failures should include route/DNS checks before assuming feed errors.
- **Modern SCP**: New `scp` clients use SFTP by default. Routers should include `openssh-sftp-server`; otherwise deployments may need legacy `scp -O`.
