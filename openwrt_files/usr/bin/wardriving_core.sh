#!/bin/sh

# Start virtual GPS server if it doesn't exist
killall socat 2>/dev/null
socat pty,link=/tmp/vGPS,raw,echo=0 tcp-listen:2947,reuseaddr,fork &

# Función para parpadear un LED si existe (feedback visual)
blink_led() {
    # Intenta encontrar un LED que probablemente sea seguro usar
    local LED=$(ls /sys/class/leds/ 2>/dev/null | grep -iE "usb" | head -n 1); [ -z "$LED" ] && LED=$(ls /sys/class/leds/ 2>/dev/null | grep -iE "wps|wlan|wifi|system|power" | head -n 1)
    if [ -n "$LED" ] && [ -f "/sys/class/leds/$LED/brightness" ]; then
        local current=$(cat /sys/class/leds/$LED/brightness)
        echo 0 > /sys/class/leds/$LED/brightness
        sleep 0.1
        echo 255 > /sys/class/leds/$LED/brightness 2>/dev/null || echo 1 > /sys/class/leds/$LED/brightness
        sleep 0.1
        echo $current > /sys/class/leds/$LED/brightness
    fi
}

while true; do
    if ! mount | grep -q "/mnt/wardriving"; then
        echo "ERROR: USB NOT DETECTED"
        exit 1
    fi

    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    FILENAME="/mnt/wardriving/wardriving_${TIMESTAMP}.pcapng"
    NMEAFILE="/mnt/wardriving/wardriving_${TIMESTAMP}.nmea"
    HC2200FILE="/mnt/wardriving/wardriving_${TIMESTAMP}.hc2200"
    TMP_ESSID="/tmp/essid_${TIMESTAMP}.txt"
    
    echo "[*] Starting session: $FILENAME"
    hcxdumptool -i wlan0mon -w "$FILENAME" --nmea_dev=/tmp/vGPS --nmea_pcapng --nmea_out="$NMEAFILE" -F -t 3 --tot=5
    
    if [ -f "$FILENAME" ]; then
        echo "[*] Converting $FILENAME to $HC2200FILE"
        hcxpcapngtool -o "$HC2200FILE" -E "$TMP_ESSID" "$FILENAME" > /dev/null 2>&1
        
        # Si la conversión generó un hash
        if [ -s "$HC2200FILE" ]; then
            blink_led
            # Fusionar hashes para sincronización
            cat "$HC2200FILE" >> /mnt/wardriving/master.hc2200
            awk '!a[$0]++' /mnt/wardriving/master.hc2200 > /tmp/tmp.hc2200 && mv /tmp/tmp.hc2200 /mnt/wardriving/master.hc2200
        fi
        
        # Limpiar el hc2200 individual (si estaba vacio se borra, si tenia hashes ya estan en el master)
        rm -f "$HC2200FILE"
        
        # Guardar diccionario de ESSID descubiertos
        if [ -s "$TMP_ESSID" ]; then
            cat "$TMP_ESSID" >> /mnt/wardriving/master_essid.txt
            sort -u /mnt/wardriving/master_essid.txt -o /mnt/wardriving/master_essid.txt
            rm -f "$TMP_ESSID"
        fi
        
        # Eliminar el archivo pcapng bruto para ahorrar almacenamiento (~90%)
        rm -f "$FILENAME"
    fi

    # Evitar que el log en RAM crezca infinitamente
    tail -n 2000 /tmp/wardriving_status.log > /tmp/wardriving_status.tmp 2>/dev/null && mv /tmp/wardriving_status.tmp /tmp/wardriving_status.log

    sync
    sleep 2
done
