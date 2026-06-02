#!/bin/sh
set -eu

ROUTER_HOST="${ROUTER_HOST:-root@192.168.1.1}"
GPU_HOST="${GPU_HOST:-root@10.128.128.254}"
GPU_URL="${GPU_URL:-http://10.128.128.254:5000}"
SSH_OPTS="${SSH_OPTS:--o BatchMode=yes -o ConnectTimeout=8}"

ssh_cmd() {
    # shellcheck disable=SC2086 # SSH_OPTS is intentionally split into options.
    # shellcheck disable=SC2029 # Commands are intentionally evaluated on the remote host.
    ssh $SSH_OPTS "$@"
}

curl_router() {
    action="$1"
    token_arg="$2"
    ssh_cmd "$ROUTER_HOST" "wget -qO- 'http://127.0.0.1/cgi-bin/wardriving_api?action=$action$token_arg'"
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
case "$CRACKED" in \[* ) echo "router cracked_networks: ok" ;; *) echo "router cracked_networks: failed"; exit 1 ;; esac

MAP_DATA=$(curl_router map_data "&token=$ROUTER_TOKEN")
case "$MAP_DATA" in *nmea_b64*) echo "router map_data: ok" ;; *) echo "router map_data: failed"; exit 1 ;; esac

echo "== GPU auth smoke =="
GPU_SECRET=$(ssh_cmd "$ROUTER_HOST" "cat /etc/wardriving_remote_secret 2>/dev/null || cat /etc/wardriving_api_token")
NO_GPU=$(ssh_cmd "$GPU_HOST" "curl -s -o - -w ' HTTP_STATUS:%{http_code}' -F hc2200=@/dev/null '$GPU_URL/upload_hc2200'")
case "$NO_GPU" in *HTTP_STATUS:401*|*unauthorized*) echo "gpu upload_hc2200 without token: unauthorized" ;; *) echo "gpu upload_hc2200 without token: failed"; echo "$NO_GPU"; exit 1 ;; esac

OK_GPU=$(ssh_cmd "$GPU_HOST" "tmp=\$(mktemp /tmp/owrt_smoke_XXXXXX.hc2200); : > \"\$tmp\"; curl -s -o - -w ' HTTP_STATUS:%{http_code}' -H 'X-OWRT-Token: $GPU_SECRET' -F hc2200=@\"\$tmp\" '$GPU_URL/upload_hc2200'; rm -f \"\$tmp\"")
case "$OK_GPU" in *HTTP_STATUS:200*) echo "gpu upload_hc2200 with token: ok" ;; *) echo "gpu upload_hc2200 with token: failed"; echo "$OK_GPU"; exit 1 ;; esac

echo "== Router-GPU contract =="
REMOTE_ENABLED=$(ssh_cmd "$ROUTER_HOST" "cat /etc/wardriving_remote_enabled 2>/dev/null || echo 0")
REMOTE_URL=$(ssh_cmd "$ROUTER_HOST" "cat /etc/wardriving_remote_url 2>/dev/null || true")
[ "$REMOTE_ENABLED" = "1" ] || { echo "router remote processing disabled"; exit 1; }
[ "$REMOTE_URL" = "$GPU_URL/upload" ] || { echo "router remote url mismatch: $REMOTE_URL"; exit 1; }

if ssh_cmd "$ROUTER_HOST" "test -f /etc/wardriving_remote_allow_sql"; then
    echo "legacy SQL mode unexpectedly enabled"
    exit 1
fi

echo "smoke: ok"
