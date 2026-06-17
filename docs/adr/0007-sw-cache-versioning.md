# 0007 — Service worker cache versioning strategy

- **Status:** Accepted
- **Date:** 2025-06-16
- **Deciders:** @tuxevil

## Context

`openwrt_files/www/wardriving/sw.js` registers a service worker that
pre-caches the app shell (`index.html`, `app.css`, `app.js`,
`app-utils.js`, the Leaflet bundle, and a small set of icons). The
cache is what makes the dashboard load instantly when the tablet
loses WiFi roaming between the car AP and the house.

Three refresh patterns had to be settled:

1. **Force a refresh on deploy** without a manual "clear site data"
   dance from the user. Without this, a bug fix in `app.js` ships
   silently because the SW serves the old copy.
2. **Do not hijack open tabs on deploy.** A `skipWaiting()` in the
   `install` event promotes a new worker eagerly, which kicks the
   user out of the current map view, the current GPS follow-mode,
   and the current zoom. The complaint that drove the fix was a
   field report: "I lost my route when the dashboard updated itself
   at a red light."
3. **Coexist with the GPS, replay, and map state.** The SW is
   intentionally small; it does not cache map tiles, the SQLite
   backend, or the live status payload.

## Decision

- The cache name is `CACHE_NAME = 'owrt-store-vN'` where `N` is
  bumped by hand on every release that ships a dashboard change. The
  bump lives in `openwrt_files/www/wardriving/sw.js`; the release
  PR must include a one-line `N → N+1` commit.
- `skipWaiting()` is called **only** from the `message` handler, and
  only in response to `event.data.type === 'SKIP_WAITING'`. The
  dashboard opts in via `postMessage({type: 'SKIP_WAITING'})` from
  an explicit "Refresh" affordance, not from a deploy.
- The `install` event pre-caches the shell and returns; it does not
  call `skipWaiting()` or `clients.claim()`. This means an in-flight
  dashboard keeps running the old worker until the user navigates or
  the page is reloaded, and then the new worker is offered via the
  standard update flow.
- The SW does not cache `/cgi-bin/wardriving_api` or any of the
  `/api/...` endpoints. Status, maps, and replay are always live.

## Consequences

- **Easier:** A bumped `N` guarantees every client picks up the new
  shell on next reload. The "Refresh" affordance is opt-in, so the
  user keeps their state.
- **Harder:** Every release that ships a dashboard change must
  remember to bump `N`. We mitigate by adding the bump to the
  release checklist in
  [CONTRIBUTING.md → Versioning & release](../../CONTRIBUTING.md#versioning--release).
- **Trade-off:** A user who never clicks "Refresh" keeps the old
  shell indefinitely. We accept this because the alternative
  (eager `skipWaiting()`) breaks the in-vehicle UX that the
  project is designed for.
- **Follow-up:** A future revision could add a "stale shell"
  indicator (badge in the top bar) so the user knows a refresh is
  available. That is an enhancement, not a correctness fix.
