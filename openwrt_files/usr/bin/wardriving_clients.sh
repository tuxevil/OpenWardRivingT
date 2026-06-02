#!/bin/sh
# Extract associated Wi-Fi clients/stations from a pcapng into wardriving.db.

set -u

PCAP="${1:-}"
CSV_IN="${2:-}"
DB="${3:-/mnt/wardriving/wardriving.db}"

[ -f "$PCAP" ] || exit 0
command -v sqlite3 >/dev/null 2>&1 || exit 0
command -v hcxpcapngtool >/dev/null 2>&1 || exit 0

RAW="/tmp/clients_raw_$$.txt"
AP="/tmp/clients_ap_$$.tsv"
SQL="/tmp/clients_$$.sql"
CSV="$CSV_IN"
LIVE_GPS="/tmp/clients_livegps_$$.tsv"

[ -n "$CSV" ] || CSV="/tmp/clients_csv_$$.txt"
if [ ! -s "$CSV" ]; then
    hcxpcapngtool --csv="$CSV" "$PCAP" >/dev/null 2>&1 || true
fi
hcxpcapngtool --raw-out="$RAW" "$PCAP" >/dev/null 2>&1 || true
[ -s "$RAW" ] || { rm -f "$RAW" "$AP" "$SQL"; exit 0; }

sqlite3 "$DB" "CREATE TABLE IF NOT EXISTS clients (client_mac TEXT, ap_mac TEXT, ssid TEXT, channel INTEGER, lat REAL, lon REAL, first_seen DATETIME, last_seen DATETIME, rssi INTEGER, frame_type TEXT, seen_mode TEXT, PRIMARY KEY(client_mac, ap_mac)); CREATE INDEX IF NOT EXISTS idx_clients_last_seen ON clients(last_seen); CREATE INDEX IF NOT EXISTS idx_clients_ap ON clients(ap_mac);" >/dev/null 2>&1

GPS_MAX_AGE="${WARDRIVING_GPS_MAX_AGE:-20}"
GPS_NOW=$(date +%s 2>/dev/null || echo 0)
GPS_MOD=0
[ -s /tmp/vGPS_last ] && GPS_MOD=$(date -r /tmp/vGPS_last +%s 2>/dev/null || echo 0)
GPS_AGE=$((GPS_NOW - GPS_MOD))
if [ -s /tmp/vGPS_last ] && [ "$GPS_MOD" -gt 0 ] && [ "$GPS_AGE" -le "$GPS_MAX_AGE" ]; then
    awk -F',' '
    function dec(raw,dir,islat, deg,min,val) {
        if (raw == "") return ""
        deg = islat ? substr(raw,1,2) : substr(raw,1,3)
        min = islat ? substr(raw,3) : substr(raw,4)
        val = deg + (min / 60)
        if (dir == "S" || dir == "W") val = -val
        return val
    }
    /^\$[A-Z]{2}RMC/ && $3 == "A" { lat=dec($4,$5,1); lon=dec($6,$7,0) }
    /^\$[A-Z]{2}GGA/ && $7 != "0" { lat=dec($3,$4,1); lon=dec($5,$6,0) }
    END { if (lat != "" && lon != "") printf "%.8f\t%.8f\n", lat, lon }
    ' /tmp/vGPS_last > "$LIVE_GPS"
else
    : > "$LIVE_GPS"
fi

: > "$AP"
if [ -s "$CSV" ]; then
    awk -F'\t' '{
        mac=tolower($2); ssid=$3; chan=$8; rssi=$9; gpsd=$11
        if (mac !~ /^[0-9a-f][0-9a-f](:[0-9a-f][0-9a-f]){5}$/) next
        lat="NULL"; lon="NULL"; split(gpsd,g," "); if(g[1]!="") lat=g[1]; if(g[2]!="") lon=g[2]
        gsub(/\047/, "\047\047", ssid); gsub(/\t/, " ", ssid)
        printf "%s\t%s\t%d\t%d\t%s\t%s\n", mac, ssid, chan, rssi, lat, lon
    }' "$CSV" > "$AP"
fi

