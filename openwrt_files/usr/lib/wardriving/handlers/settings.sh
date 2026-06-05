#!/bin/sh
# shellcheck shell=sh

handle_start() {
/etc/init.d/wardriving start >/dev/null 2>&1
echo '{"status": "started"}'
}

handle_stop() {
/etc/init.d/wardriving stop >/dev/null 2>&1
echo '{"status": "stopped"}'
}

handle_get_mode() {
CUR_MODE="active"
if [ -f "$MODE_FILE" ]; then CUR_MODE=$(cat "$MODE_FILE" | tr -cd 'a-z'); fi
case "$CUR_MODE" in active|passive|smart) ;; *) CUR_MODE="active" ;; esac
echo "{\"mode\":\"$CUR_MODE\"}"
}

handle_set_mode() {
MODE=$(echo "$QUERY_STRING" | grep -o "mode=[^&]*" | cut -d= -f2 | tr -cd 'a-z')
case "$MODE" in active|passive|smart) ;; *) json_error "invalid mode"; exit 0 ;; esac
OLD_MODE="active"
if [ -f "$MODE_FILE" ]; then OLD_MODE=$(cat "$MODE_FILE" | tr -cd 'a-z'); fi
echo "$MODE" > "$MODE_FILE"
RESTARTED="false"
if [ "$MODE" != "$OLD_MODE" ] && pgrep -f "hcxdumptool.*wlan0mon" >/dev/null 2>&1; then
    pkill -TERM -f "hcxdumptool.*wlan0mon" 2>/dev/null || true
    RESTARTED="true"
fi
echo "{\"status\":\"saved\",\"mode\":\"$MODE\",\"capture_restarted\":$RESTARTED}"
}

handle_get_hw() {
LEDS=$(ls -1 /sys/class/leds/ 2>/dev/null | awk 'BEGIN{printf "["} {if (NR>1) printf ","; printf "\"%s\"", $1} END{print "]"}')
CUR_LED=$(grep "/sys/class/leds/" /etc/init.d/wardriving | head -n 1 | sed -n 's|.*/sys/class/leds/\([^/]*\)/.*|\1|p')
[ -z "$CUR_LED" ] && CUR_LED="green:wps"
CUR_BTN="none"
if grep -q "wardriving_core" /etc/rc.button/wps 2>/dev/null; then CUR_BTN="wps"; fi
if grep -q "wardriving_core" /etc/rc.button/rfkill 2>/dev/null; then CUR_BTN="wifi"; fi

CUR_MODE="active"
if [ -f "$MODE_FILE" ]; then CUR_MODE=$(cat "$MODE_FILE"); fi
KEEP="false"; [ -f /etc/wardriving_keep_pcap.txt ] && KEEP="true"
echo "{\"leds\": $LEDS, \"current_led\": \"$CUR_LED\", \"current_button\": \"$CUR_BTN\", \"mode\": \"$CUR_MODE\", \"keep_pcap\": \"$KEEP\"}"
}

handle_set_processing() {
EN=$(echo "$QUERY_STRING" | awk -F"&en=" '{print $2}' | awk -F"&" '{print $1}')
if [ -z "$EN" ]; then EN=$(echo "$QUERY_STRING" | awk -F"?en=" '{print $2}' | awk -F"&" '{print $1}'); fi
S_URL=$(echo "$QUERY_STRING" | grep -o "url=[^&]*" | cut -d= -f2 | sed 's/%3A/:/g; s/%2F/\//g')
echo "$EN" > /etc/wardriving_remote_enabled
echo "$S_URL" > /etc/wardriving_remote_url
echo '{"status": "saved"}'
}

handle_get_processing() {
EN="0"; S_URL=""
[ -f /etc/wardriving_remote_enabled ] && EN=$(cat /etc/wardriving_remote_enabled)
[ -f /etc/wardriving_remote_url ] && S_URL=$(cat /etc/wardriving_remote_url)
EN=$(echo "$EN" | tr -d "\n"); S_URL=$(echo "$S_URL" | tr -d "\n"); echo "{\"enabled\": \"$EN\", \"url\": \"$S_URL\"}"
}

