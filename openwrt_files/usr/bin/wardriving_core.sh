#!/bin/sh

# ===== SIGNAL TRAP FOR CLEAN SHUTDOWN =====
cleanup() {
    echo "[!] Caught signal - cleaning up..."
    jobs -p | while read -r pid; do
        [ -n "$pid" ] && kill -15 "$pid" 2>/dev/null
    done
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
        _current=$(cat "/sys/class/leds/$_LED/brightness")
        echo 0 > "/sys/class/leds/$_LED/brightness"
        usleep 100000 2>/dev/null || sleep 1
        echo 255 > "/sys/class/leds/$_LED/brightness" 2>/dev/null || echo 1 > "/sys/class/leds/$_LED/brightness"
        usleep 100000 2>/dev/null || sleep 1
        echo "$_current" > "/sys/class/leds/$_LED/brightness"
    fi
}

write_remote_status() {
    _state="$1"
    _code="$2"
    _msg="$3"
    _ts=$(date +%s)
    {
        echo "state=$_state"
        echo "code=$_code"
        echo "message=$_msg"
        echo "updated=$_ts"
    } > /tmp/wardriving_remote_status
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
        REMOTE_SECRET=""
        [ -f /etc/wardriving_remote_secret ] && REMOTE_SECRET=$(cat /etc/wardriving_remote_secret)
        [ -z "$REMOTE_SECRET" ] && [ -f /etc/wardriving_api_token ] && REMOTE_SECRET=$(cat /etc/wardriving_api_token)
        
        PROCESSED_REMOTE=0
        if [ "$REMOTE_ENABLED" = "1" ] && [ -n "$REMOTE_URL" ]; then
            echo "[*] Sending $FILENAME to remote server ($REMOTE_URL) ..."
            write_remote_status "uploading" "0" "sending capture"
            AUTH_HEADER=""
            [ -n "$REMOTE_SECRET" ] && AUTH_HEADER="X-OWRT-Token: $REMOTE_SECRET"
            if [ -n "$AUTH_HEADER" ]; then
                HTTP_CODE=$(curl -s -o "/tmp/respuesta_server.jsonl" -w "%{http_code}" -X POST -H "X-OWRT-Contract: jsonl" -H "$AUTH_HEADER" -F "pcap=@$FILENAME" "$REMOTE_URL" --connect-timeout 10)
            else
                HTTP_CODE=$(curl -s -o "/tmp/respuesta_server.jsonl" -w "%{http_code}" -X POST -H "X-OWRT-Contract: jsonl" -F "pcap=@$FILENAME" "$REMOTE_URL" --connect-timeout 10)
            fi
            if [ "$HTTP_CODE" = "200" ]; then
                echo "[+] Remote server processed capture successfully."
                write_remote_status "ok" "$HTTP_CODE" "remote processed"
                PROCESSED_REMOTE=1
                
                if [ -s "/tmp/respuesta_server.jsonl" ] && grep -q '"mac"' /tmp/respuesta_server.jsonl 2>/dev/null; then
                    sqlite3 /mnt/wardriving/wardriving.db "CREATE TABLE IF NOT EXISTS networks (mac TEXT PRIMARY KEY, ssid TEXT, enc TEXT, channel INTEGER, lat REAL, lon REAL, first_seen DATETIME, last_seen DATETIME, rssi INTEGER);"
                    sqlite3 /mnt/wardriving/wardriving.db "PRAGMA journal_mode=WAL; CREATE INDEX IF NOT EXISTS idx_last_seen ON networks(last_seen);" > /dev/null 2>&1
                    while IFS= read -r line; do
                        MAC=$(echo "$line" | sed -n 's/.*"mac":"\([^"]*\)".*/\1/p' | tr -cd 'a-fA-F0-9:')
                        SSID_B64=$(echo "$line" | sed -n 's/.*"ssid_b64":"\([^"]*\)".*/\1/p' | tr -cd 'A-Za-z0-9+/=')
                        ENC=$(echo "$line" | sed -n 's/.*"enc":"\([^"]*\)".*/\1/p' | sed "s/'/''/g" | tr -cd '[:print:]')
                        CHAN=$(echo "$line" | sed -n 's/.*"channel":\([-0-9]*\).*/\1/p' | tr -cd '0-9-')
                        LAT=$(echo "$line" | sed -n 's/.*"lat":\([^,}]*\).*/\1/p' | tr -cd '0-9.-')
                        LON=$(echo "$line" | sed -n 's/.*"lon":\([^,}]*\).*/\1/p' | tr -cd '0-9.-')
                        RSSI=$(echo "$line" | sed -n 's/.*"rssi":\([-0-9]*\).*/\1/p' | tr -cd '0-9-')
                        case "$MAC" in
                            [0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]) ;;
                            *) continue ;;
                        esac
                        [ -z "$CHAN" ] && CHAN=0
                        [ -z "$RSSI" ] && RSSI=0
                        [ -z "$LAT" ] && LAT="NULL"
                        [ -z "$LON" ] && LON="NULL"
                        SSID=$(printf "%s" "$SSID_B64" | base64 -d 2>/dev/null | sed "s/'/''/g" | tr -cd '[:print:]')
                        [ -z "$SSID" ] && continue
                        [ "$RSSI" -gt 0 ] 2>/dev/null && continue
                        sqlite3 /mnt/wardriving/wardriving.db "INSERT INTO networks (mac, ssid, enc, channel, lat, lon, first_seen, last_seen, rssi) VALUES ('$MAC', '$SSID', '$ENC', $CHAN, $LAT, $LON, datetime('now'), datetime('now'), $RSSI) ON CONFLICT(mac) DO UPDATE SET ssid=EXCLUDED.ssid, enc=EXCLUDED.enc, channel=EXCLUDED.channel, lat=EXCLUDED.lat, lon=EXCLUDED.lon, last_seen=EXCLUDED.last_seen, rssi=EXCLUDED.rssi;"
                    done < /tmp/respuesta_server.jsonl
                fi
                /usr/bin/wardriving_clients.sh "$FILENAME" "/tmp/client_csv_${TIMESTAMP}.txt" /mnt/wardriving/wardriving.db 2>/dev/null || true
                rm -f "/tmp/client_csv_${TIMESTAMP}.txt"
                rm -f "/tmp/respuesta_server.jsonl"
                rm -f "$FILENAME" "$NMEAFILE"
                # Sync offline hashes si existen
                if [ -s "/mnt/wardriving/master.hc2200" ]; then
                    SYNC_URL=$(echo "$REMOTE_URL" | sed 's|/upload|/upload_hc2200|')
                    echo "[*] Syncing offline hashes to $SYNC_URL ..."
                    if [ -n "$AUTH_HEADER" ]; then
                        SYNC_HTTP=$(curl -s -o /dev/null -w "%{http_code}" -X POST -H "$AUTH_HEADER" -F "hc2200=@/mnt/wardriving/master.hc2200" "$SYNC_URL" --connect-timeout 10)
                    else
                        SYNC_HTTP=$(curl -s -o /dev/null -w "%{http_code}" -X POST -F "hc2200=@/mnt/wardriving/master.hc2200" "$SYNC_URL" --connect-timeout 10)
                    fi
                    if [ "$SYNC_HTTP" = "200" ]; then
                        echo "[+] Offline hashes synced successfully."
                        write_remote_status "synced" "$SYNC_HTTP" "hashes synced"
                        rm -f "/mnt/wardriving/master.hc2200"
                    else
                        echo "[-] Failed to sync offline hashes (Code: $SYNC_HTTP). Will retry later."
                        write_remote_status "sync_error" "$SYNC_HTTP" "hash sync failed"
                    fi
                fi
            else
                echo "[-] Remote server failed (Code: $HTTP_CODE). Falling back to local processing..."
                write_remote_status "fallback" "$HTTP_CODE" "using local processing"
            fi
        elif [ "$REMOTE_ENABLED" = "1" ]; then
            write_remote_status "unconfigured" "0" "missing remote url"
        else
            write_remote_status "local" "0" "remote disabled"
        fi

        if [ "$PROCESSED_REMOTE" = "0" ]; then
            echo "[*] Converting $FILENAME to $HC2200FILE"
            nice -n 10 hcxpcapngtool -o "$HC2200FILE" -E "$TMP_ESSID" --csv="/tmp/csv_${TIMESTAMP}.txt" "$FILENAME" > /dev/null 2>&1
            /usr/bin/wardriving_clients.sh "$FILENAME" "/tmp/csv_${TIMESTAMP}.txt" /mnt/wardriving/wardriving.db 2>/dev/null || true
            
            # SQLite Integration
            if command -v sqlite3 >/dev/null 2>&1 && [ -s "/tmp/csv_${TIMESTAMP}.txt" ]; then
                sqlite3 /mnt/wardriving/wardriving.db "CREATE TABLE IF NOT EXISTS networks (mac TEXT PRIMARY KEY, ssid TEXT, enc TEXT, channel INTEGER, lat REAL, lon REAL, first_seen DATETIME, last_seen DATETIME, rssi INTEGER);"
                sqlite3 /mnt/wardriving/wardriving.db "PRAGMA journal_mode=WAL; CREATE INDEX IF NOT EXISTS idx_last_seen ON networks(last_seen);" > /dev/null 2>&1
                
                awk -F'\t' '{
                    mac=$2; ssid=$3; enc=$4; chan=$8; rssi=$9; gpsd=$11
                    if (mac !~ /^[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]$/) next
                    if (ssid == "" || rssi > 0) next
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
            rm -f "$FILENAME" "$NMEAFILE"
                # Sync offline hashes si existen
                if [ "$REMOTE_ENABLED" = "1" ] && [ -n "$REMOTE_URL" ] && [ -s "/mnt/wardriving/master.hc2200" ]; then
                    SYNC_URL=$(echo "$REMOTE_URL" | sed 's|/upload|/upload_hc2200|')
                    echo "[*] Syncing offline hashes to $SYNC_URL ..."
                    if [ -n "$AUTH_HEADER" ]; then
                        SYNC_HTTP=$(curl -s -o /dev/null -w "%{http_code}" -X POST -H "$AUTH_HEADER" -F "hc2200=@/mnt/wardriving/master.hc2200" "$SYNC_URL" --connect-timeout 10)
                    else
                        SYNC_HTTP=$(curl -s -o /dev/null -w "%{http_code}" -X POST -F "hc2200=@/mnt/wardriving/master.hc2200" "$SYNC_URL" --connect-timeout 10)
                    fi
                    if [ "$SYNC_HTTP" = "200" ]; then
                        echo "[+] Offline hashes synced successfully."
                        rm -f "/mnt/wardriving/master.hc2200"
                    else
                        echo "[-] Failed to sync offline hashes (Code: $SYNC_HTTP). Will retry later."
                    fi
                fi
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
