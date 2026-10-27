# StepBSD

**NextBSD with the GNUstep desktop, on an installable ISO.**

StepBSD is a fork of [NextBSD](https://github.com/nextbsd/nextbsd): a FreeBSD
15.1 kernel with Darwin's system layer (`launchd` as PID 1, Mach IPC,
`configd`, IOKit registry, `.plist` services). StepBSD adds the part a NeXT
heritage calls for and NextBSD does not ship, a
[GNUstep](https://gnustep.org) desktop, and adds an installer, so the ISO
boots a live desktop and installs to disk:

| | NextBSD | StepBSD |
|---|---|---|
| System layer | launchd, Mach, Darwin userland | same, from NextBSD's packages |
| GNUstep | support libraries only | gnustep-base 1.31, gui/back 0.32 |
| Desktop | none (text console) | Window Maker + GWorkspace, Terminal, SystemPreferences, Preview, ImageViewer, Addresses, SimpleAgenda, Gorm, ProjectCenter |
| X server | not in the default image | XLibre with libinput, scfb/vesa/modesetting |
| ISO | live only | live + `stepbsd-install` (BIOS + UEFI GPT) |

## Get it

The [continuous release](https://github.com/beeksiwaais/StepBSD/releases/tag/continuous)
is rebuilt every week and on every change. Each build has been installed to a
disk and booted in CI before it is published.

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

### Install on a PC

1. Write the ISO to a USB stick: `dd if=StepBSD-amd64-<date>.iso of=/dev/<stick> bs=1m`.
2. Boot it. The live system logs `admin` in (no password) and starts the
   desktop.
3. Open Terminal (in the dock on the right) and run:

   ```sh
   sudo stepbsd-install
   ```

   Pick the target disk and type `yes`. **The whole disk is erased.** It is
   partitioned GPT with BIOS boot code (amd64), an EFI system partition and a UFS
   root labelled `ROOTFS`, the layout of NextBSD's disk image. The root
   grows to fill the disk.
4. Remove the stick and reboot.

Unattended: `sudo stepbsd-install -y -d ada0 -p` (installs without asking, then
powers off).

## Using it

- The desktop is Window Maker with GWorkspace, the GNUstep Workspace
  Manager, which draws the desktop and the file viewers. The dock on the right
  holds GWorkspace, Terminal, SystemPreferences, Preview and xterm; every
  GNUstep application is in `/usr/local/GNUstep/System/Applications`.
- The desktop starts by itself on the first virtual console. `touch
  ~/.stepbsd-nodesktop` turns that off; `startstep` starts it by hand.
  `~/.xsession` replaces the session.
- `pkg install <name>` installs from NextBSD's repository and from FreeBSD's
  ports packages (for example `pkg install gnumail pikopixel cenon`; `pkg
  search -c gnustep` lists the GNUstep software).
- Everything else is NextBSD: see [NEXTBSD-README.md](NEXTBSD-README.md)
  (`launchctl`, `ipconfig`, `ioreg`, `syslog`, ...).

## How it is built

`build.sh` is NextBSD's image builder, run in a FreeBSD 15.1 VM in GitHub
Actions. It installs `NextBSD-everything` from nextbsd-pkg into a staged
root, then sources [`stepbsd/layer.sh`](stepbsd/layer.sh). The layer:

1. installs [`stepbsd/packages.txt`](stepbsd/packages.txt) from FreeBSD's
   package repository;
2. removes [`stepbsd/prune.txt`](stepbsd/prune.txt), about 780 MiB of
   ImageMagick build and Python dependencies the desktop never loads. A
   shared-library closure check before and after fails the build if pruning
   removes a library anything still needs;
3. lays [`stepbsd/overlay/`](stepbsd/overlay) onto the root: the installer,
   the X session, and launchd jobs for `gdomap` and for the linker hints and
   caches;
4. builds the linker hints and the font, MIME and GLib caches in a chroot
   (amd64). The cross-built arm64 image builds them on its first boot.

`build.sh` then makes the disk image and the live ISO exactly as NextBSD does.

```sh
# on FreeBSD 15.1 (amd64), as root; ARCH=arm64 cross-builds the arm64 image:
pkg install -y git zip
DIST_NAME=StepBSD ARCH=amd64 sh build.sh      # -> out/StepBSD-amd64-*.{iso,img}.zip
sh tests/stepbsd-install-test.sh out/StepBSD-amd64-*.iso.zip   # needs qemu + expect
```

### CI and maintenance

- [`stepbsd.yml`](.github/workflows/stepbsd.yml) builds the amd64 and arm64
  ISOs, runs
  [`tests/stepbsd-install-test.sh`](tests/stepbsd-install-test.sh) and
  publishes `continuous`. On a runner of each architecture, the test installs
  to a disk from the live ISO, boots the installed system (amd64: BIOS; arm64:
  UEFI), checks GNUstep at run time, then boots it with UEFI and checks a
  screenshot of the desktop. It runs on every push and
  PR, and every Monday so new NextBSD and FreeBSD packages get picked up.
- [`sync-upstream.yml`](.github/workflows/sync-upstream.yml) merges
  nextbsd/nextbsd into `sync/upstream` every Monday, builds and tests it, and
  opens a pull request. A conflict opens an issue instead. StepBSD changes
  only two hook lines and the artifact names in upstream's `build.sh`, so
  merges are usually clean.

## Licence

BSD-2-Clause like NextBSD (see [LICENSE](LICENSE) and [NOTICE](NOTICE)).
GNUstep is GPL/LGPL, and Window Maker and XLibre carry their own licences.
All of them ship as unmodified FreeBSD packages.
