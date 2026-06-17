# 0001 — Use BusyBox `ash` exclusively

- **Status:** Accepted
- **Date:** 2025-06-16
- **Deciders:** @tuxevil

## Context

OpenWardRivingT runs on commodity OpenWrt routers with as little as 64 MB
of RAM and a 600 MHz MIPS CPU. The base image is BusyBox, and the
official package feed does not ship `bash` (or ships it as an optional
~1 MB package the user must install). Every file under
`openwrt_files/usr/bin/`, `openwrt_files/usr/lib/wardriving/`,
`openwrt_files/etc/init.d/`, and `openwrt_files/www/cgi-bin/` is
executed on the router, including inside `uhttpd`'s per-request CGI
fork.

Bashisms (arrays `()`, `[[ … ]]`, `&>`, `source`, `local` in pure-POSIX
code paths, `${var//pat/repl}`) work on a developer laptop and silently
fail or error on the router, sometimes with destructive consequences
(e.g. `hcxdumptool` writing to a half-mounted filesystem).

The CI runs shellcheck with a long exclusion list
(`SC1090,SC2002,SC2010,SC2012,SC2015,SC2016,SC2018,SC2035,SC2045,SC3013,SC3043,SC3048`),
but the only signal that a script is genuinely BusyBox-compatible is
deployment on real hardware.

## Decision

All shell scripts in this repository:

- Use `#!/bin/sh` as the shebang. We rely on BusyBox `ash` (the default
  `/bin/sh` on OpenWrt) for semantics.
- Avoid bashisms. The full list of forbidden constructs is in
  [CONTEXT.md](../../CONTEXT.md#ash-vs-bash) and
  [CONTRIBUTING.md](../../CONTRIBUTING.md#shell-scripts).
- Stick to POSIX `awk` / `sed` / `tr` / `cut` for text processing. `awk`
  is preferred over `sed -E` for portability.
- Detect BusyBox-only utilities explicitly in the install script and
  fall back gracefully (e.g. `coreutils-stat` is optional; the API
  cache uses a timestamp fallback if it is missing).

## Consequences

- **Easier:** Reviewers can trust that `sh test/run_tests.sh` on a
  developer laptop exercises the same code path as the router. The
  one tool that is allowed to use `bash`-only behaviour is the test
  runner itself (`test/run_tests.sh`), which is a developer-only file.
- **Harder:** We cannot use features that would make the scripts
  shorter (arrays, `[[`, `printf -v`). The ~5% verbosity is the price
  we pay for guaranteed on-target behaviour.
- **Trade-off:** Shellcheck exclusions mask a few real warnings
  (`SC2016` is informational only because the test runner uses single
  quotes to send literal NMEA strings). We mitigate by running the
  exclusion list through the [CONTRIBUTING.md](../../CONTRIBUTING.md#testing)
  section so the trade-off is documented.
- **Follow-up:** New scripts MUST be added to the shellcheck invocation
  in `.github/workflows/ci.yml` and the local command in the README.
