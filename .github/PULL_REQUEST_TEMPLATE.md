## Summary

<!-- One paragraph: what does this PR do and why? Link the issue it closes. -->

Closes #

## Type of change

<!-- Check exactly one. Delete the others. -->

- [ ] Bug fix (`fix:`)
- [ ] New feature (`feat:`)
- [ ] Documentation only (`docs:`)
- [ ] Security fix (`security:`)
- [ ] Refactor / chore (`chore:`, `refactor:`)
- [ ] CI / tooling (`ci:`, `test:`)

## Affected layer

<!-- Check the architecture layer(s) you touched. -->

- [ ] Layer 1 — Capture daemon (`openwrt_files/usr/bin/wardriving_core.sh`, `wardriving_clients.sh`, `wardriving_replay.sh`)
- [ ] Layer 2 — GPS bridge
- [ ] Layer 3 — CGI API (`openwrt_files/www/cgi-bin/wardriving_api`, `openwrt_files/usr/lib/wardriving/`)
- [ ] Layer 4 — Web dashboard (`openwrt_files/www/wardriving/`)
- [ ] Layer 5 — Install / init (`install.sh`, `uninstall.sh`, `openwrt_files/etc/init.d/wardriving`)
- [ ] GPU server (`server_files/`)
- [ ] Tests / CI
- [ ] Docs (`README.md`, `CONTEXT.md`, `AGENTS.md`, `docs/`, `CHANGELOG.md`)

## Checklist

<!-- Each box must be true before requesting review. CI will fail otherwise. -->

- [ ] `sh test/run_tests.sh` passes locally
- [ ] `sh test/run_js_tests.sh` passes locally
- [ ] Shellcheck (with the project's exclusions, see README) passes locally
- [ ] New `/etc/wardriving_*` writes are guarded by a `WARDRIVING_*_FILE` env-var override
- [ ] New CGI actions go through `is_protected_action` (or are explicitly documented as public)
- [ ] New dashboard `fetch()` calls go through `apiUrl()` / `apiJson()` / `withApiAuth()`
- [ ] No new bashisms, no `mountpoint` / `findmnt`, no `npm` / `pip` build step
- [ ] `CHANGELOG.md` `## Unreleased` updated (user-visible changes only)
- [ ] I have **not** committed any API token, WiFi password, captured hashes, or `.pcapng` files

## Testing

<!-- How did you verify the change? Include the exact commands and the observed output. -->

```
$ sh test/run_tests.sh
…159 passed…
```

## Screenshots / recordings

<!-- If the change touches the dashboard, attach before/after. -->

## Risk and rollback

<!-- What can break? How do we revert? -->
