# home-wifi — install one NetworkManager wifi profile so the Pi joins
# the home AP at boot. Capability lives in lib/wifi.sh.

source "$LIB_DIR/wifi.sh"

echo "--- home-wifi module ---"
install_nm_wifi home-wifi "$WIFI_SSID" "$WIFI_PSK" "" 100
echo "  installed wifi profile for SSID: $WIFI_SSID"
echo "--- home-wifi module done ---"
