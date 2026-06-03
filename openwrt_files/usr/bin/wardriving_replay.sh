#!/bin/sh
# wardriving_replay.sh - Visual-first WiGLE route replay.

set -u

WARD_MNT="${WARDRIVING_MNT:-/mnt/wardriving}"
CSV_FILE="${1:-}"
DELAY_MS="${2:-500}"
RADIUS_M="${3:-75}"
CLEAN_BEFORE="${4:-0}"
START_INDEX="${5:-0}"

STATE="/tmp/wardriving_replay_status.json"
REPORT="/tmp/wardriving_replay_report.json"
LOG="/tmp/wardriving_replay.log"
PIDFILE="/tmp/wardriving_replay.pid"
QUEUE_PIDFILE="/tmp/wardriving_replay_queue.pid"
STOPFILE="/tmp/wardriving_replay.stop"
PAUSEFILE="/tmp/wardriving_replay.pause"
SEEKFILE="/tmp/wardriving_replay.seek"
VISUAL_DONE="/tmp/wardriving_replay.visual_done"
WORK="/tmp/wardriving_replay_work"
EVENTS="$WORK/events.log"
CAP_INDEX="$WORK/captures.tsv"
ROWS="$WORK/wigle.tsv"
SENT_CAPS="$WORK/sent_captures.txt"
QUEUE="$WORK/capture_queue.txt"
DONE_QUEUE="$WORK/capture_done.txt"
LAST_MACS="$WORK/last_macs.txt"
LAST_NEAR="$WORK/nearby.json"
DISCOVERED="$WORK/discovered.tsv"
MAC_DIR="$WORK/mac"

json_escape() {
    sed 's/\\/\\\\/g; s/"/\\"/g; s/	/ /g; s/[^[:print:]]//g'
}

now_epoch() {
    date +%s
}

line_count() {
    _file="$1"
    if [ -f "$_file" ]; then
        wc -l < "$_file" 2>/dev/null || echo 0
    else
        echo 0
    fi
}

delay_sleep() {
    _ms="$1"
    if [ "$_ms" -le 0 ] 2>/dev/null; then
        return
    fi
    _sec=$(awk -v ms="$_ms" 'BEGIN{printf "%.3f", ms/1000}')
    sleep "$_sec" 2>/dev/null || sleep 1
}

read_cracks() {
    line_count "$WARD_MNT/hashcat.potfile"
}

write_state() {
    _state="$1"
    _idx="$2"
    _total="$3"
    _lat="$4"
    _lon="$5"
    _speed="$6"
    _near="$7"
    _matches="$8"
    _sent="$9"
    _rows="${10}"
    _cracks="${11}"
    _gpu="${12}"
    _tx="${13}"
    _event="${14}"
    _started="${15}"
    _paused="${16}"
    _processing_index="${17}"
    _updated=$(now_epoch)
    _safe_event=$(printf "%s" "$_event" | json_escape)
    _pending=$(line_count "$QUEUE")
    _done=$(line_count "$DONE_QUEUE")
    _near_json="[]"
    [ -s "$LAST_NEAR" ] && _near_json=$(cat "$LAST_NEAR")
    cat > "$STATE" <<JSON
{"state":"$_state","paused":$_paused,"pid":$$,"index":$_idx,"visual_index":$_idx,"processing_index":$_processing_index,"total":$_total,"lat":$_lat,"lon":$_lon,"speed_kmh":$_speed,"nearby":$_near,"matches":$_matches,"sent":$_sent,"rows":$_rows,"cracks":$_cracks,"gpu":"$_gpu","tx":"$_tx","event":"$_safe_event","started":$_started,"updated":$_updated,"queue_pending":$_pending,"queue_done":$_done,"effective_delay_ms":$DELAY_MS,"nearby_networks":$_near_json}
JSON
}

