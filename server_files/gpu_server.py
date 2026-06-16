import base64
import io
import json
import os
import subprocess
import tarfile
import time
from flask import Flask, Response, jsonify, request
from werkzeug.utils import secure_filename

app = Flask(__name__)
app.config["MAX_CONTENT_LENGTH"] = int(os.environ.get("OWRT_GPU_MAX_UPLOAD", str(50 * 1024 * 1024)))

# ================= RUTAS Y CONFIGURACIÓN =================
UPLOAD_DIR = os.environ.get("OWRT_GPU_UPLOAD_DIR", "/root/wardriving_uploads")
DICT_DIR = os.environ.get("OWRT_GPU_DICT_DIR", "/root/dicts")
ROUTER_IP = os.environ.get("OWRT_ROUTER_IP", "192.168.1.1")
ROUTER_TOKEN = os.environ.get("OWRT_ROUTER_TOKEN", "")
GPU_SHARED_SECRET = os.environ.get("OWRT_GPU_SHARED_SECRET", "")
HCXPCAPNGTOOL_BIN = os.environ.get("HCXPCAPNGTOOL_BIN", "hcxpcapngtool")
RUN_HASHCAT = os.environ.get("OWRT_RUN_HASHCAT", "/root/run_hashcat.sh")
# =========================================================

os.makedirs(UPLOAD_DIR, exist_ok=True)

def require_auth():
    if not GPU_SHARED_SECRET:
        return jsonify({"error": "server_missing_shared_secret"}), 503
    supplied = request.headers.get("X-OWRT-Token", "")
    if supplied != GPU_SHARED_SECRET:
        return jsonify({"error": "unauthorized"}), 401
    return None

def upload_path(filename, fallback):
    safe = secure_filename(filename or fallback)
    if not safe:
        safe = fallback
    return os.path.join(UPLOAD_DIR, safe)

# Conversor de Formato NMEA a Decimal Degrees para mapas Web
def parse_nmea(val, is_lon, direction):
    if not val or val == "0.000000": return "NULL"
    try:
        idx = val.find('.')
        deg_len = idx - 2 if idx >= 2 else (3 if is_lon else 2)
        deg = float(val[:deg_len])
        minutes = float(val[deg_len:])
        dd = deg + (minutes / 60.0)
        if direction in ['S', 'W']:
            dd = -dd
        return str(dd)
    except:
        return "NULL"

def parse_csv_rows(csv_path):
    rows = []
    if not os.path.exists(csv_path):
        return rows
    with open(csv_path, "r", encoding="utf-8", errors="ignore") as f:
        for line in f:
            parts = line.strip().split("\t")
            if len(parts) < 10:
                continue
            try:
                lat = float(parts[14]) if len(parts) > 14 and parts[14] not in ("", "0.000000") else None
                if lat is not None and parts[11] == "S":
                    lat = -abs(lat)
                lon = float(parts[15]) if len(parts) > 15 and parts[15] not in ("", "0.000000") else None
                if lon is not None and parts[13] == "W":
                    lon = -abs(lon)
            except (ValueError, IndexError):
                lat, lon = None, None
            rows.append({
                "mac": parts[2],
                "ssid": parts[3],
                "enc": parts[4],
                "channel": int(parts[8]) if parts[8].lstrip("-").isdigit() else 0,
                "lat": lat,
                "lon": lon,
                "rssi": int(parts[9]) if parts[9].lstrip("-").isdigit() else 0,
            })
    return rows

def rows_to_jsonl(rows):
    lines = []
    for row in rows:
        ssid_b64 = base64.b64encode(row["ssid"].encode("utf-8", errors="ignore")).decode("ascii")
        lines.append(json.dumps({
            "mac": row["mac"],
            "ssid_b64": ssid_b64,
            "enc": row["enc"],
            "channel": row["channel"],
            "lat": row["lat"],
            "lon": row["lon"],
            "rssi": row["rssi"],
        }, separators=(",", ":")))
    return "\n".join(lines)

