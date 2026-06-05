#!/bin/sh
# OpenWardRivingT — Test Suite
# Run: sh test/run_tests.sh
# Requires: bash (or busybox ash), the project CGI files accessible

PASS=0
FAIL=0
CGI="openwrt_files/www/cgi-bin/wardriving_api"
TOKEN="test_token_12345"

# Setup test token
setup() {
    rm -f /tmp/wardriving_replay.pause /tmp/wardriving_replay.stop /tmp/wardriving_replay.seek
    rm -f /tmp/wardriving_replay.pid /tmp/wardriving_replay_queue.pid /tmp/wardriving_replay_status.json
    rm -rf /tmp/wardriving_replay_work /tmp/wardriving_replay_uploads
    rm -rf /tmp/test_wardriving_mnt
    rm -f /tmp/test_wardriving_mode /tmp/test_wardriving_extraction_mode /tmp/test_wardriving_gpu_cracking
    rm -f /tmp/test_wardriving_remote_enabled /tmp/test_wardriving_remote_url /tmp/test_wardriving_remote_secret
    echo "$TOKEN" > /tmp/test_wardriving_token
    echo "active" > /tmp/test_wardriving_mode
    cat > /tmp/test_wardriving_init <<'INIT'
#!/bin/sh
case "$1" in
    start|stop|status)
        echo "$1" >> /tmp/test_wardriving_service_calls
        exit 0
        ;;
esac
echo "timer" > "/sys/class/leds/green:wps/trigger"
echo "none" > "/sys/class/leds/green:wps/trigger"
INIT
    chmod +x /tmp/test_wardriving_init
    : > /tmp/test_wardriving_wps
    : > /tmp/test_wardriving_rfkill
    # Minimal mock: create dummy master files
    mkdir -p /tmp/test_wardriving_mnt
    echo "WPA*02*0011*22334455*4a1f5e6c7d8e9a0b1c2d3e4f5a6b7c8d*70617373776F7264* ***" > /tmp/test_wardriving_mnt/master.hc2200
    echo "WPA*02*aaaaaaaaaaaa*001122334455*4a1f5e6c7d8e9a0b1c2d3e4f5a6b7c8d*70617373776F7264* ***" > /tmp/test_wardriving_mnt/hashcat.potfile
    echo "test_network" > /tmp/test_wardriving_mnt/master_essid.txt
    echo '{"001122": "TestVendor"}' > /tmp/test_wardriving_mnt/oui.json
    echo "2025-01-01 12:00:00|00:11:22:33:44:55|TestNet|WPA2|6|-45|40.7128|-74.0060|" > /tmp/test_wardriving_mnt/test.csv
    cat > /tmp/test_wardriving_mnt/route.nmea <<'NMEA'
$GPRMC,123519,A,4807.038,N,01131.000,E,022.4,084.4,230394,003.1,W*6A
NMEA
    if command -v sqlite3 >/dev/null 2>&1; then
        sqlite3 /tmp/test_wardriving_mnt/wardriving.db <<'SQL'
CREATE TABLE networks (
    mac TEXT PRIMARY KEY,
    ssid TEXT,
    enc TEXT,
    channel INTEGER,
    lat REAL,
    lon REAL,
    first_seen TEXT,
    last_seen TEXT,
    rssi INTEGER
);
INSERT INTO networks VALUES ('00:11:22:33:44:55','TestNet','WPA2',6,40.7128,-74.0060,'2025-01-01','2025-01-01',-45);
CREATE TABLE clients (
    client_mac TEXT,
    ap_mac TEXT,
    ssid TEXT,
    channel INTEGER,
    lat REAL,
    lon REAL,
    first_seen TEXT,
    last_seen TEXT,
    rssi INTEGER,
    frame_type TEXT,
    seen_mode TEXT,
    PRIMARY KEY(client_mac, ap_mac)
);
INSERT INTO clients VALUES ('aa:bb:cc:dd:ee:ff','00:11:22:33:44:55','TestNet',6,40.7128,-74.0060,'2025-01-01','2025-01-01',-45,'data_to_ap','capture');
SQL
    fi
}

cleanup() {
    rm -rf /tmp/test_wardriving_*
    rm -f /tmp/wardriving_replay.pause /tmp/wardriving_replay.stop /tmp/wardriving_replay.seek
    rm -f /tmp/wardriving_replay.pid /tmp/wardriving_replay_queue.pid /tmp/wardriving_replay_status.json
    rm -rf /tmp/wardriving_replay_work /tmp/wardriving_replay_uploads
}

assert_json() {
    local desc="$1"
    local output="$2"
    local body
    # Strip HTTP headers (everything before first blank line)
    body=$(printf "%s" "$output" | sed '1,/^$/d')
    if echo "$body" | python3 -m json.tool >/dev/null 2>&1; then
        PASS=$((PASS + 1))
        echo "  ✓ $desc"
    else
        FAIL=$((FAIL + 1))
        echo "  ✗ $desc — invalid JSON"
        echo "    Body: $(echo "$body" | head -c 200)"
    fi
}

