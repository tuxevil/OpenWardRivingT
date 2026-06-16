#!/bin/sh
# wardriving_sync.sh - Oportunistic Synchronization Script
# Checks if connected to a known home/lab network and syncs captures.

# set -e: bail out on unexpected failure. The script is run from cron every
# 5 minutes; an unhandled error here would otherwise silently keep retrying
# the same broken rsync/SSH call until the next config edit.

set -e

# ================= CONFIGURATION =================
# Config file: /etc/wardriving_sync.conf
# Format:
#   KNOWN_SSID="YourHomeWiFi"
#   SERVER_USER="root"
#   SERVER_IP="192.168.1.100"
#   SERVER_PORT="22"
#   SERVER_DEST="/opt/wardriving_sync/"
#
# If config file is missing or contains placeholders, sync is skipped.
# =================================================

CONF="/etc/wardriving_sync.conf"
if [ -f "$CONF" ]; then
    . "$CONF"
else
    logger -t "wardriving_sync" "No config at $CONF — sync disabled"
    exit 0
fi

# Validate: reject if still using placeholder values
if [ -z "$SERVER_IP" ] || [ "$SERVER_IP" = "192.168.1.100" ]; then
    logger -t "wardriving_sync" "Sync config has placeholder IP — sync disabled"
    exit 0
fi

# 1. Comprobar si estamos conectados a la red de casa (como cliente) o si alcanzamos el servidor
if ping -c 1 -W 2 "$SERVER_IP" > /dev/null 2>&1; then
    echo "[*] Home server reached. Starting sync..."
    
    # 2. Asegurarse de que el USB está montado
    if mount | grep -q "/mnt/wardriving"; then
        # 3. Sincronizar archivos al servidor usando rsync
        if rsync -avz -e "ssh -p $SERVER_PORT -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10" \
            /mnt/wardriving/*.hc2200 /mnt/wardriving/*.nmea /mnt/wardriving/master_essid.txt \
            "$SERVER_USER@$SERVER_IP:$SERVER_DEST"; then
            echo "[+] Sync successful!"
            # 4. Move synced files to archive (KEEP master.hc2200!)
            mkdir -p /mnt/wardriving/synced
            for f in /mnt/wardriving/wardriving_*.hc2200 /mnt/wardriving/wardriving_*.nmea; do
                [ -f "$f" ] && mv "$f" /mnt/wardriving/synced/ 2>/dev/null
            done
        else
            echo "[-] Sync failed. Will retry later."
        fi
    fi
else
    # Opcional: intentar encender el WiFi en modo cliente y conectarse si no lo está
    # (Requiere que uci tenga la configuración wpa_supplicant)
    # echo "No server connection."
    exit 0
fi
