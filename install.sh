#!/bin/sh
# OpenWardRivingT Local Installer Script

echo "[*] Installing OpenWardRivingT..."

echo "[*] Installing required dependencies..."
if command -v apk >/dev/null 2>&1; then
    echo "[*] Detected 'apk' package manager (OpenWrt 24.x+)"
    apk update
    apk add sqlite3-cli hcxdumptool hcxtools socat block-mount kmod-fs-ext4 kmod-usb-storage e2fsprogs rsync openssh-client openssh-sftp-server
elif command -v opkg >/dev/null 2>&1; then
    echo "[*] Detected 'opkg' package manager (OpenWrt 23.x or older)"
    opkg update
    opkg install sqlite3-cli hcxdumptool hcxtools socat block-mount kmod-fs-ext4 kmod-usb-storage e2fsprogs rsync openssh-client openssh-sftp-server
else
    echo "[-] ERROR: Neither apk nor opkg package manager found!"
    exit 1
fi

echo "[*] Configuring USB Auto-Mount (fstab)..."
/etc/init.d/fstab enable
mkdir -p /mnt/wardriving

# Auto-detect first USB block device
USB_DEV=""
for dev in $(block info 2>/dev/null | grep -o '/dev/sd[a-z][0-9]*' | sort -u); do
    if [ -b "$dev" ]; then
        USB_DEV="$dev"
        break
    fi
done

# Fallback to /dev/sda1 if detection fails (most common)
[ -z "$USB_DEV" ] && USB_DEV="/dev/sda1"
echo "[*] Using USB device: $USB_DEV"

# Configure fstab to mount the USB drive to /mnt/wardriving
uci -q delete fstab.wardriving
uci set fstab.wardriving='mount'
uci set fstab.wardriving.target='/mnt/wardriving'
uci set fstab.wardriving.device="$USB_DEV"
uci set fstab.wardriving.fstype='ext4'
uci set fstab.wardriving.options='rw,async'
uci set fstab.wardriving.enabled='1'
uci set fstab.wardriving.enabled_fsck='1'
uci commit fstab

# Generate API auth token for dashboard security
echo "[*] Generating API token..."
API_TOKEN=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32)
echo "$API_TOKEN" > /etc/wardriving_api_token
chmod 600 /etc/wardriving_api_token

echo "[*] Backing up existing files and deploying..."
BACKUP_DIR="/root/openwardrivingt_backup_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$BACKUP_DIR"

# Backup and deploy: copy per-directory with safety checks
for dir in usr www etc; do
    if [ -d "openwrt_files/$dir" ]; then
        find "openwrt_files/$dir" -type f 2>/dev/null | while read -r src; do
            dst="/${src#openwrt_files/}"
            # Backup existing file if present
            [ -f "$dst" ] && cp -f "$dst" "$BACKUP_DIR/" 2>/dev/null
            # Create parent dirs and copy
            mkdir -p "$(dirname "$dst")"
            cp -f "$src" "$dst"
        done
    fi
done
# Also copy any root-level files from openwrt_files (if present in future)
find openwrt_files -maxdepth 1 -type f 2>/dev/null | while read -r src; do
    dst="/${src#openwrt_files/}"
    [ -f "$src" ] && cp -f "$src" "$dst"
done
chmod +x /usr/bin/wardriving_core.sh
chmod +x /usr/bin/wardriving_sync.sh
chmod +x /etc/init.d/wardriving
chmod +x /www/cgi-bin/wardriving_api

# Inject API token into dashboard (for authenticated API calls)
if [ -f /www/wardriving/index.html ] && [ -n "$API_TOKEN" ]; then
    sed -i "s|^\([[:space:]]*\)// API_TOKEN_PLACEHOLDER[[:space:]]*$|\1window.API_TOKEN = '$API_TOKEN';|" /www/wardriving/index.html
fi

# Ensure symlink for capture files
mkdir -p /mnt/wardriving
rm -f /www/wardriving/captures
ln -s /mnt/wardriving /www/wardriving/captures

# Configure Hostname
echo "[*] Configuring Hostname..."
uci set system.@system[0].hostname='OpenWardRivingT'
uci commit system

# Configure 5GHz WiFi (Stealth / AP for UI)
if uci get wireless.radio1 >/dev/null 2>&1; then
    echo "[*] Configuring 5GHz Radio for Control Panel access..."
    WIFI_PASS=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 12)
    [ -z "$WIFI_PASS" ] && WIFI_PASS="wardriving" # fallback
    
    uci set wireless.default_radio1.ssid='OpenWardRivingT'
    uci set wireless.default_radio1.encryption='psk2'
    uci set wireless.default_radio1.key="$WIFI_PASS"
    uci set wireless.default_radio1.disabled='0'
    uci set wireless.radio1.disabled='0'
    uci commit wireless
    echo "[!] IMPORTANT: The new WiFi Password for 'OpenWardRivingT' is: $WIFI_PASS"
    echo "$WIFI_PASS" > /root/wardriving_wifi_pass.txt
fi

# Configurar cron para sincronizacion oportunista
sed -i '/wardriving_sync.sh/d' /etc/crontabs/root 2>/dev/null
echo "*/5 * * * * /usr/bin/wardriving_sync.sh" >> /etc/crontabs/root
/etc/init.d/cron enable

# Reload services
/etc/init.d/system reload
wifi up radio1 2>/dev/null
/etc/init.d/wardriving enable

echo "[*] Installation Complete!"
echo "[*] Connect your tablet/phone to the 5GHz network (Check /root/wardriving_wifi_pass.txt for password)"
echo "[*] Go to http://192.168.1.1/wardriving/index.html (or your router's IP)"
