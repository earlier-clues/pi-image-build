# test-image.sh (planned)

A QEMU smoke-test runner. Not yet implemented — placeholder so the joint is named.

## What it should do

```
test-image.sh <image-file>                              # interactive: boot, print ssh command
test-image.sh <image-file> --check 'CMD'                # CI: boot, run CMD over SSH, exit code 0/1
test-image.sh <image-file> --pubkey ~/.ssh/id_ed25519.pub  # inject pubkey before launch
```

Boots the image under `qemu-system-aarch64 -M virt`, forwards a host port to
guest 22, waits for SSH to come up, and either drops the user into a shell
or runs the check command and exits.

## What works

- Booting userspace, init, services. systemd, network stack, file layout, package state.
- Apple Silicon hosts get HVF acceleration — fast. Intel Macs get emulation — slower but fine.

## What doesn't

- Pi-specific hardware: GPIO, I2C, PWM, camera CSI, hardware HDMI/audio. The `raspi3b` / `raspi4b` QEMU machines exist but are flaky on Bookworm; not worth using.
- Real wifi. QEMU networking is slirp/usermode — `wpa_supplicant.conf` is verifiable, association is not.
- Boot timing: races sometimes hide or surface differently than on metal.

## Implementation notes for whoever picks this up

- Extract kernel + initrd from the image's boot partition (or use a known-good arm64 kernel — Debian's `linux-image-arm64` works against arbitrary rootfses).
- Inject an authorized_keys for first-boot access. The kiosk customize step disables password auth, so SSH-by-key is the only way in.
- Port-forward 22 → host port (e.g. 5022). Wait on `nc -z localhost 5022` with a timeout, then SSH.
- On failure: leave the qemu process running and print the SSH command, so the user can investigate. Don't auto-cleanup unless `--check` was passed.
