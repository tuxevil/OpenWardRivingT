#!/bin/sh
# Shared CGI helpers for OpenWardRivingT.

: "${QUERY_STRING:=}"
: "${REQUEST_METHOD:=GET}"

TOKEN_FILE="${WARDRIVING_TOKEN_FILE:-/etc/wardriving_api_token}"
# shellcheck disable=SC2034 # Used by sourced handler modules.
WARD_MNT="${WARDRIVING_MNT:-/mnt/wardriving}"
# shellcheck disable=SC2034 # Used by sourced handler modules.
MODE_FILE="${WARDRIVING_MODE_FILE:-/etc/wardriving_mode.txt}"
API_CACHE_DIR="${WARDRIVING_API_CACHE_DIR:-/tmp/wardriving_api_cache}"

query_param() {
    _qp_key="$1"
    printf "%s" "$QUERY_STRING" | tr '&' '\n' | awk -F= -v key="$_qp_key" '$1 == key {print substr($0, index($0, "=") + 1); exit}'
}

ACTION=$(query_param action)
TOKEN=$(query_param token)

emit_json_headers() {
    echo "Content-Type: application/json"
    echo "Access-Control-Allow-Origin: *"
    echo ""
}

json_error() {
    echo "{\"status\": \"error\", \"reason\": \"$1\"}"
}

require_post() {
    if [ "$REQUEST_METHOD" != "POST" ]; then
        json_error "POST required"
        exit 0
    fi
}

check_content_length() {
    _max="$1"
    _label="$2"
    _len="${CONTENT_LENGTH:-0}"
    case "$_len" in
        ''|*[!0-9]*) _len=0 ;;
    esac
    if [ "$_len" -gt "$_max" ]; then
        json_error "$_label too large"
        exit 0
    fi
}

is_protected_action() {
    case "$1" in
        start|stop|delete_file|set_mode|get_mode|set_hw|set_processing|set_pcap_retention|save_wigle_token|wigle_upload|upload_tiles|upload_potfile|pwnagotchi_sync|replay_start|replay_status|replay_seek|replay_pause|replay_stop|replay_report|replay_discovered|networks_map|clients_map|add_target|remove_target|add_exclusion|remove_exclusion|download_all|download_bbox|export_gpx|export_kml|export_hashcat|cracked_networks|map_data|heatmap_data|download_status|list_files|get_processing|get_targets|check_targets|get_exclusions|history|scored_networks|pwnagotchi_status|gps_push|get_hw)
            return 0
            ;;
    esac
    return 1
}

require_auth() {
    if is_protected_action "$ACTION"; then
        _expected_token=""
        [ -f "$TOKEN_FILE" ] && _expected_token=$(cat "$TOKEN_FILE")
        if [ -z "$_expected_token" ] || [ "$TOKEN" != "$_expected_token" ]; then
            emit_json_headers
            echo '{"error": "unauthorized", "reason": "valid token required for this action"}'
            exit 1
        fi
    fi
}

encode_base64() {
    if command -v base64 >/dev/null 2>&1; then
        base64
    elif command -v openssl >/dev/null 2>&1; then
        openssl enc -A -base64
    elif command -v hexdump >/dev/null 2>&1; then
        hexdump -v -e '1/1 "%02x"' | awk '
        function hexval(c) {
            c=tolower(c)
            return index("0123456789abcdef", c) - 1
        }
        BEGIN { b64="ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/" }
        {
            for (i=1; i<=length($0); i+=2) {
                bytes[++n] = hexval(substr($0, i, 1)) * 16 + hexval(substr($0, i + 1, 1))
            }
        }
        END {
            for (i=1; i<=n; i+=3) {
                b1=bytes[i]; b2=(i+1<=n?bytes[i+1]:0); b3=(i+2<=n?bytes[i+2]:0)
                c1=int(b1/4)
                c2=((b1%4)*16)+int(b2/16)
                c3=((b2%16)*4)+int(b3/64)
                c4=b3%64
                out = out substr(b64,c1+1,1) substr(b64,c2+1,1)
                out = out (i+1<=n ? substr(b64,c3+1,1) : "=")
                out = out (i+2<=n ? substr(b64,c4+1,1) : "=")
            }
            printf "%s", out
        }'
    else
        return 1
    fi
}