append_event() {
    _kind="$1"
    _message="$2"
    _ts=$(now_epoch)
    _safe=$(printf "%s" "$_message" | json_escape)
    printf '{"ts":%s,"kind":"%s","message":"%s"}\n' "$_ts" "$_kind" "$_safe" >> "$EVENTS"
    echo "[$_kind] $_message" >> "$LOG"
}

backup_and_clean() {
    _stamp=$(date +%Y%m%d_%H%M%S)
    _backup="$WARD_MNT/e2e_backups/$_stamp"
    mkdir -p "$_backup"
    cp -f "$WARD_MNT/wardriving.db" "$_backup/" 2>/dev/null || true
    cp -f "$WARD_MNT/master.hc2200" "$_backup/" 2>/dev/null || true
    cp -f "$WARD_MNT/hashcat.potfile" "$_backup/" 2>/dev/null || true
    cp -f /tmp/wardriving_remote_status "$_backup/" 2>/dev/null || true
    cp -f "$STATE" "$_backup/" 2>/dev/null || true
    rm -f "$WARD_MNT/master.hc2200" /tmp/wardriving_remote_status
    if command -v sqlite3 >/dev/null 2>&1; then
        sqlite3 "$WARD_MNT/wardriving.db" "DROP TABLE IF EXISTS networks; CREATE TABLE networks (mac TEXT PRIMARY KEY, ssid TEXT, enc TEXT, channel INTEGER, lat REAL, lon REAL, first_seen DATETIME, last_seen DATETIME, rssi INTEGER);" 2>/dev/null || true
    fi
    append_event "backup" "clean_before enabled; state backed up to $_backup"
}

decimal_to_nmea() {
    _lat="$1"
    _lon="$2"
    _speed="$3"
    _date="$4"
    _time="$5"
    awk -v lat="$_lat" -v lon="$_lon" -v sp="$_speed" -v d="$_date" -v t="$_time" '
    function abs(v){return v<0?-v:v}
    function nmea(v,islat, deg,min,dir) {
        dir = v < 0 ? (islat ? "S" : "W") : (islat ? "N" : "E")
        v = abs(v)
        deg = int(v)
        min = (v - deg) * 60
        return sprintf(islat ? "%02d%08.5f,%s" : "%03d%08.5f,%s", deg, min, dir)
    }
    BEGIN {
        gsub(/[-:]/, "", d); gsub(/[:]/, "", t)
        if (length(d) >= 8) d = substr(d,7,2) substr(d,5,2) substr(d,3,2); else d = "010100"
        if (length(t) >= 6) t = substr(t,1,2) substr(t,3,2) substr(t,5,2) ".00"; else t = "000000.00"
        rmc = "GPRMC," t ",A," nmea(lat,1) "," nmea(lon,0) "," sprintf("%.1f", sp/1.852) ",0.0," d ",,,A"
        gga = "GPGGA," t "," nmea(lat,1) "," nmea(lon,0) ",1,08,1.0,0.0,M,0.0,M,,"
        print "$" rmc "*00"
        print "$" gga "*00"
    }'
}

build_capture_index() {
    : > "$CAP_INDEX"
    rm -rf "$MAC_DIR"
    mkdir -p "$MAC_DIR"
    find "$WARD_MNT" "$WARD_MNT/backup_old_captures" -maxdepth 1 -type f -name '*.pcapng' 2>/dev/null | while IFS= read -r cap; do
        tmp="$WORK/$(basename "$cap").csv"
        if [ ! -s "$tmp" ] || [ "$(date -r "$cap" +%s 2>/dev/null || echo 0)" -gt "$(date -r "$tmp" +%s 2>/dev/null || echo 0)" ]; then
            hcxpcapngtool --csv "$tmp" "$cap" >/dev/null 2>&1 || true
        fi
        [ -s "$tmp" ] || continue
        awk -F'\t' -v cap="$cap" '
        {
            mac=tolower($3); ssid=$4; chan=$9; rssi=$10; lat=$15; lon=$16
            if ($12 == "S" && lat > 0) lat = -lat
            if ($14 == "W" && lon > 0) lon = -lon
            if (mac !~ /^[0-9a-f][0-9a-f](:[0-9a-f][0-9a-f]){5}$/) mac=tolower($2)
            if (mac !~ /^[0-9a-f][0-9a-f](:[0-9a-f][0-9a-f]){5}$/) next
            if (lat == "" || lon == "" || lat == 0 || lon == 0) next
            gsub(/\t/, " ", ssid)
            printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n", mac, ssid, chan, rssi, lat, lon, cap
        }' "$tmp" >> "$CAP_INDEX"
    done
    sort -u "$CAP_INDEX" -o "$CAP_INDEX" 2>/dev/null || true
    awk -F'\t' -v dir="$MAC_DIR" '{
        m=$1; gsub(/:/, "", m);
        if (!(m in seen)) {
            print $7 > (dir "/" m)
            seen[m]=1
        }
    }' "$CAP_INDEX"
}

