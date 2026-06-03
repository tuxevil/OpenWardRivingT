import base64
import os
import subprocess
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
            lat = parse_nmea(parts[9], False, parts[10] if len(parts) > 10 else 'N') if len(parts) > 9 else "NULL"
            lon = parse_nmea(parts[11], True, parts[12] if len(parts) > 12 else 'E') if len(parts) > 11 else "NULL"
            rows.append({
                "mac": parts[1],
                "ssid": parts[2],
                "enc": parts[3],
                "channel": int(parts[7]) if parts[7].lstrip("-").isdigit() else 0,
                "lat": None if lat == "NULL" else float(lat),
                "lon": None if lon == "NULL" else float(lon),
                "rssi": int(parts[8]) if parts[8].lstrip("-").isdigit() else 0,
            })
    return rows

def rows_to_jsonl(rows):
    lines = []
    for row in rows:
        ssid_b64 = base64.b64encode(row["ssid"].encode("utf-8", errors="ignore")).decode("ascii")
        lines.append(
            '{"mac":"%s","ssid_b64":"%s","enc":"%s","channel":%d,"lat":%s,"lon":%s,"rssi":%d}'
            % (
                row["mac"],
                ssid_b64,
                row["enc"].replace("\\", "").replace('"', ""),
                row["channel"],
                "null" if row["lat"] is None else row["lat"],
                "null" if row["lon"] is None else row["lon"],
                row["rssi"],
            )
        )
    return "\n".join(lines)

@app.route('/upload', methods=['POST'])
def receive_pcap():
    auth_error = require_auth()
    if auth_error:
        return auth_error
    if 'pcap' not in request.files:
        return jsonify({"error": "no_pcap_file"}), 400
        
    pcap_file = request.files['pcap']
    pcap_path = upload_path(pcap_file.filename, "capture.pcapng")
    pcap_file.save(pcap_path)
    
    hc2200_path = pcap_path + ".hc2200"
    csv_path = pcap_path + ".csv"
    
    subprocess.run([HCXPCAPNGTOOL_BIN, "-o", hc2200_path, "--csv", csv_path, pcap_path], capture_output=True)
    
    rows = parse_csv_rows(csv_path)
    
    if os.path.exists(hc2200_path) and os.path.getsize(hc2200_path) > 0:
        subprocess.Popen(["bash", RUN_HASHCAT, hc2200_path, ROUTER_IP, ROUTER_TOKEN, DICT_DIR])
    else:
        if os.path.exists(hc2200_path): os.remove(hc2200_path)
    
    if os.path.exists(pcap_path): os.remove(pcap_path)
    if os.path.exists(csv_path): os.remove(csv_path)

    return Response(rows_to_jsonl(rows), mimetype="application/x-ndjson")


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
