#!/bin/sh
# shellcheck shell=sh

handle_download_all() {
echo "Content-Type: application/gzip"
echo "Content-Disposition: attachment; filename=\"openwardrivingt_captures_$(date +%Y%m%d_%H%M).tar.gz\""
echo ""
cd "$WARD_MNT" && tar -czf - *.pcapng *.nmea *.hc2200 *.txt 2>/dev/null
exit 0
}

handle_export_gpx() {
echo "Content-Type: application/gpx+xml"
echo "Access-Control-Allow-Origin: *"
echo "Content-Disposition: attachment; filename=\"wardriving_route_$(date +%Y%m%d_%H%M).gpx\""
echo ""
cat "$WARD_MNT"/*.nmea 2>/dev/null | awk '
BEGIN {
    print "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
    print "<gpx version=\"1.0\">"
    print "  <trk><name>OpenWardRivingT Route</name><trkseg>"
}
# NMEA RMC parser — same formula as parse_nmea_rmc()
/^\$[A-Z]{2}RMC/ {
    if($3 == "A") {
        lat_dec = substr($4,1,2) + (substr($4,3) / 60)
        if($5 == "S") lat_dec = -lat_dec
        lon_dec = substr($6,1,3) + (substr($6,4) / 60)
        if($7 == "W") lon_dec = -lon_dec
        t_raw = $2; d_raw = $10
        ts = "20" substr(d_raw,5,2) "-" substr(d_raw,3,2) "-" substr(d_raw,1,2) "T" substr(t_raw,1,2) ":" substr(t_raw,3,2) ":" substr(t_raw,5,2) "Z"
        printf "    <trkpt lat=\"%.6f\" lon=\"%.6f\">\n      <time>%s</time>\n    </trkpt>\n", lat_dec, lon_dec, ts
    }
}
END {
    print "  </trkseg></trk>"
    print "</gpx>"
}'
exit 0
}

handle_export_kml() {
echo "Content-Type: application/vnd.google-earth.kml+xml"
echo "Access-Control-Allow-Origin: *"
echo "Content-Disposition: attachment; filename=\"wardriving_route_$(date +%Y%m%d_%H%M).kml\""
echo ""
cat "$WARD_MNT"/*.nmea 2>/dev/null | awk '
BEGIN {
    print "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
    print "<kml xmlns=\"http://www.opengis.net/kml/2.2\">"
    print "  <Document><name>OpenWardRivingT Route</name>"
    print "    <Placemark><name>Route</name><LineString>"
    print "      <tessellate>1</tessellate><coordinates>"
}
# NMEA RMC parser — same formula as parse_nmea_rmc()
/^\$[A-Z]{2}RMC/ {
    if($3 == "A") {
        lat_dec = substr($4,1,2) + (substr($4,3) / 60)
        if($5 == "S") lat_dec = -lat_dec
        lon_dec = substr($6,1,3) + (substr($6,4) / 60)
        if($7 == "W") lon_dec = -lon_dec
        printf "        %.6f,%.6f,0\n", lon_dec, lat_dec
    }
}
END {
    print "      </coordinates>"
    print "    </LineString></Placemark>"
    print "  </Document>"
    print "</kml>"
}'
exit 0
}

handle_export_hashcat() {
echo "Content-Type: application/octet-stream"
echo "Content-Disposition: attachment; filename=\"openwardrivingt_handshakes_$(date +%Y%m%d).hc2200\""
echo ""
cat "$WARD_MNT"/master.hc2200 2>/dev/null
exit 0
}

handle_upload_potfile() {
require_post
check_content_length 1048576 "potfile upload"
# Limit upload to 1MB to prevent USB fill attacks
dd bs=1k count=1024 of=/tmp/uploaded.potfile 2>/dev/null
if [ ! -s /tmp/uploaded.potfile ]; then
    rm -f /tmp/uploaded.potfile
    json_error "empty upload"
    exit 0
fi
cat /tmp/uploaded.potfile >> "$WARD_MNT"/hashcat.potfile
sort -u "$WARD_MNT"/hashcat.potfile -o "$WARD_MNT"/hashcat.potfile 2>/dev/null
rm -f /tmp/uploaded.potfile
api_cache_clear cracked_networks
api_cache_clear networks_map
echo '{"status": "ok"}'
}

handle_pwnagotchi_sync() {
# Pwnagotchi Bridge: receive .pcap from pwnagotchi, extract PMKIDs, merge into master
require_post
check_content_length 52428800 "pcap upload"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
PCAP_IN="/tmp/pwnagotchi_${TIMESTAMP}.pcap"
HC2200_OUT="/tmp/pwnagotchi_${TIMESTAMP}.hc2200"
ESSID_OUT="/tmp/pwnagotchi_${TIMESTAMP}.essid"

# Save uploaded pcap with a hard 50MB cap for clients that omit CONTENT_LENGTH.
dd bs=1k count=51200 of="$PCAP_IN" 2>/dev/null

if [ -s "$PCAP_IN" ]; then
    # Extract PMKIDs and ESSIDs
    hcxpcapngtool -o "$HC2200_OUT" -E "$ESSID_OUT" "$PCAP_IN" > /dev/null 2>&1
    
    HAS_HASHES=0
    if [ -s "$HC2200_OUT" ]; then
        cat "$HC2200_OUT" >> "$WARD_MNT"/master.hc2200
        sort -u "$WARD_MNT"/master.hc2200 -o "$WARD_MNT"/master.hc2200
        HAS_HASHES=$(wc -l < "$HC2200_OUT")
    fi
    
    HAS_ESSIDS=0
    if [ -s "$ESSID_OUT" ]; then
        cat "$ESSID_OUT" >> "$WARD_MNT"/master_essid.txt
        sort -u "$WARD_MNT"/master_essid.txt -o "$WARD_MNT"/master_essid.txt
        HAS_ESSIDS=$(wc -l < "$ESSID_OUT")
    fi
    
    # Cleanup
    rm -f "$PCAP_IN" "$HC2200_OUT" "$ESSID_OUT"
    echo "{\"status\": \"ok\", \"hashes_added\": $HAS_HASHES, \"essids_added\": $HAS_ESSIDS}"
else
    rm -f "$PCAP_IN"
    echo '{"status": "error", "reason": "empty upload"}'
fi
}

handle_cracked_networks() {
if api_cache_emit cracked_networks 20; then
    exit 0
fi
OUT=$(mktemp /tmp/wardriving_cracked_XXXXXX) || { echo "[]"; exit 0; }
CRACKED_MACS="/tmp/cracked_macs_$$.txt"
SSID_PWD="/tmp/ssid_pwd_$$.txt"
{
echo "["
if [ -f "$WARD_MNT"/hashcat.potfile ] && [ -f "$WARD_MNT"/wardriving.db ]; then
    awk '{ if ($0 ~ /^WPA\*/) { split($0, arr, "*"); print arr[4] } else if ($0 ~ /^[0-9a-fA-F]{32}:[0-9a-fA-F]{12}:/) { split($0, arr, ":"); print arr[2] } }' "$WARD_MNT"/hashcat.potfile | awk '{gsub(/../,"&:"); sub(/:$/,""); print tolower($0)}' | sort -u > "$CRACKED_MACS"
    
    # Extract cracked networks. The UNION also covers rows where mac/ssid were
    # swapped in old database migrations, ensuring backward compat with existing DBs.
    if [ -s "$CRACKED_MACS" ]; then
        awk -F: '{ssid=$4; pwd=""; for(i=5;i<=NF;i++){if(i>5)pwd=pwd":"; pwd=pwd $i}; print ssid"|"pwd}' "$WARD_MNT"/hashcat.potfile | sort -t'|' -k1,1 -u > "$SSID_PWD"
        COND=$(awk '{printf "\"%s\",", $1}' "$CRACKED_MACS" | sed 's/,$//')
        sqlite3 -separator '|' "$WARD_MNT"/wardriving.db "
            SELECT lat, lon, ssid FROM networks
            WHERE lower(mac) IN ($COND) AND lat IS NOT NULL AND lon IS NOT NULL
            UNION
            SELECT lat, lon, enc FROM networks
            WHERE lower(ssid) IN ($COND) AND lat IS NOT NULL AND lon IS NOT NULL
        " 2>/dev/null | awk -F'|' -v ssid_pwd="$SSID_PWD" '
        BEGIN {
            while((getline line < ssid_pwd) > 0) {
                n=index(line,"|"); s=substr(line,1,n-1); p=substr(line,n+1); pwd[s]=p
            }
            first=1
        }
        function json_escape(v) {
            gsub(/\\/, "\\\\", v)
            gsub("\x22", "\\\"", v)
            gsub(/\x08/, "\\b", v)
            gsub(/\x0c/, "\\f", v)
            gsub(/\n/, "\\n", v)
            gsub(/\r/, "\\r", v)
            gsub(/\t/, "\\t", v)
            gsub(/[^\x20-\x7E]/, "", v)
            return v
        }
        {
            if(!first) printf ","
            ssid=json_escape($3);
            p=json_escape(pwd[$3]); if (p == "") p=json_escape(pwd[$3]);
            printf "{\"lat\":%s, \"lon\":%s, \"ssid\":\"%s\", \"password\":\"%s\"}", $1, $2, ssid, p
            first=0
        }'
    fi
