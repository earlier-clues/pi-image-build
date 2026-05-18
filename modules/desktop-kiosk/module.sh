# desktop-kiosk module — configure a Pi OS Full desktop session for
# unattended kiosk operation. Runs INSIDE the chroot (arm64-via-qemu).
#
# Assumes Pi OS Full (desktop + wayfire) as the base. Payload-local
# modules add their own [autostart] entries to wayfire.ini after this
# module.

source "$LIB_DIR/apt.sh"

if ! id "$KIOSK_USER" >/dev/null 2>&1; then
    echo "modules/desktop-kiosk: KIOSK_USER='$KIOSK_USER' missing — core must precede desktop-kiosk in modules.list" >&2
    exit 2
fi

echo "--- desktop-kiosk module: user=$KIOSK_USER debloat=$KIOSK_DEBLOAT ---"

# 1. Boot to desktop with autologin (raspi-config B4).
raspi-config nonint do_boot_behaviour B4

# 2. Purge piwiz first-boot wizard — always, regardless of KIOSK_DEBLOAT.
rm -f /etc/xdg/autostart/piwiz.desktop
apt-get purge -y piwiz 2>/dev/null || true

# 3. Conditional desktop debloat.
if [[ "$KIOSK_DEBLOAT" == "true" ]]; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get purge -y --auto-remove \
        'libreoffice*' wolfram-engine sonic-pi 'thonny*' 'scratch*' \
        'minecraft-pi*' nuscratch realvnc-vnc-server realvnc-vnc-viewer \
        'rpi-chromium-mods' 2>/dev/null || true
    apt-get autoremove -y --purge
fi

# 4. Cursor hiding.
apt_install unclutter

# 5. Base wayfire.ini — hide-cursor + idle (DPMS off) + empty [autostart].
install -d -m 755 "/home/$KIOSK_USER/.config"
cat > "/home/$KIOSK_USER/.config/wayfire.ini" <<'WAYFIRE'
[core]
plugins = autostart hide-cursor idle

[autostart]

[hide-cursor]
hide_delay = 0.1

[idle]
dpms_timeout = -1
WAYFIRE
chown -R "$KIOSK_USER:$KIOSK_USER" "/home/$KIOSK_USER/.config"

# 6. Boot quieting — suppress splash screen, kernel logo, console cursor.
CMDLINE=/boot/firmware/cmdline.txt
sed -i 's/ \?splash//g' "$CMDLINE"
for _param in 'consoleblank=0' 'quiet' 'loglevel=0' 'logo.nologo' 'vt.global_cursor_default=0'; do
    grep -q "$_param" "$CMDLINE" || sed -i "s/$/ $_param/" "$CMDLINE"
done
unset _param

CONFIG=/boot/firmware/config.txt
if grep -qE "^[# ]*disable_splash=" "$CONFIG"; then
    sed -i -E "s|^[# ]*disable_splash=.*|disable_splash=1|" "$CONFIG"
else
    printf 'disable_splash=1\n' >> "$CONFIG"
fi

echo "--- desktop-kiosk module done ---"
