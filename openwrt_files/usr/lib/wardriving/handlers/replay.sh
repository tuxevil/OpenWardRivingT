#!/bin/sh
# shellcheck shell=sh

handle_replay_start() {
require_post
check_content_length 10485760 "replay CSV"
REPLAY_PID="/tmp/wardriving_replay.pid"
REPLAY_WORK="/tmp/wardriving_replay_work"
REPLAY_META="$REPLAY_WORK/current_csv"
RESUME=$(echo "$QUERY_STRING" | grep -o "resume=[^&]*" | cut -d= -f2 | tr -cd '01')
[ -z "$RESUME" ] && RESUME=1
if [ -f "$REPLAY_PID" ]; then
    OLD_PID=$(cat "$REPLAY_PID" 2>/dev/null | tr -cd '0-9')
    if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
        if [ -f /tmp/wardriving_replay.pause ]; then
            rm -f /tmp/wardriving_replay.pause
            echo "{\"status\":\"resumed\",\"pid\":$OLD_PID}"
        else
            echo '{"status":"error","reason":"replay already running"}'
        fi
        exit 0
    fi
    rm -f "$REPLAY_PID"
fi
DELAY=$(echo "$QUERY_STRING" | grep -o "delay=[^&]*" | cut -d= -f2 | tr -cd '0-9')
RADIUS=$(echo "$QUERY_STRING" | grep -o "radius=[^&]*" | cut -d= -f2 | tr -cd '0-9')
CLEAN=$(echo "$QUERY_STRING" | grep -o "clean=[^&]*" | cut -d= -f2 | tr -cd '01')
[ -z "$DELAY" ] && DELAY=500
[ -z "$RADIUS" ] && RADIUS=75
[ -z "$CLEAN" ] && CLEAN=0
[ "$DELAY" -lt 50 ] 2>/dev/null && DELAY=50
[ "$DELAY" -gt 10000 ] 2>/dev/null && DELAY=10000
[ "$RADIUS" -lt 1 ] 2>/dev/null && RADIUS=75
[ "$RADIUS" -gt 1000 ] 2>/dev/null && RADIUS=1000
mkdir -p "$REPLAY_WORK"

BODY_REQUIRED=1
CSV_IN=""
BODY_LEN="${CONTENT_LENGTH:-0}"
case "$BODY_LEN" in ''|*[!0-9]*) BODY_LEN=0 ;; esac
if [ "$RESUME" = "1" ] && [ "$BODY_LEN" -eq 0 ] && [ -f /tmp/wardriving_replay.pause ] && [ -f "$REPLAY_META" ]; then
    CSV_IN=$(cat "$REPLAY_META" 2>/dev/null)
    [ -f "$CSV_IN" ] && BODY_REQUIRED=0
fi
CURRENT_IDX=0
if [ -f /tmp/wardriving_replay_status.json ]; then
    CURRENT_IDX=$(sed -n 's/.*"index":\([0-9]*\).*/\1/p' /tmp/wardriving_replay_status.json | head -n 1)
    [ -z "$CURRENT_IDX" ] && CURRENT_IDX=0
fi

if [ "$BODY_REQUIRED" = "1" ]; then
    rm -rf "$REPLAY_WORK"
    mkdir -p "$REPLAY_WORK"
    rm -f /tmp/wardriving_replay.pause
    mkdir -p /tmp/wardriving_replay_uploads
    CSV_IN="/tmp/wardriving_replay_uploads/wigle_$(date +%Y%m%d_%H%M%S)_$$.csv"
    dd bs=1k count=10240 of="$CSV_IN" 2>/dev/null
    if [ ! -s "$CSV_IN" ]; then
        rm -f "$CSV_IN"
        json_error "empty CSV"
        exit 0
    fi
    if ! grep -q '^MAC,SSID,' "$CSV_IN"; then
        rm -f "$CSV_IN"
        json_error "invalid WiGLE CSV"
        exit 0
    fi
    printf "%s\n" "$CSV_IN" > "$REPLAY_META"
    CURRENT_IDX=0
fi
rm -f /tmp/wardriving_replay.stop /tmp/wardriving_replay.seek /tmp/wardriving_replay.pause
/usr/bin/wardriving_replay.sh "$CSV_IN" "$DELAY" "$RADIUS" "$CLEAN" "$CURRENT_IDX" >/tmp/wardriving_replay.stdout 2>&1 &
echo "{\"status\":\"started\",\"pid\":$!}"
}