assert_contains() {
    local desc="$1"
    local output="$2"
    local pattern="$3"
    local body
    body=$(printf "%s" "$output" | sed '1,/^$/d')
    if echo "$body" | grep -qF "$pattern"; then
        PASS=$((PASS + 1))
        echo "  ✓ $desc"
    else
        FAIL=$((FAIL + 1))
        echo "  ✗ $desc — expected '$pattern' not found"
    fi
}

assert_status() {
    local desc="$1"
    local expected="$2"
    local actual="$3"
    if [ "$actual" = "$expected" ]; then
        PASS=$((PASS + 1))
        echo "  ✓ $desc"
    else
        FAIL=$((FAIL + 1))
        echo "  ✗ $desc — expected $expected, got $actual"
    fi
}

# ===== TESTS =====
setup
export WARDRIVING_TOKEN_FILE=/tmp/test_wardriving_token
export WARDRIVING_MNT=/tmp/test_wardriving_mnt
export WARDRIVING_MODE_FILE=/tmp/test_wardriving_mode
export WARDRIVING_LIB_DIR="$PWD/openwrt_files/usr/lib/wardriving"
export WARDRIVING_INIT_SCRIPT=/tmp/test_wardriving_init
export WARDRIVING_WPS_BUTTON_SCRIPT=/tmp/test_wardriving_wps
export WARDRIVING_RFKILL_BUTTON_SCRIPT=/tmp/test_wardriving_rfkill
export WARDRIVING_EXTRACTION_MODE_FILE=/tmp/test_wardriving_extraction_mode
export WARDRIVING_GPU_CRACKING_FILE=/tmp/test_wardriving_gpu_cracking
export WARDRIVING_REMOTE_ENABLED_FILE=/tmp/test_wardriving_remote_enabled
export WARDRIVING_REMOTE_URL_FILE=/tmp/test_wardriving_remote_url
export WARDRIVING_REMOTE_SECRET_FILE=/tmp/test_wardriving_remote_secret

echo ""
echo "=== CGI Tests ==="

# Test 1: Status returns valid JSON
echo "  Test: action=status"
OUT=$(QUERY_STRING="action=status" sh "$CGI" 2>/dev/null)
assert_json "status returns JSON" "$OUT"
assert_contains "status has running field" "$OUT" "running"

# Test 2: Unknown action
echo "  Test: action=invalid"
OUT=$(QUERY_STRING="action=invalid" sh "$CGI" 2>/dev/null)
assert_json "invalid action returns JSON" "$OUT"
assert_contains "invalid action has error" "$OUT" "error"

# Test 3: Protected action without token
echo "  Test: action=start (no token)"
OUT=$(QUERY_STRING="action=start" sh "$CGI" 2>/dev/null)
assert_json "unauthorized returns JSON" "$OUT"
assert_contains "unauthorized has error" "$OUT" "unauthorized"

# Test 4: Protected action with wrong token
echo "  Test: action=start (wrong token)"
OUT=$(QUERY_STRING="action=start&token=wrong" sh "$CGI" 2>/dev/null)
assert_contains "wrong token rejected" "$OUT" "unauthorized"

echo "  Test: action=export_hashcat (no token)"
OUT=$(QUERY_STRING="action=export_hashcat" sh "$CGI" 2>/dev/null)
assert_json "sensitive export without token returns JSON" "$OUT"
assert_contains "sensitive export requires token" "$OUT" "unauthorized"

echo "  Test: action=map_data (no token)"
OUT=$(QUERY_STRING="action=map_data" sh "$CGI" 2>/dev/null)
assert_contains "map_data requires token" "$OUT" "unauthorized"

echo "  Test: action=cracked_networks (no token)"
OUT=$(QUERY_STRING="action=cracked_networks" sh "$CGI" 2>/dev/null)
assert_contains "cracked_networks requires token" "$OUT" "unauthorized"

echo "  Test: action=list_files (no token)"
OUT=$(QUERY_STRING="action=list_files" sh "$CGI" 2>/dev/null)
assert_contains "list_files requires token" "$OUT" "unauthorized"

# Test 5: Export GPX
echo "  Test: action=export_gpx"
OUT=$(QUERY_STRING="action=export_gpx&token=$TOKEN" sh "$CGI" 2>/dev/null)
assert_contains "export_gpx returns XML" "$OUT" "<?xml"

# Test 6: Export KML  
echo "  Test: action=export_kml"
OUT=$(QUERY_STRING="action=export_kml&token=$TOKEN" sh "$CGI" 2>/dev/null)
assert_contains "export_kml returns XML" "$OUT" "<?xml"

