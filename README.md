# OpenWardRivingT 🛰️🚗

**OpenWardRivingT** is an automated, headless **active** wardriving suite built specifically for **OpenWrt** hardware (highly optimized for Atheros chipsets like Netgear WNDR3700, GL-A1300, etc.). It is designed to operate autonomously in your vehicle, actively targeting networks to capture PMKID and EAPOL handshakes while tracking network locations via GPS.

It features a spectacular **Tablet-Optimized Web Dashboard** (The "Batcave") meant to be used from your car's Android head unit or tablet. It includes real-time statistics, an offline map radar, a live spectrum analyzer, and a built-in capture manager.

## ✨ Key Features
- **100% Headless & Autonomous**: Start capturing by simply pressing a physical button (WPS/WiFi) on your router.
- **Vehicular Dashboard**: A beautiful Single Page Application (SPA) designed with huge icons and high contrast for drivers.
- **Live Spectrum Analyzer**: Visualize 2.4GHz channel congestion in real-time as you drive.
- **Offline/Online Maps**: See your route and pinpoint geolocated routers using Leaflet.js. Upload your own tile maps directly from the UI for 100% offline usage.
- **Visual Hardware Feedback**: Bind your router's LEDs to visually blink when actively sniffing handshakes.
- **Native GPS Integration**: Seamlessly injects NMEA data from your Android device directly into standard `.pcapng` files and draws your path.

## 🛠️ Hardware Requirements
1. **OpenWrt Router**: Preferably with dual radios (2.4GHz dedicated to monitor mode/injection, and 5GHz to host the stealth control panel).
2. **USB Flash Drive (MANDATORY)**: Formatted in `ext4` to store captures and offline map tiles. Must be mounted at `/mnt/wardriving/`.
   > **⚠️ Safety Mechanism**: The core script will refuse to start capturing if a USB drive is not detected. This is a deliberate safety measure to prevent permanent NAND wear (flash memory degradation) caused by continuous pcapng writes, and to protect the router from a system collapse due to reaching 100% internal storage capacity.
3. **Car Power Supply**: A 12V to 5V/12V step-down converter depending on your router's needs.
4. **Android Device (Optional but recommended)**: To share GPS NMEA data via TCP port 2947.

## 📦 Software Dependencies
Ensure the following packages are installed on your OpenWrt router:
- `hcxdumptool` (v6.3+)
- `hcxtools` (includes `hcxpcapngtool`)
- `socat`
- `uhttpd` (standard OpenWrt web server)

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
2. Open your NMEA GPS forwarder app on your Android tablet, pointing to the router's IP on port 2947.
3. Connect your tablet to the 5GHz WiFi network (`owrt`).
4. Navigate to `http://192.168.1.1/wardriving/index.html` (or your router's IP).
5. Hit **START** on the screen or press the configured physical router button. Start driving!

## 🗺️ Offline Map Management
In the "Settings" tab of the web application, you can upload a `.tar.gz` file containing a standard `Z/X/Y.png` tile folder (generated via tools like Mobile Atlas Creator). This gives you a rich street map on your dashboard without needing mobile data.


## ⚖️ Legal and Ethical Disclosure

**OpenWardRivingT** is an **active** auditing tool designed exclusively for educational purposes, authorized security testing, and academic research. 

- This software actively transmits deauthentication and probe frames, which can briefly disrupt connectivity on targeted wireless networks.
- You must **only** operate this tool against networks you own, or networks where you have explicit, documented consent from the owner to conduct penetration testing.
- The creators and contributors of this repository are not responsible for any misuse, illegal activity, or damage caused by this software. It is your sole responsibility to ensure you comply with all local, state, and federal laws regarding wireless communications and data interception before using this suite.
