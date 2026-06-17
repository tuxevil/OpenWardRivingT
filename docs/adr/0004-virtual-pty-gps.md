# 0004 — Synthetic NMEA over a virtual PTY for GPS

- **Status:** Accepted
- **Date:** 2025-06-16
- **Deciders:** @tuxevil

## Context

`hcxdumptool` accepts a GPS source via `--nmea_dev=<path>`. The
captured NMEA is stamped into the `.pcapng` and later extracted by
`hcxpcapngtool` for the geolocation columns. On a router without a
USB GPS dongle, the dashboard's HTML5 Geolocation API is the only
realistic source of position.

Two design constraints:

1. **Latency**. A full CGI fork per GPS sample would saturate `uhttpd`
   workers. The CGI has 12 workers (configured in
   `install.sh:97-99`); we observed CPU saturation on a GL.iNet
   GL-A1300 at ~3 Hz raw sample rate.
2. **Process model**. `hcxdumptool` opens its NMEA source once and
   reads it like a serial device; it does not support
   write-anywhere-IPC. We need a stable path that the daemon can
   `open()` and that we can keep writing to.

A previous ad-hoc solution that wrote to `/tmp/vGPS` directly lost
NMEA data on rollover (hcxdumptool's read head stalled) and had no
backpressure when the FIFO was full.

## Decision

We use a four-stage pipeline, end to end:

1. **Browser** — HTML5 `watchPosition` → JS NMEA generator
   (`$GPRMC`, `$GPGGA`) → `window.nmeaBuffer` (bounded to
   `GPS_BUFFER_MAX=32`, drop-oldest on overflow).
2. **CGI** — `action=gps_push` validates each NMEA line against the
   strict regex
   `^\$[A-Z]{2}(RMC|GGA|WPL),[^*]*\*[0-9A-Fa-f]{2}$` and writes to
   `/tmp/vGPS_fifo` (a named pipe).
3. **socat** — a background `socat` instance reads `/tmp/vGPS_fifo` and
   pushes the data into a virtual PTY at `/tmp/vGPS`. The daemon owns
   this socat; it is started by `/etc/init.d/wardriving` and torn
   down on stop.
4. **Daemon** — `hcxdumptool --nmea_dev=/tmp/vGPS` reads the PTY like a
   serial device.

The buffer between the CGI and socat is a FIFO so the CGI never blocks
on the consumer. A `last` write to `/tmp/vGPS_last` lets replay mode
seed the same path with recorded NMEA. The buffer is cleared only on
a **successful** `gps_push` response — never in the request branch, so
a transient 4xx/5xx does not drop GPS data on the floor.

## Consequences

- **Easier:** The browser, CGI, and capture stages are decoupled and
  individually testable. The dashboard can be developed against a
  recorded NMEA track in `replay` mode without a live GPS.
- **Harder:** The pipeline has four failure points (browser → CGI →
  FIFO → socat → PTY). The init script
  (`openwrt_files/etc/init.d/wardriving`) is responsible for creating
  the FIFO with the right permissions and starting socat before the
  capture loop.
- **Trade-off:** GPS is best-effort. If the browser loses geolocation
  permission or the FIFO blocks, the capture continues without GPS
  and the resulting networks/clients are written with `NULL`
  coordinates. This is preferable to dropping the capture.
- **Follow-up:** A future revision could swap the FIFO for a Unix
  datagram socket to get a single-writer guarantee, but the FIFO is
  good enough for the polling cadence we use today.
