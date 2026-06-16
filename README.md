# OpenWardRivingT

[![License: GPL-3.0](https://img.shields.io/badge/License-GPL--3.0-blue.svg)](LICENSE)
[![CI](https://img.shields.io/badge/CI-passing-brightgreen.svg)](.github/workflows/ci.yml)
[![OpenWrt](https://img.shields.io/badge/OpenWrt-23.05%20%7C%2024.x%20%7C%2025.x-orange.svg)](https://openwrt.org/)
[![Shell](https://img.shields.io/badge/shell-BusyBox%20ash-blue.svg)](openwrt_files/)
[![Tests](https://img.shields.io/badge/tests-159%20passing-brightgreen.svg)](test/)

**Active wardriving suite for OpenWrt, designed for in-vehicle autonomous operation.**

OpenWardRivingT runs on commodity OpenWrt routers to capture WPA/WPA2/WPA3 PMKID and
EAPOL handshakes while geolocating them with GPS. The headless capture daemon is paired
with a tablet-optimized web dashboard and an optional companion GPU server for
[hashcat](https://hashcat.net/) offload.

It is **active** auditing software: it transmits deauth and probe frames and must only be
used against networks you own or have explicit written authorization to test. See
[Legal & Ethics](#legal--ethics) before deploying.

---

## Table of contents

- [How it works](#how-it-works)
- [Features](#features)
- [Hardware](#hardware)
- [Software requirements](#software-requirements)
- [Installation](#installation)
- [Configuration](#configuration)
- [Usage](#usage)
- [GPU offload (optional)](#gpu-offload-optional)
- [API & security](#api--security)
- [Development](#development)
- [Known quirks](#known-quirks)
- [Legal & ethics](#legal--ethics)
- [Contributing](#contributing)
- [Acknowledgments](#acknowledgments)
- [License](#license)

---

## How it works

OpenWardRivingT is built as five thin layers with no build step:

```
   ┌─────────────────────────────────────────────────────────┐
   │  Layer 5 — Init & install                               │
   │  install.sh (apk/opkg auto-detect), uninstall.sh,        │
   │  /etc/init.d/wardriving (OpenWrt rc.common)             │
   └─────────────────────────────────────────────────────────┘
                            │
   ┌─────────────────────────────────────────────────────────┐
   │  Layer 4 — Web dashboard (vanilla JS SPA)               │
   │  openwrt_files/www/wardriving/{index.html,app.css,      │
   │  app.js,app-utils.js,sw.js}                             │
   └─────────────────────────────────────────────────────────┘
                            │  fetch (Bearer / ?token=)
   ┌─────────────────────────────────────────────────────────┐
   │  Layer 3 — CGI API                                      │
   │  /www/cgi-bin/wardriving_api  →  /usr/lib/wardriving/   │
   │  {common,db,remote}.sh + handlers/{status,captures,     │
   │  maps,replay,settings}.sh                               │
   └─────────────────────────────────────────────────────────┘
                            │  /etc/wardriving_*
   ┌─────────────────────────────────────────────────────────┐
   │  Layer 2 — GPS bridge (NMEA over socat PTY)             │
   │  Browser HTML5 Geolocation → JS NMEA → CGI gps_push →  │
   │  /tmp/vGPS_fifo → socat → /tmp/vGPS → hcxdumptool      │
   └─────────────────────────────────────────────────────────┘
                            │
   ┌─────────────────────────────────────────────────────────┐
   │  Layer 1 — Capture daemon                               │
   │  /usr/bin/wardriving_core.sh                            │
   │  loop: monitor iface check → hcxdumptool -t 3 --tot=1  │
   │    → hcxpcapngtool → SQLite + master.hc2200            │
   │  Optional: GPU /extract (bundle) or /upload_hc2200      │
   └─────────────────────────────────────────────────────────┘
```

- **No build step.** Files are deployed directly by `install.sh` and edited in place.
- **Pure BusyBox ash.** All shell scripts target POSIX `sh` plus BusyBox extensions;
  bashisms are not allowed (see [Conventions](#conventions)).
- **Local-first data.** The dashboard never reads the GPU directly — every map, history,
  client, and cracked view reads the router's own SQLite database and pot/hash files.

For deeper architecture notes (capture state machine, GPS pipeline, dispatch table) see
[CONTEXT.md](CONTEXT.md).

---

## Features

**Capture**
- Active PMKID + EAPOL handshake capture via `hcxdumptool` (rolling 1-minute windows)
- Per-network extraction via `hcxpcapngtool` into a deduplicated `master.hc2200`
- SQLite (WAL) log of every observed BSSID/client with GPS coordinates
- Heatmap, smart target scoring, and "fresh networks" ranking
- Two-mode pipeline: extraction on the router, cracking on the GPU

**Dashboard** (vanilla JS, no framework)
- Tablet-optimised 4-column layout for car head units (1280×720 down to mobile)
- Live spectrum analyser (2.4 GHz channel tree with per-channel network counts)
- Offline-first maps via `Z/X/Y.png` tile upload; optional online tile toggle
- Browser GPS override (HTML5 Geolocation → synthetic NMEA → `hcxdumptool`)
- Pwnagotchi bridge: read stats from a real Pwnagotchi over its REST API and
  ingest its `.pcap` files into the local database
- Replay mode: feed a recorded GPS track back into the dashboard map
- Night mode (deep-red tint), wake lock, fullscreen, Text-to-Speech target alerts
- Service worker for offline app shell; versioned cache for forced refreshes

**Hardware feedback**
- Bind the router's LEDs to blink while a capture window is active
- Map a physical WPS/WiFi button to start/stop capture

**Security**
- Token-based API auth with `Authorization: Bearer` (preferred) and `?token=…` fallback
- `action=status` is the only public endpoint; everything else requires a token
- Path-traversal guards on every file-serving endpoint
- Strict NMEA regex validation in `gps_push`
- Security headers (`nosniff`, `DENY`, `no-referrer`, `no-store`) on every CGI response
- `set -e` on every long-running script; `trap` cleanup on `SIGTERM`/`SIGINT`

---

## Hardware

### Requirements

1. **OpenWrt router** with at least one Atheros AR9xxx or Qualcomm IPQ40xx radio
   (best monitor-mode + injection support). MediaTek MT76xx works with extra `kmod`
   packages. Broadcom is **not** supported.
   - 2.4 GHz radio in monitor mode (capture)
   - 5 GHz radio as the control-panel AP (recommended; 2.4 GHz single-radio is supported)
2. **USB flash drive (mandatory)** formatted `ext4`, mounted at `/mnt/wardriving/`.
   This is a deliberate safety measure: the capture loop refuses to start without it
   to prevent NAND wear from continuous `.pcapng` writes and to keep the router
   bootable when internal flash fills up.
3. **12V → 5V/12V step-down** for the car.
4. **GPS-capable device** (phone, tablet, or Android head unit) for dashboard GPS
   override. A USB GPS dongle feeding `gpsd` is also supported via `--nmea_dev`.

### Tested

| Device                  | Chipset                  | OpenWrt | Status         |
| ----------------------- | ------------------------ | ------- | -------------- |
| Netgear WNDR3700v2     | AR7161 + AR9220/AR9223   | 23.05   | ✅ Full        |
| GL.iNet GL-A1300        | IPQ4018                  | 24.10   | ✅ Full        |
| TP-Link Archer C7 v2    | QCA9558 + QCA9880        | 23.05   | ✅ Monitor OK  |
| Generic x86_64          | Any                      | 24.10+  | ✅ USB GPS req |

---

## Software requirements

`install.sh` auto-detects `apk` (OpenWrt 24.x+) or `opkg` (OpenWrt 23.x and earlier) and
installs the rest:

- `hcxdumptool` ≥ 6.3, `hcxtools` (capture + extraction)
- `socat` (NMEA over a virtual PTY)
- `sqlite3-cli` (WAL database)
- `block-mount`, `e2fsprogs`, `kmod-fs-ext4`, `kmod-usb-storage` (USB auto-mount)
- `openssh-client`, `openssh-sftp-server` (modern `scp`/SFTP without `scp -O`)
- `uhttpd` (built-in OpenWrt web server)

OpenWrt 24.x and 25.x images may ship with `apk` only; `install.sh` handles both. If
package updates fail with WireGuard enabled, the WAN/WG subnet is the prime suspect
(see [Configuration → Network topology](#network-topology)).

---

## Installation

```bash
# On the router, as root:
wget -O- https://raw.githubusercontent.com/tuxevil/OpenWardRivingT/main/install.sh | sh
```

Or clone and run interactively:

```bash
git clone https://github.com/tuxevil/OpenWardRivingT.git
cd OpenWardRivingT
chmod +x install.sh uninstall.sh
./install.sh
```

`install.sh` will:

1. Install all required packages (auto-detecting `apk` vs `opkg`).
2. Configure USB auto-mount (`/etc/fstab` → `/mnt/wardriving`).
3. Generate a 32-char API token at `/etc/wardriving_api_token` (mode `0600`).
4. Generate a 12-char random WiFi password for the 5 GHz control-panel AP
   (`OpenWardRivingT`) and save it to `/etc/wardriving_wifi_pass` (mode `0600`).
5. Deploy the CGI, dashboard, init script, and shell libraries.
6. Inject the API token into the dashboard so the UI works out of the box.
7. Enable the `wardriving` service on boot.
8. Bump `uhttpd.main.max_requests` to at least 12 so dashboard polling coexists
   with LuCI.

> **No default password is used.** The WiFi password is printed to the install console
> and saved to `/etc/wardriving_wifi_pass`. Treat this file as a secret.

To remove: `sh uninstall.sh` (leaves captures on the USB drive intact).

---

## Configuration

All runtime configuration lives in `/etc/wardriving_*` files. The dashboard reads them
directly; you can also edit them with `uci` or any text editor.

| File                                          | Purpose                                                | Default      |
| --------------------------------------------- | ------------------------------------------------------ | ------------ |
| `/etc/wardriving_api_token`                   | Bearer token for protected API actions                 | (generated)  |
| `/etc/wardriving_wifi_pass`                   | 5 GHz control-panel WiFi password                       | (generated)  |
| `/etc/wardriving_mode.txt`                    | Operation mode: `active`, `passive`, `smart`           | `smart`      |
| `/etc/wardriving_targets.txt`                 | One MAC per line — TTS/visual alerts when seen         | (empty)      |
| `/etc/wardriving_excluded.txt`                | SSIDs/MACs to never capture or alert                   | (empty)      |
| `/etc/wardriving_removed.txt`                 | SSIDs/MACs to drop from already-captured history       | (empty)      |
| `/etc/wardriving_keep_pcap.txt`               | `1` = keep `.pcapng` after extraction                  | `0`          |
| `/etc/wardriving_wigle_token`                 | WiGLE API token (Basic-auth)                           | (empty)      |
| `/etc/wardriving_extraction_mode`             | `local` or `remote`                                    | `local`      |
| `/etc/wardriving_gpu_cracking_enabled`        | `0` or `1`                                             | `1`          |
| `/etc/wardriving_remote_enabled`              | `0` or `1`                                             | `1`          |
| `/etc/wardriving_remote_url`                  | GPU server base URL                                    | (empty)      |
| `/etc/wardriving_remote_secret`               | Shared secret for GPU server (X-OWRT-Token header)     | (empty)      |

### Network topology

When the router reaches the GPU over WireGuard, route **only the GPU host** if your
WireGuard subnet overlaps with the WAN. Configure WireGuard with a `/32` host route
(e.g. `<GPU_WG_HOST>/32`) rather than the full WireGuard subnet; advertising the whole
`/24` through WireGuard can steal the WAN default route and break `apk update`.

---

## Usage

1. Plug in the USB drive, power the router from the car.
2. Connect your phone/tablet to the **`OpenWardRivingT`** 5 GHz WiFi using the password
   from `/etc/wardriving_wifi_pass` (or the install console).
3. Open `http://192.168.1.1/wardriving/index.html` (or your router's LAN IP).
4. Toggle **Browser GPS Override** in the dashboard to start streaming NMEA from the
   phone's GPS into `hcxdumptool`.
5. Hit **START** on the dashboard — or press the configured physical router button
   (WPS/WiFi by default).

### Offline maps

In **Settings → Maps**, upload a `.tar.gz` built with a tool like Mobile Atlas Creator
(`Z/X/Y.png` folder layout). The dashboard will switch to offline tiles automatically;
clear the **Online tiles** checkbox to fall back to offline-only.

### Replay

A recorded capture can be replayed: **Settings → Replay → Upload CSV** accepts a
CSV of NMEA sentences and animates the car marker back through the route while
re-emitting discovered networks to the map. Useful for post-drive review.

---

## GPU offload (optional)

The companion GPU server (`server_files/`) is a small Flask app that:

- Receives `.pcapng` uploads and returns a bundle of `networks.jsonl`, `clients.jsonl`,
  and `capture.hc2200` (router imports the bundle into its local DB — never queries
  the GPU directly).
- Receives `.hc2200` uploads, runs `hashcat` against user-provided wordlists, and
  syncs cracked passwords back to the router via `action=upload_potfile`.

```
                    POST /extract        (X-OWRT-Token)
   Router  ──────────────────────────────────────────►   GPU server (gpu_server.py)
            ◄────────────────────────────  bundle.json + capture.hc2200
            imports into SQLite + master.hc2200

            POST /upload_hc2200        (X-OWRT-Token)
            ──────────────────────────────────────────►
                                                    hashcat run_hashcat.sh
            POST action=upload_potfile&token=…        ◄──── cracked.txt
            ◄────────────────────────────  200 OK
```

### Deploy the GPU server

```bash
# On the GPU host (Linux + hashcat ≥ 6.2 + Python 3.9+)
sudo cp server_files/wardriving_gpu.service /etc/systemd/system/
sudo cp server_files/gpu_server.py  /var/lib/openwardrivingt/
sudo cp server_files/run_hashcat.sh /var/lib/openwardrivingt/
sudo chmod +x /var/lib/openwardrivingt/run_hashcat.sh

# Generate a shared secret and edit the service unit
SECRET=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 48)
sudo sed -i "s/^Environment=OWRT_GPU_SHARED_SECRET=.*/Environment=OWRT_GPU_SHARED_SECRET=$SECRET/" \
    /etc/systemd/system/wardriving_gpu.service

# Same secret on the router
echo "$SECRET" | ssh root@router 'cat > /etc/wardriving_remote_secret && chmod 600 /etc/wardriving_remote_secret'

sudo systemctl daemon-reload
sudo systemctl enable --now wardriving_gpu
```

For end-to-end deploy + smoke testing, the optional `scripts/deploy_test_env.sh` and
`scripts/smoke_router_gpu.sh` wrap the steps above. They require `GPU_HOST`,
`GPU_URL`, and `ROUTER_HOST` to be set.

---

## API & security

The CGI exposes a single `action=` dispatcher at `/cgi-bin/wardriving_api`. The
dispatcher sources handler modules from `/usr/lib/wardriving/handlers/` and
authorisation is enforced centrally in `common.sh`.

### Auth contract

| Endpoint         | Auth         | Notes                                                |
| ---------------- | ------------ | ---------------------------------------------------- |
| `action=status`  | ❌ No        | Public health check — running state, network counts  |
| All other actions| ✅ Yes       | `Authorization: Bearer <token>` header (preferred) or `?token=…` query (fallback for `window.open()` downloads) |

Tokens are read from `/etc/wardriving_api_token` (mode `0600`, generated by `install.sh`).
The dashboard's `apiUrl()` and `withApiAuth()` helpers attach the Bearer header
automatically — never construct raw `fetch('/cgi-bin/wardriving_api?…')` calls in the
frontend, or the request will silently fail with `401 Unauthorized`.

### Endpoint surface

`status`, `start`, `stop`, `set_hw`, `set_mode`, `set_processing`, `set_pcap_retention`,
`networks_map`, `clients_map`, `map_data`, `heatmap_data`, `scored_networks`,
`cracked_networks`, `history`, `list_files`, `download_all`, `download_bbox`,
`download_status`, `export_gpx`, `export_kml`, `export_hashcat`, `delete_file`,
`add_target`, `remove_target`, `check_targets`, `get_targets`, `add_exclusion`,
`remove_exclusion`, `get_exclusions`, `save_wigle_token`, `wigle_upload`, `upload_tiles`,
`upload_potfile`, `gps_push`, `pwnagotchi_sync`, `pwnagotchi_status`, `replay_start`,
`replay_status`, `replay_seek`, `replay_pause`, `replay_stop`, `replay_report`,
`replay_discovered`.

### Hardening

- `X-Content-Type-Options: nosniff`, `X-Frame-Options: DENY`, `Referrer-Policy: no-referrer`,
  `Cache-Control: no-store` on every response
- No CORS (`Access-Control-Allow-Origin: *` is intentionally absent)
- `POST` required for state-changing actions; `CONTENT_LENGTH` capped per endpoint
- Path-traversal payloads (`../etc/passwd`, `%2Fetc%2Fpasswd`) rejected
- URL-decoded SSIDs in `add_exclusion`/`remove_exclusion`
- Legacy `wardriving_remote_allow_sql` mode is **off by default** and emits a syslog
  warning if the file appears

---

## Development

### Running the test suite

The CI runs `test/run_tests.sh` against the project tree (≈ 159 assertions covering
shell syntax, shellcheck compliance, CGI contracts, security guards, service worker
behaviour, etc.). Locally:

```bash
sudo apt-get install -y shellcheck busybox-static sqlite3 nodejs
shellcheck -e SC1090,SC2002,SC2010,SC2012,SC2015,SC2016,SC2018,SC2035,SC2045,SC3013,SC3043,SC3048 -x \
    install.sh uninstall.sh \
    openwrt_files/usr/bin/*.sh \
    openwrt_files/usr/lib/wardriving/common.sh \
    openwrt_files/usr/lib/wardriving/db.sh \
    openwrt_files/usr/lib/wardriving/remote.sh \
    openwrt_files/usr/lib/wardriving/handlers/*.sh \
    openwrt_files/etc/init.d/wardriving \
    openwrt_files/www/cgi-bin/wardriving_api \
    test/run_tests.sh

sh test/run_tests.sh
sh test/run_js_tests.sh
```

CI also runs on every push and pull request (see `.github/workflows/ci.yml`).

### Conventions

- **POSIX `ash`, not bash.** OpenWrt ships BusyBox `ash`; bashisms break the build
  (no arrays `()`, no `[[`, no `&>`, no `source` → use `.`, no `local` keyword in
  pure-POSIX code paths).
- **No `mountpoint`, no `findmnt`.** OpenWrt's BusyBox doesn't include them — use
  `/proc/mounts` for mountpoint checks.
- **`set -e` for long-running loops.** `wardriving_core.sh`, `wardriving_clients.sh`,
  `run_hashcat.sh` set `-e`; `wardriving_replay.sh` opts for `set -u` because
  transient errors should not abort a replay.
- **`mktemp` for atomic writes.** Never write directly to live system paths.
- **Trap signals.** Every infinite-loop script must `trap cleanup SIGTERM SIGINT SIGHUP`
  and write its PID to `/var/run/`.
- **Test env-var overrides.** Handlers that write to `/etc/wardriving_*` paths must
  respect `${WARDRIVING_X_FILE:-/etc/...}` so the CI suite (non-root) can run. The
  full list is in `openwrt_files/usr/lib/wardriving/common.sh`.
- **No large binaries in the repo.** Vendor libraries (Leaflet) are kept as
  statically-linked files; build artefacts are not.

For AI agent workflows (commit conventions, session close protocol, end-to-end
architecture) see [AGENTS.md](AGENTS.md) and [CLAUDE.md](CLAUDE.md).

---

## Known quirks

1. **Rollover CPU spikes.** Capture windows roll over every minute; the brief period
   where `hcxdumptool` exits, `hcxpcapngtool` extracts, and SQLite ingests can hit
   100% CPU. We run these with `nice -n 10` so the UI stays responsive, but expect
   small API delays.
2. **GPS buffer lag.** The browser batches NMEA and posts every 4 seconds to avoid
   forking uhttpd. At highway speeds, expect ~40–50 m of spatial lag — well within
   standard WiFi range.
3. **Handshake count caching.** `/status` reports handshakes from a cached counter
   refreshed on every `master.hc2200` merge, not a live `wc -l`. The cached value
   may lag the file by one rollover.
4. **APK vs opkg.** OpenWrt 24.x/25.x images may only include `apk`. `install.sh`
   auto-detects; if your router still has `opkg`, you can pin a 23.x build.
5. **Modern `scp`.** OpenWrt's dropbear doesn't include an SFTP subsystem; install
   `openssh-sftp-server` to copy files to the router with modern OpenSSH clients
   (no need for `scp -O`).

---

## Legal & ethics

**OpenWardRivingT is an active auditing tool.** It transmits deauthentication and
probe frames and will briefly disrupt connectivity on targeted wireless networks.

It is provided exclusively for:

- Educational use
- Authorised security testing of networks you own
- Penetration testing engagements with explicit, documented consent

You must comply with all local, state, and federal laws regarding wireless
communications, data interception, and computer-misuse statutes in your jurisdiction.
The maintainers and contributors of this repository accept no liability for misuse.

If you are unsure whether your use case is authorised: **stop and ask the network
owner in writing first.**

---

## Contributing

Issues and pull requests are welcome on GitHub.

**Before opening a pull request**

1. Search existing issues to avoid duplicates.
2. For non-trivial changes, open an issue first to discuss the approach.
3. Fork the repo and create a feature branch off `main`.
4. Run the full test suite locally — `sh test/run_tests.sh` and the shellcheck
   command from [Development](#development) must both pass.
5. Follow the project conventions in [AGENTS.md](AGENTS.md) and
   [CLAUDE.md](CLAUDE.md) (BusyBox ash, no bashisms, mktemp for atomic writes,
   `WARDRIVING_*_FILE` env-var overrides for any new `/etc` handler).
6. Keep commits focused; write a clear conventional-commit message
   (`fix:`, `feat:`, `docs:`, `security:`, `chore:`).
7. Update [CHANGELOG.md](CHANGELOG.md) under `## Unreleased` for user-visible changes.

**Security issues**

Please **do not** file public issues for suspected vulnerabilities. Email the
maintainer (see GitHub profile) with a description and reproduction steps. We
will respond within a reasonable window and coordinate a fix before disclosure.

**Code of conduct**

Be respectful in issues and PRs. Assume good faith; ask for clarification rather
than assuming malice. The maintainers reserve the right to close unproductive
threads.

---

## Acknowledgments

- [Jens Steube](https://github.com/JeremyDeNotariis) and the `hcxtools` / `hcxdumptool`
  authors — the project would not exist without their work
- [evilsocket](https://github.com/evilsocket) for the [pwnagotchi](https://pwnagotchi.ai/)
  inspiration (the dashboard's virtual pet is a small homage)
- The [Leaflet](https://leafletjs.com/) and [OpenStreetMap](https://www.openstreetmap.org/)
  projects
- The OpenWrt project and its maintainers
- [WiGLE](https://wigle.net/) for the public wardriving dataset and upload API
- Everyone who has filed issues, tested on real hardware, or contributed patches

---

## License

Copyright © 2026 OpenWardRivingT contributors.

OpenWardRivingT is licensed under the **GNU General Public License v3.0** (GPL-3.0).
See [LICENSE](LICENSE) for the full text.

If you redistribute a modified version, you must also release the source under the
same licence.
