#!/bin/sh
# wardriving_sync.sh - Oportunistic Synchronization Script
# Checks if connected to a known home/lab network and syncs captures.

# ================= CONFIGURATION =================
# Cambia estas variables por los datos de tu red / servidor
KNOWN_SSID="MiRedCasa"
SERVER_USER="root"
SERVER_IP="192.168.1.100"
SERVER_PORT="22"
SERVER_DEST="/opt/wardriving_sync/"
# =================================================

# 1. Comprobar si estamos conectados a la red de casa (como cliente) o si alcanzamos el servidor
if ping -c 1 -W 2 "$SERVER_IP" > /dev/null 2>&1; then
    echo "[*] Home server reached. Starting sync..."
    
    # 2. Asegurarse de que el USB está montado
    if mount | grep -q "/mnt/wardriving"; then
        # 3. Sincronizar archivos al servidor usando rsync
        rsync -avz -e "ssh -p $SERVER_PORT -o StrictHostKeyChecking=no" /mnt/wardriving/*.hc2200 /mnt/wardriving/*.nmea /mnt/wardriving/master_essid.txt "$SERVER_USER@$SERVER_IP:$SERVER_DEST"
        
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
