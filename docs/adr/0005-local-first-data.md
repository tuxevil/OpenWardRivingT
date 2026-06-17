# 0005 — Router is the local source of truth

- **Status:** Accepted
- **Date:** 2025-06-16
- **Deciders:** @tuxevil

## Context

The companion GPU server (`server_files/gpu_server.py`) runs hashcat
and, when `extraction_mode=remote`, runs `hcxpcapngtool` for the
router. There is an obvious temptation to expose the GPU's SQLite and
JSON bundle to the dashboard directly, eliminating the import step
on the router.

Two concerns ruled that out:

1. **Connectivity**: the GPU is reached over WireGuard, and the
   recommended deployment routes only the GPU host as a `/32` (see
   [README → Network topology](../../README.md#network-topology)). A
   dashboard that depended on a live GPU connection would refuse to
   load when the car drove out of WireGuard range, which is the
   entire operating envelope.
2. **Security surface**: a dashboard that talks to the GPU opens a
   second auth path (the `X-OWRT-Token` shared secret) and a second
   attack surface (the GPU's Flask app, exposed to a mobile browser).
   The current model keeps the dashboard LAN-only.

## Decision

The dashboard, the map, the history, the heatmap, and the
"fresh networks" view read exclusively from the router's local
SQLite database (`/mnt/wardriving/wardriving.db`) and the local
`master.hc2200` / `master_essid.txt`. The GPU is contacted only from
the router-side daemon (`wardriving_core.sh`), and only for the two
endpoints that materially benefit from offload:

- `POST /extract` — returns a `networks.jsonl`, `clients.jsonl`,
  `capture.hc2200` bundle that the router **imports** into its local
  store.
- `POST /upload_hc2200` — receives the merged `master.hc2200` for
  cracking. Cracked passwords come back via `action=upload_potfile`.

The legacy `POST /upload` endpoint has been removed; new clients use
`/upload_pcap`. This is enforced in
[CHANGELOG.md](../../CHANGELOG.md) and in
[CONTEXT.md](../../CONTEXT.md#api-and-security-patterns-critical).

## Consequences

- **Easier:** The dashboard works offline (no WireGuard, no GPU,
  no internet). The capture loop is fully self-contained. Recovery
  from a GPU failure is automatic — the router falls back to local
  extraction.
- **Harder:** A bundle import step runs after every `/extract` round
  trip. We mitigate with an `API_CACHE_DIR` short-TTL cache
  (introduced in the same commit) so the dashboard's polling does
  not repeatedly re-read the same bundle.
- **Trade-off:** There is a one-`master.hc2200`-merge delay before
  the dashboard reflects hashes the GPU has cracked. The
  `action=upload_potfile` is a pull from the router's perspective
  (the GPU posts back), so the round trip is bounded by the daemon's
  cron and the API cache TTL.
- **Follow-up:** None. This is the model's design contract, not a
  temporary simplification.
