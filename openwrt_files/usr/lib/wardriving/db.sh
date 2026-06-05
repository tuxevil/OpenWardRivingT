#!/bin/sh
# SQLite and hash helpers shared by capture, replay, and CGI handlers.

db_init_networks() {
    _db="$1"
    command -v sqlite3 >/dev/null 2>&1 || return 0
    sqlite3 "$_db" "CREATE TABLE IF NOT EXISTS networks (mac TEXT PRIMARY KEY, ssid TEXT, enc TEXT, channel INTEGER, lat REAL, lon REAL, first_seen DATETIME, last_seen DATETIME, rssi INTEGER);" 2>/dev/null || return 0
    sqlite3 "$_db" "PRAGMA journal_mode=WAL; CREATE INDEX IF NOT EXISTS idx_last_seen ON networks(last_seen);" >/dev/null 2>&1 || true
}

db_init_clients() {
    _db="$1"
    command -v sqlite3 >/dev/null 2>&1 || return 0
    sqlite3 "$_db" "CREATE TABLE IF NOT EXISTS clients (client_mac TEXT, ap_mac TEXT, ssid TEXT, channel INTEGER, lat REAL, lon REAL, first_seen DATETIME, last_seen DATETIME, rssi INTEGER, frame_type TEXT, seen_mode TEXT, PRIMARY KEY(client_mac, ap_mac)); CREATE INDEX IF NOT EXISTS idx_clients_last_seen ON clients(last_seen); CREATE INDEX IF NOT EXISTS idx_clients_ap ON clients(ap_mac);" >/dev/null 2>&1 || true
}

db_insert_jsonl_rows() {
    _jsonl="$1"
    _db="$2"
    [ -s "$_jsonl" ] || return 0
    command -v sqlite3 >/dev/null 2>&1 || return 0
    db_init_networks "$_db"

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
        [ "$RSSI" -gt 0 ] 2>/dev/null && continue
        [ -z "$LAT" ] && LAT="NULL"
        [ -z "$LON" ] && LON="NULL"
        SSID=$(printf "%s" "$SSID_B64" | base64 -d 2>/dev/null | sed "s/'/''/g" | tr -cd '[:print:]')
        [ -z "$SSID" ] && continue
        sqlite3 "$_db" "INSERT INTO networks (mac, ssid, enc, channel, lat, lon, first_seen, last_seen, rssi) VALUES ('$MAC', '$SSID', '$ENC', $CHAN, $LAT, $LON, datetime('now'), datetime('now'), $RSSI) ON CONFLICT(mac) DO UPDATE SET ssid=EXCLUDED.ssid, enc=EXCLUDED.enc, channel=EXCLUDED.channel, lat=EXCLUDED.lat, lon=EXCLUDED.lon, last_seen=EXCLUDED.last_seen, rssi=EXCLUDED.rssi;" 2>/dev/null || true
    done < "$_jsonl"
}

hashcat_macs_to_file() {
    _hash_file="$1"
    _out_file="$2"
    if [ -f "$_hash_file" ]; then
        grep -oE '\*[0-9a-fA-F]{12}' "$_hash_file" 2>/dev/null | sed 's/^\*//' | tr '[:upper:]' '[:lower:]' | sort -u > "$_out_file"
    else
        : > "$_out_file"
    fi
}

potfile_macs_to_file() {
    _potfile="$1"
    _out_file="$2"
    if [ -f "$_potfile" ]; then
        awk '{ if ($0 ~ /^WPA\*/) { split($0, arr, "*"); print arr[4] } else if ($0 ~ /^[0-9a-fA-F]{32}:[0-9a-fA-F]{12}:/) { split($0, arr, ":"); print arr[2] } }' "$_potfile" | tr '[:upper:]' '[:lower:]' | sort -u > "$_out_file"
    else
        : > "$_out_file"
    fi
}