fi
echo "]"
} > "$OUT"
api_cache_store cracked_networks "$OUT" || true
cat "$OUT"
rm -f "$OUT" "$CRACKED_MACS" "$SSID_PWD"
exit 0
}

handle_upload_tiles() {
require_post
check_content_length 52428800 "tiles upload"
TILE_ARCHIVE="/tmp/tiles_$$.tar.gz"
TILE_EXTRACT="/tmp/extract_tiles_$$"
dd bs=1k count=51200 of="$TILE_ARCHIVE" 2>/dev/null
if [ ! -s "$TILE_ARCHIVE" ]; then
    rm -f "$TILE_ARCHIVE"
    json_error "empty upload"
    exit 0
fi
if ! tar -tzf "$TILE_ARCHIVE" >/tmp/tiles_list_$$ 2>/dev/null; then
    rm -f "$TILE_ARCHIVE" /tmp/tiles_list_$$
    json_error "invalid tile archive"
    exit 0
fi
if awk 'BEGIN{bad=0} /^\// || /(^|\/)\.\.($|\/)/ {bad=1} END{exit bad?0:1}' /tmp/tiles_list_$$; then
    rm -f "$TILE_ARCHIVE" /tmp/tiles_list_$$
    json_error "unsafe tile archive"
    exit 0
fi
rm -rf "$TILE_EXTRACT"
mkdir -p "$WARD_MNT"/tiles/ "$TILE_EXTRACT"
if ! tar -xzf "$TILE_ARCHIVE" -C "$TILE_EXTRACT" 2>/dev/null; then
    rm -rf "$TILE_EXTRACT"
    rm -f "$TILE_ARCHIVE" /tmp/tiles_list_$$
    json_error "tile extraction failed"
    exit 0
fi

Z_PARENT=$(find "$TILE_EXTRACT" -type d -name '[0-9]*' | head -n 1 | awk -F/ '{OFS="/"; NF--; print $0}')
if [ -n "$Z_PARENT" ] && [ -d "$Z_PARENT" ]; then
    cp -rf "$Z_PARENT"/* "$WARD_MNT"/tiles/ 2>/dev/null
else
    cp -rf "$TILE_EXTRACT"/* "$WARD_MNT"/tiles/ 2>/dev/null
fi

rm -rf "$TILE_EXTRACT"
rm -f "$TILE_ARCHIVE" /tmp/tiles_list_$$
echo '{"status": "ok"}'
}

handle_wigle_upload() {
if [ ! -f "/etc/wardriving_wigle_token" ]; then
    echo '{"success": false, "error": "No WiGLE token configured. Save your API token first."}'
    exit 0
fi
if [ ! -f "$WARD_MNT/wardriving.db" ]; then
    echo '{"success": false, "error": "No database found"}'
    exit 0
fi
TOKEN=$(cat /etc/wardriving_wigle_token)

echo "WigleWifi-1.4,appRelease=1.0,model=OpenWardRivingT,release=1.0,device=OpenWrt,display=OpenWrt,board=OpenWrt,brand=OpenWrt" > /tmp/wigle.csv
echo "MAC,SSID,AuthMode,FirstSeen,Channel,RSSI,CurrentLatitude,CurrentLongitude,AltitudeMeters,AccuracyMeters,Type" >> /tmp/wigle.csv
sqlite3 -separator ',' "$WARD_MNT"/wardriving.db "SELECT mac, ssid, enc, first_seen, channel, rssi, lat, lon, 0, 10, 'WIFI' FROM networks WHERE lat IS NOT NULL AND lat != 'NULL';" >> /tmp/wigle.csv

RES=$(curl -s -m 30 -X POST "https://api.wigle.net/api/v2/network/upload" -H "Authorization: Basic $TOKEN" -H "Accept: application/json" -F "file=@/tmp/wigle.csv")
rm -f /tmp/wigle.csv

if echo "$RES" | grep -q '"success":true'; then
    echo '{"success": true}'
else
    ERR=$(echo "$RES" | tr -d '\n' | sed 's/"/\\"/g')
    echo "{\"success\": false, \"error\": \"WiGLE rejected: $ERR\"}"
fi
exit 0
}

handle_heatmap_data() {
if api_cache_emit heatmap_data 30; then
    return
fi
OUT=$(mktemp /tmp/wardriving_heatmap_XXXXXX) || { echo "[]"; return; }
{
if [ -f "$WARD_MNT"/wardriving.db ]; then
    sqlite3 -separator ',' "$WARD_MNT"/wardriving.db "SELECT lat, lon, rssi FROM networks WHERE lat IS NOT NULL;" 2>/dev/null | awk -F',' '
    BEGIN { printf "[" }
    {
        if (NR>1) printf ",";
        intensity = ($3 + 100) / 60;
        if (intensity < 0) intensity = 0.1;
        if (intensity > 1) intensity = 1.0;
        printf "[%s, %s, %.2f]", $1, $2, intensity
    }
    END { print "]" }'
else
    echo "[]"
fi
} > "$OUT"
api_cache_store heatmap_data "$OUT" || true
cat "$OUT"
rm -f "$OUT"
}

handle_map_data() {
if api_cache_emit map_data 5; then
    return
fi
OUT=$(mktemp /tmp/wardriving_map_data_XXXXXX) || { echo '{"nmea_b64": ""}'; return; }
{
LATEST_NMEA=$(ls -1t "$WARD_MNT"/*.nmea 2>/dev/null | head -n 1)
if [ -f "$LATEST_NMEA" ]; then
    NMEA_B64=$(tail -n 20 "$LATEST_NMEA" | encode_base64 | tr -d '\n')
    echo "{\"nmea_b64\": \"$NMEA_B64\"}"
else
    echo '{"nmea_b64": ""}'
fi
} > "$OUT"
api_cache_store map_data "$OUT" || true
cat "$OUT"
rm -f "$OUT"
}

handle_download_status() {
if [ -f /tmp/dl_status.txt ]; then
    STAT=$(cat /tmp/dl_status.txt)
    echo "{\"status\": \"$STAT\"}"
else
    echo '{"status": "NONE"}'
fi
}

handle_download_bbox() {
N=$(echo "$QUERY_STRING" | grep -o "n=[^&]*" | cut -d= -f2 | tr -cd '0-9.-')
S=$(echo "$QUERY_STRING" | grep -o "s=[^&]*" | cut -d= -f2 | tr -cd '0-9.-')
E=$(echo "$QUERY_STRING" | grep -o "e=[^&]*" | cut -d= -f2 | tr -cd '0-9.-')
W=$(echo "$QUERY_STRING" | grep -o "w=[^&]*" | cut -d= -f2 | tr -cd '0-9.-')
ZMIN=$(echo "$QUERY_STRING" | grep -o "z1=[^&]*" | cut -d= -f2 | tr -cd '0-9')
ZMAX=$(echo "$QUERY_STRING" | grep -o "z2=[^&]*" | cut -d= -f2 | tr -cd '0-9')

# Validate zoom levels
[ -z "$ZMIN" ] && ZMIN=12
[ -z "$ZMAX" ] && ZMAX=16
if [ "$ZMIN" -gt "$ZMAX" ]; then TMP=$ZMIN; ZMIN=$ZMAX; ZMAX=$TMP; fi
[ "$ZMIN" -lt 0 ] && ZMIN=0
[ "$ZMAX" -gt 18 ] && ZMAX=18

# Write a wrapper script with unique PID to avoid race conditions
DL_SCRIPT="/tmp/download_tiles_$$.sh"
cat << 'SCRIPTEOF' > "$DL_SCRIPT"
#!/bin/sh
N="$1"; S="$2"; E="$3"; W="$4"; ZMIN="$5"; ZMAX="$6"; WARD_MNT="$7"
# Basic tile calculation function
lat2tile() {
lat=$1; zoom=$2
awk -v lat=$lat -v z=$zoom 'BEGIN{ pi=3.141592653589793; print int((1.0 - log(tan(lat * pi/180.0) + 1.0/cos(lat * pi/180.0))/pi) / 2.0 * (2^z)) }'
}
lon2tile() {
lon=$1; zoom=$2
awk -v lon=$lon -v z=$zoom 'BEGIN{ print int((lon + 180.0) / 360.0 * (2^z)) }'
}

for z in $(seq $ZMIN $ZMAX); do
X_MIN=$(lon2tile $W $z)
X_MAX=$(lon2tile $E $z)
Y_MIN=$(lat2tile $N $z)
Y_MAX=$(lat2tile $S $z)

for x in $(seq $X_MIN $X_MAX); do
    mkdir -p "$WARD_MNT/tiles/$z/$x"
    for y in $(seq $Y_MIN $Y_MAX); do
        FILE="$WARD_MNT/tiles/$z/$x/$y.png"
        if [ ! -f "$FILE" ]; then
            wget -q -T 10 -O "$FILE" "https://tile.openstreetmap.org/$z/$x/$y.png" || rm -f "$FILE"
            sleep 0.2
        fi
    done
done
done
echo "DONE" > /tmp/dl_status.txt
SCRIPTEOF
chmod +x "$DL_SCRIPT"
echo "RUNNING" > /tmp/dl_status.txt
"$DL_SCRIPT" "$N" "$S" "$E" "$W" "$ZMIN" "$ZMAX" "$WARD_MNT" >/tmp/dl_log_$$.txt 2>&1 &
# Self-cleanup after execution
( wait; rm -f "$DL_SCRIPT" ) &

echo '{"status": "started"}'
}

handle_list_files() {
echo "["
FIRST=1

if [ -f "$WARD_MNT"/master.hc2200 ]; then
    NAME="master.hc2200"
    SIZE=$(du -h "$WARD_MNT/master.hc2200" | awk '{print $1}')
    DATE=$(date -r "$WARD_MNT/master.hc2200" "+%Y-%m-%d %H:%M:%S" 2>/dev/null || echo "Unknown")
    TOTAL_NETS=$(wc -l < "$WARD_MNT"/master_essid.txt 2>/dev/null || echo 0)
    NETS=$(head -n 5 "$WARD_MNT"/master_essid.txt 2>/dev/null | tr '\n' ',' | sed 's/,$//' | sed 's/\\/\\\\/g' | sed 's/"/\\"/g')
    if [ "$TOTAL_NETS" -gt 5 ]; then NETS="$NETS... (+$((TOTAL_NETS - 5)))"; fi
    [ -z "$NETS" ] && NETS="No networks / Empty"
    echo "{\"name\": \"$NAME\", \"size\": \"$SIZE\", \"date\": \"$DATE\", \"nets\": \"$NETS\", \"total_nets\": $TOTAL_NETS}"
    FIRST=0
fi

for f in $(ls -1r "$WARD_MNT"/*.pcapng 2>/dev/null); do
    NAME=$(basename "$f")
    SIZE=$(du -h "$f" | awk '{print $1}')
    DATE=$(date -r "$f" "+%Y-%m-%d %H:%M:%S")
    TXT="${f%.pcapng}.txt"
    TOTAL_NETS=$(wc -l < "$TXT" 2>/dev/null || echo 0)
    NETS=$(head -n 5 "$TXT" 2>/dev/null | tr '\n' ',' | sed 's/,$//' | sed 's/\\/\\\\/g' | sed 's/"/\\"/g')
    if [ "$TOTAL_NETS" -gt 5 ]; then NETS="$NETS... (+$((TOTAL_NETS - 5)))"; fi
    [ -z "$NETS" ] && NETS="No networks / Empty"
    [ $FIRST -eq 0 ] && echo ","
    echo "{\"name\": \"$NAME\", \"size\": \"$SIZE\", \"date\": \"$DATE\", \"nets\": \"$NETS\", \"total_nets\": $TOTAL_NETS}"
    FIRST=0
done
echo "]"
}

handle_delete_file() {
FILE=$(echo "$QUERY_STRING" | grep -o "file=[^&]*" | cut -d= -f2)
if [ -n "$FILE" ]; then
    # Sanitize: keep only alphanumeric, dot, underscore, dash. Reject if contains /
    SAFE=$(echo "$FILE" | sed -e 's/[^a-zA-Z0-9._-]//g')
    if [ "$SAFE" != "$FILE" ] || echo "$FILE" | grep -q '/'; then
        echo '{"status": "error", "reason": "invalid filename"}'
        exit 0
    fi
    BASENAME=$(basename "$SAFE")
    # Safety: only allow deletion within $WARD_MNT
    TARGET="$WARD_MNT/$BASENAME"
    case "$(readlink -f "$TARGET" 2>/dev/null || realpath "$TARGET" 2>/dev/null || echo "$TARGET")" in
        "$WARD_MNT"/*)
            rm -f "$TARGET"
            rm -f "$WARD_MNT/${BASENAME%.pcapng}.txt"
            rm -f "$WARD_MNT/${BASENAME%.pcapng}.nmea"
            echo '{"status": "deleted"}'
            ;;
        *)
            echo '{"status": "error", "reason": "path traversal blocked"}'
            ;;
    esac
else
    echo '{"status": "error"}'
fi
}
