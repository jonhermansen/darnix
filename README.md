# Darnix

Boot a fully open-source Darwin system using Nix. One command, no macOS install required (beyond the build host).

```
 ____    _    ____  _   _ _____  __
|  _ \  / \  |  _ \| \ | |_ _\ \/ /
| | | |/ _ \ | |_) |  \| || | \  /
| |_| / ___ \|  _ <| |\  || | /  \
|____/_/   \_\_| \_\_| \_|___/_/\_\
```

```
$ nix run github:jonhermansen/darwin-xnu-build/nix
```

Boots XNU (macOS 26.4 / xnu-12377.101.15) in QEMU with an HFS+ root filesystem, devfs, and a working `/dev/console` — all from a single Nix flake. The entire build runs under Nix's strict sandbox (`sandbox = true`) with no network access, no impure host dependencies, and no `/dev` access.

## What this is

Darnix is a revival of the [PureDarwin](https://www.puredarwin.org/) idea: run Apple's open-source XNU kernel with an entirely open userland managed by Nix. The long-term goal is a NixOS-style system on a Darwin kernel.

**Current status:** The kernel boots in QEMU (x86_64, TCG), mounts an HFS+ ramdisk as root, opens `/dev/console`, and executes a statically linked init binary that prints to serial. There is no networking, no kext loading, and no userland beyond init.

## What we had to do

### Nix build system (`darwin-xnu-build`)
- Wrapped [blacktop/darwin-xnu-build](https://github.com/blacktop/darwin-xnu-build) in a Nix flake that builds XNU in a fully sandboxed derivation
- All Apple open-source dependencies (bootstrap_cmds, dtrace, AvailabilityVersions, Libsystem, libplatform, libdispatch) fetched as flake inputs
- Xcode SDK and KDK extracted from Apple's downloads and wrapped as Nix derivations
- `nix run` builds the kernel, assembles a GRUB EFI image with embedded ramdisk, and launches QEMU

### XNU kernel patches (`xnu`)

**QEMU platform support:**
- Built-in platform expert for QEMU (`IOQEMUPlatform`) — no IOKit kexts needed
- PRNG fallback when RDRAND/RDSEED are unavailable (QEMU TCG doesn't emulate them)
- `ignore_msrs` boot arg for unimplemented MSRs under TCG
- TSC fallback when `MSR_PLATFORM_INFO` bus ratio reads as 0
- EFI runtime mapping skip for QEMU's firmware
- Default to 1 CPU when ACPI tables are missing

**Bare boot (no kexts):**
- Skip networking, pthread shims, trust cache, corecrypto, AMFI
- Guard subsystems that assume kexts/coalitions/entitlements are present
- Allow `PE_i_can_has_debugger` on DEVELOPMENT builds
- Skip code signing validation when enforcement is disabled

**HFS+ as root filesystem:**
- Registered HFS as an in-kernel filesystem
- Added `VFC_VFSCANMOUNTROOT` flag so `vfs_mountroot()` tries HFS
- Fixed `bsd_init` console open: `FREAD|FWRITE` → `O_RDWR`, `authfd=0` → `AUTH_OPEN_NOAUTHFD`

### HFS+ in-kernel build (`hfs`)

Apple's HFS+ ships as a kext depending on IOKit and corecrypto. We ported it to compile directly into the kernel:
- Stubbed IOKit helper functions
- Called `hfs_init_zones()` from `hfs_init()` (previously only called from the kext's IOKit entry point)
- Fixed `hfs_getvoluuid()` to use a fixed UUID (MD5 requires corecrypto which isn't available)
- Stubbed AKS (Apple Key Services) for content protection code paths
- Patched `newfs_hfs` to format regular files, not just block devices (runs inside Nix sandbox)

### GRUB (`grub`)
- Fixed `xnu_kernel64` page fault loading 64-bit Mach-O kernels
- Added Nix flake for building GRUB EFI on aarch64-darwin

### HFS+ ramdisk image
- Built with patched `newfs_hfs` + `xpwn`'s `hfsplus` tool
- 8 MB image containing `/sbin/launchd` and `/dev` mountpoint
- Created entirely inside the Nix sandbox — no root, no devices

## Architecture

```
nix run
  └─ QEMU (x86_64, TCG, no KVM)
       └─ GRUB EFI (grub-mkstandalone)
            ├─ xnu_kernel64 /boot/kernel
            ├─ xnu_ramdisk /boot/rootfs-hfs.dmg   ← HFS+ image
            └─ boot
                 └─ XNU boots
                      ├─ vfs_mountroot() → HFS+ on md0
                      ├─ devfs_kernel_mount("/dev")
                      ├─ open /dev/console → fd 0/1/2
                      └─ exec /sbin/launchd (init)
```

## Boot options

GRUB presents two menu entries:

| Entry | Root filesystem | Description |
|-------|----------------|-------------|
| **Darnix (HFS+)** | 8 MB HFS+ ramdisk | Real filesystem with directory hierarchy |
| **Darnix (mockfs)** | Raw Mach-O binary | Minimal fake FS for debugging (the ramdisk *is* the binary) |

## Current limitations

- **x86_64 only** — cross-compiled from aarch64-darwin, runs under TCG (no KVM on Apple Silicon)
- **No networking** — network subsystem init is skipped
- **No crypto** — corecrypto kext not loaded, volume UUID is hardcoded
- **No kext loading** — HFS, devfs, and all filesystems are compiled into the kernel
- **No ACPI** — fake platform expert, hardcoded to 1 CPU
- **Build host** — currently requires aarch64-darwin (macOS on Apple Silicon) with Xcode SDK

## Building

```bash
# Build everything (kernel + ESP + ramdisk)
nix build .#esp

# Build and boot in QEMU
nix run

# Build just the kernel
nix build .#xnu-x86_64
```

## Repositories

| Repo | Branch | Description |
|------|--------|-------------|
| [darwin-xnu-build](https://github.com/jonhermansen/darwin-xnu-build/tree/nix) | `nix` | Nix flake, build scripts, init binary, QEMU runner |
| [xnu](https://github.com/jonhermansen/xnu/tree/nix) | `nix` | Patched XNU kernel |
| [hfs](https://github.com/jonhermansen/hfs/tree/nix) | `nix` | HFS+ ported to in-kernel build |
| [grub](https://github.com/jonhermansen/grub/tree/nix) | `nix` | GRUB with Mach-O fix + Nix flake |

## What's next

- Shell: get toybox running with serial I/O
- Kext support: rebuild with proper kext loading infrastructure
- Native x86_64 build: currently cross-compiles, should compile natively too
- DMG installer: boot from a DMG on real hardware via development kernel

## Special thanks

[Obsidian Systems](https://obsidian.systems/) — The partner to bring your digital dream to life.

## Credit

- [blacktop/darwin-xnu-build](https://github.com/blacktop/darwin-xnu-build) — upstream build scripts that this project wraps
- [PureDarwin](https://www.puredarwin.org/) — the original vision
- [NixThePlanet](https://github.com/MatthewCroughan/NixThePlanet) — Nix-based OS virtualization
- [kernelshaman](https://kernelshaman.blogspot.com/2021/02/building-xnu-for-macos-112-intel-apple.html)