handle_set_pcap_retention() {
KEEP=$(echo "$QUERY_STRING" | grep -o "keep=[^&]*" | cut -d= -f2)
if [ "$KEEP" = "true" ]; then touch /etc/wardriving_keep_pcap.txt; else rm -f /etc/wardriving_keep_pcap.txt; fi
echo '{"status": "saved"}'
}

handle_set_hw() {
LED=$(echo "$QUERY_STRING" | grep -o "led=[^&]*" | cut -d= -f2 | sed 's/%3A/:/g' | sed 's/[^a-zA-Z0-9:._-]//g')
BTN=$(echo "$QUERY_STRING" | grep -o "btn=[^&]*" | cut -d= -f2)
MODE=$(echo "$QUERY_STRING" | grep -o "mode=[^&]*" | cut -d= -f2 | tr -cd 'a-z')
case "$MODE" in active|passive|smart) ;; *) MODE="active" ;; esac
echo "$MODE" > "$MODE_FILE"

# Atomic sed: write to temp, then mv
TMP_INIT=$(mktemp /tmp/wardriving_init_XXXXXX)
sed "s|/sys/class/leds/[^/]*/|/sys/class/leds/$LED/|g" /etc/init.d/wardriving > "$TMP_INIT" && mv "$TMP_INIT" /etc/init.d/wardriving
rm -f "$TMP_INIT"

