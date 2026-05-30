# OpenWardRivingT 🛰️🚗

OpenWardRivingT es una suite automatizada de wardriving pasivo para hardware **OpenWrt** (optimizada para routers con chipsets Atheros como Netgear WNDR3700, GL-A1300, etc). Está diseñada para operar de forma autónoma (headless) en tu vehículo, capturando handshakes (PMKID y EAPOL) y mapeando las redes mediante un GPS (desde un dispositivo Android conectado).

Cuenta con un espectacular **Panel de Control Web** (La "Baticueva") optimizado para usarse desde la pantalla táctil de tu radio Android o Tablet en el auto, con estadísticas en tiempo real, mapas offline y gestor de capturas.

## Características ✨
- **100% Autónomo**: Empieza a capturar con pulsar un botón físico del router (WPS/WiFi).
- **Dashboard Vehicular**: Interfaz web (SPA) diseñada con íconos y textos grandes para conductores.
- **Analizador de Espectro en Vivo**: Visualiza congestiones en los canales 2.4GHz en tiempo real.
- **Mapa (Online/Offline)**: Mira en el mapa por dónde has estado y la ubicación geolocalizada de cada router descubierto usando Leaflet.js.
- **Feedback Visual**: El LED de tu router parpadea cuando está capturando handshakes activamente.
- **Integración GPS Nativa**: Inyecta datos NMEA en los archivos `.pcapng` y visualiza la traza del recorrido.

## Requisitos de Hardware 🛠️
1. **Router OpenWrt**: Preferiblemente con 2 radios (2.4GHz para modo monitor e inyección, y 5GHz para acceder al panel de control).
2. **Pendrive USB**: Formateado en `ext4` para almacenar las capturas y montado en `/mnt/wardriving/`.
3. **Fuente de Poder Vehicular**: Convertidor de 12V a 5V/12V dependiendo de tu router.

## Requisitos de Software 📦
Asegúrate de tener instalados los siguientes paquetes en tu OpenWrt:
- `hcxdumptool` (v6.3+)
- `hcxtools` (contiene hcxpcapngtool)
- `socat`
- `uhttpd` (usualmente incluido por defecto en OpenWrt)

## Instalación Fácil 🚀
1. Conéctate a tu router OpenWrt por SSH.
2. Clona o descarga este repositorio.
3. Ejecuta el instalador:
   ```bash
   chmod +x install.sh
   ./install.sh
   ```
4. El script configurará automáticamente la red de 5GHz (`owrt` / `wardriving`), copiará la aplicación web y activará el servicio.

## Uso Básico 🚙
1. Enciende el router en el vehículo y asegúrate de que el USB esté conectado.
2. Abre la app en tu Tablet/Radio Android apuntando al puerto NMEA por defecto (2947).
3. Conéctate al WiFi 5GHz del router (`owrt`).
4. Entra a `http://192.168.1.1/wardriving/index.html` (o la IP que tenga tu router).
5. Pulsa **START** en la pantalla o usa el botón físico del router configurado. ¡Y a conducir!

## Gestión de Mapas Offline 🗺️
En la pestaña "Ajustes" de la aplicación, puedes subir un archivo `.tar.gz` que contenga una carpeta `tiles/` generada con Mobile Atlas Creator. Esto te permitirá tener un mapa callejero local sin necesidad de gastar datos móviles mientras manejas.
# OpenWardRivingT
