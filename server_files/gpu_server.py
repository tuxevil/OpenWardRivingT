import os
import subprocess
from flask import Flask, request

app = Flask(__name__)

# ================= RUTAS Y CONFIGURACIÓN =================
UPLOAD_DIR = "/root/wardriving_uploads"
DICT_DIR = "/root/dicts"
ROUTER_IP = "192.168.1.1" 
ROUTER_TOKEN = "8qVLrQmXACkghv8lkKhH0u3pFJ2LHR8L"
HCXPCAPNGTOOL_BIN = "hcxpcapngtool" 
# =========================================================

os.makedirs(UPLOAD_DIR, exist_ok=True)

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

@app.route('/upload', methods=['POST'])
def receive_pcap():
    if 'pcap' not in request.files:
        return "Error: No pcap file", 400
        
    pcap_file = request.files['pcap']
    base_name = pcap_file.filename or "capture.pcapng"
    pcap_path = os.path.join(UPLOAD_DIR, base_name)
    pcap_file.save(pcap_path)
    
    hc2200_path = pcap_path + ".hc2200"
    csv_path = pcap_path + ".csv"
    
    subprocess.run([HCXPCAPNGTOOL_BIN, "-o", hc2200_path, "--csv", csv_path, pcap_path], capture_output=True)
    
    sql_statements = []
    if os.path.exists(csv_path):
        with open(csv_path, "r", encoding="utf-8", errors="ignore") as f:
            for line in f:
                parts = line.strip().split("\t")
                if len(parts) >= 10:
                    mac = parts[1]
                    ssid = parts[2].replace("'", "''") 
                    enc = parts[3]
                    chan = parts[7]
                    rssi = parts[8]
                    
                    # Extraer y convertir GPS
                    lat = parse_nmea(parts[9], False, parts[10] if len(parts) > 10 else 'N') if len(parts) > 9 else "NULL"
                    lon = parse_nmea(parts[11], True, parts[12] if len(parts) > 12 else 'E') if len(parts) > 11 else "NULL"
                    
                    sql = f"INSERT INTO networks (mac, ssid, enc, channel, lat, lon, rssi, first_seen, last_seen) VALUES ('{mac}', '{ssid}', '{enc}', {chan}, {lat}, {lon}, {rssi}, datetime('now'), datetime('now')) ON CONFLICT(mac) DO UPDATE SET rssi=EXCLUDED.rssi, last_seen=datetime('now');"
                    sql_statements.append(sql)
    
    if os.path.exists(hc2200_path) and os.path.getsize(hc2200_path) > 0:
        subprocess.Popen(["bash", "/root/run_hashcat.sh", hc2200_path, ROUTER_IP, ROUTER_TOKEN, DICT_DIR])
    else:
        if os.path.exists(hc2200_path): os.remove(hc2200_path)
    
    if os.path.exists(pcap_path): os.remove(pcap_path)
    if os.path.exists(csv_path): os.remove(csv_path)

    return "\n".join(sql_statements), 200


@app.route('/upload_hc2200', methods=['POST'])
def receive_hc2200():
    if 'hc2200' not in request.files:
        return "Error: No hc2200 file", 400
        
    hc2200_file = request.files['hc2200']
    base_name = hc2200_file.filename or "offline_sync.hc2200"
    hc2200_path = os.path.join(UPLOAD_DIR, base_name)
    hc2200_file.save(hc2200_path)
    
    if os.path.exists(hc2200_path) and os.path.getsize(hc2200_path) > 0:
        subprocess.Popen(["bash", "/root/run_hashcat.sh", hc2200_path, ROUTER_IP, ROUTER_TOKEN, DICT_DIR])
        return "Offline hashes queued", 200
    else:
        if os.path.exists(hc2200_path): os.remove(hc2200_path)
        return "Empty file", 200

if __name__ == '__main__':
    print("[*] Iniciando OpenWardrivingT GPU Server en puerto 5000...")
    app.run(host='0.0.0.0', port=5000)
