# Contributing to OpenWardRivingT

Thanks for your interest in OpenWardRivingT. This project is a pure
`ash` + vanilla-JS wardriving suite for OpenWrt routers with **no build
step**; please read this guide before opening an issue or a pull request.

> **Active auditing software.** OpenWardRivingT transmits deauthentication
> and probe frames. By contributing you confirm that your contributions
> are intended for use against networks you own or have explicit written
> authorisation to test. See [README → Legal & ethics](README.md#legal--ethics)
> and the [Code of conduct](CODE_OF_CONDUCT.md).

## Table of contents

- [Quick start](#quick-start)
- [Issue filing](#issue-filing)
- [Pull requests](#pull-requests)
- [Conventions](#conventions)
- [Testing](#testing)
- [Commit messages](#commit-messages)
- [Versioning & release](#versioning--release)
- [Security issues](#security-issues)

## Quick start

```bash
git clone https://github.com/tuxevil/OpenWardRivingT.git
cd OpenWardRivingT
sh test/run_tests.sh        # ~159 shell + busybox assertions
sh test/run_js_tests.sh     # Node-based dashboard unit tests
```

For a deeper tour, read:

- [README.md](README.md) — features, hardware, install
- [ARCHITECTURE.md](ARCHITECTURE.md) — five-layer architecture, dispatcher
- [CONTEXT.md](CONTEXT.md) — GPS pipeline, quirks, design intent
- [AGENTS.md](AGENTS.md) — AI-agent workflow (beads, push protocol)
- [docs/adr/](docs/adr/) — captured architectural decisions
- [CHANGELOG.md](CHANGELOG.md) — release notes

## Issue filing

Use the GitHub issue templates:

- **Bug** — `.github/ISSUE_TEMPLATE/bug_report.yml`
- **Feature** — `.github/ISSUE_TEMPLATE/feature_request.yml`

Please do **not** file security issues publicly — see
[SECURITY.md](SECURITY.md).

## Pull requests

1. Fork and create a feature branch off `main`.
2. Make the change. Follow the conventions below.
3. Update [CHANGELOG.md](CHANGELOG.md) under `## Unreleased` for any
   user-visible change.
4. Run the full quality gate locally (see [Testing](#testing)).
5. Open a PR using [`.github/PULL_REQUEST_TEMPLATE.md`](.github/PULL_REQUEST_TEMPLATE.md).
6. Address review feedback by force-pushing a clean history (or by
   squashing when the PR is approved).

## Conventions

### Shell scripts

- **Shebang**: `#!/bin/sh`. OpenWrt ships BusyBox `ash`; bashisms break
  the build. No arrays `()`, no `[[`, no `&>`, no `source` → use `.`.
- **No `mountpoint`, no `findmnt`** — use `/proc/mounts`.
- **Loop scripts** (`wardriving_core.sh`, `wardriving_clients.sh`,
  `run_hashcat.sh`) run with `set -e`; replay runs with `set -u`.
- **Trap signals** in every infinite loop: `trap cleanup SIGTERM SIGINT SIGHUP`.
- **Atomic writes** with `mktemp`; never write directly to live system
  paths.
- **Env-var overrides** for any handler that writes to a fixed
  `/etc/wardriving_*` path. The full list lives in
  `openwrt_files/usr/lib/wardriving/common.sh`; add a new entry there
  for any new fixed-path handler so the test suite (non-root) can run.

### CGI handlers

- Authenticate via `is_protected_action` in `common.sh`. The only public
  endpoint is `action=status` — keep new public endpoints to a minimum
  and document the attack-surface trade-off.
- Build responses manually with `cat << JSON` heredocs; validate with
  `python3 -m json.tool`.
- Emit the security headers set in `common.sh` on every response
  (`nosniff`, `DENY`, `no-referrer`, `no-store` for JSON). Do not
  introduce `Access-Control-Allow-Origin: *`.
- Cap `CONTENT_LENGTH` per endpoint and reject path-traversal payloads
  (`../etc/passwd`, `%2Fetc%2Fpasswd`).

### Web dashboard

- **No build step.** Vanilla JS only. No `npm`, no bundler, no framework.
- **Auth**: every `fetch()` goes through `apiUrl()`, `apiJson()`, or
  `withApiAuth()`. Never write raw `fetch('/cgi-bin/wardriving_api?…')`
  — the request will silently 401 and the UI will look frozen.
- **Service worker** (`sw.js`): bump `CACHE_NAME = 'owrt-store-vN'` to
  force a refresh on all clients. `skipWaiting()` is only called from
  the `message` handler, never from `install`.
- **Escaping**: any user-controlled string rendered via `innerHTML`
  (SSID, filename, target, exclusion) must pass through the `esc()`
  helper or be inserted with DOM text APIs.
- **GPS buffer**: `window.nmeaBuffer` is bounded to `GPS_BUFFER_MAX=32`
  entries; drop-oldest on overflow. Clear the buffer only after a
  successful `gps_push` response.

### Documentation

- English for new prose. Bilingual glosses are welcome in code comments
  where the project already uses them.
- Markdown; wrap at 100 columns where reasonable.
- Code blocks use a language hint (`sh`, `json`, `awk`, `text`).

## Testing

The CI runs three gates (see [`.github/workflows/ci.yml`](.github/workflows/ci.yml)).
Run them locally before pushing:

```bash
# 1. Shell + busybox integration tests
sh test/run_tests.sh

# 2. JavaScript unit tests (Node)
sh test/run_js_tests.sh

# 3. Shellcheck with the project's exclusions
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

New tests live in `test/` (shell) or `test/js/` (Node). Each new handler
or env-var override must be covered.

## Local pre-commit and commit-msg hooks

Pure POSIX `sh` hooks live in [`.githooks/`](.githooks). They are not
installed by `git clone` — run the installer once per clone:

```bash
sh scripts/install_hooks.sh           # install (idempotent)
sh scripts/install_hooks.sh --status  # show current state
sh scripts/install_hooks.sh --uninstall
```

The installer writes small wrapper files into whatever directory git
already uses for hooks (it honours `core.hooksPath` — for example, it
chains cleanly with `bd`/beads). It never modifies `core.hooksPath`
itself. The wrappers are recognised on uninstall by an
"installed by scripts/install_hooks.sh" marker and removed only if that
marker is present.

What the hooks do:

- **`pre-commit`** — runs shellcheck (`-x` with the project's exclusion
  list), `sh -n`, `py_compile`, `node --check` (skipping the dashboard
  entry-point `app.js`), and JSON validation on the staged files. Fails
  the commit if any check fails. Bypass once with
  `git commit --no-verify`.
- **`commit-msg`** — validates the commit message against the
  [Conventional Commits](https://www.conventionalcommits.org/) spec
  (type allowlist, scope optional, breaking-change marker, 72-char
  subject, 100-char header, no trailing period, imperative mood). Merge
  and squash commits are passed through. Bypass once with
  `git commit --no-verify`.

CI does not depend on these hooks — `.github/workflows/ci.yml` runs the
same checks on every push.

## Commit messages

We use [Conventional Commits](https://www.conventionalcommits.org/)
prefixes. The `commit-msg` hook (see [Local pre-commit and commit-msg hooks](#local-pre-commit-and-commit-msg-hooks))
enforces them locally; the release workflow reads them to generate
changelogs:

```
<type>(<scope>): <short summary>

<optional body>

<optional footer>
```

Allowed types:

| Type        | Purpose                                          |
| ----------- | ------------------------------------------------ |
| `feat`      | New user-visible feature                         |
| `fix`       | Bug fix                                          |
| `docs`      | Documentation only                               |
| `security`  | Security fix or hardening                        |
| `refactor`  | Code change that neither fixes a bug nor adds a feature |
| `perf`      | Performance improvement                          |
| `test`      | Adding or fixing tests                           |
| `ci`        | CI, shellcheck, dependabot                       |
| `chore`     | Tooling, repo-meta, formatting                   |
| `revert`    | Revert a previous commit                         |

Keep the subject line ≤ 72 characters; imperative mood; no trailing
period.

## Versioning & release

The project follows [SemVer](https://semver.org/). The current version is
pinned in [VERSION](VERSION). Releases are cut by:

```bash
sh scripts/bump_version.sh 0.2.0   # updates VERSION, refreshes CHANGELOG header
git tag -s v0.2.0 -m "v0.2.0"
git push --follow-tags
```

The release workflow (`.github/workflows/release.yml`) creates a GitHub
Release with auto-generated notes grouped by commit type. Critical fixes
follow the same flow after a security advisory is opened.

## Security issues

Please **do not** open a public issue for suspected vulnerabilities.
Email or use GitHub private advisories as described in
[SECURITY.md](SECURITY.md). We will respond within 72 hours.