parse_wigle_csv() {
    awk -F',' '
    function clean(v){gsub(/^"|"$/, "", v); gsub(/\r/, "", v); return v}
    BEGIN{header=0}
    /^MAC,/ {
        for (i=1; i<=NF; i++) {
            h=clean($i)
            idx[h]=i
        }
        header=1
        next
    }
    header && NF >= 9 {
        mac=tolower(clean($idx["MAC"]))
        ssid=clean($idx["SSID"])
        ts=clean($idx["FirstSeen"])
        chan=clean($idx["Channel"])
        rssi=clean($idx["RSSI"])
        lat=clean($idx["CurrentLatitude"])
        lon=clean($idx["CurrentLongitude"])
        if (mac ~ /^[0-9a-f][0-9a-f](:[0-9a-f][0-9a-f]){5}$/ && lat != "" && lon != "") {
            gsub(/\t/, " ", ssid)
            printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n", ts, mac, ssid, chan, rssi, lat, lon
        }
    }' "$CSV_FILE" | sort > "$ROWS"
}

write_nearby_json() {
    _lat="$1"
    _lon="$2"
    _mac="$3"
    _ssid="$4"
    _rssi="$5"
    awk -F'\t' -v lat="$_lat" -v lon="$_lon" -v r="$RADIUS_M" -v curmac="$_mac" -v curssid="$_ssid" -v currssi="$_rssi" '
    function esc(s){gsub(/\\/,"\\\\",s); gsub(/"/,"\\\"",s); return s}
    function dist(a,b,c,d, x,y){x=(a-c)*111320; y=(b-d)*111320; return sqrt(x*x+y*y)}
    BEGIN {
        printf "["
        if (curmac != "" && lat != "" && lon != "") {
            printf "{\"mac\":\"%s\",\"ssid\":\"%s\",\"ssids\":\"%s\",\"lat\":%s,\"lon\":%s,\"rssi\":%s,\"count\":1,\"has_handshake\":false,\"is_cracked\":false}", curmac, esc(curssid), esc(curssid), lat, lon, (currssi==""?0:currssi)
            n=1
        }
    }
    $5 != "" && $6 != "" && dist(lat,lon,$5,$6) <= r && n < 12 {
        if (n) printf ","
        printf "{\"mac\":\"%s\",\"ssid\":\"%s\",\"ssids\":\"%s\",\"lat\":%s,\"lon\":%s,\"rssi\":%s,\"count\":1,\"has_handshake\":true,\"is_cracked\":false}", $1, esc($2), esc($2), $5, $6, ($4==""?0:$4)
        n++
    }
    END {printf "]"}' "$CAP_INDEX" > "$LAST_NEAR"
}

