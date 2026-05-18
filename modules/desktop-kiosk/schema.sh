# desktop-kiosk module — configure a Pi OS Full desktop session for
# unattended kiosk operation: autologin, bloat removal, cursor hiding,
# screensaver/DPMS disable, boot quieting. Payload-local modules add
# their own wayfire [autostart] entries after this module runs.
#
# Requires Pi OS Full (desktop) as the base image. Must appear after
# core in modules.list (needs PI_USER to exist).

optional KIOSK_USER default=$PI_USER
optional KIOSK_DEBLOAT default=true