# Test 7: Heatmap data
echo "  Test: action=heatmap_data"
OUT=$(QUERY_STRING="action=heatmap_data&token=$TOKEN" sh "$CGI" 2>/dev/null)
assert_json "heatmap returns JSON array" "$OUT"

# Test 8: Scored networks
echo "  Test: action=scored_networks"
OUT=$(QUERY_STRING="action=scored_networks&token=$TOKEN" sh "$CGI" 2>/dev/null)
assert_json "scored returns JSON array" "$OUT"

# Test 9: History
echo "  Test: action=history"
OUT=$(QUERY_STRING="action=history&token=$TOKEN" sh "$CGI" 2>/dev/null)
assert_json "history returns JSON" "$OUT"

# Test 10: Get hardware
echo "  Test: action=get_hw"
OUT=$(QUERY_STRING="action=get_hw&token=$TOKEN" sh "$CGI" 2>/dev/null)
assert_json "get_hw returns JSON" "$OUT"
assert_contains "get_hw has leds" "$OUT" "leds"

echo "  Test: action=get_mode"
OUT=$(QUERY_STRING="action=get_mode&token=$TOKEN" sh "$CGI" 2>/dev/null)
assert_json "get_mode returns JSON" "$OUT"
assert_contains "get_mode has mode" "$OUT" "mode"

echo "  Test: action=get_processing defaults"
OUT=$(QUERY_STRING="action=get_processing&token=$TOKEN" sh "$CGI" 2>/dev/null)
assert_json "get_processing returns JSON" "$OUT"
assert_contains "get_processing has extraction mode" "$OUT" "\"extraction_mode\":\"local\""
assert_contains "get_processing has gpu cracking default" "$OUT" "\"gpu_cracking_enabled\":\"1\""

echo "  Test: action=set_processing rejects missing URL"
OUT=$(QUERY_STRING="action=set_processing&extraction_mode=remote&gpu_cracking_enabled=1&url=&token=$TOKEN" sh "$CGI" 2>/dev/null)
assert_json "set_processing invalid returns JSON" "$OUT"
assert_contains "set_processing requires URL" "$OUT" "remote url required"

echo "  Test: action=set_processing saves local/off"
OUT=$(QUERY_STRING="action=set_processing&extraction_mode=local&gpu_cracking_enabled=0&url=&token=$TOKEN" sh "$CGI" 2>/dev/null)
assert_json "set_processing local/off returns JSON" "$OUT"
assert_contains "set_processing saves local mode" "$OUT" "\"extraction_mode\":\"local\""
assert_contains "set_processing saves gpu off" "$OUT" "\"gpu_cracking_enabled\":\"0\""

echo "  Test: action=get_processing migrates legacy remote flag"
rm -f "$WARDRIVING_EXTRACTION_MODE_FILE" "$WARDRIVING_GPU_CRACKING_FILE"
echo "1" > "$WARDRIVING_REMOTE_ENABLED_FILE"
echo "http://gpu.example:5000" > "$WARDRIVING_REMOTE_URL_FILE"
OUT=$(QUERY_STRING="action=get_processing&token=$TOKEN" sh "$CGI" 2>/dev/null)
assert_json "legacy processing returns JSON" "$OUT"
assert_contains "legacy remote flag becomes remote extraction" "$OUT" "\"extraction_mode\":\"remote\""
assert_contains "legacy processing keeps URL" "$OUT" "http://gpu.example:5000"

echo "  Test: action=set_mode"
OUT=$(QUERY_STRING="action=set_mode&mode=passive&token=$TOKEN" sh "$CGI" 2>/dev/null)
assert_json "set_mode returns JSON" "$OUT"
assert_contains "set_mode saved passive" "$OUT" "\"mode\":\"passive\""

echo "  Test: action=set_hw preserves executable service controls"
OUT=$(QUERY_STRING="action=set_hw&led=green%3Awps&btn=wps&mode=passive&token=$TOKEN" sh "$CGI" 2>/dev/null)
assert_json "set_hw returns JSON" "$OUT"
assert_contains "set_hw saved hardware" "$OUT" "\"status\": \"saved\""
if [ -x "$WARDRIVING_INIT_SCRIPT" ] && [ -x "$WARDRIVING_WPS_BUTTON_SCRIPT" ] && [ -x "$WARDRIVING_RFKILL_BUTTON_SCRIPT" ]; then
    PASS=$((PASS + 1)); echo "  ✓ set_hw keeps init and button scripts executable"
else
    FAIL=$((FAIL + 1)); echo "  ✗ set_hw removed executable permissions"
fi

