#!/bin/bash
# Locale, timezone, keyboard. Run inside the chroot.
LIB_API_VERSION=1

set_timezone() {
    local tz="$1"
    ln -sf "/usr/share/zoneinfo/$tz" /etc/localtime
    echo "$tz" > /etc/timezone
}

set_keyboard() {
    local layout="$1"
    cat > /etc/default/keyboard <<KBD
XKBMODEL="pc105"
XKBLAYOUT="$layout"
XKBVARIANT=""
XKBOPTIONS=""
BACKSPACE="guess"
KBD
}
