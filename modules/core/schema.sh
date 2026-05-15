# core module — baseline OS configuration. Required for any payload that
# wants a usable Pi (boots, has a user, sshable, on wifi). Composed of
# pure lib/*.sh calls; no new behavior.

require HOSTNAME
require TIMEZONE
require PI_USER
require ENCRYPTED_PASSWORD
require SSH_PUBKEY

optional KEYMAP default=us
optional AP_COUNTRY default=US