def byte_from_hex(hex_string):
    try:
        return int(hex_string, 16)
    except ValueError:
        return 0

def format_mac(hex_mac):
    hex_mac = (hex_mac or "").lower()
    if len(hex_mac) != 12:
        return ""
    return ":".join(hex_mac[i:i + 2] for i in range(0, 12, 2))

def is_valid_unicast_mac(mac):
    parts = mac.split(":")
    if len(parts) != 6:
        return False
    try:
        first_octet = int(parts[0], 16)
    except ValueError:
        return False
    return mac != "ff:ff:ff:ff:ff:ff" and first_octet % 2 == 0

def parse_client_rows(raw_path, network_rows):
    if not os.path.exists(raw_path):
        return []

    ap_meta = {}
    for row in network_rows:
        mac = (row.get("mac") or "").lower()
        ap_meta[mac] = row

    clients = {}
    with open(raw_path, "r", encoding="utf-8", errors="ignore") as f:
        for line in f:
            parts = line.strip().split("*")
            if len(parts) < 3:
                continue
            frame = parts[2].strip()
            if len(frame) < 80:
                continue
            rt = byte_from_hex(frame[4:6]) + byte_from_hex(frame[6:8]) * 256
            dot11 = frame[rt * 2:]
            if len(dot11) < 48:
                continue

            b1 = byte_from_hex(dot11[0:2])
            b2 = byte_from_hex(dot11[2:4])
            frame_type = (b1 // 4) % 4
            subtype = b1 // 16
            to_ds = b2 % 2
            from_ds = (b2 // 2) % 2
            addr1 = format_mac(dot11[8:20])
            addr2 = format_mac(dot11[20:32])
            addr3 = format_mac(dot11[32:44])
            client = ""
            ap = ""
            kind = ""

            if frame_type == 2:
                if to_ds == 1 and from_ds == 0:
                    client = addr2
                    ap = addr1
                    kind = "data_to_ap"
                elif to_ds == 0 and from_ds == 1:
                    client = addr1
                    ap = addr2
                    kind = "data_from_ap"
            elif frame_type == 0 and subtype in (0, 2, 11):
                client = addr2
                ap = addr1
                kind = "auth" if subtype == 11 else "assoc"

            if not is_valid_unicast_mac(client) or not is_valid_unicast_mac(ap) or client == ap:
                continue
            meta = ap_meta.get(ap, {})
            key = (client, ap)
            clients[key] = {
                "client_mac": client,
                "ap_mac": ap,
                "ssid": meta.get("ssid") or ap,
                "channel": meta.get("channel") or 0,
                "lat": meta.get("lat"),
                "lon": meta.get("lon"),
                "rssi": meta.get("rssi") or 0,
                "frame_type": kind,
                "seen_mode": "remote",
            }
    return list(clients.values())

def clients_to_jsonl(rows):
    lines = []
    for row in rows:
        ssid_b64 = base64.b64encode(row["ssid"].encode("utf-8", errors="ignore")).decode("ascii")
        lines.append(json.dumps({
            "client_mac": row["client_mac"],
            "ap_mac": row["ap_mac"],
            "ssid_b64": ssid_b64,
            "channel": row["channel"],
            "lat": row["lat"],
            "lon": row["lon"],
            "rssi": row["rssi"],
            "frame_type": row["frame_type"],
            "seen_mode": row["seen_mode"],
        }, separators=(",", ":")))
    return "\n".join(lines)

def tar_bytes(files):
    data = io.BytesIO()
    with tarfile.open(fileobj=data, mode="w:gz") as tar:
        for name, content in files.items():
            payload = content if isinstance(content, bytes) else content.encode("utf-8")
            info = tarfile.TarInfo(name)
            info.size = len(payload)
            info.mtime = int(time.time())
            tar.addfile(info, io.BytesIO(payload))
    data.seek(0)
    return data.getvalue()

@app.route('/extract', methods=['POST'])
def extract_pcap_bundle():
    auth_error = require_auth()
    if auth_error:
        return auth_error
    if 'pcap' not in request.files:
        return jsonify({"error": "no_pcap_file"}), 400

    pcap_file = request.files['pcap']
    pcap_path = upload_path(pcap_file.filename, "extract_capture.pcapng")
    pcap_file.save(pcap_path)

    hc2200_path = pcap_path + ".hc2200"
    csv_path = pcap_path + ".csv"
    raw_path = pcap_path + ".raw"
    crack_requested = request.form.get("crack", "1") == "1"
    queued_hashcat = False

    # hcxpcapngtool can hang on malformed pcaps (e.g. truncated file
    # mid-frame) without producing any output. Without a timeout the
    # HTTP request would sit indefinitely until the client gave up.
    # 300s is generous: a real 50MB pcap extracts in ~5s, the per-
    # capture window is 60s, and we add headroom for slow disks.
    HCXPCAPNGTOOL_TIMEOUT = 300
    try:
        result = subprocess.run(
            [HCXPCAPNGTOOL_BIN, "-o", hc2200_path, "--csv", csv_path, pcap_path],
            capture_output=True, timeout=HCXPCAPNGTOOL_TIMEOUT,
        )
        subprocess.run(
            [HCXPCAPNGTOOL_BIN, "--raw-out", raw_path, pcap_path],
            capture_output=True, timeout=HCXPCAPNGTOOL_TIMEOUT,
        )
        rows = parse_csv_rows(csv_path)
        clients = parse_client_rows(raw_path, rows)

        hash_payload = b""
        if os.path.exists(hc2200_path):
            with open(hc2200_path, "rb") as f:
                hash_payload = f.read()

        if result.returncode != 0 and not rows and not hash_payload:
            return jsonify({"error": "extraction_failed"}), 422

        if crack_requested and hash_payload:
            subprocess.Popen(["bash", RUN_HASHCAT, hc2200_path, ROUTER_IP, ROUTER_TOKEN, DICT_DIR])
            queued_hashcat = True

        bundle = tar_bytes({
            "clients.jsonl": clients_to_jsonl(clients),
            "capture.hc2200": hash_payload,
        })
        return Response(bundle, mimetype="application/gzip", headers={"X-OWRT-Contract": "extraction-bundle-v1"})
    except subprocess.TimeoutExpired as e:
        # hcxpcapngtool hung (truncated pcap, IO stall, etc).
        # Surface a clean 422 so the router falls back to local
        # extraction rather than retrying forever.
        return jsonify({"error": "extraction_timeout", "stage": e.cmd[0] if e.cmd else "hcxpcapngtool"}), 422
    finally:
        for path in (pcap_path, csv_path, raw_path):
            if os.path.exists(path):
                os.remove(path)
        if os.path.exists(hc2200_path) and not queued_hashcat:
            os.remove(hc2200_path)

@app.route('/upload_hc2200', methods=['POST'])
def receive_hc2200():
    auth_error = require_auth()
    if auth_error:
        return auth_error
    if 'hc2200' not in request.files:
        return jsonify({"error": "no_hc2200_file"}), 400
        
    hc2200_file = request.files['hc2200']
    hc2200_path = upload_path(hc2200_file.filename, "offline_sync.hc2200")
    hc2200_file.save(hc2200_path)
    
    if os.path.exists(hc2200_path) and os.path.getsize(hc2200_path) > 0:
        subprocess.Popen(["bash", RUN_HASHCAT, hc2200_path, ROUTER_IP, ROUTER_TOKEN, DICT_DIR])
        return jsonify({"status": "queued"}), 200
    else:
        if os.path.exists(hc2200_path): os.remove(hc2200_path)
        return jsonify({"status": "empty"}), 200

if __name__ == '__main__':
    print("[*] Iniciando OpenWardrivingT GPU Server en puerto 5000...")
    app.run(host='0.0.0.0', port=5000)