echo "  Test: action=start detects broken init permissions"
OUT=$(QUERY_STRING="action=start&token=$TOKEN" sh "$CGI" 2>/dev/null)
assert_json "start returns JSON" "$OUT"
assert_contains "start reports started" "$OUT" "\"status\": \"started\""
chmod 600 "$WARDRIVING_INIT_SCRIPT"
OUT=$(QUERY_STRING="action=start&token=$TOKEN" sh "$CGI" 2>/dev/null)
assert_json "start permission failure returns JSON" "$OUT"
assert_contains "start reports non-executable init" "$OUT" "init script is not executable"
chmod +x "$WARDRIVING_INIT_SCRIPT"

echo "  Test: action=map_data"
OUT=$(QUERY_STRING="action=map_data&token=$TOKEN" sh "$CGI" 2>/dev/null)
assert_json "map_data returns JSON" "$OUT"
assert_contains "map_data includes nmea_b64" "$OUT" "nmea_b64"

echo "  Test: action=replay_status"
OUT=$(QUERY_STRING="action=replay_status&token=$TOKEN" sh "$CGI" 2>/dev/null)
assert_json "replay_status returns JSON" "$OUT"
assert_contains "replay_status has state" "$OUT" "state"

echo "  Test: action=networks_map"
OUT=$(QUERY_STRING="action=networks_map&token=$TOKEN" sh "$CGI" 2>/dev/null)
assert_json "networks_map returns JSON" "$OUT"
assert_contains "networks_map includes handshake flag" "$OUT" "has_handshake"

echo "  Test: action=clients_map"
OUT=$(QUERY_STRING="action=clients_map&token=$TOKEN" sh "$CGI" 2>/dev/null)
assert_json "clients_map returns JSON" "$OUT"
assert_contains "clients_map includes client count" "$OUT" "client_count"
assert_contains "clients_map includes AP count" "$OUT" "ap_count"

echo "  Test: action=replay_discovered"
mkdir -p /tmp/wardriving_replay_work
cat > /tmp/wardriving_replay_work/discovered.tsv <<'TSV'
00:11:22:33:44:55	TestNet	40.7128	-74.0060	-45	1
66:77:88:99:aa:bb	ReplayOnly	40.7129	-74.0061	-61	0
TSV
OUT=$(QUERY_STRING="action=replay_discovered&token=$TOKEN" sh "$CGI" 2>/dev/null)
assert_json "replay_discovered returns JSON" "$OUT"
assert_contains "replay_discovered includes handshake flag" "$OUT" "has_handshake"
assert_contains "replay_discovered includes replay SSID" "$OUT" "ReplayOnly"

if command -v sqlite3 >/dev/null 2>&1; then
    echo "  Test: action=cracked_networks"
    OUT=$(QUERY_STRING="action=cracked_networks&token=$TOKEN" sh "$CGI" 2>/dev/null)
    assert_json "cracked_networks returns JSON" "$OUT"
    assert_contains "cracked_networks includes matched SSID" "$OUT" "TestNet"
fi

echo ""
echo "=== Upload Guard Tests ==="

echo "  Test: upload_potfile rejects GET"
OUT=$(REQUEST_METHOD="GET" QUERY_STRING="action=upload_potfile&token=$TOKEN" sh "$CGI" 2>/dev/null)
assert_contains "upload_potfile requires POST" "$OUT" "POST required"

echo "  Test: upload_potfile rejects oversized payload"
OUT=$(REQUEST_METHOD="POST" CONTENT_LENGTH="1048577" QUERY_STRING="action=upload_potfile&token=$TOKEN" sh "$CGI" 2>/dev/null < /dev/null)
assert_contains "upload_potfile size guard" "$OUT" "too large"

echo "  Test: upload_potfile rejects empty body"
OUT=$(REQUEST_METHOD="POST" CONTENT_LENGTH="0" QUERY_STRING="action=upload_potfile&token=$TOKEN" sh "$CGI" 2>/dev/null < /dev/null)
assert_contains "upload_potfile empty guard" "$OUT" "empty upload"

echo "  Test: upload_tiles rejects invalid archive"
OUT=$(printf 'not a tar' | REQUEST_METHOD="POST" CONTENT_LENGTH="9" QUERY_STRING="action=upload_tiles&token=$TOKEN" sh "$CGI" 2>/dev/null)
assert_contains "upload_tiles invalid tar guard" "$OUT" "invalid tile archive"

echo "  Test: replay_start rejects GET"
OUT=$(REQUEST_METHOD="GET" QUERY_STRING="action=replay_start&token=$TOKEN" sh "$CGI" 2>/dev/null)
assert_contains "replay_start requires POST" "$OUT" "POST required"

echo "  Test: replay_start rejects empty body"
OUT=$(REQUEST_METHOD="POST" CONTENT_LENGTH="0" QUERY_STRING="action=replay_start&token=$TOKEN" sh "$CGI" 2>/dev/null < /dev/null)
assert_contains "replay_start empty guard" "$OUT" "empty CSV"

