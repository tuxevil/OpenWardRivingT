#!/bin/sh
# Remote GPU processing helpers.

REMOTE_ENABLED_FILE="${WARDRIVING_REMOTE_ENABLED_FILE:-/etc/wardriving_remote_enabled}"
EXTRACTION_MODE_FILE="${WARDRIVING_EXTRACTION_MODE_FILE:-/etc/wardriving_extraction_mode}"
GPU_CRACKING_FILE="${WARDRIVING_GPU_CRACKING_FILE:-/etc/wardriving_gpu_cracking_enabled}"
REMOTE_URL_FILE="${WARDRIVING_REMOTE_URL_FILE:-/etc/wardriving_remote_url}"
REMOTE_SECRET_FILE="${WARDRIVING_REMOTE_SECRET_FILE:-/etc/wardriving_remote_secret}"
API_TOKEN_FILE="${WARDRIVING_TOKEN_FILE:-/etc/wardriving_api_token}"
REMOTE_SYNCED_HASHES_FILE="${WARDRIVING_REMOTE_SYNCED_HASHES_FILE:-/mnt/wardriving/.remote_synced.hc2200}"

remote_write_status() {
    _state="$1"
    _code="$2"
    _msg="$3"
    _ts=$(date +%s)
    {
        echo "state=$_state"
        echo "code=$_code"
        echo "message=$_msg"
        echo "updated=$_ts"
    } > /tmp/wardriving_remote_status
}

remote_read_config() {
    LEGACY_REMOTE_ENABLED="0"
    [ -f "$REMOTE_ENABLED_FILE" ] && LEGACY_REMOTE_ENABLED=$(cat "$REMOTE_ENABLED_FILE" | tr -cd '01' | head -c 1)

    EXTRACTION_MODE=""
    [ -f "$EXTRACTION_MODE_FILE" ] && EXTRACTION_MODE=$(cat "$EXTRACTION_MODE_FILE" | tr -cd 'a-z' | head -c 16)
    if [ -z "$EXTRACTION_MODE" ]; then
        if [ "$LEGACY_REMOTE_ENABLED" = "1" ]; then
            EXTRACTION_MODE="remote"
        else
            EXTRACTION_MODE="local"
        fi
    fi
    case "$EXTRACTION_MODE" in
        local|remote) ;;
        *) EXTRACTION_MODE="local" ;;
    esac

    GPU_CRACKING_ENABLED="1"
    [ -f "$GPU_CRACKING_FILE" ] && GPU_CRACKING_ENABLED=$(cat "$GPU_CRACKING_FILE" | tr -cd '01' | head -c 1)
    case "$GPU_CRACKING_ENABLED" in
        0|1) ;;
        *) GPU_CRACKING_ENABLED="1" ;;
    esac

    # shellcheck disable=SC2034 # Read by sourced callers after remote_read_config.
    REMOTE_ENABLED="0"
    if [ "$EXTRACTION_MODE" = "remote" ] || [ "$GPU_CRACKING_ENABLED" = "1" ]; then
        # shellcheck disable=SC2034 # Read by sourced callers after remote_read_config.
        REMOTE_ENABLED="1"
    fi
    REMOTE_URL=""
    [ -f "$REMOTE_URL_FILE" ] && REMOTE_URL=$(cat "$REMOTE_URL_FILE" | tr -d '\r\n')
    REMOTE_SECRET=""
    [ -f "$REMOTE_SECRET_FILE" ] && REMOTE_SECRET=$(cat "$REMOTE_SECRET_FILE" | tr -d '\r\n')
    [ -z "$REMOTE_SECRET" ] && [ -f "$API_TOKEN_FILE" ] && REMOTE_SECRET=$(cat "$API_TOKEN_FILE" | tr -d '\r\n')
    AUTH_HEADER=""
    [ -n "$REMOTE_SECRET" ] && AUTH_HEADER="X-OWRT-Token: $REMOTE_SECRET"
}

