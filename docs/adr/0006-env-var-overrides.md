# 0006 — Env-var overrides for `/etc` paths in handlers

- **Status:** Accepted
- **Date:** 2025-06-16
- **Deciders:** @tuxevil

## Context

The CGI handlers in `openwrt_files/usr/lib/wardriving/handlers/`
write to a fixed set of paths under `/etc`:

- `/etc/wardriving_api_token`
- `/etc/wardriving_mode.txt`
- `/etc/wardriving_keep_pcap.txt`
- `/etc/wardriving_excluded.txt`
- `/etc/wardriving_removed.txt`
- `/etc/wardriving_extraction_mode`
- `/etc/wardriving_gpu_cracking_enabled`
- `/etc/wardriving_remote_enabled`
- `/etc/wardriving_remote_url`
- `/etc/wardriving_remote_secret`
- `/etc/wardriving_targets.txt`
- `/etc/wardriving_wigle_token`
- `/etc/wardriving_api_cache/`

The CI runs the test suite as a non-root `runner` user. Without
overrides, every handler test that writes a config file fails with
`Permission denied` on the first `touch /etc/wardriving_…`. Routing
the entire CI through `sudo` is brittle (it requires NOPASSWD, it
hides per-test effects in `/etc`, and it makes the test suite
non-reproducible on a developer laptop without root).

## Decision

Every handler reads its target path from a `WARDRIVING_*_FILE`
environment variable, with the production path as the default. The
list of supported overrides lives in
`openwrt_files/usr/lib/wardriving/common.sh` and is reproduced in
[README → Conventions](../../README.md#conventions) and
[AGENTS.md](../../AGENTS.md). The test runner exports per-test
overrides to a `/tmp/wardriving_test_…` tree.

For a new fixed-path handler:

1. Add the `WARDRIVING_X_FILE` variable to `common.sh` with the
   `${WARDRIVING_X_FILE:-/etc/wardriving_x}` default.
2. Add the override to the test setup in
   `test/run_tests.sh` so the test tree does not collide with the
   host's `/etc`.
3. Update [README.md → Conventions](../../README.md#conventions) and
   [AGENTS.md](../../AGENTS.md) (the env-var list is duplicated in
   both for discoverability).

The runtime uses of `/etc/wardriving_*` paths (e.g. `install.sh`,
`wardriving_core.sh`, the init script) are **not** wrapped — they
are guaranteed root-on-router code and the test suite does not
exercise them.

## Consequences

- **Easier:** The CI runs without `sudo`, and developers can run
  `sh test/run_tests.sh` on a laptop. The router-installer path
  (`install.sh`, init script) is unchanged because the wrapper is
  one-line in `common.sh`.
- **Harder:** Every new fixed-path handler needs a wrapper. Skipping
  it breaks the test suite. We mitigate by code review.
- **Trade-off:** A handler that forgets the wrapper looks correct on
  the router (production default applies) but fails in CI. We
  document the requirement in
  [CONTRIBUTING.md → Conventions](../../CONTRIBUTING.md#shell-scripts).
- **Follow-up:** None. The pattern is settled and the test suite
  is the canary.
