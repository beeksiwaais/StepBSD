# stepbsd/desktop

StepBSD's desktop: GNUstep and the Gershwin desktop, rebuilt here from pinned
sources the way gershwin-developer builds them, following NextBSD's E24 plan
([E24: GNUstep & Gershwin requirements](https://github.com/nextbsd/nextbsd-userland/wiki/E24-GNUstep-Gershwin-Requirements-Direction)):

- built **on a NextBSD system with NextBSD-toolchain** (Q1, D10, D11), against
  **NextBSD packages only** (`requirements.txt`): the base with Apple's
  libxml2, libxslt, libffi, curl and ICU, and NextBSD-xlibs, -mesa, -xlibre,
  -gnustep-support and -printing-support;
- installed in **`/System`** with gnustep-make's `gershwin` layout (Q7), never
  `/usr/local`;
- **no FreeBSD packages, no D-Bus, no Avahi** (DNS-SD is mDNSResponder's), no
  ImageMagick (D2, D3).

It ships as one package, `StepBSD-desktop`, in the StepBSD pkg repository,
next to NextBSD's.

## Layout

The [source repo conventions](https://github.com/nextbsd/nextbsd-userland/wiki/Source-Repo-Conventions)
of NextBSD's own repos, adapted to an on-machine build:

| Path | What |
|---|---|
| `sources.lock` | `<name> <version> <sha256> <url>`: every component, as an archive at a pinned commit |
| `patches/<name>/series` | each component's patches, in order; every patch has an `Origin:` header (gershwin-developer's, or `NextBSD` for ours) |
| `build-desktop.sh` | the build: one `build_<name>()` per component in `COMPONENTS` order (gershwin-developer's `install-system-domain.sh`, step for step); runs as root inside a NextBSD system |
| `package.sh` | assembles that NextBSD system from NextBSD packages, runs the build in it (chroot), checks it and packages `StepBSD-desktop` |
| `requirements.txt` | the NextBSD packages built against (E24's target `nextbsd.txt`) |
| `NOTICE.md` | the components' licences |

`package.sh` refuses to package when the build installed anything outside
`/System`, changed a file a NextBSD package owns, or left anything writable
by group or others.

## Our patches

What did not behave on NextBSD is patched (`Origin: NextBSD`), never worked
around in the image:

| Patch | Why |
|---|---|
| `swift-corelibs-libdispatch/no-mach.patch` | NextBSD ships `<mach/mach.h>`; libdispatch's probes would build the Mach backend, which breaks GNUstep's fd sources (gershwin-developer does this with sed) |
| `libs-base/nstimezones-modes.patch` | the time zone data was installed group-writable |
| `gershwin-terminal/no-libiconv-freebsd.patch` | iconv is in libc; there is no separate libiconv without FreeBSD packages |
| `gershwin-components/menu-optional-dbus.patch` | Menu builds without D-Bus (E24 D2, risk 9): GNUstep apps' menus go over Distributed Objects |
| `gershwin-components/directoryservices-nextbsd.patch` | no ldconfig entry or rc.d script under `/usr/local`; launchd starts dshelper |
| `gershwin-components/loginwindow-nextbsd-launchd.patch` | no rc.d script; launchd starts LoginWindow |
| `gershwin-components/fontconfig-nextbsd.patch` | the surrogate-font rule goes where the desktop's fontconfig reads it, in `/System` |
| `gershwin-components/x11-paths-nextbsd.patch` | X and the X tools are in `/usr/X11` on NextBSD (E23) |

Build configuration rather than patches: libs-gui gets ICU's `--cflags` from
pkgconf (`/usr/include/icucore`, E24 Q2), X is searched in `/usr/X11`
(`CPATH`, `LIBRARY_PATH`, as gershwin-developer does for OpenBSD's
`/usr/X11R6`), and `uname -s` reports NextBSD (`UNAME_s`) because the chroot
runs on the FreeBSD build host's kernel.

Not built, for want of a NextBSD package: ColorAssistant needs lcms2, which
belongs to NextBSD-gershwin-support (not published yet).

## Building

On FreeBSD 15.1, as root, on the architecture you build for:

```sh
pkg install -y git
sh stepbsd/desktop/package.sh stepbsd-packages
# development: rebuild only some components in the last run's build root
REUSE_ROOT=1 sh stepbsd/desktop/package.sh stepbsd-packages gershwin-components
```
