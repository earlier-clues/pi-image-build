# mpv-loop

A Pi that joins wifi, then plays one video file on infinite loop, fullscreen,
straight to the framebuffer via KMS. No videosync, no clustering, no UI.

## What gets baked in

- `mpv` + `alsa-utils` packages, `/etc/mpv/mpv.conf` set up for `vo=gpu / gpu-context=drm`.
- `/usr/local/bin/mpv-loop` — picks the first file in `/home/pi/video/` and runs `mpv --loop-file=inf` on it.
- `mpv-loop.service` — runs the launcher as user `pi`, restarts forever.
- `mpv-loop-assign-hostname.service` — sets hostname to `mpv-loop-<last 6 of wlan0 MAC>` on every boot.
- `wifi-powersave-off.service` — kills `iw wlan0 set power_save off`.
- `mpv-loop-boot-report.timer` — at T+90s after boot, dumps a diagnostic snapshot (services, wifi scan, NM profiles, journals) to `/boot/firmware/mpv-loop-boot.log`. The bootfs is FAT, so you can pull the SD card and read the log on macOS without ext4 tooling.
- NetworkManager profile for the aether AP (if `AP_SSID` is provided).
- SSH on, key auth only, `pi` user in sudoers nopasswd.

## Debugging a pi that won't come up

If the pi doesn't appear on the network, give it ~2 minutes after power-on,
then yank the SD card and plug it into your Mac. The bootfs partition
mounts at `/Volumes/bootfs/` and contains `mpv-loop-boot.log` — service
states, wifi scan results, NetworkManager profiles, and the last 40 lines
of every key service journal.

## Build

The image is generic; the video is supplied at build time. The easy path
is the wrapper, which reads a `.env`, derives the password hash + ssh key,
and calls `bin/build-image.sh` for you:

```bash
cd examples/mpv-loop
cp .env.example .env
$EDITOR .env          # fill in AP_*, PI_PASSWORD, SSH_PUBKEY_FILE, VIDEO
./build-example.sh
```

The video can be a single file or a directory. A single file gets staged
into a tempdir and mounted (no copy — symlink). Override on the CLI:

```bash
./build-example.sh --video /elsewhere/clip.mp4
./build-example.sh -c /path/to/other.env --output-format gz
```

Anything after the wrapper's own flags is passed through to
`bin/build-image.sh`.

If you'd rather drive the builder directly:

```bash
cd pi-image-build

export ENCRYPTED_PASSWORD="$(openssl passwd -6 "$PI_PASSWORD")"
export SSH_PUBKEY="$(cat ~/.ssh/id_ed25519.pub)"
export AP_SSID=aether AP_PSK=<the-psk> AP_COUNTRY=US

./bin/build-image.sh examples/mpv-loop \
    --output-format xz \
    --env-regex 'AP_.*|MPV_.*' \
    --mount video=/path/to/dir/containing/the/video
```

`MPV_AUDIO_OUT` (default `null`) is the only knob beyond the canonical
hostname/timezone/keymap/user envs. Set it to `alsa` if you want sound.

## Flash

From the pi-image-build root (where `out/` lives):

```bash
diskutil list external physical          # find your SD card's /dev/diskN
./bin/flash-image.sh mpv-loop /dev/diskN  # picks newest out/mpv-loop-*.img.*
```

Or pass an explicit image path instead of `mpv-loop`.

## Caveats

- The launcher plays only the **first** file (lexicographic) in `/home/pi/video/`.
  Bake exactly the one video you want looped; everything else in the
  mount directory gets copied but ignored.
- Hostname derivation reads `wlan0`. If you boot with no wifi adapter
  the assign-hostname service exits cleanly and the placeholder
  `mpv-loop` hostname persists.
- Trusted-LAN posture: nopasswd sudo + key-only SSH. Don't ship this
  to a stranger without re-evaluating.
