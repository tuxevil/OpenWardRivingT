# OpenWardRivingT 🛰️🚗

**OpenWardRivingT** is an automated, headless **active** wardriving suite built specifically for **OpenWrt** hardware (highly optimized for Atheros chipsets like Netgear WNDR3700, GL-A1300, etc.). It is designed to operate autonomously in your vehicle, actively targeting networks to capture PMKID and EAPOL handshakes while tracking network locations via GPS.

It features a spectacular **Tablet-Optimized Web Dashboard** meant to be used from your car's Android head unit or tablet. It includes real-time statistics, an offline map radar, a live spectrum analyzer, and a built-in capture manager.

## ✨ Key Features
- **100% Headless & Autonomous**: Start capturing by simply pressing a physical button (WPS/WiFi) on your router.
- **Responsive Vehicular Dashboard**: A beautiful 4-column Single Page Application (SPA) designed with huge icons and high contrast. Automatically adapts to ultra-wide car radios (1280x720) down to mobile screens.
- **Live Spectrum Analyzer**: Visualize 2.4GHz channel congestion with an interactive, scrollable tree-view (accordion) showing live channel network counts and detailed captured SSIDs in real-time.
- **Offline/Online Maps**: See your route and pinpoint geolocated routers using Leaflet.js. Upload your own tile maps directly from the UI for 100% offline usage.
- **Visual Hardware Feedback**: Bind your router's LEDs to visually blink when actively sniffing handshakes.
- **Native GPS Integration**: Geotag your captures seamlessly! You can feed GPS data using a dedicated NMEA forwarder app, OR simply use the built-in **Browser GPS Override** toggle right in the dashboard (using HTML5 Geolocation) without needing any third-party apps.
- **WiGLE Integration**: Automatically upload a CSV of all detected networks directly to your WiGLE account. *(Note: This uploads the list of spotted networks, but your raw .pcapng handshakes remain private on your USB).*
- **Rich Export Options**: Easily download your captures, KML/GPX route files, and clean `.hc2200` Hashcat-ready crack files.
- **Smart SQLite Logging & Scoring**: Captures are tracked in a lightning-fast SQLite WAL database, bringing powerful features like Heatmaps and Smart Target Scoring right to the dashboard.
- **Cyberpunk Night Mode & TTS**: Safely wardrive at night with a deeply-red-tinted "Night Mode" and audio-driven Text-To-Speech (TTS) alerts when specific targets are found.

## 🛠️ Hardware Requirements
1. **OpenWrt Router**: Preferably with dual radios (2.4GHz dedicated to monitor mode/injection, and 5GHz to host the stealth control panel).
2. **USB Flash Drive (MANDATORY)**: Formatted in `ext4` to store captures and offline map tiles. Must be mounted at `/mnt/wardriving/`.
   > **⚠️ Safety Mechanism**: The core script will refuse to start capturing if a USB drive is not detected. This is a deliberate safety measure to prevent permanent NAND wear (flash memory degradation) caused by continuous pcapng writes, and to protect the router from a system collapse due to reaching 100% internal storage capacity.
3. **Car Power Supply**: A 12V to 5V/12V step-down converter depending on your router's needs.
4. **GPS-Enabled Device (Optional but recommended)**: A smartphone, tablet, or Android head unit with GPS capabilities to provide location data to the dashboard.

## ✅ Tested Hardware

| Device | Chipset | Radios | OpenWrt Version | Status |
|--------|---------|--------|-----------------|--------|
| Netgear WNDR3700v2 | AR7161 + AR9220/AR9223 | 2.4 + 5 GHz | 23.05 | ✅ Full support |
| GL.iNet GL-A1300 | IPQ4018 | 2.4 + 5 GHz | 24.10 | ✅ Full support |
| TP-Link Archer C7 v2 | QCA9558 + QCA9880 | 2.4 + 5 GHz | 23.05 | ✅ Monitor mode OK |
| Generic x86_64 | Any compatible | Any | 24.10 | ✅ USB GPS required |

