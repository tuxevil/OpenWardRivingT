#!/bin/sh
# wardriving_sync.sh - Oportunistic Synchronization Script
# Checks if connected to a known home/lab network and syncs captures.

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
        rsync -avz -e "ssh -p $SERVER_PORT -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10" /mnt/wardriving/*.hc2200 /mnt/wardriving/*.nmea /mnt/wardriving/master_essid.txt "$SERVER_USER@$SERVER_IP:$SERVER_DEST"
        
        if [ $? -eq 0 ]; then
            echo "[+] Sync successful!"
            # 4. Opcional: mover archivos sincronizados a una carpeta 'done' o borrarlos
            mkdir -p /mnt/wardriving/synced
            mv /mnt/wardriving/*.hc2200 /mnt/wardriving/synced/ 2>/dev/null
            mv /mnt/wardriving/*.nmea /mnt/wardriving/synced/ 2>/dev/null
            # Limpiamos el master.hc2200 también o lo dejamos como backup? Lo movemos a synced.
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
