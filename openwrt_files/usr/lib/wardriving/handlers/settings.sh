#!/bin/sh
# shellcheck shell=sh

INIT_SCRIPT="${WARDRIVING_INIT_SCRIPT:-/etc/init.d/wardriving}"
WPS_BUTTON_SCRIPT="${WARDRIVING_WPS_BUTTON_SCRIPT:-/etc/rc.button/wps}"
RFKILL_BUTTON_SCRIPT="${WARDRIVING_RFKILL_BUTTON_SCRIPT:-/etc/rc.button/rfkill}"

handle_start() {
if [ ! -x "$INIT_SCRIPT" ]; then
    json_error "wardriving init script is not executable"
    return
fi
if "$INIT_SCRIPT" start >/tmp/wardriving_init_start.log 2>&1; then
    api_cache_clear_all
    echo '{"status": "started"}'
else
    json_error "wardriving init start failed"
fi
}

handle_stop() {
if [ ! -x "$INIT_SCRIPT" ]; then
    json_error "wardriving init script is not executable"
    return
fi
if "$INIT_SCRIPT" stop >/tmp/wardriving_init_stop.log 2>&1; then
    api_cache_clear_all
    echo '{"status": "stopped"}'
else
    json_error "wardriving init stop failed"
fi
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
api_cache_clear_all
RESTARTED="false"
if [ "$MODE" != "$OLD_MODE" ] && pgrep -f "hcxdumptool.*wlan0mon" >/dev/null 2>&1; then
    pkill -TERM -f "hcxdumptool.*wlan0mon" 2>/dev/null || true
    RESTARTED="true"
fi
echo "{\"status\":\"saved\",\"mode\":\"$MODE\",\"capture_restarted\":$RESTARTED}"
}

handle_get_hw() {
LEDS=$(ls -1 /sys/class/leds/ 2>/dev/null | awk 'BEGIN{printf "["} {if (NR>1) printf ","; printf "\"%s\"", $1} END{print "]"}')
CUR_LED=$(grep "/sys/class/leds/" "$INIT_SCRIPT" 2>/dev/null | head -n 1 | sed -n 's|.*/sys/class/leds/\([^/]*\)/.*|\1|p')
[ -z "$CUR_LED" ] && CUR_LED="green:wps"
CUR_BTN="none"
if grep -q "wardriving_core" "$WPS_BUTTON_SCRIPT" 2>/dev/null; then CUR_BTN="wps"; fi
if grep -q "wardriving_core" "$RFKILL_BUTTON_SCRIPT" 2>/dev/null; then CUR_BTN="wifi"; fi

CUR_MODE="active"
if [ -f "$MODE_FILE" ]; then CUR_MODE=$(cat "$MODE_FILE"); fi
KEEP="false"; [ -f /etc/wardriving_keep_pcap.txt ] && KEEP="true"
echo "{\"leds\": $LEDS, \"current_led\": \"$CUR_LED\", \"current_button\": \"$CUR_BTN\", \"mode\": \"$CUR_MODE\", \"keep_pcap\": \"$KEEP\"}"
}

handle_set_processing() {
MODE=$(query_param extraction_mode | tr -cd 'a-z')
CRACKING=$(query_param gpu_cracking_enabled | tr -cd '01' | head -c 1)
S_URL=$(query_param url | sed 's/%3A/:/g; s/%3a/:/g; s/%2F/\//g; s/%2f/\//g; s/%2D/-/g; s/%2d/-/g; s/%5F/_/g; s/%5f/_/g')

if [ -z "$MODE" ]; then
    EN=$(query_param en | tr -cd '01' | head -c 1)
    if [ "$EN" = "1" ]; then MODE="remote"; else MODE="local"; fi
fi
case "$MODE" in
    local|remote) ;;
    *) json_error "invalid extraction mode"; exit 0 ;;
esac

if [ -z "$CRACKING" ]; then
    CRACKING="1"
    [ -f "$GPU_CRACKING_FILE" ] && CRACKING=$(cat "$GPU_CRACKING_FILE" | tr -cd '01' | head -c 1)
    case "$CRACKING" in 0|1) ;; *) CRACKING="1" ;; esac
fi
case "$CRACKING" in
    0|1) ;;
    *) json_error "invalid gpu cracking value"; exit 0 ;;
esac

if { [ "$MODE" = "remote" ] || [ "$CRACKING" = "1" ]; } && [ -z "$S_URL" ]; then
    json_error "remote url required"
    exit 0
fi

