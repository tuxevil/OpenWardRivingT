#!/bin/sh

# Start virtual GPS server if it doesn't exist
killall socat 2>/dev/null
socat pty,link=/tmp/vGPS,raw,echo=0 tcp-listen:2947,reuseaddr,fork &

while true; do
    if ! mount | grep -q "/mnt/wardriving"; then
        echo "ERROR: USB NOT DETECTED"
        exit 1
    fi

    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    FILENAME="/mnt/wardriving/wardriving_${TIMESTAMP}.pcapng"
    NMEAFILE="/mnt/wardriving/wardriving_${TIMESTAMP}.nmea"
    
    echo "[*] Starting session: $FILENAME"
    hcxdumptool -i wlan0mon -w "$FILENAME" --nmea_dev=/tmp/vGPS --nmea_pcapng --nmea_out="$NMEAFILE" -F -t 3 --tot=5
    
    sync
    sleep 2
done