# Always restore defaults first (atomic via temp + mv)
TMP_WPS=$(mktemp /tmp/wardriving_wps_XXXXXX)
cat << 'EOF_RESTORE' > "$TMP_WPS"
#!/bin/sh
[ "$ACTION" = "pressed" ] && exit 5
for script in /etc/rc.wps/*; do
	[ -x "$script" ] || continue
	"$script" && break
done
EOF_RESTORE
mv "$TMP_WPS" /etc/rc.button/wps
rm -f "$TMP_WPS"

TMP_RFKILL=$(mktemp /tmp/wardriving_rfkill_XXXXXX)
cat << 'EOF_RESTORE' > "$TMP_RFKILL"
#!/bin/sh
[ "${ACTION}" = "released" -o -n "${TYPE}" ] || exit 0
. /lib/functions.sh
rfkill_state=0
wifi_rfkill_set() { uci set wireless.$1.disabled=$rfkill_state; }
wifi_rfkill_check() {
	local disabled; config_get disabled $1 disabled
	[ "$disabled" = "1" ] || rfkill_state=1
}
config_load wireless
case "${TYPE}" in
"switch") [ "${ACTION}" = "released" ] && rfkill_state=1 ;;
*) config_foreach wifi_rfkill_check wifi-device ;;
esac
config_foreach wifi_rfkill_set wifi-device
uci commit wireless; wifi up
return 0
EOF_RESTORE
mv "$TMP_RFKILL" /etc/rc.button/rfkill
rm -f "$TMP_RFKILL"

if [ "$BTN" = "wps" ]; then
    TMP_BTN=$(mktemp /tmp/wardriving_btn_XXXXXX)
    cat << 'EOF2' > "$TMP_BTN"
#!/bin/sh
[ "${ACTION}" = "released" ] || exit 0
if pgrep -f "wardriving_core.sh" >/dev/null; then
/etc/init.d/wardriving stop
else
/etc/init.d/wardriving start
fi
EOF2
    chmod +x "$TMP_BTN"
    mv "$TMP_BTN" /etc/rc.button/wps
    rm -f "$TMP_BTN"
elif [ "$BTN" = "wifi" ]; then
    TMP_BTN=$(mktemp /tmp/wardriving_btn_XXXXXX)
    cat << 'EOF2' > "$TMP_BTN"
#!/bin/sh
[ "${ACTION}" = "released" ] || exit 0
if pgrep -f "wardriving_core.sh" >/dev/null; then
/etc/init.d/wardriving stop
else
/etc/init.d/wardriving start
fi
EOF2
    chmod +x "$TMP_BTN"
    mv "$TMP_BTN" /etc/rc.button/rfkill
    rm -f "$TMP_BTN"
fi
echo '{"status": "saved"}'
}

handle_save_wigle_token() {
require_post
check_content_length 4096 "WiGLE token"
WIGLE_RAW=$(dd bs=4k count=1 2>/dev/null | tr -d '\r\n\t ')
# Validate: WiGLE API tokens are Base64-encoded "user:apikey" strings (only base64 chars)
case "$WIGLE_RAW" in
    *[!A-Za-z0-9+/=]*|'')
        json_error "invalid WiGLE token format"
        exit 0
        ;;
esac
[ "${#WIGLE_RAW}" -lt 10 ] && { json_error "token too short"; exit 0; }
printf '%s' "$WIGLE_RAW" > /etc/wardriving_wigle_token
chmod 600 /etc/wardriving_wigle_token
echo '{"status": "ok"}'
}

handle_pwnagotchi_status() {
# Proxy to pwnagotchi REST API (typically on port 8080)
PWN_HOST="127.0.0.1:8080"
RES=$(curl -s -m 2 "http://$PWN_HOST/api/v1/status" 2>/dev/null || echo '{}')
echo "$RES"
}

handle_get_targets() {
touch /etc/wardriving_targets.txt
awk 'BEGIN {print "["} {if (NR>1) print ","; printf "\"%s\"", $0} END {print "\n]"}' /etc/wardriving_targets.txt
}

handle_add_target() {
MAC=$(echo "$QUERY_STRING" | awk -F'mac=' '{print $2}' | cut -d'&' -f1 | sed 's/%3A/:/g' | sed 's/%3a/:/g')
if [ -n "$MAC" ]; then
    touch /etc/wardriving_targets.txt
    if ! grep -Fxq "$MAC" /etc/wardriving_targets.txt; then
        echo "$MAC" >> /etc/wardriving_targets.txt
    fi
    echo '{"status":"added"}'
else
    echo '{"status":"error"}'
fi
}

handle_remove_target() {
MAC=$(echo "$QUERY_STRING" | awk -F'mac=' '{print $2}' | cut -d'&' -f1 | sed 's/%3A/:/g' | sed 's/%3a/:/g')
if [ -n "$MAC" ]; then
    touch /etc/wardriving_targets.txt
    awk -v m="$MAC" '$0!=m' /etc/wardriving_targets.txt > /tmp/tmp_tm && mv /tmp/tmp_tm /etc/wardriving_targets.txt
    echo '{"status":"removed"}'
else
    echo '{"status":"error"}'
fi
}

handle_check_targets() {
if [ -f "$WARD_MNT"/wardriving.db ] && [ -s /etc/wardriving_targets.txt ]; then
    # Sanitize MACs: keep only hex digits and colons, then build SQL
    COND=$(sed "s/[^a-fA-F0-9:]//g" /etc/wardriving_targets.txt | awk 'NF {printf "mac LIKE '"'"'%s%%'"'"' OR ", $1}' | sed 's/ OR $//')
    [ -z "$COND" ] && { echo "[]"; exit 0; }
    sqlite3 -json "$WARD_MNT"/wardriving.db "SELECT mac, ssid FROM networks WHERE ($COND) AND last_seen >= datetime('now', '-2 minutes');" 2>/dev/null || echo "[]"
else
    echo "[]"
fi
}

handle_get_exclusions() {
touch /etc/wardriving_excluded.txt /etc/wardriving_removed.txt
cat "$WARD_MNT"/*.txt 2>/dev/null | sort -u | awk 'FILENAME == ARGV[1] {rem[$0]; next} {if (!($0 in rem)) print $0}' /etc/wardriving_removed.txt - > /tmp/new_excl
cat /etc/wardriving_excluded.txt >> /tmp/new_excl
sort -u /tmp/new_excl > /etc/wardriving_excluded.txt
rm -f /tmp/new_excl

awk 'BEGIN {print "["} {if (NR>1) print ","; gsub(/\\/, "\\\\"); gsub(/"/, "\\\""); printf "\"%s\"", $0} END {print "\n]"}' /etc/wardriving_excluded.txt
}

handle_add_exclusion() {
RAW_SSID=$(echo "$QUERY_STRING" | awk -F'ssid=' '{print $2}' | cut -d'&' -f1)
SSID=$(echo "$RAW_SSID" | awk 'BEGIN{c2x["0"]="0";c2x["1"]="1";c2x["2"]="2";c2x["3"]="3";c2x["4"]="4";c2x["5"]="5";c2x["6"]="6";c2x["7"]="7";c2x["8"]="8";c2x["9"]="9";c2x["A"]="10";c2x["B"]="11";c2x["C"]="12";c2x["D"]="13";c2x["E"]="14";c2x["F"]="15";c2x["a"]="10";c2x["b"]="11";c2x["c"]="12";c2x["d"]="13";c2x["e"]="14";c2x["f"]="15"} {gsub(/\+/," "); res=""; i=1; while(i<=length($0)){c=substr($0,i,1); if(c=="%"){hex=substr($0,i+1,2); val=c2x[substr(hex,1,1)]*16+c2x[substr(hex,2,1)]; res=res sprintf("%c",val); i+=2} else{res=res c} i++} print res}')
if [ -n "$SSID" ]; then
    touch /etc/wardriving_excluded.txt /etc/wardriving_removed.txt
    awk -v s="$SSID" '$0!=s' /etc/wardriving_removed.txt > /tmp/tmp_rm && mv /tmp/tmp_rm /etc/wardriving_removed.txt
    if ! grep -Fxq "$SSID" /etc/wardriving_excluded.txt; then
        echo "$SSID" >> /etc/wardriving_excluded.txt
    fi
    echo '{"status":"added"}'
else
    echo '{"status":"error"}'
fi
}

handle_remove_exclusion() {
RAW_SSID=$(echo "$QUERY_STRING" | awk -F'ssid=' '{print $2}' | cut -d'&' -f1)
SSID=$(echo "$RAW_SSID" | awk 'BEGIN{c2x["0"]="0";c2x["1"]="1";c2x["2"]="2";c2x["3"]="3";c2x["4"]="4";c2x["5"]="5";c2x["6"]="6";c2x["7"]="7";c2x["8"]="8";c2x["9"]="9";c2x["A"]="10";c2x["B"]="11";c2x["C"]="12";c2x["D"]="13";c2x["E"]="14";c2x["F"]="15";c2x["a"]="10";c2x["b"]="11";c2x["c"]="12";c2x["d"]="13";c2x["e"]="14";c2x["f"]="15"} {gsub(/\+/," "); res=""; i=1; while(i<=length($0)){c=substr($0,i,1); if(c=="%"){hex=substr($0,i+1,2); val=c2x[substr(hex,1,1)]*16+c2x[substr(hex,2,1)]; res=res sprintf("%c",val); i+=2} else{res=res c} i++} print res}')
if [ -n "$SSID" ]; then
    touch /etc/wardriving_excluded.txt /etc/wardriving_removed.txt
    awk -v s="$SSID" '$0!=s' /etc/wardriving_excluded.txt > /tmp/tmp_rm && mv /tmp/tmp_rm /etc/wardriving_excluded.txt
    if ! grep -Fxq "$SSID" /etc/wardriving_removed.txt; then
        echo "$SSID" >> /etc/wardriving_removed.txt
    fi
    echo '{"status":"removed"}'
else
    echo '{"status":"error"}'
fi
}