awk -F'\t' -v apfile="$AP" -v gpsfile="$LIVE_GPS" '
function h(c, n,i,p) { n=0; for(i=1;i<=length(c);i++){p=index("0123456789abcdef",tolower(substr(c,i,1))); if(p<1)return 0; n=n*16+p-1} return n }
function mac(s) { return tolower(substr(s,1,2) ":" substr(s,3,2) ":" substr(s,5,2) ":" substr(s,7,2) ":" substr(s,9,2) ":" substr(s,11,2)) }
function good(m, o) { o=h(substr(m,1,2)); return m!="ff:ff:ff:ff:ff:ff" && o%2==0 && m ~ /^[0-9a-f][0-9a-f](:[0-9a-f][0-9a-f]){5}$/ }
function esc(s){gsub(/\047/,"\047\047",s); return s}
BEGIN {
    while ((getline line < apfile) > 0) {
        split(line,a,"\t"); ap=a[1]; ssid[ap]=a[2]; chan[ap]=a[3]; arssi[ap]=a[4]; lat[ap]=a[5]; lon[ap]=a[6]
        if (dlat=="" && a[5]!="NULL" && a[6]!="NULL") { dlat=a[5]; dlon=a[6] }
    }
    close(apfile)
    if (dlat=="" && (getline line < gpsfile) > 0) { split(line,g,"\t"); dlat=g[1]; dlon=g[2] }
    close(gpsfile)
}
{
    split($0,p,"*"); frame=p[3]
    if (length(frame) < 80) next
    rt=h(substr(frame,5,2)) + h(substr(frame,7,2))*256
    dot=substr(frame,rt*2+1)
    if (length(dot) < 48) next
    b1=h(substr(dot,1,2)); b2=h(substr(dot,3,2))
    type=int(b1/4)%4; stype=int(b1/16); tods=b2%2; fromds=int(b2/2)%2
    a1=mac(substr(dot,9,12)); a2=mac(substr(dot,21,12)); a3=mac(substr(dot,33,12))
    client=""; ap=""; ftype=""
    if (type==2) {
        if (tods==1 && fromds==0) { client=a2; ap=a1; ftype="data_to_ap" }
        else if (tods==0 && fromds==1) { client=a1; ap=a2; ftype="data_from_ap" }
    } else if (type==0 && (stype==0 || stype==2 || stype==11)) {
        client=a2; ap=a1
        if (stype==11) ftype="auth"; else ftype="assoc"
    }
    if (!good(client) || !good(ap) || client==ap) next
    key=client "\t" ap
    cnt[key]++; ft[key]=ftype
}
END {
    for (key in cnt) {
        split(key,k,"\t"); c=k[1]; ap=k[2]
        s=esc(ssid[ap]); if (s=="") s=ap
        ch=chan[ap]; if (ch=="") ch=0
        r=arssi[ap]; if (r=="") r=0
        la=lat[ap]; if (la=="") la=dlat; if (la=="") la="NULL"
        lo=lon[ap]; if (lo=="") lo=dlon; if (lo=="") lo="NULL"
        printf "INSERT INTO clients (client_mac, ap_mac, ssid, channel, lat, lon, first_seen, last_seen, rssi, frame_type, seen_mode) VALUES (\047%s\047,\047%s\047,\047%s\047,%d,%s,%s,datetime(\047now\047),datetime(\047now\047),%d,\047%s\047,\047capture\047) ON CONFLICT(client_mac, ap_mac) DO UPDATE SET ssid=COALESCE(NULLIF(EXCLUDED.ssid,\047\047),clients.ssid), channel=EXCLUDED.channel, lat=EXCLUDED.lat, lon=EXCLUDED.lon, last_seen=EXCLUDED.last_seen, rssi=EXCLUDED.rssi, frame_type=EXCLUDED.frame_type, seen_mode=EXCLUDED.seen_mode;\n", c, ap, s, ch, la, lo, r, ft[key]
    }
}' "$RAW" > "$SQL"

[ -s "$SQL" ] && nice -n 10 sqlite3 "$DB" < "$SQL" 2>/dev/null || true
rm -f "$RAW" "$AP" "$SQL" "$LIVE_GPS"
[ "$CSV" = "$CSV_IN" ] || rm -f "$CSV"
