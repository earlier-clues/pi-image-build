# Design Decisions

A log of non-obvious architectural choices, the alternatives considered, and
the conditions under which we'd revisit. Append new sections at the bottom
as decisions get made. Don't edit old entries in place — supersede with a
new entry that links back.

---

## Module system: roll our own (not Nix, not Ansible)

**Decided:** 2026-05-13
**Status:** active

### Context

pi-image-build is moving toward a module-composition model: a Pi image becomes
a list of modules (wifi, tailscale, boot-report, mqtt-telemetry, mpv-loop, …)
plus their per-deployment configuration. See `TODO.md` for the principle and
the planned modules.

Before building this on top of pi-image-build, we asked whether to instead
adopt an existing tool that already implements module composition for Linux
hosts.

### Alternatives considered

#### Nix / NixOS

The architecturally correct answer. NixOS *is* the module system we're
sketching, but mature, with thousands of person-years of work behind it.

- `nixos-generators -f sd-aarch64` builds Pi SD images directly from a flake.
- Composition is `imports = [ ./tailscale.nix ./mqtt.nix ];`. Module
  ordering, conflicts, conditional inclusion — all solved problems.
- Reproducibility is bit-for-bit, not aspirational. "Rebuild the Gospel
  installation in 2027 from a git tag" is a one-liner.
- Service definitions collapse to one-liners
  (`services.openssh.enable = true;`).

Cost:

- Pi OS → NixOS migration. Different default tooling (no raspi-config, different
  firmware update path, different community ecosystem around the Pi hardware).
  First-class arm64 support is good but rougher than Pi OS for Pi-specific bits
  (firmware overlays, vcgencmd, GPU drivers).
- Nix language and module system are their own paradigm. Weeks of learning,
  not days.
- Existing aether/server, aether/zero, and mpv-loop payloads all get
  rewritten as NixOS configurations.

#### Ansible

Imperative, role-based config management. Roles ≈ modules.

Cost / mismatch:

- Ansible's natural fit is **run-time**: ssh into a booted host, push
  config, declare success. pi-image-build is **bake-time**: configure
  the image during the docker chroot, flash, done.
- The Ansible-native path is "flash vanilla Pi OS → boot →
  `ansible-playbook` configures it." That loses pi-image-build's key
  property ("flash + boot = configured") and replaces bake-time
  reproducibility with two-stage drift.
- Running Ansible against a chroot at bake-time works but fights the
  tool's grain.

#### Roll our own (chosen)

Extend pi-image-build with a `modules/` directory. Each module owns:
- `schema.sh` declaring required env vars and defaults (validated host-side
  before docker spins up)
- `module.sh` running in the chroot
- `files/` for anything to ship verbatim

A payload collapses to `modules.list` + `.env`. `bin/build-image.sh` reads
the list, validates each schema, then runs each module's script.

Estimated ~200 LOC of shell. Stays in the idiom we already understand.
The composition shape is identical to NixOS's `imports = [...]` — just
dumber and in shell, so a future migration maps 1:1.

### Decision

Roll our own module system on top of pi-image-build.

### Why (the underlying axis)

The hidden axis under "Nix vs Ansible vs roll-our-own" is
**bake-time vs run-time configuration**. pi-image-build is fundamentally
bake-time: configure once during chroot, flash, that's it until reflash.

- Nix is bake-time + has a run-time push path (`nixos-rebuild switch`). Aligned.
- Ansible is run-time-native, awkward at bake-time. Misaligned.
- Rolling our own is bake-time-native by construction. Aligned and cheap.

Nix is the correct *eventual* answer. It's the wrong *now* answer because
the migration cost (new OS, new language, port everything) exceeds the
benefit at our current scale (~5 pis, 3 payloads, solo dev). The shell
module system buys time without painting us into a corner — when we
migrate, the module shape transfers.

The thing we explicitly do *not* do is Ansible. It solves a different
problem than the one we have.

### Migration triggers

Revisit this decision and likely move to Nix if **any** of:

- **Scale:** more than ~20 modules total, or more than ~10 payloads.
- **Reproducibility requirement:** a real need to rebuild a specific
  installation from a git tag a year later, bit-equivalent. (Gospel-rebuild
  scenario.)
- **Second maintainer:** someone else starts contributing and would
  benefit from Nix's docs + ecosystem more than from learning our bespoke
  shell conventions.
- **Dependency graph complexity:** modules conditionally including modules,
  cross-module ordering constraints, or templated module sets. (Signs that
  we're reinventing a worse module system.)

None of these are true on 2026-05-13. Several are plausible within 1–2 years.