echo "  Test: replay_start rejects invalid CSV"
OUT=$(printf 'not wigle' | REQUEST_METHOD="POST" CONTENT_LENGTH="9" QUERY_STRING="action=replay_start&token=$TOKEN" sh "$CGI" 2>/dev/null)
assert_contains "replay_start invalid CSV guard" "$OUT" "invalid WiGLE CSV"

echo "  Test: replay_pause returns JSON"
OUT=$(QUERY_STRING="action=replay_pause&token=$TOKEN" sh "$CGI" 2>/dev/null)
assert_json "replay_pause returns JSON" "$OUT"
assert_contains "replay_pause has paused status" "$OUT" "paused"

echo "  Test: frontend has escaping helper"
if grep -q "function esc" openwrt_files/www/wardriving/app.js && grep -q "esc(n.ssid" openwrt_files/www/wardriving/app.js; then
    PASS=$((PASS + 1)); echo "  ✓ frontend escaping helper present"
else
    FAIL=$((FAIL + 1)); echo "  ✗ frontend escaping helper missing"
fi

echo "  Test: frontend has token injection placeholder"
if grep -q "API_TOKEN_PLACEHOLDER" openwrt_files/www/wardriving/app.js && grep -q "window.fetch=function" openwrt_files/www/wardriving/app.js; then
    PASS=$((PASS + 1)); echo "  ✓ frontend token injection hook present"
else
    FAIL=$((FAIL + 1)); echo "  ✗ frontend token injection hook missing"
fi

echo "  Test: frontend static asset split"
if grep -q 'href="app.css"' openwrt_files/www/wardriving/index.html && grep -q 'src="app.js"' openwrt_files/www/wardriving/index.html && ! grep -q "API_TOKEN_PLACEHOLDER" openwrt_files/www/wardriving/index.html; then
    PASS=$((PASS + 1)); echo "  ✓ frontend references split app.css/app.js"
else
    FAIL=$((FAIL + 1)); echo "  ✗ frontend split references missing"
fi

echo "  Test: dashboard fullscreen button"
if grep -q "btnFullscreen" openwrt_files/www/wardriving/index.html && grep -q "function toggleFullscreen" openwrt_files/www/wardriving/app.js && grep -q "requestFullscreen" openwrt_files/www/wardriving/app.js && grep -q "fullscreen-toggle" openwrt_files/www/wardriving/app.css; then
    PASS=$((PASS + 1)); echo "  ✓ fullscreen control is wired in header"
else
    FAIL=$((FAIL + 1)); echo "  ✗ fullscreen control missing"
fi

echo "  Test: frontend processing settings are split"
if grep -q "selExtractionMode" openwrt_files/www/wardriving/index.html && grep -q "selGpuCracking" openwrt_files/www/wardriving/index.html && grep -q "extraction_mode" openwrt_files/www/wardriving/app.js && grep -q "gpu_cracking_enabled" openwrt_files/www/wardriving/app.js; then
    PASS=$((PASS + 1)); echo "  ✓ frontend exposes extraction and cracking settings separately"
else
    FAIL=$((FAIL + 1)); echo "  ✗ frontend processing settings split missing"
fi

echo "  Test: Redes Ahora uses live status channels"
if grep -q "function updateScores(channelsData)" openwrt_files/www/wardriving/app.js && grep -q "updateScores(d.channels_data)" openwrt_files/www/wardriving/app.js && ! grep -q "apiJson('scored_networks')" openwrt_files/www/wardriving/app.js; then
    PASS=$((PASS + 1)); echo "  ✓ live networks render from status.channels_data"
else
    FAIL=$((FAIL + 1)); echo "  ✗ live networks still depend on scored_networks"
fi

echo "  Test: Redes Ahora hides implementation wording"
if ! grep -q "in hcxdumptool" openwrt_files/www/wardriving/app.js && grep -q "visto " openwrt_files/www/wardriving/app.js; then
    PASS=$((PASS + 1)); echo "  ✓ live networks copy is user-facing"
else
    FAIL=$((FAIL + 1)); echo "  ✗ live networks copy still exposes implementation wording"
fi

echo "  Test: Redes Ahora shows live encryption"
if grep -q '\\"e\\"' openwrt_files/usr/lib/wardriving/handlers/status.sh && grep -Fq 'return substr(line, 23, 1) == "+" ? "PSK" : "?"' openwrt_files/usr/lib/wardriving/handlers/status.sh && grep -q "v==='PSK'" openwrt_files/www/wardriving/app.js && grep -q "sr-enc" openwrt_files/www/wardriving/app.js && grep -q "ENC ?" openwrt_files/www/wardriving/app.js; then
    PASS=$((PASS + 1)); echo "  ✓ live networks include encryption badge"
