#!/bin/sh
echo "[*] Uninstalling OpenWardRivingT..."

/etc/init.d/wardriving stop 2>/dev/null
/etc/init.d/wardriving disable 2>/dev/null

sed -i '/wardriving_sync.sh/d' /etc/crontabs/root 2>/dev/null

rm -f /etc/init.d/wardriving
rm -f /usr/bin/wardriving_core.sh
rm -f /usr/bin/wardriving_sync.sh
rm -rf /www/wardriving
rm -f /www/cgi-bin/wardriving_api

# Clean configuration files
rm -f /etc/wardriving_mode.txt
rm -f /etc/wardriving_targets.txt
rm -f /etc/wardriving_excluded.txt
rm -f /etc/wardriving_removed.txt
rm -f /etc/wardriving_keep_pcap.txt
rm -f /etc/wardriving_wigle_token
rm -f /etc/wardriving_sync.conf 2>/dev/null

# Clean symlinks
rm -f /www/wardriving/captures 2>/dev/null

echo "[*] Reverting Network Config..."
uci delete wireless.default_radio1 2>/dev/null
uci commit wireless 2>/dev/null
wifi reload 2>/dev/null

echo "[*] Uninstallation Complete."
echo "[!] Note: Your capture data on /mnt/wardriving/ has NOT been removed."
echo "[!] To fully clean: rm -rf /mnt/wardriving/"
