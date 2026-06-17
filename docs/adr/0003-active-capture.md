# 0003 — Capture is active by design

- **Status:** Accepted
- **Date:** 2025-06-16
- **Deciders:** @tuxevil

## Context

OpenWardRivingT captures WPA/WPA2/WPA3 handshakes and PMKID. There are
two distinct modes in the wider ecosystem:

- **Passive**: listen for 4-way EAPOL exchanges, deauthenticate nothing.
- **Active**: transmit deauthentication and probe frames to force a
  client/AP handshake capture, or to elicit PMKID from APs that would
  not otherwise respond.

PMKID is by design an *opportunistic* artefact: APs only emit it on
association. An entirely passive wardriver would miss the majority of
useful captures in real driving conditions. The project explicitly
targets this use case ("in-vehicle autonomous operation"), and the
caller has already self-declared authorisation in
[README.md → Legal & ethics](../../README.md#legal--ethics).

## Decision

Capture in OpenWardRivingT is **active** by default. The capture loop
in `openwrt_files/usr/bin/wardriving_core.sh` calls `hcxdumptool` with
`--enable_status=1` and the rolling window (`-t 3 --tot=1`). The
project does not implement a passive-only mode in the daemon — the
constraint is documented in the README and enforced socially through
the [Code of conduct](../../CODE_OF_CONDUCT.md).

The dashboard's "mode" setting (`/etc/wardriving_mode.txt`: `active`,
`passive`, `smart`) controls **filtering and targeting**, not whether
deauth is sent. `passive` skips targets the operator has not flagged;
`active`/`smart` follow the targets list and heatmap scoring.

## Consequences

- **Easier:** Operators get a working PMKID capture out of the box and
  can focus on driving rather than on the capture window.
- **Harder:** The project cannot be advertised as "non-disruptive" or
  "passive auditing". Bug reports and feature requests must filter
  for the legal context. The [Code of conduct](../../CODE_OF_CONDUCT.md)
  and the security policy's "out of scope" section
  ([SECURITY.md](../../SECURITY.md#out-of-scope-reports)) make this
  explicit.
- **Trade-off:** A small number of users who wanted a strictly
  passive tool will not adopt OpenWardRivingT. That is acceptable:
  `hcxdumptool` and `tshark` already cover that audience.
- **Follow-up:** A `--passive-only` daemon flag has been requested in
  the past. Implementing it would require a separate ADR that
  re-evaluates the legal-ethics language.