else
    FAIL=$((FAIL + 1)); echo "  ✗ live network encryption badge missing"
fi

echo "  Test: frontend treats remote extraction success as GPU OK"
if grep -q "rs==='ok'||rs==='synced'||rs==='extracted'" openwrt_files/www/wardriving/app.js; then
    PASS=$((PASS + 1)); echo "  ✓ pipeline accepts extracted remote state"
else
    FAIL=$((FAIL + 1)); echo "  ✗ pipeline does not accept extracted remote state"
fi

echo "  Test: cracked historical map toggle"
if grep -q "chkCracked" openwrt_files/www/wardriving/index.html && grep -q "showCracked" openwrt_files/www/wardriving/app.js && grep -q "function toggleCrackedButton" openwrt_files/www/wardriving/app.js && grep -q "cracked_networks" openwrt_files/www/wardriving/app.js; then
    PASS=$((PASS + 1)); echo "  ✓ cracked map layer has persisted toggle"
else
    FAIL=$((FAIL + 1)); echo "  ✗ cracked map layer toggle missing"
fi

echo "  Test: service worker updates dashboard assets"
if grep -q "owrt-store-v" openwrt_files/www/wardriving/sw.js && grep -q "skipWaiting" openwrt_files/www/wardriving/sw.js && grep -q "clients.claim" openwrt_files/www/wardriving/sw.js && grep -q "caches.delete" openwrt_files/www/wardriving/sw.js && grep -q "/cgi-bin/wardriving_api" openwrt_files/www/wardriving/sw.js; then
    PASS=$((PASS + 1)); echo "  ✓ service worker refreshes app shell and bypasses API cache"
else
    FAIL=$((FAIL + 1)); echo "  ✗ service worker cache refresh safeguards missing"
fi

echo "  Test: hardware settings LED fallback"
if grep -q "function loadHW(){apiJson('get_hw')" openwrt_files/www/wardriving/app.js && grep -q "No LEDs found" openwrt_files/www/wardriving/app.js && grep -q "LED status unavailable" openwrt_files/www/wardriving/app.js; then
    PASS=$((PASS + 1)); echo "  ✓ hardware LED selector has API and fallback handling"
else
    FAIL=$((FAIL + 1)); echo "  ✗ hardware LED selector fallback missing"
fi

echo "  Test: frontend replay markers are cumulative"
if grep -q "function mergeReplayNetworks" openwrt_files/www/wardriving/app.js && grep -q "replayDiscoveredItems={}" openwrt_files/www/wardriving/app.js && grep -q "if(d&&d.length){mergeReplayNetworks" openwrt_files/www/wardriving/app.js; then
    PASS=$((PASS + 1)); echo "  ✓ replay marker cache preserves discovered networks"
else
    FAIL=$((FAIL + 1)); echo "  ✗ replay marker cache missing"
fi

echo "  Test: frontend replay map has free/follow controls"
if grep -q "function fitReplayNetworks" openwrt_files/www/wardriving/app.js && grep -q "btnReplayFollow" openwrt_files/www/wardriving/index.html && grep -q "if(replayFollowMode)" openwrt_files/www/wardriving/app.js; then
    PASS=$((PASS + 1)); echo "  ✓ replay map follow controls present"
else
    FAIL=$((FAIL + 1)); echo "  ✗ replay map follow controls missing"
fi

echo "  Test: frontend dashboard mode and client layer"
if grep -q "id=\"dashMode\"" openwrt_files/www/wardriving/index.html && grep -q "function setOperationMode" openwrt_files/www/wardriving/app.js && grep -q "clients_map" openwrt_files/www/wardriving/app.js && grep -q "function drawClientLayer" openwrt_files/www/wardriving/app.js; then
    PASS=$((PASS + 1)); echo "  ✓ dashboard mode/client layer present"
else
    FAIL=$((FAIL + 1)); echo "  ✗ dashboard mode/client layer missing"
fi

echo "  Test: frontend map markers cluster by zoom"
if grep -q "function clusterMapItems" openwrt_files/www/wardriving/app.js && grep -q "clusterPixelSize" openwrt_files/www/wardriving/app.js && grep -q "zoomend.*refreshVisibleLayers" openwrt_files/www/wardriving/app.js; then
    PASS=$((PASS + 1)); echo "  ✓ zoom-aware map clustering present"
else
    FAIL=$((FAIL + 1)); echo "  ✗ zoom-aware map clustering missing"
fi

echo "  Test: frontend pushes browser GPS while stopped"
if grep -q "action=gps_push" openwrt_files/www/wardriving/app.js && ! grep -q "if(isRunning).*gps_push" openwrt_files/www/wardriving/app.js; then
    PASS=$((PASS + 1)); echo "  ✓ browser GPS push is independent of capture state"
else
    FAIL=$((FAIL + 1)); echo "  ✗ browser GPS push still depends on running state"
