# OpenWardRivingT Context

This file provides architectural context for AI agents working on the OpenWardRivingT project, preventing the need to analyze the entire codebase from scratch.

## 🎯 Project Overview
OpenWardRivingT is a headless active wardriving suite built for low-resource OpenWrt routers (typically 600MHz MIPS processors, 64-128MB RAM, 16MB Flash).
It uses a completely serverless backend approach: the "backend" is a collection of POSIX `ash` shell scripts exposed via OpenWrt's `uhttpd` CGI gateway, and the frontend is a vanilla HTML/JS/CSS Single Page Application (SPA).

## 📂 Core Architecture & Files

- **`openwrt_files/www/wardriving/index.html`**: The entire Frontend SPA.
  - **No Build Step**: It uses raw vanilla JS, CSS variables, and HTML. No React, no Webpack.
  - **Theme**: "Cyberpunk" aesthetic. High-contrast colors (green, cyan, magenta) meant to be viewed from a car's Android head unit.
  - **Logic**: Uses `setInterval` to periodically poll the backend via `fetch()`. Polling intervals are carefully tuned (4-10 seconds) to avoid crashing the router's CPU.

- **`openwrt_files/www/cgi-bin/wardriving_api`**: The Backend API.
  - **Pure Shell**: Written in busybox `ash`.
  - **Stateless CGI**: Every HTTP request forks `/bin/sh` to run this script. It parses the `QUERY_STRING` manually.
  - **Authentication**: Requires a `token=` URL parameter on most endpoints. The frontend intercepts `fetch` calls to automatically append `window.API_TOKEN` (which is injected by `install.sh`).
  - **JSON Generation**: Uses extensive `awk` scripting to parse logs, SQLite databases, and `hc2200` hash files into raw JSON strings.

- **`openwrt_files/usr/bin/wardriving_core.sh`**: The Capture Daemon.
  - Runs a continuous loop launching `hcxdumptool` for 5 minutes (`--tot=5`).
  - Upon exiting, it uses `hcxpcapngtool` to extract handshakes and GPS tracks.
  - Integrates with `sqlite3` to push captured networks into `/mnt/wardriving/wardriving.db`.
  - Dedupes hashes into `/mnt/wardriving/master.hc2200`.
  - **Performance Note**: The 5-minute rollover is CPU-heavy. We run these heavy tasks with `nice -n 10` so they don't freeze the router's UI.

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
- **5-Minute CPU Spikes**: Due to the `hcxdumptool` 5-minute capture limits, exactly every 5 minutes the core script stops capturing and processes the `.pcapng` file. This takes 5-10 seconds of 100% CPU. During this time, API responses might be slightly delayed. This is normal.
- **Ash vs Bash**: OpenWrt uses BusyBox `ash`. Scripts MUST be POSIX compliant. Do not use bash arrays (`()`) or bash substring replacements (`${var//...}`). Use `awk` or `sed` heavily.
- **ShellCheck CI**: The GitHub Actions CI runs ShellCheck configured with specific exclusions (`-e SC3043,SC3048,etc.`) because `ash` supports `local` and `SIGTERM`, even though pure POSIX `sh` does not.
