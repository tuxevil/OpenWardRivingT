# OpenWardRivingT — Architecture

This document is a tour of the codebase aimed at contributors who need
to make non-trivial changes. The top-level [README.md](README.md) is
the operator's manual; this file is the maintainer's manual.

## 1. Five-layer model

The project is intentionally split into five thin layers with **no
build step** — every file in `openwrt_files/` is deployed directly by
`install.sh` and edited in place on the router.

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
   │    → hcxpcapngtool → SQLite + master.hc22000            │
   │  Optional: GPU /extract (bundle) or /upload_hc22000    │
   └─────────────────────────────────────────────────────────┘
```

### Layer 1 — Capture daemon

`openwrt_files/usr/bin/wardriving_core.sh` is the only place that
touches `hcxdumptool` and `hcxpcapngtool`. The capture window is
1 minute (`-t 3 --tot=1`); at the end of the window the daemon
extracts handshakes, ingests networks into SQLite, and merges the
new `.hc2200` into `master.hc2200` with `sort -u`.

`extraction_mode=local` runs the extraction on the router;
`extraction_mode=remote` POSTs the `.pcapng` to the GPU's
`/extract` endpoint and imports the returned bundle. The two paths
share the SQLite/hash helpers in
`openwrt_files/usr/lib/wardriving/db.sh`. `gpu_cracking_enabled` is
orthogonal: it controls only whether `/upload_hc2200` is called.

### Layer 2 — GPS bridge

The full pipeline is in
[ADR-0004](docs/adr/0004-virtual-pty-gps.md). Briefly: the browser
batches NMEA every 4 s, the CGI validates against a strict regex,
`socat` bridges the FIFO to a virtual PTY, and `hcxdumptool` reads
the PTY like a serial device. The bridge is owned by
`/etc/init.d/wardriving`.

### Layer 3 — CGI API

`openwrt_files/www/cgi-bin/wardriving_api` is intentionally thin —
it sources `common.sh`, `db.sh`, `remote.sh`, dispatches `action=`
to a handler module under `openwrt_files/usr/lib/wardriving/handlers/`,
and emits security headers on every response. New endpoints
**must** be added via the `is_protected_action` predicate in
`common.sh` (see [ADR-0002](docs/adr/0002-bearer-auth.md)).

The handler directories are:

| Directory        | What lives there                                |
| ---------------- | ----------------------------------------------- |
| `handlers/status`   | Public `/status` endpoint                   |
| `handlers/captures` | Map, history, scored networks, heatmap, list_files, download_all, delete_file, export_* |
| `handlers/maps`     | Tile upload, BBOX download, replay         |
| `handlers/replay`   | Replay start / seek / pause / stop / discovered |
| `handlers/settings` | Targets, exclusions, removals, Wigle, mode, processing, hardware, potfile, pwnagotchi |

### Layer 4 — Web dashboard

Vanilla JS, no framework, no bundler. The shell is `index.html`;
styles are in `app.css`; behaviour is in `app.js`; small helpers
live in `app-utils.js`. The service worker (`sw.js`) is the only
client-side caching layer (see
[ADR-0007](docs/adr/0007-sw-cache-versioning.md)).

Two helpers are mandatory for new fetch calls:

- `apiUrl(action, params)` — returns a URL with the `?token=…`
  fallback for `window.open()` downloads.
- `apiJson(action, params)` — `fetch()` wrapper that attaches the
  `Authorization: Bearer <token>` header and runs the request
  through `fetchWithTimeout` (10 s `AbortController`).

Anything else is a regression: a raw `fetch('/cgi-bin/wardriving_api?…')`
will silently 401 and the UI will look frozen.

### Layer 5 — Install & init

`install.sh` and `uninstall.sh` are the only scripts that touch
`/etc/config/`, `block info`, and the uci state. The init script
(`openwrt_files/etc/init.d/wardriving`) is a standard OpenWrt
`rc.common` script; it owns the `socat` PTY lifecycle and the
daemon PID at `/var/run/wardriving_core.pid`.

## 2. GPS pipeline (critical)

The pipeline is delicate. Read the [ADR-0004](docs/adr/0004-virtual-pty-gps.md)
before touching any of:

- `app.js` (`window.nmeaBuffer`, the 4 s poll, the `gps_push` body)
- `openwrt_files/usr/lib/wardriving/handlers/…/gps_push.sh`
- `/etc/init.d/wardriving` (FIFO creation, socat start)
- `wardriving_core.sh` (`--nmea_dev=/tmp/vGPS`)

The `gps_push` validator is the only line of defence against
malformed NMEA: it rejects unknown sentence types, missing/invalid
checksums, and any non-ASCII garbage.

## 3. Dispatcher table

The `action=` dispatcher in `wardriving_api` is a `case` statement
that maps each action to a sourced handler script. The full list
(≈ 40 actions) is in
[README.md → Endpoint surface](README.md#endpoint-surface). New
actions must:

1. Be added to the dispatcher.
2. Be added to `is_protected_action` (default: protected).
3. Have a corresponding shellcheck-clean handler script.
4. Have a test in `test/run_tests.sh` that covers the auth contract.

## 4. Data flow

```
Browser GPS → CGI gps_push → /tmp/vGPS_fifo → socat PTY /tmp/vGPS → hcxdumptool
                                                                  ↓
