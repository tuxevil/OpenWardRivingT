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

echo "[*] Reverting Network Config..."
uci delete wireless.default_radio1 2>/dev/null
uci commit wireless 2>/dev/null
wifi reload 2>/dev/null

echo "[*] Uninstallation Complete."