record_discovered() {
    _mac="$1"
    _ssid="$2"
    _lat="$3"
    _lon="$4"
    _rssi="$5"
    _hs="$6"
    [ -z "$_mac" ] && return
    [ -z "$_lat" ] && return
    [ -z "$_lon" ] && return
    _safe_ssid=$(printf "%s" "$_ssid" | sed 's/	/ /g; s/[^[:print:]]//g')
    if grep -q "^$_mac	" "$DISCOVERED" 2>/dev/null; then
        if [ "$_hs" = "1" ]; then
            awk -F'\t' -v OFS='\t' -v mac="$_mac" '$1==mac {$6=1} {print}' "$DISCOVERED" > "$WORK/discovered.tmp" && mv "$WORK/discovered.tmp" "$DISCOVERED"
        fi
    else
        printf "%s\t%s\t%s\t%s\t%s\t%s\n" "$_mac" "$_safe_ssid" "$_lat" "$_lon" "${_rssi:-0}" "$_hs" >> "$DISCOVERED"
    fi
}

insert_jsonl_rows() {
    _jsonl="$1"
    [ -s "$_jsonl" ] || return 0
    command -v sqlite3 >/dev/null 2>&1 || return 0
    sqlite3 "$WARD_MNT/wardriving.db" "CREATE TABLE IF NOT EXISTS networks (mac TEXT PRIMARY KEY, ssid TEXT, enc TEXT, channel INTEGER, lat REAL, lon REAL, first_seen DATETIME, last_seen DATETIME, rssi INTEGER);"
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
        sqlite3 "$WARD_MNT/wardriving.db" "INSERT INTO networks (mac, ssid, enc, channel, lat, lon, first_seen, last_seen, rssi) VALUES ('$MAC', '$SSID', '$ENC', $CHAN, $LAT, $LON, datetime('now'), datetime('now'), $RSSI) ON CONFLICT(mac) DO UPDATE SET ssid=EXCLUDED.ssid, enc=EXCLUDED.enc, channel=EXCLUDED.channel, lat=EXCLUDED.lat, lon=EXCLUDED.lon, last_seen=EXCLUDED.last_seen, rssi=EXCLUDED.rssi;" 2>/dev/null || true
    done < "$_jsonl"
}

process_queue() {
    REMOTE_ENABLED="0"
    [ -f /etc/wardriving_remote_enabled ] && REMOTE_ENABLED=$(cat /etc/wardriving_remote_enabled)
    REMOTE_URL=""
    [ -f /etc/wardriving_remote_url ] && REMOTE_URL=$(cat /etc/wardriving_remote_url)
    REMOTE_SECRET=""
    [ -f /etc/wardriving_remote_secret ] && REMOTE_SECRET=$(cat /etc/wardriving_remote_secret)
    [ -z "$REMOTE_SECRET" ] && [ -f /etc/wardriving_api_token ] && REMOTE_SECRET=$(cat /etc/wardriving_api_token)
    while [ ! -f "$STOPFILE" ]; do
        CAP=$(awk 'NF{print; exit}' "$QUEUE" 2>/dev/null)
        if [ -z "$CAP" ]; then
            [ -f "$VISUAL_DONE" ] && exit 0
            sleep 1
            continue
        fi
        awk -v cap="$CAP" '$0!=cap' "$QUEUE" > "$WORK/queue.tmp" 2>/dev/null && mv "$WORK/queue.tmp" "$QUEUE"
        [ -f "$CAP" ] || continue
        grep -Fxq "$CAP" "$DONE_QUEUE" 2>/dev/null && continue
        append_event "gpu" "processing $(basename "$CAP")"
        if [ "$REMOTE_ENABLED" = "1" ] && [ -n "$REMOTE_URL" ]; then
            RESP="$WORK/response_$(date +%s)_$$.jsonl"
            AUTH_HEADER=""
            [ -n "$REMOTE_SECRET" ] && AUTH_HEADER="X-OWRT-Token: $REMOTE_SECRET"
            if [ -n "$AUTH_HEADER" ]; then
                HTTP=$(curl -s -o "$RESP" -w "%{http_code}" -X POST -H "X-OWRT-Contract: jsonl" -H "$AUTH_HEADER" -F "pcap=@$CAP" "$REMOTE_URL" --connect-timeout 10)
            else
                HTTP=$(curl -s -o "$RESP" -w "%{http_code}" -X POST -H "X-OWRT-Contract: jsonl" -F "pcap=@$CAP" "$REMOTE_URL" --connect-timeout 10)
            fi
            if [ "$HTTP" = "200" ]; then
                ADDED=$(grep -c '"mac"' "$RESP" 2>/dev/null || echo 0)
                insert_jsonl_rows "$RESP"
                echo "$CAP" >> "$DONE_QUEUE"
                append_event "gpu" "GPU processed $(basename "$CAP") and returned $ADDED rows"
            else
                append_event "error" "GPU upload failed for $(basename "$CAP") with HTTP $HTTP"
            fi
        else
            append_event "gpu" "remote GPU disabled; queued capture skipped"
            echo "$CAP" >> "$DONE_QUEUE"
        fi
    done
}