> **Chipset note**: Atheros AR9xxx and Qualcomm IPQ40xx chipsets have best monitor mode + packet injection support. MediaTek MT76xx works but may require additional kmod packages. Broadcom is NOT supported.

## 📦 Software Dependencies
The automated installer will automatically detect your package manager (`apk` for OpenWrt 24.x+ or `opkg` for older versions) and install the required tools:
- `hcxdumptool` (v6.3+) & `hcxtools` (for capturing and parsing)
- `socat` (for NMEA GPS tunneling)
- `block-mount`, `e2fsprogs`, and `kmod-usb-storage` (for USB ext4 auto-mounting)
- `openssh-client` and `openssh-sftp-server` (for modern `scp`/SFTP uploads without forcing legacy `scp -O`)
- `uhttpd` (built-in OpenWrt web server)

OpenWrt 24/25 images may not include `opkg`; use `apk update` and `apk add ...` on those builds. If package updates fail while WireGuard is enabled, check for route overlap before blaming the package feeds.

## 🚀 Easy Installation
1. SSH into your OpenWrt router.
2. Clone or download this repository.
3. Run the setup script:
   ```bash
   chmod +x install.sh
   ./install.sh
   ```
4. The script will automatically configure the 5GHz network (`owrt` / pass: `wardriving`), deploy the web app, and enable the service on boot.

