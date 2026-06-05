#!/bin/sh
# shellcheck shell=sh

handle_networks_map() {
if [ ! -f "$WARD_MNT"/wardriving.db ]; then
    echo "[]"
    exit 0
fi
grep -oE '\*[0-9a-fA-F]{12}' "$WARD_MNT"/master.hc2200 2>/dev/null | sed 's/^\*//' | tr '[:upper:]' '[:lower:]' | sort -u > /tmp/map_hs_macs.txt
if [ -f "$WARD_MNT"/hashcat.potfile ]; then
    awk '{ if ($0 ~ /^WPA\*/) { split($0, arr, "*"); print arr[4] } else if ($0 ~ /^[0-9a-fA-F]{32}:[0-9a-fA-F]{12}:/) { split($0, arr, ":"); print arr[2] } }' "$WARD_MNT"/hashcat.potfile | tr '[:upper:]' '[:lower:]' | sort -u > /tmp/map_cracked_macs.txt
else
    : > /tmp/map_cracked_macs.txt
fi
sqlite3 -separator '|' "$WARD_MNT"/wardriving.db "SELECT lower(replace(mac,':','')), ssid, lat, lon, rssi FROM networks WHERE lat IS NOT NULL AND lon IS NOT NULL AND lat != 'NULL' AND lon != 'NULL' LIMIT 3000;" 2>/dev/null | awk -F'|' '
FILENAME==ARGV[1] {hs[$1]=1; next}
FILENAME==ARGV[2] {cr[$1]=1; next}
{
    mac=$1; ssid=$2; lat=$3+0; lon=$4+0; rssi=$5+0
    key=sprintf("%.4f,%.4f", lat, lon)
    if (!(key in seen)) { order[++n]=key; glat[key]=lat; glon[key]=lon; maxr[key]=rssi }
    seen[key]++
    if (rssi > maxr[key]) maxr[key]=rssi
    if (hs[mac]) gh[key]=1
    if (cr[mac]) gc[key]=1
    if (samples[key] == "") samples[key]=ssid; else if (split(samples[key], a, ",") < 4 && index(samples[key], ssid)==0) samples[key]=samples[key] "," ssid
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
}' /tmp/map_hs_macs.txt /tmp/map_cracked_macs.txt -
}

handle_clients_map() {
if [ ! -f "$WARD_MNT"/wardriving.db ]; then
    echo "[]"
    exit 0
fi
sqlite3 -separator '|' "$WARD_MNT"/wardriving.db "CREATE TABLE IF NOT EXISTS clients (client_mac TEXT, ap_mac TEXT, ssid TEXT, channel INTEGER, lat REAL, lon REAL, first_seen DATETIME, last_seen DATETIME, rssi INTEGER, frame_type TEXT, seen_mode TEXT, PRIMARY KEY(client_mac, ap_mac)); SELECT lower(replace(client_mac,':','')), lower(replace(ap_mac,':','')), ssid, lat, lon, rssi, channel, frame_type FROM clients WHERE lat IS NOT NULL AND lon IS NOT NULL AND lat != 'NULL' AND lon != 'NULL' ORDER BY last_seen DESC LIMIT 4000;" 2>/dev/null | awk -F'|' '
{
    client=$1; ap=$2; ssid=$3; lat=$4+0; lon=$5+0; rssi=$6+0; chan=$7+0; ftype=$8
    if (lat == 0 || lon == 0 || client == "" || ap == "") next
    key=sprintf("%.4f,%.4f", lat, lon)
    if (!(key in seen)) { order[++n]=key; glat[key]=lat; glon[key]=lon; maxr[key]=rssi }
    seen[key]++
    clients[key SUBSEP client]=1
    aps[key SUBSEP ap]=1
    if (rssi > maxr[key]) maxr[key]=rssi
    if (samples[key] == "") samples[key]=ssid; else if (split(samples[key], a, ",") < 5 && ssid != "" && index(samples[key], ssid)==0) samples[key]=samples[key] "," ssid
    if (channels[key] == "") channels[key]=chan; else if (chan && index("," channels[key] ",", "," chan ",")==0) channels[key]=channels[key] "," chan
    if (ftype ~ /auth|assoc/) assoc[key]++
}
function esc(s){gsub(/\\/,"\\\\",s); gsub(/"/,"\\\"",s); return s}
END {
    printf "["
    for (i=1; i<=n; i++) {
        k=order[i]; cc=0; ac=0
        for (x in clients) { split(x,p,SUBSEP); if (p[1]==k) cc++ }
        for (x in aps) { split(x,p,SUBSEP); if (p[1]==k) ac++ }
        if (i>1) printf ","
        printf "{\"lat\":%.6f,\"lon\":%.6f,\"count\":%d,\"client_count\":%d,\"ap_count\":%d,\"associated\":%d,\"rssi\":%d,\"ssids\":\"%s\",\"channels\":\"%s\",\"kind\":\"clients\"}", glat[k], glon[k], seen[k], cc, ac, assoc[k]+0, maxr[k], esc(samples[k]), esc(channels[k])
    }
    print "]"
}'
}