cleanup() {
    rm -f "$PIDFILE"
}
trap cleanup EXIT INT TERM

mkdir -p "$WORK" "$MAC_DIR"
rm -f "$STOPFILE" "$VISUAL_DONE"
touch "$QUEUE" "$DONE_QUEUE" "$SENT_CAPS"
touch "$DISCOVERED"
: > "$LAST_MACS"
echo "$$" > "$PIDFILE"
STARTED=$(now_epoch)
write_state "preparing" "$START_INDEX" 0 0 0 0 0 0 "$(line_count "$SENT_CAPS")" 0 0 "WAIT" "IDLE" "preparing replay" "$STARTED" "false" "$(line_count "$DONE_QUEUE")"

if [ -z "$CSV_FILE" ] || [ ! -s "$CSV_FILE" ]; then
    write_state "error" 0 0 0 0 0 0 0 0 0 0 "ERR" "IDLE" "missing CSV" "$STARTED" "false" 0
    exit 1
fi

if [ "$CLEAN_BEFORE" = "1" ]; then
    backup_and_clean
    : > "$QUEUE"
    : > "$DONE_QUEUE"
    : > "$SENT_CAPS"
fi

if [ ! -s "$CAP_INDEX" ]; then
    append_event "index" "indexing router captures"
    write_state "indexing" "$START_INDEX" 0 0 0 0 0 0 "$(line_count "$SENT_CAPS")" 0 0 "WAIT" "SCAN" "indexing router captures" "$STARTED" "false" "$(line_count "$DONE_QUEUE")"
    build_capture_index
fi

if [ ! -s "$ROWS" ] || [ "$(date -r "$CSV_FILE" +%s 2>/dev/null || echo 0)" -gt "$(date -r "$ROWS" +%s 2>/dev/null || echo 0)" ]; then
    parse_wigle_csv
fi

TOTAL=$(line_count "$ROWS")
if [ "$TOTAL" -eq 0 ] 2>/dev/null; then
    write_state "error" 0 0 0 0 0 0 0 0 0 0 "ERR" "IDLE" "CSV has no usable WiGLE rows" "$STARTED" "false" 0
    exit 1
fi

process_queue &
echo "$!" > "$QUEUE_PIDFILE"

append_event "start" "visual replay started with $TOTAL WiGLE points"
IDX=0
LAST_LAT=0
LAST_LON=0
CRACKS_START=$(read_cracks)