handle_replay_status() {
STATE="/tmp/wardriving_replay_status.json"
PIDFILE="/tmp/wardriving_replay.pid"
if [ -f "$STATE" ]; then
    cat "$STATE"
else
    echo '{"state":"idle","pid":0,"index":0,"total":0,"lat":0,"lon":0,"speed_kmh":0,"nearby":0,"matches":0,"sent":0,"rows":0,"cracks":0,"gpu":"IDLE","tx":"IDLE","event":"no replay loaded","started":0,"updated":0}'
fi
if [ -f "$PIDFILE" ]; then
    PID=$(cat "$PIDFILE" 2>/dev/null | tr -cd '0-9')
    [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null || rm -f "$PIDFILE"
fi
}

handle_replay_seek() {
IDX=$(echo "$QUERY_STRING" | grep -o "idx=[^&]*" | cut -d= -f2 | tr -cd '0-9')
[ -z "$IDX" ] && IDX=0
echo "$IDX" > /tmp/wardriving_replay.seek
rm -f /tmp/wardriving_replay.pause
echo '{"status":"seek_set"}'
}

handle_replay_pause() {
touch /tmp/wardriving_replay.pause
echo '{"status":"paused"}'
}

handle_replay_stop() {
touch /tmp/wardriving_replay.stop
if [ -f /tmp/wardriving_replay.pid ]; then
    PID=$(cat /tmp/wardriving_replay.pid 2>/dev/null | tr -cd '0-9')
    [ -n "$PID" ] && kill "$PID" 2>/dev/null || true
fi
if [ -f /tmp/wardriving_replay_queue.pid ]; then
    QPID=$(cat /tmp/wardriving_replay_queue.pid 2>/dev/null | tr -cd '0-9')
    [ -n "$QPID" ] && kill "$QPID" 2>/dev/null || true
fi
rm -f /tmp/wardriving_replay.pause /tmp/wardriving_replay.pid /tmp/wardriving_replay_queue.pid
echo '{"status":"stopping"}'
}

handle_replay_report() {
if [ -f /tmp/wardriving_replay_report.json ]; then
    cat /tmp/wardriving_replay_report.json
elif [ -f /tmp/wardriving_replay_status.json ]; then
    cat /tmp/wardriving_replay_status.json
else
    echo '{"state":"idle","event":"no replay report"}'
fi
}

handle_replay_discovered() {
DISC="/tmp/wardriving_replay_work/discovered.tsv"
if [ ! -s "$DISC" ]; then
    echo "[]"
    exit 0
fi
if [ -f "$WARD_MNT"/hashcat.potfile ]; then
    awk '{ if ($0 ~ /^WPA\*/) { split($0, arr, "*"); print arr[4] } else if ($0 ~ /^[0-9a-fA-F]{32}:[0-9a-fA-F]{12}:/) { split($0, arr, ":"); print arr[2] } }' "$WARD_MNT"/hashcat.potfile | tr '[:upper:]' '[:lower:]' | sort -u > /tmp/replay_cracked_macs.txt
else
    : > /tmp/replay_cracked_macs.txt
fi
awk -F'\t' '
FILENAME==ARGV[1] {cr[$1]=1; next}
{
    mac=tolower($1); ssid=$2; lat=$3+0; lon=$4+0; rssi=$5+0; hs=$6+0
    if (lat == 0 || lon == 0) next
    key=sprintf("%.4f,%.4f", lat, lon)
    if (!(key in seen)) { order[++n]=key; glat[key]=lat; glon[key]=lon; maxr[key]=rssi }
    seen[key]++
    if (rssi > maxr[key]) maxr[key]=rssi
    if (hs) gh[key]=1
    if (cr[mac]) gc[key]=1
    if (samples[key] == "") samples[key]=ssid; else if (split(samples[key], a, ",") < 5 && index(samples[key], ssid)==0) samples[key]=samples[key] "," ssid
}
function esc(s){gsub(/\\/,"\\\\",s); gsub(/"/,"\\\"",s); return s}
END {
    printf "["
    for (i=1; i<=n; i++) {
        k=order[i]
        if (i>1) printf ","
        printf "{\"lat\":%.6f,\"lon\":%.6f,\"count\":%d,\"has_handshake\":%s,\"is_cracked\":%s,\"rssi\":%d,\"ssids\":\"%s\"}", glat[k], glon[k], seen[k], (gh[k]?"true":"false"), (gc[k]?"true":"false"), maxr[k], esc(samples[k])
    }
    print "]"
}' /tmp/replay_cracked_macs.txt "$DISC"
}
