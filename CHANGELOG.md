# Changelog

All notable changes to OpenWardRivingT are documented here. The format is
loosely [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) but
adapted to a single rolling `Unreleased` section — the most recent
release tag (`vX.Y.Z`) marks the latest shipped version. The current
pin is in [VERSION](VERSION).

The project follows [Semantic Versioning](https://semver.org/). Release
notes are generated from conventional-commit history by
`.github/workflows/release.yml`; the steps to cut a release are in
[CONTRIBUTING.md → Versioning & release](CONTRIBUTING.md#versioning--release).

## Unreleased

### Security
- `Authorization: Bearer <token>` header is the preferred way to
  authenticate dashboard calls. The CGI accepts the header
  case-insensitively and falls back to `?token=…` for `window.open()`
  downloads and external scripts. Helpers `apiUrl()` and `withApiAuth()`
  in `app.js` attach the header automatically — never write raw
  `fetch('/cgi-bin/wardriving_api?…')` in the dashboard.
- Stricter NMEA validation in `gps_push`: rejects malformed sentences
  (unknown sentence types, missing/invalid checksums, garbage strings)
  before writing to the FIFO. Also gates FIFO writes on an active
  `socat` vGPS reader to avoid blocking processes.
- `set_hw` serializes concurrent requests with `flock` to keep the
  init and button scripts from being clobbered mid-write.
- Security headers (`X-Content-Type-Options: nosniff`,
  `X-Frame-Options: DENY`, `Referrer-Policy: no-referrer`,
  `Cache-Control: no-store`) emitted on every CGI response; the
  wildcard `Access-Control-Allow-Origin: *` is gone.
- `delete_file` blocks path-traversal payloads (`../etc/passwd`,
  `%2Fetc%2Fpasswd`, etc.).
- `add_exclusion` and `remove_exclusion` URL-decode the SSID before
  storing/deleting, so `Mi%20Red%20WiFi` matches `Mi Red WiFi` on the
  file.

### Performance
- OUI DB fetch removed from the dashboard. The 869KB `oui.json`
  download is gone from every page load.
- `/status` `handshakes` count is cached in `/tmp` instead of running
  `wc -l` on the potfile every poll.
- `API_CACHE_DIR` short-TTL JSON cache for heavy endpoints
  (`networks_map`, `clients_map`, `heatmap_data`, `scored_networks`)
  so repeated dashboard polls reuse the same response.

### Reliability
- `fetchWithTimeout` wraps every `apiJson` call with a 10s
  `AbortController` timeout. Hung `uhttpd` workers (common during
  background handshake capture) no longer block the polling loop.
  On timeout the error is rewritten to `request timeout (Xms)` so
  toast/banner messages are readable. Long-running calls
  (`download_all`, `upload_tiles`, `upload_potfile`) opt out via
  `window.open()` rather than going through `apiJson`.
- `pwnagotchi_status` curl timeout 2s → 10s (pwnagotchi UI loads
  can take several seconds), and the host is configurable via
  `WARDRIVING_PWN_HOST` (default `127.0.0.1`).
- `subprocess.run` in the GPU server uses an explicit timeout for
  `hcxpcapngtool` so a stuck PCAP conversion no longer hangs the
  upload endpoint.
- Service worker no longer hijacks open tabs on deploy. `skipWaiting()`
  is only called from the `message` handler (not `install`), so
  existing dashboards keep their map state, GPS position, and
  follow mode across an update.

### Refactors
- `evalMood(name, mood)` — unused `de` parameter dropped.
- Handlers that wrote to fixed `/etc/wardriving_*` paths now read
  from `WARDRIVING_*_FILE` env-var overrides (with the same default
  paths), making the test suite possible on a non-root CI runner.
  New overrides: `WARDRIVING_TARGETS_FILE`, `WARDRIVING_WIGLE_TOKEN_FILE`,
  `WARDRIVING_PWN_HOST`.
- `wardriving_core.sh`, `wardriving_clients.sh`, and `run_hashcat.sh`
  run with `set -e`. `wardriving_replay.sh` opts into `set -u`
  explicitly.
- `/upload` legacy endpoint removed from `gpu_server.py`. New
  clients use `/upload_pcap` (with the token).

### Tooling
- `.editorconfig`, `CODEOWNERS`, and `.github/dependabot.yml` added
  so formatting/PR routing/security updates are handled consistently.
- ShellCheck CI excludes SC2016 globally (informational only — the
  test runner intentionally uses single quotes to send literal
  NMEA strings to the CGI).
- 155 shell + busybox tests run in CI; new regression tests lock
  the OUI_DB removal, the AbortController contract, the service
  worker `skipWaiting` placement, the API_TOKEN placeholder format,
  and the path-traversal guard.
- `VERSION` file pins the current SemVer (v0.1.0). `scripts/bump_version.sh`
  is a BusyBox-ash-compatible bumper that updates `VERSION`, refreshes the
  CHANGELOG header, and prints the next commit/tag commands.
- `.github/workflows/release.yml` builds a source tarball, runs the
  full test matrix, and creates a GitHub Release on every `vX.Y.Z` tag.
- `.github/ISSUE_TEMPLATE/{bug_report,feature_request}.yml` and
  `.github/ISSUE_TEMPLATE/config.yml` standardize issue filing; a
  `PULL_REQUEST_TEMPLATE.md` and `labels.yml` round out the GitHub
  ergonomics.
- `.github/labeler.yml` and `.github/workflows/labeler.yml` apply
  path-based labels (layer:1-capture … repo-meta) to every PR; the
  `labels` workflow keeps the label definitions in `.github/labels.yml`
  in sync with GitHub.
- `.githooks/{commit-msg,pre-commit}` enforce Conventional Commits and
  run shellcheck / `sh -n` / `py_compile` / `node --check` / JSON
  validation on staged files. `scripts/install_hooks.sh` wires the
  hooks into the active git hooks directory without touching
  `core.hooksPath` (chains cleanly with `bd`/beads).

### Docs
- `AGENTS.md`, `CLAUDE.md`, and `CONTEXT.md` synchronized with the
  current state (env var list, auth flow, ops notes).
- README auth summary now points to Bearer header as the primary
  method (with `?token=` kept for fallback).
- This `CHANGELOG.md` introduces a rolling changelog so future
  changes are visible to users without diffing git log.
- `SECURITY.md` formalises the vulnerability disclosure process, the
  supported-versions table, and the hardening checklist.
- `CODE_OF_CONDUCT.md` (Contributor Covenant 2.1, adapted for
  active-war-driving context) and `CONTRIBUTING.md` (extracted from
  the README) cover contributor and community norms.
- `ARCHITECTURE.md` complements `CONTEXT.md` with the dispatcher
  table, the data flow diagram, and a per-layer change guide.
- `docs/adr/README.md` plus seven ADRs capture the non-obvious
  decisions: BusyBox ash, Bearer auth, active capture, virtual-PTY
  GPS, local-first data, env-var overrides, and the service-worker
  cache strategy.
