#!/bin/sh
# Shared CGI helpers for OpenWardRivingT.

: "${QUERY_STRING:=}"
: "${REQUEST_METHOD:=GET}"

TOKEN_FILE="${WARDRIVING_TOKEN_FILE:-/etc/wardriving_api_token}"
# shellcheck disable=SC2034 # Used by sourced handler modules.
WARD_MNT="${WARDRIVING_MNT:-/mnt/wardriving}"
# shellcheck disable=SC2034 # Used by sourced handler modules.
MODE_FILE="${WARDRIVING_MODE_FILE:-/etc/wardriving_mode.txt}"
# shellcheck disable=SC2034 # Used by sourced handler modules.
KEEP_PCAP_FILE="${WARDRIVING_KEEP_PCAP_FILE:-/etc/wardriving_keep_pcap.txt}"
# shellcheck disable=SC2034 # Used by sourced handler modules.
EXCLUDED_FILE="${WARDRIVING_EXCLUDED_FILE:-/etc/wardriving_excluded.txt}"
# shellcheck disable=SC2034 # Used by sourced handler modules.
REMOVED_FILE="${WARDRIVING_REMOVED_FILE:-/etc/wardriving_removed.txt}"
# shellcheck disable=SC2034 # Used by sourced handler modules.
TARGETS_FILE="${WARDRIVING_TARGETS_FILE:-/etc/wardriving_targets.txt}"
# shellcheck disable=SC2034 # Used by sourced handler modules.
WIGLE_TOKEN_FILE="${WARDRIVING_WIGLE_TOKEN_FILE:-/etc/wardriving_wigle_token}"
API_CACHE_DIR="${WARDRIVING_API_CACHE_DIR:-/tmp/wardriving_api_cache}"

query_param() {
    _qp_key="$1"
    printf "%s" "$QUERY_STRING" | tr '&' '\n' | awk -F= -v key="$_qp_key" '$1 == key {print substr($0, index($0, "=") + 1); exit}'
}

# extract_bearer_token: returns the token from the Authorization header
# (if present and well-formed), or empty string. uhttpd exposes request
# headers as HTTP_* environment variables; the standard Authorization
# header becomes HTTP_AUTHORIZATION.
extract_bearer_token() {
    _hdr="${HTTP_AUTHORIZATION:-}"
    case "$_hdr" in
        [Bb]earer\ *) printf "%s" "${_hdr#* }" ;;
        *) ;;
    esac
}

ACTION=$(query_param action)
# Prefer the Authorization: Bearer header so the token doesn't leak into
# access logs or Referer headers. Fall back to ?token= for backward
# compatibility with older clients and with run_hashcat.sh on the GPU
# server (which posts via curl and was authored before the header
# migration).
TOKEN=$(extract_bearer_token)
[ -z "$TOKEN" ] && TOKEN=$(query_param token)

# url_decode <input> -> prints the URL-decoded value.
# Decodes '+' as space and '%XX' as the corresponding byte. Pure awk so
# the helper is reusable from any handler sourced after common.sh
# without spawning a subshell.
url_decode() {
    printf '%s' "$1" | awk '
    BEGIN {
        for (i = 0; i < 16; i++) {
            v = sprintf("%x", i)
            c2x[toupper(v)] = i
            c2x[v] = i
        }
    }
    {
        out = ""
        i = 1
        while (i <= length($0)) {
            c = substr($0, i, 1)
            if (c == "+") {
                out = out " "
            } else if (c == "%" && i + 2 <= length($0)) {
                h1 = substr($0, i + 1, 1)
                h2 = substr($0, i + 2, 1)
                if ((h1 h2) ~ /^[0-9A-Fa-f][0-9A-Fa-f]$/) {
                    out = out sprintf("%c", c2x[h1] * 16 + c2x[h2])
                    i += 2
                } else {
                    out = out c
                }
            } else {
                out = out c
            }
            i++
        }
        print out
    }'
}

emit_json_headers() {
    echo "Content-Type: application/json"
    emit_security_headers
    echo "Cache-Control: no-store"
    echo ""
}

# Emit the standard headers for non-JSON responses (XML, gzip, octet-stream,
# etc.) with an optional Content-Disposition. Centralises the security
# headers and avoids copy-paste between handle_download_all, export_gpx,
# export_kml, and export_hashcat.
emit_headers() {
    _em_ct="$1"
    _em_disp="$2"
    echo "Content-Type: $_em_ct"
    [ -n "$_em_disp" ] && echo "Content-Disposition: $_em_disp"
    emit_security_headers
    echo ""
}

# Security headers applied to all CGI responses (JSON, XML, tar, etc.).
# These mirror the recommendations in the audit:
#   - nosniff prevents content-type sniffing attacks on attacker-supplied
#     filenames (download_all, pcapng, hc2200) which would otherwise
#     let a malicious pcap be rendered as HTML.
#   - DENY blocks clickjacking by preventing the CGI from being framed.
#   - no-referrer stops the dashboard's URL from leaking to third-party
#     tile servers (OpenStreetMap) when the browser fetches tiles.
emit_security_headers() {
    echo "X-Content-Type-Options: nosniff"
    echo "X-Frame-Options: DENY"
    echo "Referrer-Policy: no-referrer"
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
