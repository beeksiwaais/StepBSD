# StepBSD

**NextBSD with GNUstep and the Gershwin desktop, on an installable ISO.**

StepBSD is a fork of [NextBSD](https://github.com/nextbsd/nextbsd): a FreeBSD
15.1 kernel with Darwin's system layer (`launchd` as PID 1, Mach IPC,
`configd`, the IOKit registry, `.plist` services). NextBSD keeps GNUstep out of
its base on purpose ([PORTING.md](PORTING.md): "GNUstep is not on this ISO")
and plans it as a desktop layer on top, in its
[E24 plan](https://github.com/nextbsd/nextbsd-userland/wiki/E24-GNUstep-Gershwin-Requirements-Direction).
StepBSD is that layer, built the way the plan says:

| | NextBSD | StepBSD |
|---|---|---|
| System layer | launchd, Mach, Darwin userland | the same, from NextBSD's packages |
| GNUstep | support libraries only | libobjc2, gnustep-make, -base, -gui, -back, built from source |
| Desktop | none (text console) | Gershwin: LoginWindow, Workspace, Menu, WindowManager, SystemPreferences, Terminal, TextEdit and the rest |
| X, Mesa, GNUstep's libraries | NextBSD packages, not in the default image | the same NextBSD packages, installed |
| FreeBSD packages | the ports repo is configured | none; the image configures NextBSD's and StepBSD's repositories only |
| Installer | `nextbsd-installer` | the same, installing the desktop too |

## Get it

The [continuous release](https://github.com/beeksiwaais/StepBSD/releases/tag/continuous)
holds the latest images:

| | amd64 | arm64 |
|---|---|---|
| For | x86-64 PCs and VMs (BIOS or UEFI) | UEFI arm64 machines and VMs (Apple Silicon under QEMU/UTM, Arm servers) |
| Live + installer ISO | `StepBSD-amd64-<date>.iso` | `StepBSD-arm64-<date>.iso` |
| Installed disk image | `StepBSD-amd64-<date>.img.zip` | `StepBSD-arm64-<date>.img.zip` |

### Try it in a VM

```sh
qemu-img create -f qcow2 stepbsd.qcow2 20G
qemu-system-x86_64 -machine q35 -accel kvm -cpu host -m 4096 -smp 2 \
  -bios /usr/share/ovmf/OVMF.fd \
  -cdrom StepBSD-amd64-*.iso -boot d \
  -drive file=stepbsd.qcow2,if=virtio -nic user,model=e1000
```

On Apple Silicon, use the arm64 ISO, which runs at native speed with HVF:

```sh
qemu-img create -f qcow2 stepbsd.qcow2 20G
qemu-system-aarch64 -machine virt -accel hvf -cpu host -m 4096 -smp 4 \
  -bios "$(brew --prefix qemu)/share/qemu/edk2-aarch64-code.fd" \
  -drive file=StepBSD-arm64-*.iso,format=raw,if=none,id=cd0,media=cdrom \
  -device virtio-scsi-pci -device scsi-cd,drive=cd0,bootindex=0 \
  -drive file=stepbsd.qcow2,if=virtio \
  -device virtio-gpu-pci -device qemu-xhci -device usb-kbd -device usb-tablet \
  -netdev user,id=net0 -device virtio-net-pci,netdev=net0,romfile=
```

### Install

1. Write the ISO to a USB stick (`dd if=StepBSD-<arch>-<date>.iso of=/dev/<stick> bs=1m`)
   and boot it.
2. Log in as `admin` (no password) at the login window, open Terminal and run
   NextBSD's installer:

   ```sh
   sudo nextbsd-installer
   ```

   Pick the disk and confirm. **The whole disk is erased.** It is
   partitioned GPT (BIOS boot code on amd64, an EFI system partition, a UFS
   root) and the running system, desktop included, is copied onto it.
3. Remove the stick and reboot.

Unattended: `sudo /usr/libexec/nextbsd-installer/do-install.sh -d <disk>`,
the installer's own back end.

## Using it

- launchd starts Gershwin's LoginWindow, which starts X. While it is
  installed NextBSD logs nobody in automatically on the console: the login
  window asks. The first account, `admin`, has no password.
- GNUstep lives in `/System` (gnustep-make's `gershwin` layout):
  applications in `/System/Applications`, frameworks, libraries and tools in
  `/System/Library`. `. /System/Library/Makefiles/GNUstep.sh` sets up a
  shell for building GNUstep software with the installed toolchain
  (`NextBSD-toolchain`: clang, gmake, cmake, autotools, git).
- `pkg upgrade` updates NextBSD from NextBSD's repository and the desktop
  from StepBSD's (`StepBSD-desktop`).
- Everything else is NextBSD: see [NEXTBSD-README.md](NEXTBSD-README.md)
  (`launchctl`, `ipconfig`, `ioreg`, `syslog`, ...).

## How it is built

1. **The desktop** ([`stepbsd/desktop`](stepbsd/desktop)): GNUstep and
   Gershwin from pinned sources, built on a NextBSD system assembled from
   NextBSD packages, with NextBSD's own toolchain, into `/System`, and
   packaged as `StepBSD-desktop`. What did not behave on NextBSD is patched
   there (see its README); nothing is worked around in the image.
2. **The image**: NextBSD's `build.sh`, run in a FreeBSD 15.1 VM, installs
   `NextBSD-everything` and then sources [`stepbsd/layer.sh`](stepbsd/layer.sh),
   which installs `StepBSD-desktop` and `NextBSD-toolchain` from NextBSD's and
   StepBSD's repositories, drops the FreeBSD repository, adds the desktop's
   launchd jobs (LoginWindow, dshelper, gdomap) and checks the result: no
   package from anywhere else, every shared library present, and GNUstep
   running. `build.sh` then makes the disk image and the live ISO exactly as
   NextBSD does.
3. **The test** ([`tests/stepbsd-install-test.sh`](tests/stepbsd-install-test.sh)):
   in qemu, install the ISO onto a blank disk with NextBSD's installer, boot
   the installed system (amd64: BIOS; arm64: UEFI), check the packages, the
   libraries, GNUstep and the launchd jobs, then boot it with UEFI like a real
   machine, log in as `admin` at the login window and check the screenshots:
   the login window, then the desktop session's menu bar.

```sh
# on FreeBSD 15.1, as root, on the target architecture:
pkg install -y git zip
sh stepbsd/desktop/package.sh stepbsd-packages
DIST_NAME=StepBSD ARCH=$(uname -m) sh build.sh     # -> out/StepBSD-<arch>-*.{iso,img}.zip
# anywhere with qemu and expect (KVM, or HVF on Apple Silicon for arm64):
sh tests/stepbsd-install-test.sh out/StepBSD-<arch>-*.iso.zip
```

### CI and maintenance

- [`stepbsd.yml`](.github/workflows/stepbsd.yml) builds the desktop for
  amd64 and arm64 in native FreeBSD VMs (three chained jobs, since the
  emulated arm64 build is longer than one job may run), then the images,
  runs the install test on each and publishes `continuous` and the pkg
  repositories `packages-amd64` and `packages-arm64`. A weekly run rebuilds
  against NextBSD's latest packages.
- [`sync-upstream.yml`](.github/workflows/sync-upstream.yml) merges
  nextbsd/nextbsd into `sync/upstream` every week, builds and tests it, and
  opens a pull request; a conflict opens an issue instead. StepBSD changes
  only a few hook lines in upstream's `build.sh`.

## Licence

StepBSD's own files are BSD-2-Clause, like NextBSD's ([LICENSE](LICENSE),
[NOTICE](NOTICE)). The desktop's components keep their licences (GPL, LGPL,
MIT, Apache, BSD); see [stepbsd/desktop/NOTICE.md](stepbsd/desktop/NOTICE.md).