write_processing_setting "$EXTRACTION_MODE_FILE" "$MODE" || { json_error "could not save extraction mode"; exit 0; }
write_processing_setting "$GPU_CRACKING_FILE" "$CRACKING" || { json_error "could not save gpu cracking"; exit 0; }
write_processing_setting "$REMOTE_URL_FILE" "$S_URL" || { json_error "could not save remote url"; exit 0; }
api_cache_clear_all
if [ "$MODE" = "remote" ] || [ "$CRACKING" = "1" ]; then
    write_processing_setting "$REMOTE_ENABLED_FILE" "1" || true
else
    write_processing_setting "$REMOTE_ENABLED_FILE" "0" || true
fi
echo "{\"status\":\"saved\",\"extraction_mode\":\"$MODE\",\"gpu_cracking_enabled\":\"$CRACKING\",\"url\":\"$S_URL\"}"
}

handle_get_processing() {
remote_read_config
LEGACY_EN="0"
[ "$EXTRACTION_MODE" = "remote" ] && LEGACY_EN="1"
echo "{\"enabled\":\"$LEGACY_EN\",\"extraction_mode\":\"$EXTRACTION_MODE\",\"gpu_cracking_enabled\":\"$GPU_CRACKING_ENABLED\",\"url\":\"$REMOTE_URL\"}"
}

write_processing_setting() {
_path="$1"
_value="$2"
_tmp=$(mktemp /tmp/wardriving_setting_XXXXXX) || return 1
printf "%s\n" "$_value" > "$_tmp" || { rm -f "$_tmp"; return 1; }
mv -f "$_tmp" "$_path"
}

handle_set_pcap_retention() {
KEEP=$(echo "$QUERY_STRING" | grep -o "keep=[^&]*" | cut -d= -f2 | tr -cd 'a-zA-Z01')
case "$KEEP" in
    true|1) touch /etc/wardriving_keep_pcap.txt; KEEP="true" ;;
    false|0) rm -f /etc/wardriving_keep_pcap.txt; KEEP="false" ;;
    *) json_error "invalid keep value"; exit 0 ;;
esac
echo "{\"status\": \"saved\", \"keep\": \"$KEEP\"}"
}

handle_set_hw() {
LED=$(echo "$QUERY_STRING" | grep -o "led=[^&]*" | cut -d= -f2 | sed 's/%3A/:/g' | sed 's/[^a-zA-Z0-9:._-]//g')
BTN=$(echo "$QUERY_STRING" | grep -o "btn=[^&]*" | cut -d= -f2)
MODE=$(echo "$QUERY_STRING" | grep -o "mode=[^&]*" | cut -d= -f2 | tr -cd 'a-z')
case "$MODE" in active|passive|smart) ;; *) MODE="active" ;; esac
[ -z "$LED" ] && { json_error "invalid led"; exit 0; }
echo "$MODE" > "$MODE_FILE"

# Atomic sed: write to temp, then mv
TMP_INIT=$(mktemp /tmp/wardriving_init_XXXXXX)
if sed "s|/sys/class/leds/[^/]*/|/sys/class/leds/$LED/|g" "$INIT_SCRIPT" > "$TMP_INIT"; then
    chmod +x "$TMP_INIT"
    mv "$TMP_INIT" "$INIT_SCRIPT"
else
    rm -f "$TMP_INIT"
    json_error "init update failed"
    exit 0
fi
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
chmod +x "$TMP_WPS"
mv "$TMP_WPS" "$WPS_BUTTON_SCRIPT"
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
chmod +x "$TMP_RFKILL"
mv "$TMP_RFKILL" "$RFKILL_BUTTON_SCRIPT"
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
    mv "$TMP_BTN" "$WPS_BUTTON_SCRIPT"
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
    mv "$TMP_BTN" "$RFKILL_BUTTON_SCRIPT"
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
{
    [ -f "$WARD_MNT"/master_essid.txt ] && cat "$WARD_MNT"/master_essid.txt
    for _ssid_file in "$WARD_MNT"/wardriving_*.txt; do
        [ -f "$_ssid_file" ] && cat "$_ssid_file"
    done
} 2>/dev/null | sort -u | awk 'FILENAME == ARGV[1] {rem[$0]; next} {if (!($0 in rem)) print $0}' /etc/wardriving_removed.txt - > /tmp/new_excl
cat /etc/wardriving_excluded.txt >> /tmp/new_excl
sort -u /tmp/new_excl > /etc/wardriving_excluded.txt
rm -f /tmp/new_excl

awk 'BEGIN {print "["} {if (NR>1) print ","; gsub(/\\/, "\\\\"); gsub(/"/, "\\\""); printf "\"%s\"", $0} END {print "\n]"}' /etc/wardriving_excluded.txt
}

handle_add_exclusion() {
RAW_SSID=$(echo "$QUERY_STRING" | awk -F'ssid=' '{print $2}' | cut -d'&' -f1)
SSID=$(url_decode "$RAW_SSID")
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
SSID=$(url_decode "$RAW_SSID")
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
