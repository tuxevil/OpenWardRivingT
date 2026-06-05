#!/bin/sh
# Remote GPU processing helpers.

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
    REMOTE_ENABLED="0"
    [ -f /etc/wardriving_remote_enabled ] && REMOTE_ENABLED=$(cat /etc/wardriving_remote_enabled)
    REMOTE_URL=""
    [ -f /etc/wardriving_remote_url ] && REMOTE_URL=$(cat /etc/wardriving_remote_url)
    REMOTE_SECRET=""
    [ -f /etc/wardriving_remote_secret ] && REMOTE_SECRET=$(cat /etc/wardriving_remote_secret)
    [ -z "$REMOTE_SECRET" ] && [ -f /etc/wardriving_api_token ] && REMOTE_SECRET=$(cat /etc/wardriving_api_token)
    AUTH_HEADER=""
    [ -n "$REMOTE_SECRET" ] && AUTH_HEADER="X-OWRT-Token: $REMOTE_SECRET"
}

remote_upload_capture() {
    _pcap="$1"
    _response="$2"
    if [ -n "$AUTH_HEADER" ]; then
        curl -s -o "$_response" -w "%{http_code}" -X POST -H "X-OWRT-Contract: jsonl" -H "$AUTH_HEADER" -F "pcap=@$_pcap" "$REMOTE_URL" --connect-timeout 10 -m 15
    else
        curl -s -o "$_response" -w "%{http_code}" -X POST -H "X-OWRT-Contract: jsonl" -F "pcap=@$_pcap" "$REMOTE_URL" --connect-timeout 10 -m 15
    fi
}

remote_sync_hashes() {
    _hash_file="${1:-/mnt/wardriving/master.hc2200}"
    [ "$REMOTE_ENABLED" = "1" ] || return 0
    [ -n "$REMOTE_URL" ] || return 0
    [ -s "$_hash_file" ] || return 0

    SYNC_URL=$(echo "$REMOTE_URL" | sed 's|/upload|/upload_hc2200|')
    echo "[*] Syncing offline hashes to $SYNC_URL ..."
    if [ -n "$AUTH_HEADER" ]; then
        SYNC_HTTP=$(curl -s -o /dev/null -w "%{http_code}" -X POST -H "$AUTH_HEADER" -F "hc2200=@$_hash_file" "$SYNC_URL" --connect-timeout 10 -m 15)
    else
        SYNC_HTTP=$(curl -s -o /dev/null -w "%{http_code}" -X POST -F "hc2200=@$_hash_file" "$SYNC_URL" --connect-timeout 10 -m 15)
    fi
    if [ "$SYNC_HTTP" = "200" ]; then
        echo "[+] Offline hashes synced successfully."
        remote_write_status "synced" "$SYNC_HTTP" "hashes synced"
        rm -f "$_hash_file"
        return 0
    fi

    echo "[-] Failed to sync offline hashes (Code: $SYNC_HTTP). Will retry later."
    remote_write_status "sync_error" "$SYNC_HTTP" "hash sync failed"
    return 1
}
