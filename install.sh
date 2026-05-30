#!/bin/sh
# OpenWardRivingT Local Installer Script

echo "[*] Instalando OpenWardRivingT..."

# Copy files from repository to system
cp -r openwrt_files/* /
chmod +x /usr/bin/wardriving_core.sh
chmod +x /etc/init.d/wardriving
chmod +x /www/cgi-bin/wardriving_api

# Ensure symlink for capture files
mkdir -p /mnt/wardriving
rm -f /www/wardriving/captures
ln -s /mnt/wardriving /www/wardriving/captures

# Configure Hostname
echo "[*] Configurando Hostname..."
uci set system.@system[0].hostname='OpenWardRivingT'
uci commit system

# Configure 5GHz WiFi (Stealth / AP for UI)
if uci get wireless.radio1 >/dev/null 2>&1; then
    echo "[*] Configurando Radio de 5GHz para acceso al panel..."
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

echo "[*] ¡Instalación Completa!"
echo "[*] Conecta tu tablet/teléfono a la red 5GHz 'owrt' (pass: wardriving)"
echo "[*] Ingresa a http://192.168.1.1/wardriving/index.html (o la IP de tu router)"
