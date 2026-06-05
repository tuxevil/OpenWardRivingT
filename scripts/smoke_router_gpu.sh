#!/bin/sh
set -eu

ROUTER_HOST="${ROUTER_HOST:-root@192.168.1.1}"
GPU_HOST="${GPU_HOST:-root@10.128.128.254}"
GPU_URL="${GPU_URL:-http://10.128.128.254:5000}"
SSH_OPTS="${SSH_OPTS:--o BatchMode=yes -o ConnectTimeout=8}"

GPU_URL="${GPU_URL%/}"
case "$GPU_URL" in
    */upload) GPU_URL="${GPU_URL%/upload}" ;;
    */upload_hc2200) GPU_URL="${GPU_URL%/upload_hc2200}" ;;
    */extract) GPU_URL="${GPU_URL%/extract}" ;;
esac

ssh_cmd() {
    # shellcheck disable=SC2086 # SSH_OPTS is intentionally split into options.
    # shellcheck disable=SC2029 # Commands are intentionally evaluated on the remote host.
    ssh $SSH_OPTS "$@"
}

curl_router() {
    action="$1"
    token_arg="$2"
    ssh_cmd "$ROUTER_HOST" "wget -T 10 -qO- 'http://127.0.0.1/cgi-bin/wardriving_api?action=$action$token_arg' || true"
}

echo "== Router auth smoke =="
ROUTER_TOKEN=$(ssh_cmd "$ROUTER_HOST" "cat /etc/wardriving_api_token")
STATUS=$(curl_router status "")
case "$STATUS" in *'"running"'*) echo "router status: ok" ;; *) echo "router status: failed"; exit 1 ;; esac

NO_TOKEN=$(curl_router history "")
case "$NO_TOKEN" in *unauthorized*) echo "router history without token: unauthorized" ;; *) echo "router history without token: failed"; exit 1 ;; esac

WITH_TOKEN=$(curl_router history "&token=$ROUTER_TOKEN")
case "$WITH_TOKEN" in *unauthorized*|"") echo "router history with token: failed"; exit 1 ;; *) echo "router history with token: ok" ;; esac

CRACKED=$(curl_router cracked_networks "&token=$ROUTER_TOKEN")
CRACKED_FIRST=$(printf "%s" "$CRACKED" | tr -d '\r\n\t ' | cut -c 1)
case "$CRACKED_FIRST" in
    "[") echo "router cracked_networks: ok" ;;
    *) echo "router cracked_networks: failed"; exit 1 ;;
esac

MAP_DATA=$(curl_router map_data "&token=$ROUTER_TOKEN")
case "$MAP_DATA" in *nmea_b64*) echo "router map_data: ok" ;; *) echo "router map_data: failed"; exit 1 ;; esac

echo "== GPU auth smoke =="
GPU_SECRET=$(ssh_cmd "$ROUTER_HOST" "cat /etc/wardriving_remote_secret 2>/dev/null || cat /etc/wardriving_api_token")
NO_GPU=$(ssh_cmd "$GPU_HOST" "curl -s -o - -w ' HTTP_STATUS:%{http_code}' -F hc2200=@/dev/null '$GPU_URL/upload_hc2200'")
case "$NO_GPU" in *HTTP_STATUS:401*|*unauthorized*) echo "gpu upload_hc2200 without token: unauthorized" ;; *) echo "gpu upload_hc2200 without token: failed"; echo "$NO_GPU"; exit 1 ;; esac

OK_GPU=$(ssh_cmd "$GPU_HOST" "tmp=\$(mktemp /tmp/owrt_smoke_XXXXXX.hc2200); : > \"\$tmp\"; curl -s -o - -w ' HTTP_STATUS:%{http_code}' -H 'X-OWRT-Token: $GPU_SECRET' -F hc2200=@\"\$tmp\" '$GPU_URL/upload_hc2200'; rm -f \"\$tmp\"")
case "$OK_GPU" in *HTTP_STATUS:200*) echo "gpu upload_hc2200 with token: ok" ;; *) echo "gpu upload_hc2200 with token: failed"; echo "$OK_GPU"; exit 1 ;; esac

NO_EXTRACT=$(ssh_cmd "$GPU_HOST" "curl -s -o - -w ' HTTP_STATUS:%{http_code}' -F pcap=@/dev/null '$GPU_URL/extract'")
case "$NO_EXTRACT" in *HTTP_STATUS:401*|*unauthorized*) echo "gpu extract without token: unauthorized" ;; *) echo "gpu extract without token: failed"; echo "$NO_EXTRACT"; exit 1 ;; esac

NO_PCAP=$(ssh_cmd "$GPU_HOST" "curl -s -o - -w ' HTTP_STATUS:%{http_code}' -X POST -H 'X-OWRT-Token: $GPU_SECRET' '$GPU_URL/extract'")
case "$NO_PCAP" in *HTTP_STATUS:400*|*no_pcap_file*) echo "gpu extract contract: ok" ;; *) echo "gpu extract contract: failed"; echo "$NO_PCAP"; exit 1 ;; esac

echo "== Router-GPU contract =="
EXTRACTION_MODE=$(ssh_cmd "$ROUTER_HOST" "cat /etc/wardriving_extraction_mode 2>/dev/null || echo local")
GPU_CRACKING=$(ssh_cmd "$ROUTER_HOST" "cat /etc/wardriving_gpu_cracking_enabled 2>/dev/null || echo 1")
REMOTE_URL=$(ssh_cmd "$ROUTER_HOST" "cat /etc/wardriving_remote_url 2>/dev/null || true")
[ "$EXTRACTION_MODE" = "local" ] || { echo "router extraction mode mismatch: $EXTRACTION_MODE"; exit 1; }
[ "$GPU_CRACKING" = "1" ] || { echo "router gpu cracking disabled"; exit 1; }
[ "$REMOTE_URL" = "$GPU_URL" ] || { echo "router remote url mismatch: $REMOTE_URL"; exit 1; }

if ssh_cmd "$ROUTER_HOST" "test -f /etc/wardriving_remote_allow_sql"; then
    echo "legacy SQL mode unexpectedly enabled"
    exit 1
fi

echo "smoke: ok"
