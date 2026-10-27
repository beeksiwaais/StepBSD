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

- `StepBSD-amd64-<date>.iso`: live and installer ISO.
- `StepBSD-amd64-<date>.img.zip`: the installed system as a raw disk image.

### Try it in a VM

```sh
qemu-img create -f qcow2 stepbsd.qcow2 20G
qemu-system-x86_64 -machine q35 -accel kvm -cpu host -m 4096 -smp 2 \
  -bios /usr/share/ovmf/OVMF.fd \
  -cdrom StepBSD-amd64-*.iso -boot d \
  -drive file=stepbsd.qcow2,if=virtio -nic user,model=e1000
```

(On macOS use `-accel hvf` on an Intel Mac. Apple Silicon has to emulate
x86-64 with `-accel tcg`, which is slow.)

### Install on a PC

1. Write the ISO to a USB stick: `dd if=StepBSD-amd64-<date>.iso of=/dev/<stick> bs=1m`.
2. Boot it. The live system logs `admin` in (no password) and starts the
   desktop.
3. Open Terminal.app and run:

   ```sh
   sudo stepbsd-install
   ```

   Pick the target disk and type `yes`. **The whole disk is erased.** It is
   partitioned GPT with BIOS boot code, an EFI system partition and a UFS
   root labelled `ROOTFS`, the layout of NextBSD's disk image. The root
   grows to fill the disk.
4. Remove the stick and reboot.

Unattended: `sudo stepbsd-install -y -d ada0 -p` (installs without asking, then
powers off).

## Using it

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
2. removes [`stepbsd/prune.txt`](stepbsd/prune.txt), about 1 GiB of
   ImageMagick build and Python dependencies the desktop never loads. A
   shared-library closure check before and after fails the build if pruning
   removes a library anything still needs;
3. lays [`stepbsd/overlay/`](stepbsd/overlay) onto the root: the installer,
   the X session, and launchd jobs for `gdomap` and the linker hints;
4. builds the linker hints and the font, MIME and GLib caches in a chroot.

`build.sh` then makes the disk image and the live ISO exactly as NextBSD does.

```sh
# on FreeBSD 15.1 (amd64), as root:
pkg install -y git zip
DIST_NAME=StepBSD ARCH=amd64 sh build.sh      # -> out/StepBSD-amd64-*.{iso,img}.zip
sh tests/stepbsd-install-test.sh out/StepBSD-amd64-*.iso.zip   # needs qemu + expect
```

### CI and maintenance

- [`stepbsd.yml`](.github/workflows/stepbsd.yml) builds the ISO, runs
  [`tests/stepbsd-install-test.sh`](tests/stepbsd-install-test.sh) and
  publishes `continuous`. The test installs to a disk from the live ISO, boots
  the installed system with BIOS, checks GNUstep at run time, then boots it
  with UEFI and checks a screenshot of the desktop. It runs on every push and
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