while IFS='	' read -r TS MAC SSID CHAN RSSI LAT LON; do
    IDX=$((IDX + 1))
    [ "$IDX" -le "$START_INDEX" ] && continue

    while [ -f "$PAUSEFILE" ] && [ ! -f "$STOPFILE" ]; do
        write_state "paused" "$IDX" "$TOTAL" "$LAST_LAT" "$LAST_LON" 0 0 "$(line_count "$SENT_CAPS")" "$(line_count "$SENT_CAPS")" 0 "$(( $(read_cracks) - CRACKS_START ))" "PAUSED" "IDLE" "paused at point $IDX" "$STARTED" "true" "$(line_count "$DONE_QUEUE")"
        sleep 1
    done

    if [ -f "$STOPFILE" ]; then
        append_event "stop" "replay stopped by user"
        write_state "stopped" "$IDX" "$TOTAL" "$LAST_LAT" "$LAST_LON" 0 0 "$(line_count "$SENT_CAPS")" "$(line_count "$SENT_CAPS")" 0 "$(( $(read_cracks) - CRACKS_START ))" "STOP" "IDLE" "stopped by user" "$STARTED" "false" "$(line_count "$DONE_QUEUE")"
        exit 0
    fi

    if [ -f "$SEEKFILE" ]; then
        SEEK=$(cat "$SEEKFILE" 2>/dev/null | tr -cd '0-9')
        rm -f "$SEEKFILE"
        if [ -n "$SEEK" ] && [ "$SEEK" -gt "$IDX" ] 2>/dev/null; then
            while [ "$IDX" -lt "$SEEK" ] && IFS='	' read -r TS MAC SSID CHAN RSSI LAT LON; do
                IDX=$((IDX + 1))
            done
        fi
        append_event "seek" "jumped to point $IDX"
    fi

    LAST_LAT="$LAT"
    LAST_LON="$LON"
    : > "$LAST_MACS"
    printf "%s\n" "$MAC" > "$LAST_MACS"
    write_nearby_json "$LAT" "$LON" "$MAC" "$SSID" "$RSSI"
    record_discovered "$MAC" "$SSID" "$LAT" "$LON" "$RSSI" "0"
    decimal_to_nmea "$LAT" "$LON" 0 "$(printf "%s" "$TS" | awk '{print $1}')" "$(printf "%s" "$TS" | awk '{print $2}')" > /tmp/wardriving_replay.nmea
    cp -f /tmp/wardriving_replay.nmea /tmp/vGPS_last 2>/dev/null || true

    MAC_HEX=$(printf "%s" "$MAC" | tr -d ':' | tr '[:upper:]' '[:lower:]')
    CAP=""
    [ -f "$MAC_DIR/$MAC_HEX" ] && CAP=$(head -n 1 "$MAC_DIR/$MAC_HEX" 2>/dev/null)
    if [ -n "$CAP" ] && ! grep -Fxq "$CAP" "$SENT_CAPS" 2>/dev/null; then
        echo "$CAP" >> "$SENT_CAPS"
        echo "$CAP" >> "$QUEUE"
        record_discovered "$MAC" "$SSID" "$LAT" "$LON" "$RSSI" "1"
        append_event "capture" "queued $(basename "$CAP") for $SSID"
    fi

    CRACKS=$(( $(read_cracks) - CRACKS_START ))
    [ "$CRACKS" -lt 0 ] 2>/dev/null && CRACKS=0
    NEAR=$(awk 'BEGIN{n=0} /"mac"/{n++} END{print n}' "$LAST_NEAR" 2>/dev/null || echo 0)
    SENT=$(line_count "$SENT_CAPS")
    DONE=$(line_count "$DONE_QUEUE")
    EVENT="point $IDX/$TOTAL: $SSID"
    write_state "running" "$IDX" "$TOTAL" "$LAT" "$LON" 0 "$NEAR" "$SENT" "$SENT" "$DONE" "$CRACKS" "QUEUE" "VIS" "$EVENT" "$STARTED" "false" "$DONE"
    delay_sleep "$DELAY_MS"
done < "$ROWS"

append_event "done" "visual replay complete"
touch "$VISUAL_DONE"
write_state "done" "$TOTAL" "$TOTAL" "$LAST_LAT" "$LAST_LON" 0 0 "$(line_count "$SENT_CAPS")" "$(line_count "$SENT_CAPS")" "$(line_count "$DONE_QUEUE")" "$(( $(read_cracks) - CRACKS_START ))" "DONE" "IDLE" "replay complete" "$STARTED" "false" "$(line_count "$DONE_QUEUE")"
cp -f "$STATE" "$REPORT" 2>/dev/null || true