wlan0mon → hcxdumptool → .pcapng → hcxpcapngtool → .hc2200 → master.hc2200
                                    ↓                ↓
                                  .csv → sqlite3 → wardriving.db
                                    ↓
                            master_essid.txt

Remote extraction swaps only the hcxpcapngtool step:
.pcapng → GPU /extract → bundle → router imports SQLite rows + master.hc2200
```

The router is the local source of truth at every stage (see
[ADR-0005](docs/adr/0005-local-first-data.md)). The GPU is contacted
only from the daemon, never from the dashboard.

## 5. Conventions

Summarised in [CONTRIBUTING.md → Conventions](CONTRIBUTING.md#conventions).
The full list of decisions is in
[docs/adr/](docs/adr/README.md). The non-negotiables are:

- **POSIX `ash`** — no bashisms. See
  [ADR-0001](docs/adr/0001-busybox-ash.md).
- **Bearer header preferred, `?token=` fallback** — see
  [ADR-0002](docs/adr/0002-bearer-auth.md).
- **Capture is active** — see
  [ADR-0003](docs/adr/0003-active-capture.md).
- **Env-var overrides for every `/etc/wardriving_*` write** — see
  [ADR-0006](docs/adr/0006-env-var-overrides.md).
- **Service worker `skipWaiting()` lives in the `message` handler,
  not in `install`** — see
  [ADR-0007](docs/adr/0007-sw-cache-versioning.md).

## 6. Development loop

```bash
# Edit a handler in place
$EDITOR openwrt_files/usr/lib/wardriving/handlers/captures/list_files.sh

# Run the test suite
sh test/run_tests.sh

# Run the JS test suite
sh test/run_js_tests.sh

# Run shellcheck
shellcheck -e SC1090,SC2002,SC2010,SC2012,SC2015,SC2016,SC2018,SC2035,SC2045,SC3013,SC3043,SC3048 -x \
    install.sh uninstall.sh \
    openwrt_files/usr/bin/*.sh \
    openwrt_files/usr/lib/wardriving/common.sh \
    openwrt_files/usr/lib/wardriving/db.sh \
    openwrt_files/usr/lib/wardriving/remote.sh \
    openwrt_files/usr/lib/wardriving/handlers/*.sh \
    openwrt_files/etc/init.d/wardriving \
    openwrt_files/www/cgi-bin/wardriving_api \
    scripts/*.sh \
    test/run_tests.sh
```

CI runs the same three gates on every push and PR
(`.github/workflows/ci.yml`).
