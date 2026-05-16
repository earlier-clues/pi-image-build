# mpv-loop module — payload-local. Installs mpv + alsa-utils, KMS config,
# the assign-hostname-from-MAC unit, the wifi-powersave-off unit, and the
# mpv-loop service that plays a looped video.

optional MPV_AUDIO_OUT default=null

# Wifi profile is optional — only installed if AP_SSID is set. Both
# AP_PSK and (existing optional) AP_COUNTRY are consumed by core, but
# the *profile install* lives here so mpv-loop-without-wifi works.
optional AP_SSID  default=
optional AP_PSK   default=