## 🚙 Basic Usage
1. Power up the router in your vehicle with the USB drive attached.
2. **(GPS Setup)**: Toggle the **Browser GPS Override** on the dashboard to use your device's native browser location. The dashboard posts synthetic NMEA to the CGI API, which forwards it through `/tmp/vGPS_fifo` into the `/tmp/vGPS` virtual PTY used by `hcxdumptool`.
3. Connect your tablet to the 5GHz WiFi network (`owrt`).
4. Navigate to `http://192.168.1.1/wardriving/index.html` (or your router's IP).
5. Hit **START** on the screen or press the configured physical router button. Start driving!

## 🗺️ Offline Map Management
In the "Settings" tab of the web application, you can upload a `.tar.gz` file containing a standard `Z/X/Y.png` tile folder (generated via tools like Mobile Atlas Creator). This gives you a rich street map on your dashboard without needing mobile data.

## 🔐 API & Remote Processing Security
The installer generates `/etc/wardriving_api_token` and injects it into the dashboard so normal UI actions continue to work without extra steps. Sensitive exports and data endpoints require that token; the lightweight `status` endpoint remains available for health checks.

### Endpoint Authentication Summary

| Endpoint | Auth Required | Notes |
|---|---|---|
| `action=status` | ❌ No | Public health check — exposes running state only |
| All other actions | ✅ Yes | Token via `Authorization: Bearer` header (preferred) or `?token=…` query param (fallback for `window.open()` downloads) |

> **Security note**: `action=status` is the **only** unauthenticated endpoint. It intentionally exposes minimal information (running state, network counts) so monitoring tools can poll without a secret. All write operations and sensitive data exports (captures, hashes, GPS data, history) require a valid API token.

For GPU offload, configure the same shared secret on both sides:

```bash
# Router
echo "replace-with-a-long-random-secret" > /etc/wardriving_remote_secret

# GPU server systemd environment
OWRT_GPU_SHARED_SECRET=replace-with-a-long-random-secret
OWRT_ROUTER_TOKEN=<router-api-token-used-for-potfile-sync>
```

Processing now has two independent settings:

- **Extraction Mode** (`/etc/wardriving_extraction_mode`): `local` runs `hcxpcapngtool` on the router; `remote` sends the `.pcapng` to GPU `/extract` and imports the returned bundle locally.
- **GPU Cracking** (`/etc/wardriving_gpu_cracking_enabled`): `1` uploads `.hc2200` hashes to GPU `/upload_hc2200`; `0` keeps cracking disabled even if extraction runs remotely.

The dashboard never reads the GPU directly. Live "Redes Ahora" comes from local `hcxdumptool` status, and map/history/client/cracked views read the router's local SQLite and pot/hash files. If remote extraction fails or returns an invalid bundle, the router falls back to local extraction.

If the router reaches the GPU over WireGuard, route only the GPU host when that address overlaps with the router's WAN network. For the test topology, `10.128.128.254/32` should be allowed/routed through WireGuard, not the whole `10.128.128.0/24`; advertising the whole `/24` can steal the WAN gateway route and break `apk update`.

## 🐾 Pwnagotchi Bridge & Virtual Pet
As an homage to the legendary [evilsocket/pwnagotchi](https://github.com/evilsocket/pwnagotchi) project, the dashboard features its very own JavaScript-based virtual pet.
- **Dynamic Mood Engine**: The pet reacts to its environment. It gets sleepy when the capture service is paused, sad if your USB drive is full, lonely if GPS is lost, and shifts through states of excitement (Happy, Intense, Excited) as it captures continuous bursts of handshakes in real-time.
- **Pwnagotchi Sync (The Bridge)**: If you happen to carry a real Pwnagotchi with you in the car, you can bridge it to the router! The dashboard will monitor your physical Pwnagotchi's stats via its REST API, and the router can act as a centralized "mothership" to merge `.pcap` files automatically and extract handshakes into your main USB database.

## 🛑 Known Quirks & Strange Behaviors
When operating the router, you might notice the following behaviors. These are entirely normal and part of how the software handles heavy processing on low-power hardware:

1. **Rollover CPU Spikes**: `hcxdumptool` runs in short capture windows. When the router stops sniffing to process the resulting `.pcapng` file, extract handshakes using `hcxpcapngtool`, and insert networks into SQLite, CPU can briefly hit 100%. We run these rollover tasks with lower priority (`nice`) so the UI doesn't freeze, but slight API delays are expected.
2. **GPS Buffer Lag**: When using the Browser GPS Override, your phone batches location updates and sends them to the router every 4 seconds to prevent suffocating the web server with CGI requests. This introduces a slight spatial lag of ~40-50 meters if you are driving at high speeds, which is perfectly acceptable given standard WiFi ranges.
3. **WiGLE Handshakes**: The "Upload to WiGLE" button securely generates a CSV file with router MACs, SSIDs, and GPS coordinates and sends it to the WiGLE API. It **does not** upload your captured packets or `.hc2200` password hashes.

## ⚖️ Legal and Ethical Disclosure

**OpenWardRivingT** is an **active** auditing tool designed exclusively for educational purposes, authorized security testing, and academic research. 

- This software actively transmits deauthentication and probe frames, which can briefly disrupt connectivity on targeted wireless networks.
- You must **only** operate this tool against networks you own, or networks where you have explicit, documented consent from the owner to conduct penetration testing.
- The creators and contributors of this repository are not responsible for any misuse, illegal activity, or damage caused by this software. It is your sole responsibility to ensure you comply with all local, state, and federal laws regarding wireless communications and data interception before using this suite.

## 🤝 Contributing

1. File issues using `bd` (beads) — see [AGENTS.md](AGENTS.md)
2. Follow shell conventions in [CLAUDE.md](CLAUDE.md): BusyBox ash compatibility, no bashisms, `mktemp` for atomic writes
3. Test CGI endpoints with: `QUERY_STRING='action=status' sh /www/cgi-bin/wardriving_api` and sensitive endpoints with `QUERY_STRING='action=history&token=YOUR_TOKEN' sh /www/cgi-bin/wardriving_api`
4. Pull requests welcome against `main` branch

## 📄 License

OpenWardRivingT is licensed under the **GNU General Public License v3.0** (GPL-3.0).

See [LICENSE](LICENSE) for the full text.

---

*Built for the road. Drive safe. Hack responsibly.*