api_cache_path() {
    _cache_key="$1"
    case "$_cache_key" in
        *[!A-Za-z0-9_-]*|'') return 1 ;;
    esac
    mkdir -p "$API_CACHE_DIR" 2>/dev/null || return 1
    printf "%s/%s.json" "$API_CACHE_DIR" "$_cache_key"
}

api_cache_emit() {
    _cache_key="$1"
    _cache_ttl="$2"
    _cache_file=$(api_cache_path "$_cache_key") || return 1
    [ -s "$_cache_file" ] || return 1
    _cache_now=$(date +%s)
    if command -v stat >/dev/null 2>&1; then
        _cache_ts=$(stat -c %Y "$_cache_file" 2>/dev/null | tr -cd '0-9')
    else
        [ -f "$_cache_file.ts" ] || return 1
        _cache_ts=$(cat "$_cache_file.ts" 2>/dev/null | tr -cd '0-9')
    fi
    case "$_cache_ttl" in *[!0-9]*|'') return 1 ;; esac
    case "$_cache_now" in *[!0-9]*|'') return 1 ;; esac
    case "$_cache_ts" in
        *[!0-9]*|'') return 1 ;;
    esac
    [ "$(( _cache_now - _cache_ts ))" -le "$_cache_ttl" ] || return 1
    cat "$_cache_file"
    return 0
}

api_cache_store() {
    _cache_key="$1"
    _cache_src="$2"
    _cache_file=$(api_cache_path "$_cache_key") || return 1
    [ -s "$_cache_src" ] || return 1
    _cache_tmp="${_cache_file}.$$"
    _cache_ts_tmp="${_cache_file}.ts.$$"
    cat "$_cache_src" > "$_cache_tmp" || { rm -f "$_cache_tmp"; return 1; }
    mv -f "$_cache_tmp" "$_cache_file" || { rm -f "$_cache_tmp" "$_cache_ts_tmp"; return 1; }
    if command -v stat >/dev/null 2>&1; then
        rm -f "$_cache_file.ts" "$_cache_ts_tmp"
    else
        date +%s > "$_cache_ts_tmp" || { rm -f "$_cache_ts_tmp"; return 1; }
        mv -f "$_cache_ts_tmp" "$_cache_file.ts" || { rm -f "$_cache_ts_tmp"; return 1; }
    fi
}

api_cache_clear() {
    _cache_key="$1"
    _cache_file=$(api_cache_path "$_cache_key") || return 0
    rm -f "$_cache_file" "$_cache_file.ts"
}

api_cache_clear_all() {
    rm -rf "$API_CACHE_DIR"
}

parse_nmea_rmc() {
    echo "$1" | awk -F',' '
    $1 ~ /^\$[A-Z]{2}RMC/ && $3 == "A" {
        lat_raw = $4; lat_dir = $5
        lat_deg = substr(lat_raw, 1, 2)
        lat_min = substr(lat_raw, 3)
        lat = lat_deg + (lat_min / 60)
        if (lat_dir == "S") lat = -lat

        lon_raw = $6; lon_dir = $7
        lon_deg = substr(lon_raw, 1, 3)
        lon_min = substr(lon_raw, 4)
        lon = lon_deg + (lon_min / 60)
        if (lon_dir == "W") lon = -lon

        speed_kts = $8 + 0
        speed_kmh = speed_kts * 1.852

        date_raw = $10
        time_raw = $2

        printf "%.6f %.6f %.1f %s %s", lat, lon, speed_kmh, date_raw, time_raw
    }'
}