handle_scored_networks() {
if [ -f "$WARD_MNT"/wardriving.db ]; then
    # Pre-compute handshake MACs to avoid system() calls in awk loop
    # Pre-compute handshake MACs (busybox-compatible grep -oE, no PCRE)
    HS_MACS=$(grep -oE '\*[0-9a-fA-F]{12}' "$WARD_MNT"/master.hc2200 2>/dev/null | sed 's/^\*//' | tr '[:upper:]' '[:lower:]' | sort -u | paste -sd '|' - 2>/dev/null)
    sqlite3 -separator '|' "$WARD_MNT"/wardriving.db "SELECT mac, ssid, enc, rssi, CAST((julianday('now') - julianday(last_seen)) * 86400 AS INTEGER) AS age_seconds FROM networks WHERE last_seen >= datetime('now', '-90 seconds') AND ssid IS NOT NULL AND ssid != '' AND rssi <= 0 ORDER BY rssi DESC LIMIT 12;" 2>/dev/null | awk -F'|' -v hs_macs="$HS_MACS" '
    BEGIN { printf "[" }
    {
        mac=$1; ssid=$2; enc=$3; rssi=$4; age=$5;
        if (mac !~ /^[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]$/) next;
        # Proper JSON escaping in awk
        gsub(/\\/, "\\\\", ssid);
        gsub("\x22", "\\\"", ssid);
        gsub(/\x08/, "\\b", ssid);
        gsub(/\x0c/, "\\f", ssid);
        gsub(/\n/, "\\n", ssid);
        gsub(/\r/, "\\r", ssid);
        gsub(/\t/, "\\t", ssid);
        # Remove any other non-printable characters
        gsub(/[^\x20-\x7E]/, "", ssid);
        mac_hex = tolower(mac); gsub(/:/, "", mac_hex);
        
        has_hs = "false"
        if (hs_macs ~ mac_hex) has_hs = "true"
        
        if(NR>1) printf ",";
        printf "{\"mac\":\"%s\",\"ssid\":\"%s\",\"enc\":\"%s\",\"rssi\":%s,\"age\":%s,\"has_hs\":%s}", mac, ssid, enc, rssi, age, has_hs
    }
    END { print "]" }'
else
    echo "[]"
fi
}

handle_history() {
if [ ! -f "$WARD_MNT"/wardriving.db ]; then
    echo '{"total":0, "wpa3":0, "hs":0, "days":0, "sessions":[]}'
    exit 0
fi
TOTAL=$(sqlite3 "$WARD_MNT"/wardriving.db "SELECT COUNT(*) FROM networks;" 2>/dev/null)
[ -z "$TOTAL" ] && TOTAL=0
WPA3=$(sqlite3 "$WARD_MNT"/wardriving.db "SELECT COUNT(*) FROM networks WHERE enc LIKE '%SAE%';" 2>/dev/null)
[ -z "$WPA3" ] && WPA3=0
HS=$(wc -l < "$WARD_MNT"/master.hc2200 2>/dev/null || echo 0)
DAYS=$(sqlite3 "$WARD_MNT"/wardriving.db "SELECT COUNT(DISTINCT date(last_seen)) FROM networks;" 2>/dev/null)
[ -z "$DAYS" ] && DAYS=0

# Build sessions JSON (safe: no SSIDs, only dates and counts)
SESSIONS=$(sqlite3 -separator '|' "$WARD_MNT"/wardriving.db "SELECT date(last_seen), COUNT(*) FROM networks GROUP BY date(last_seen) ORDER BY date(last_seen) DESC LIMIT 7;" 2>/dev/null | awk -F'|' '
BEGIN { first=1 }
{
    if(!first) printf ","
    printf "{\"date\":\"%s\", \"count\":%s, \"hs_count\":\"N/A\"}", $1, $2
    first=0
}')

cat << JSON
{"total":$TOTAL, "wpa3":$WPA3, "hs":$HS, "days":$DAYS, "sessions":[$SESSIONS]}
JSON
exit 0
}