fi

echo "  Test: gps_push does not block without vGPS reader"
if grep -q "socat.*vGPS" openwrt_files/usr/lib/wardriving/handlers/status.sh && grep -q "printf.*vGPS_fifo" openwrt_files/usr/lib/wardriving/handlers/status.sh; then
    PASS=$((PASS + 1)); echo "  ✓ gps_push gates FIFO writes on active socat reader"
else
    FAIL=$((FAIL + 1)); echo "  ✗ gps_push can still write to FIFO without reader"
fi

echo ""
echo "=== NMEA Parser Tests ==="

# Test NMEA RMC parsing (from shared parse_nmea_rmc function)
echo "  Test: Valid GPRMC sentence"
# shellcheck disable=SC2016 # Literal NMEA sentence must keep the leading '$'.
RMC='$GPRMC,123519,A,4807.038,N,01131.000,E,022.4,084.4,230394,003.1,W*6A'
RESULT=$(echo "$RMC" | awk -F',' '
$1 ~ /^\$[A-Z]{2}RMC/ && $3 == "A" {
    lat_dec = substr($4,1,2) + (substr($4,3) / 60)
    if($5 == "S") lat_dec = -lat_dec
    lon_dec = substr($6,1,3) + (substr($6,4) / 60)
    if($7 == "W") lon_dec = -lon_dec
    printf "%s %s", lat_dec, lon_dec
}')
assert_status "NMEA lat parse" "48.1173" "$(echo "$RESULT" | awk '{printf "%.4f", $1}')"
assert_status "NMEA lon parse" "11.5167" "$(echo "$RESULT" | awk '{printf "%.4f", $2}')"

echo "  Test: Invalid fix (V status)"
# shellcheck disable=SC2016 # Literal NMEA sentence must keep the leading '$'.
RMC_BAD='$GPRMC,123519,V,4807.038,N,01131.000,E,022.4,084.4,230394,003.1,W*6A'
RESULT=$(echo "$RMC_BAD" | awk -F',' '
$1 ~ /^\$[A-Z]{2}RMC/ && $3 == "A" {
    printf "PARSED"
}')
assert_status "invalid fix skipped" "" "$RESULT"

echo "  Test: Southern hemisphere"
# shellcheck disable=SC2016 # Literal NMEA sentence must keep the leading '$'.
RMC_SOUTH='$GPRMC,123519,A,3344.500,S,15112.700,E,010.0,180.0,230394,,,A*00'
RESULT=$(echo "$RMC_SOUTH" | awk -F',' '
$1 ~ /^\$[A-Z]{2}RMC/ && $3 == "A" {
    lat_dec = substr($4,1,2) + (substr($4,3) / 60)
    if($5 == "S") lat_dec = -lat_dec
    lon_dec = substr($6,1,3) + (substr($6,4) / 60)
    if($7 == "W") lon_dec = -lon_dec
    printf "%.4f", lat_dec
}')
assert_status "southern hemisphere negative" "-33" "$(echo "$RESULT" | cut -c1-3)"

echo ""
echo "=== Shell Script Tests ==="

# Test: install.sh syntax
echo "  Test: install.sh bash syntax"
if bash -n install.sh 2>/dev/null; then
    PASS=$((PASS + 1)); echo "  ✓ install.sh syntax OK"
else
    FAIL=$((FAIL + 1)); echo "  ✗ install.sh syntax ERROR"
fi

# Test: uninstall.sh syntax
echo "  Test: uninstall.sh bash syntax"
if bash -n uninstall.sh 2>/dev/null; then
    PASS=$((PASS + 1)); echo "  ✓ uninstall.sh syntax OK"
else
    FAIL=$((FAIL + 1)); echo "  ✗ uninstall.sh syntax ERROR"
fi

# Test: wardriving_core.sh syntax
echo "  Test: wardriving_core.sh bash syntax"
if bash -n openwrt_files/usr/bin/wardriving_core.sh 2>/dev/null; then
    PASS=$((PASS + 1)); echo "  ✓ wardriving_core.sh syntax OK"
else
    FAIL=$((FAIL + 1)); echo "  ✗ wardriving_core.sh syntax ERROR"
fi

# Test: wardriving_clients.sh syntax
echo "  Test: wardriving_clients.sh bash syntax"
if bash -n openwrt_files/usr/bin/wardriving_clients.sh 2>/dev/null; then
    PASS=$((PASS + 1)); echo "  ✓ wardriving_clients.sh syntax OK"
else
    FAIL=$((FAIL + 1)); echo "  ✗ wardriving_clients.sh syntax ERROR"
fi
echo "  Test: wardriving_clients.sh requires fresh GPS"
if grep -q "WARDRIVING_GPS_MAX_AGE" openwrt_files/usr/bin/wardriving_clients.sh && grep -q "GPS_AGE" openwrt_files/usr/bin/wardriving_clients.sh; then
    PASS=$((PASS + 1)); echo "  ✓ client GPS fallback has freshness guard"
else
    FAIL=$((FAIL + 1)); echo "  ✗ client GPS fallback freshness guard missing"
fi

# Test: wardriving_api syntax
echo "  Test: wardriving_api bash syntax"
if bash -n "$CGI" 2>/dev/null; then
    PASS=$((PASS + 1)); echo "  ✓ wardriving_api syntax OK"
else
    FAIL=$((FAIL + 1)); echo "  ✗ wardriving_api syntax ERROR"
fi

# Test: init.d syntax
echo "  Test: init.d/wardriving bash syntax"
if bash -n openwrt_files/etc/init.d/wardriving 2>/dev/null; then
    PASS=$((PASS + 1)); echo "  ✓ init.d/wardriving syntax OK"
else
    FAIL=$((FAIL + 1)); echo "  ✗ init.d/wardriving syntax ERROR"
fi
echo "  Test: init.d/wardriving start is idempotent"
if grep -q "stop_capture_processes()" openwrt_files/etc/init.d/wardriving && sed -n '/^start()/,/wifi down radio0/p' openwrt_files/etc/init.d/wardriving | grep -q "stop_capture_processes"; then
    PASS=$((PASS + 1)); echo "  ✓ init start cleans stale capture processes"
else
    FAIL=$((FAIL + 1)); echo "  ✗ init start stale-process cleanup missing"
fi

# Test: wardriving_sync.sh syntax
echo "  Test: wardriving_sync.sh bash syntax"
if bash -n openwrt_files/usr/bin/wardriving_sync.sh 2>/dev/null; then
    PASS=$((PASS + 1)); echo "  ✓ wardriving_sync.sh syntax OK"
else
    FAIL=$((FAIL + 1)); echo "  ✗ wardriving_sync.sh syntax ERROR"
fi

echo "  Test: wardriving_replay.sh bash syntax"
if bash -n openwrt_files/usr/bin/wardriving_replay.sh 2>/dev/null; then
    PASS=$((PASS + 1)); echo "  ✓ wardriving_replay.sh syntax OK"
else
    FAIL=$((FAIL + 1)); echo "  ✗ wardriving_replay.sh syntax ERROR"
fi

echo "  Test: wardriving shell libraries syntax"
LIB_FAIL=0
for f in openwrt_files/usr/lib/wardriving/*.sh openwrt_files/usr/lib/wardriving/handlers/*.sh; do
    bash -n "$f" 2>/dev/null || LIB_FAIL=1
done
if [ "$LIB_FAIL" -eq 0 ]; then
    PASS=$((PASS + 1)); echo "  ✓ wardriving shell libraries syntax OK"
else
    FAIL=$((FAIL + 1)); echo "  ✗ wardriving shell libraries syntax ERROR"
fi

echo "  Test: core no longer uses PROCESSED_REMOTE gate"
if ! grep -q "PROCESSED_REMOTE" openwrt_files/usr/bin/wardriving_core.sh && grep -q "try_remote_extract_capture" openwrt_files/usr/bin/wardriving_core.sh && grep -q "remote_extract_capture" openwrt_files/usr/lib/wardriving/remote.sh; then
    PASS=$((PASS + 1)); echo "  ✓ core separates remote extraction from local fallback"
else
    FAIL=$((FAIL + 1)); echo "  ✗ core still has old remote processing gate"
fi

echo "  Test: remote hash sync preserves local master"
# shellcheck disable=SC2016 # Literal shell snippet is what the test is looking for.
if grep -q "REMOTE_SYNCED_HASHES_FILE" openwrt_files/usr/lib/wardriving/remote.sh && grep -q "grep -Fvx" openwrt_files/usr/lib/wardriving/remote.sh && ! grep -q 'rm -f "$_hash_file"' openwrt_files/usr/lib/wardriving/remote.sh; then
    PASS=$((PASS + 1)); echo "  ✓ hash sync sends only pending hashes without deleting master"
else
    FAIL=$((FAIL + 1)); echo "  ✗ hash sync can still delete or resend master hashes"
fi

echo "  Test: gpu_server.py syntax"
if python3 -m py_compile server_files/gpu_server.py 2>/dev/null; then
    PASS=$((PASS + 1)); echo "  ✓ gpu_server.py syntax OK"
else
    FAIL=$((FAIL + 1)); echo "  ✗ gpu_server.py syntax ERROR"
fi

cleanup

echo ""
echo "========================================="
echo "  Results: $PASS passed, $FAIL failed"
echo "========================================="
[ "$FAIL" -eq 0 ] && echo "✅ ALL TESTS PASSED" || echo "❌ SOME TESTS FAILED"
exit $FAIL
