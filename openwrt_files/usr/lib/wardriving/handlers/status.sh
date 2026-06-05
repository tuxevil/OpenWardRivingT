#!/bin/sh
# shellcheck shell=sh

handle_status() {
if [ -f /var/run/wardriving_core.pid ]; then
    CORE_PID=$(cat /var/run/wardriving_core.pid)
    kill -0 "$CORE_PID" 2>/dev/null && IS_RUNNING="true" || IS_RUNNING="false"
else
    IS_RUNNING="false"
fi
if [ -f "$WARD_MNT"/master.hc2200 ]; then
    HANDSHAKES=$(wc -l < "$WARD_MNT"/master.hc2200 2>/dev/null || echo 0)
else
    HANDSHAKES=0
fi
read -r SPACE_USED SPACE_FREE USB_PCT <<_EOF
$(df -h "$WARD_MNT" | awk 'NR==2 {print $3, $4, $5}' | tr -d '%')
_EOF
read -r CPU_LOAD _ < /proc/loadavg
read -r RAM_TOTAL RAM_USED <<_EOF
$(free -m | awk '/^Mem:/{print $2, $3}')
_EOF
RAM_PCT=0; [ "$RAM_TOTAL" -gt 0 ] && RAM_PCT=$(( 100 * RAM_USED / RAM_TOTAL ))
LATEST_NMEA=$(ls -1t "$WARD_MNT"/*.nmea 2>/dev/null | head -n 1)
SATS="0"
DEAUTHS="N/A"
FIX="0"
if [ -f "$LATEST_NMEA" ]; then
    read -r FIX SATS SPEED <<_EOF
$(tail -n 30 "$LATEST_NMEA" | awk -F',' '/^\$G[PN]GGA/{f=$7; s=$8} /^\$[A-Z]{2}RMC/{sp=$8} END{print (f?f:0), (s?s:0), (sp?sp:0)}')
_EOF
fi
GPS_STAT="WAITING"
if [ -f /tmp/vGPS_last ]; then
    LAST_MOD=$(date -r /tmp/vGPS_last +%s 2>/dev/null || echo 0)
    NOW=$(date +%s)
    if [ "$((NOW - LAST_MOD))" -lt 15 ]; then
        GPS_STAT="CONNECTED"
        read -r FIX SATS SPEED <<_EOF
$(awk -F',' '/^\$G[PN]GGA/{f=$7; s=$8} /^\$[A-Z]{2}RMC/{sp=$8} END{print (f?f:0), (s?s:0), (sp?sp:0)}' /tmp/vGPS_last 2>/dev/null)
_EOF
    fi
fi

LOG_DATA=$(tail -n 1000 /tmp/wardriving_status.log 2>/dev/null | tr -cd '\11\12\40-\176')
CLEAN_LOG=$(echo "$LOG_DATA" | awk '/CHA   LAST/{buf=""} {buf = buf $0 "\n"} END{print buf}' | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' | tr -cd '\11\12\40-\176')
[ -z "$CLEAN_LOG" ] && CLEAN_LOG=$(echo "$LOG_DATA" | tail -n 30 | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' | tr -cd '\11\12\40-\176')
if [ -z "$CLEAN_LOG" ]; then
    LAST_LOG="Waiting for data or initializing monitor mode..."
else
    LAST_LOG=$(echo "$CLEAN_LOG" | tr '\t' ' ' | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/$/\\n/g' | tr -d '\n')
fi

CHANNELS_JSON=$(echo "$LOG_DATA" | awk '/^[ \t]*[0-9]+ [0-9]{2}:[0-9]{2}:[0-9]{2}/ {chan=$1; essid=$NF; if(length(essid)>2 && essid!~/:/ && essid !~ /^[0-9a-fA-F]{12}$/){ k=chan"\t"essid; if(!seen[k]++){ if(!f) printf "["; else printf ","; printf "{\"c\":%s, \"s\":\"%s\"}", chan, essid; f=1 } }} END{if(!f) printf "["; print "]"}')
[ -z "$CHANNELS_JSON" ] && CHANNELS_JSON="[]"
if [ "$CHANNELS_JSON" = "[]]" ]; then CHANNELS_JSON="[]"; fi

remote_read_config
REMOTE_STATE="local"
REMOTE_CODE="0"
REMOTE_MSG="remote disabled"
REMOTE_UPDATED="0"
if [ -f /tmp/wardriving_remote_status ]; then
    REMOTE_STATE=$(awk -F= '$1=="state"{print $2; exit}' /tmp/wardriving_remote_status | tr -cd 'a-zA-Z0-9_-')
    REMOTE_CODE=$(awk -F= '$1=="code"{print $2; exit}' /tmp/wardriving_remote_status | tr -cd '0-9')
    REMOTE_MSG=$(awk -F= '$1=="message"{print $2; exit}' /tmp/wardriving_remote_status | tr -cd 'A-Za-z0-9 _.-')
    REMOTE_UPDATED=$(awk -F= '$1=="updated"{print $2; exit}' /tmp/wardriving_remote_status | tr -cd '0-9')
fi
[ -z "$REMOTE_STATE" ] && REMOTE_STATE="unknown"
[ -z "$REMOTE_CODE" ] && REMOTE_CODE="0"
[ -z "$REMOTE_MSG" ] && REMOTE_MSG="waiting"
[ -z "$REMOTE_UPDATED" ] && REMOTE_UPDATED="0"
CUR_MODE="active"
if [ -f "$MODE_FILE" ]; then CUR_MODE=$(cat "$MODE_FILE" | tr -cd 'a-z'); fi
case "$CUR_MODE" in active|passive|smart) ;; *) CUR_MODE="active" ;; esac

cat << JSON
{
"running": $IS_RUNNING,
"mode": "$CUR_MODE",
"handshakes": "$HANDSHAKES",
"space_used": "$SPACE_USED",
"usb_pct": "$USB_PCT",
"cpu": "$CPU_LOAD",
"ram": "$RAM_PCT",
"sats": "$SATS",
"speed": "$SPEED",
"deauths": "$DEAUTHS",
"fix": "$FIX",
"space_free": "$SPACE_FREE",
"gps_status": "$GPS_STAT",
"remote_enabled": "$REMOTE_ENABLED",
"extraction_mode": "$EXTRACTION_MODE",
"gpu_cracking_enabled": "$GPU_CRACKING_ENABLED",
"remote_state": "$REMOTE_STATE",
"remote_code": "$REMOTE_CODE",
"remote_message": "$REMOTE_MSG",
"remote_updated": "$REMOTE_UPDATED",
"logs": "$LAST_LOG",
"channels_data": $CHANNELS_JSON
}
JSON
}

handle_gps_push() {
require_post
check_content_length 8192 "NMEA payload"
NMEA_DATA=$(cat)
if [ -n "$NMEA_DATA" ]; then
    # Basic NMEA validation: must start with $ and contain checksum
    case "$NMEA_DATA" in
        \$G*\**)
            if [ -p /tmp/vGPS_fifo ]; then printf "%s\n" "$NMEA_DATA" >> /tmp/vGPS_fifo; fi
            printf "%s\n" "$NMEA_DATA" > /tmp/vGPS_last
            ;;
        *)
            echo '{"status": "error", "reason": "invalid NMEA format"}'
            exit 0
            ;;
    esac
fi
echo '{"status": "ok"}'
}