remote_endpoint_url() {
    _endpoint="$1"
    _base=$(printf "%s" "$REMOTE_URL" | sed 's/[[:space:]]*$//; s|/*$||; s|/upload_hc2200$||; s|/upload$||; s|/extract$||')
    [ -n "$_base" ] || return 1
    printf "%s/%s\n" "$_base" "$_endpoint"
}

remote_upload_capture() {
    _pcap="$1"
    _response="$2"
    _upload_url=$(remote_endpoint_url upload) || return 1
    if [ -n "$AUTH_HEADER" ]; then
        curl -s -o "$_response" -w "%{http_code}" -X POST -H "X-OWRT-Contract: jsonl" -H "$AUTH_HEADER" -F "pcap=@$_pcap" "$_upload_url" --connect-timeout 10 -m 15
    else
        curl -s -o "$_response" -w "%{http_code}" -X POST -H "X-OWRT-Contract: jsonl" -F "pcap=@$_pcap" "$_upload_url" --connect-timeout 10 -m 15
    fi
}

remote_extract_capture() {
    _pcap="$1"
    _bundle="$2"
    _extract_url=$(remote_endpoint_url extract) || return 1
    if [ -n "$AUTH_HEADER" ]; then
        curl -s -o "$_bundle" -w "%{http_code}" -X POST -H "X-OWRT-Contract: extraction-bundle-v1" -H "$AUTH_HEADER" -F "pcap=@$_pcap" -F "crack=$GPU_CRACKING_ENABLED" "$_extract_url" --connect-timeout 10 -m 15
    else
        curl -s -o "$_bundle" -w "%{http_code}" -X POST -H "X-OWRT-Contract: extraction-bundle-v1" -F "pcap=@$_pcap" -F "crack=$GPU_CRACKING_ENABLED" "$_extract_url" --connect-timeout 10 -m 15
    fi
}

remote_sync_hashes() {
    _hash_file="${1:-/mnt/wardriving/master.hc2200}"
    [ "$GPU_CRACKING_ENABLED" = "1" ] || return 0
    [ -n "$REMOTE_URL" ] || return 0
    [ -s "$_hash_file" ] || return 0

    _pending_file=$(mktemp /tmp/wardriving_hash_sync_XXXXXX) || return 1
    if [ -s "$REMOTE_SYNCED_HASHES_FILE" ]; then
        grep -Fvx -f "$REMOTE_SYNCED_HASHES_FILE" "$_hash_file" > "$_pending_file" 2>/dev/null || true
    else
        cp -f "$_hash_file" "$_pending_file"
    fi
    if [ ! -s "$_pending_file" ]; then
        rm -f "$_pending_file"
        return 0
    fi

    SYNC_URL=$(remote_endpoint_url upload_hc2200) || { rm -f "$_pending_file"; return 1; }
    echo "[*] Syncing offline hashes to $SYNC_URL ..."
    if [ -n "$AUTH_HEADER" ]; then
        SYNC_HTTP=$(curl -s -o /dev/null -w "%{http_code}" -X POST -H "$AUTH_HEADER" -F "hc2200=@$_pending_file" "$SYNC_URL" --connect-timeout 10 -m 15)
    else
        SYNC_HTTP=$(curl -s -o /dev/null -w "%{http_code}" -X POST -F "hc2200=@$_pending_file" "$SYNC_URL" --connect-timeout 10 -m 15)
    fi
    if [ "$SYNC_HTTP" = "200" ]; then
        echo "[+] Offline hashes synced successfully."
        remote_write_status "synced" "$SYNC_HTTP" "hashes synced"
        cat "$_pending_file" >> "$REMOTE_SYNCED_HASHES_FILE"
        sort -u "$REMOTE_SYNCED_HASHES_FILE" -o "$REMOTE_SYNCED_HASHES_FILE" 2>/dev/null || true
        rm -f "$_pending_file"
        return 0
    fi

    echo "[-] Failed to sync offline hashes (Code: $SYNC_HTTP). Will retry later."
    remote_write_status "sync_error" "$SYNC_HTTP" "hash sync failed"
    rm -f "$_pending_file"
    return 1
}
