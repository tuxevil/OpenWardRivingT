#!/bin/sh
set -eu

ROUTER_HOST="${ROUTER_HOST:-root@192.168.1.1}"
GPU_HOST="${GPU_HOST:-root@10.128.128.254}"
GPU_URL="${GPU_URL:-http://10.128.128.254:5000/upload}"
SSH_OPTS="${SSH_OPTS:--o BatchMode=yes -o ConnectTimeout=8}"
STAMP=$(date +%Y%m%d_%H%M%S)

ssh_cmd() {
    # shellcheck disable=SC2086 # SSH_OPTS is intentionally split into options.
    # shellcheck disable=SC2029 # Commands are intentionally evaluated on the remote host.
    ssh $SSH_OPTS "$@"
}

scp_cmd() {
    # shellcheck disable=SC2086 # SSH_OPTS is intentionally split into options.
    scp $SSH_OPTS "$@"
}

copy_router() {
    src="$1"
    dst="$2"
    scp_cmd "$src" "$ROUTER_HOST:$dst"
}

copy_gpu() {
    src="$1"
    dst="$2"
    scp_cmd "$src" "$GPU_HOST:$dst"
}

echo "== Preflight =="
test -f openwrt_files/www/cgi-bin/wardriving_api
test -f openwrt_files/usr/bin/wardriving_core.sh
test -f openwrt_files/usr/bin/wardriving_replay.sh
test -f openwrt_files/www/wardriving/index.html
test -f server_files/gpu_server.py
test -f server_files/run_hashcat.sh
test -f server_files/wardriving_gpu.service

ROUTER_TOKEN=$(ssh_cmd "$ROUTER_HOST" "cat /etc/wardriving_api_token")
REMOTE_SECRET=$(ssh_cmd "$ROUTER_HOST" "cat /etc/wardriving_remote_secret 2>/dev/null || true")
if [ -z "$REMOTE_SECRET" ]; then
    REMOTE_SECRET=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 48)
fi

echo "== Backups =="
ssh_cmd "$ROUTER_HOST" "set -eu; b=/root/openwardrivingt_deploy_backup_$STAMP; mkdir -p \"\$b\"; cp -f /www/cgi-bin/wardriving_api \"\$b/\" 2>/dev/null || true; cp -f /usr/bin/wardriving_core.sh \"\$b/\" 2>/dev/null || true; cp -f /usr/bin/wardriving_replay.sh \"\$b/\" 2>/dev/null || true; cp -f /www/wardriving/index.html \"\$b/\" 2>/dev/null || true; cp -f /etc/wardriving_remote_secret \"\$b/\" 2>/dev/null || true; echo \"\$b\""
ssh_cmd "$GPU_HOST" "set -eu; b=/root/openwardrivingt_gpu_deploy_backup_$STAMP; mkdir -p \"\$b\"; cp -f /root/gpu_server.py \"\$b/\" 2>/dev/null || true; cp -f /root/run_hashcat.sh \"\$b/\" 2>/dev/null || true; cp -f /etc/systemd/system/wardriving_gpu.service \"\$b/\" 2>/dev/null || true; echo \"\$b\""

echo "== Deploy router =="
copy_router openwrt_files/www/cgi-bin/wardriving_api /www/cgi-bin/wardriving_api
copy_router openwrt_files/usr/bin/wardriving_core.sh /usr/bin/wardriving_core.sh
copy_router openwrt_files/usr/bin/wardriving_replay.sh /usr/bin/wardriving_replay.sh
copy_router openwrt_files/www/wardriving/index.html /www/wardriving/index.html
ssh_cmd "$ROUTER_HOST" "set -eu; chmod +x /www/cgi-bin/wardriving_api /usr/bin/wardriving_core.sh /usr/bin/wardriving_replay.sh; printf '%s\n' '$REMOTE_SECRET' > /etc/wardriving_remote_secret; chmod 600 /etc/wardriving_remote_secret; printf '1\n' > /etc/wardriving_remote_enabled; printf '%s\n' '$GPU_URL' > /etc/wardriving_remote_url; rm -f /etc/wardriving_remote_allow_sql; sed -i \"s|^[[:space:]]*// API_TOKEN_PLACEHOLDER[[:space:]]*$|window.API_TOKEN = '$ROUTER_TOKEN';|\" /www/wardriving/index.html; ! grep -q API_TOKEN_PLACEHOLDER /www/wardriving/index.html"

echo "== Deploy GPU =="
copy_gpu server_files/gpu_server.py /root/gpu_server.py
copy_gpu server_files/run_hashcat.sh /root/run_hashcat.sh
copy_gpu server_files/wardriving_gpu.service /etc/systemd/system/wardriving_gpu.service
ssh_cmd "$GPU_HOST" "set -eu; chmod +x /root/run_hashcat.sh; sed -i '/^Environment=OWRT_GPU_SHARED_SECRET=/d;/^Environment=OWRT_ROUTER_TOKEN=/d;/^Environment=OWRT_ROUTER_IP=/d' /etc/systemd/system/wardriving_gpu.service; sed -i '/^\\[Service\\]/a Environment=OWRT_ROUTER_IP=192.168.1.1\nEnvironment=OWRT_ROUTER_TOKEN=$ROUTER_TOKEN\nEnvironment=OWRT_GPU_SHARED_SECRET=$REMOTE_SECRET' /etc/systemd/system/wardriving_gpu.service; systemctl daemon-reload; systemctl restart wardriving_gpu; systemctl is-active wardriving_gpu"

echo "== Smoke =="
ROUTER_HOST="$ROUTER_HOST" GPU_HOST="$GPU_HOST" GPU_URL="${GPU_URL%/upload}" SSH_OPTS="$SSH_OPTS" sh scripts/smoke_router_gpu.sh
