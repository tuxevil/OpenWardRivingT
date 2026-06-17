# Architecture Decision Records (ADRs)

This directory captures architecturally significant decisions in the
OpenWardRivingT project. Each ADR records the **context**, the **decision**,
and the **consequences** of the choice so that future contributors can
understand *why* the code looks the way it does.

## How to read these

- ADRs are immutable. Once accepted, the status does not change; a
  later decision that supersedes an ADR is captured in a new ADR that
  links back to it.
- The numbering is sequential and zero-padded so files sort
  alphabetically in the same order they were written.
- Every ADR is short — aim for one screen of text.

## How to write a new one

1. Copy `template.md` to `NNNN-short-slug.md` (next free number).
2. Fill in **Status**, **Context**, **Decision**, **Consequences**.
3. Link the new ADR from the **Index** below and from any related
   sections of [README.md](../../README.md) or [ARCHITECTURE.md](../../ARCHITECTURE.md).
4. Open a PR. The CI does not validate ADRs, but reviews do.

## Index

| #    | Title                                                | Status   |
| ---- | ---------------------------------------------------- | -------- |
| 0001 | [Use BusyBox `ash` exclusively](0001-busybox-ash.md) | Accepted |
| 0002 | [Bearer token auth with `?token=` fallback](0002-bearer-auth.md) | Accepted |
| 0003 | [Capture is active by design](0003-active-capture.md) | Accepted |
| 0004 | [Synthetic NMEA over a virtual PTY for GPS](0004-virtual-pty-gps.md) | Accepted |
| 0005 | [Router is the local source of truth](0005-local-first-data.md) | Accepted |
| 0006 | [Env-var overrides for `/etc` paths in handlers](0006-env-var-overrides.md) | Accepted |
| 0007 | [Service worker cache versioning strategy](0007-sw-cache-versioning.md) | Accepted |
