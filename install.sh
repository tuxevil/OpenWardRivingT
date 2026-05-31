#!/bin/sh
# OpenWardRivingT Local Installer Script

echo "[*] Installing OpenWardRivingT..."

echo "[*] Updating package lists..."
opkg update

echo "[*] Installing required dependencies..."
opkg install hcxdumptool hcxtools socat block-mount kmod-fs-ext4 kmod-usb-storage e2fsprogs

echo "[*] Configuring USB Auto-Mount (fstab)..."
/etc/init.d/fstab enable
mkdir -p /mnt/wardriving

# Configure fstab to mount the first USB drive (usually /dev/sda1) to /mnt/wardriving
uci -q delete fstab.wardriving
uci set fstab.wardriving='mount'
uci set fstab.wardriving.target='/mnt/wardriving'
uci set fstab.wardriving.device='/dev/sda1'
uci set fstab.wardriving.fstype='ext4'
uci set fstab.wardriving.options='rw,async'
uci set fstab.wardriving.enabled='1'
uci set fstab.wardriving.enabled_fsck='1'
uci commit fstab

echo "[*] Copying files from repository to system..."
cp -r openwrt_files/* /
chmod +x /usr/bin/wardriving_core.sh
chmod +x /etc/init.d/wardriving
chmod +x /www/cgi-bin/wardriving_api

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
    uci set wireless.default_radio1.ssid='owrt'
    uci set wireless.default_radio1.encryption='psk2'
    uci set wireless.default_radio1.key='wardriving'
    uci set wireless.default_radio1.disabled='0'
    uci set wireless.radio1.disabled='0'
    uci commit wireless
fi

# Reload services
/etc/init.d/system reload
wifi up radio1 2>/dev/null
/etc/init.d/wardriving enable

echo "[*] Installation Complete!"
echo "[*] Connect your tablet/phone to the 5GHz network 'owrt' (password: wardriving)"
echo "[*] Go to http://192.168.1.1/wardriving/index.html (or your router's IP)"
