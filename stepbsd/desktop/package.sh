#!/bin/sh
#
# package.sh — build StepBSD's desktop on a NextBSD root and package it.
#
#   1. Assemble a NextBSD system in $WORKDIR/root from the NextBSD pkg
#      repository only (requirements.txt): the E24 plan's packages, toolchain
#      included. No FreeBSD repository is configured.
#   2. Run build-desktop.sh in it (chroot; a native build, so the host must be
#      the target architecture).
#   3. Check what the build did: it installed nothing outside /System and
#      changed no file a NextBSD package owns.
#   4. Package everything it added as StepBSD-desktop, depending on the NextBSD
#      packages it was built against, and write a pkg repository.
#
# Runs as root on FreeBSD 15 (CI: a vmactions VM of the target arch; locally
# any FreeBSD 15 machine or VM).
#
# usage: package.sh <outdir> [component ...]
#   <outdir>  receives StepBSD-desktop-<version>.pkg and the repository
#             catalogue (pkg repo); it is the StepBSD pkg repository.
#   WORKDIR   build root and caches (default /var/tmp/stepbsd-desktop)
#   VERSION   package version (default 0.0.0.<UTC date and time>)
#   REUSE_ROOT=1  development: keep the build root of an earlier run (and its
#             step-3 baseline) and build only the named components in it
#   SAVE_ROOT=<file>  stop after the build and save the build root and its
#             baseline to <file> (CI: the build is split into jobs that each
#             stay under the runner's time limit)
#   RESTORE_ROOT=<file>  start from a root SAVE_ROOT saved, build the named
#             components in it, then check and package

set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${1:?usage: package.sh <outdir> [component ...]}
shift
WORKDIR=${WORKDIR:-/var/tmp/stepbsd-desktop}
VERSION=${VERSION:-0.0.0.$(date -u +%Y%m%d%H%M%S)}
ARCH=$(uname -m)
case "$ARCH" in arm64) ABIARCH=aarch64 ;; *) ABIARCH=$ARCH ;; esac
NEXTBSD_REPO=https://github.com/nextbsd/nextbsd-pkg/releases/download/continuous-$ARCH

R=$WORKDIR/root
mkdir -p "$OUT" "$WORKDIR"
OUT=$(cd "$OUT" && pwd)

die() {
    echo "package.sh: $*" >&2
    exit 1
}

cleanup() {
    umount "$R/dev" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

EXCLUDE=$WORKDIR/mtree.exclude
export ASSUME_ALWAYS_YES=yes IGNORE_OSVERSION=yes
export ABI=FreeBSD:15:$ABIARCH OSVERSION="$(uname -K)"
PKG="pkg -r $R -o REPOS_DIR=$WORKDIR/repos"
REQS=$(sed -e 's/#.*//' -e '/^[[:space:]]*$/d' "$HERE/requirements.txt" | tr '\n' ' ')

if [ -n "${RESTORE_ROOT:-}" ]; then
    echo "==> restoring the build root from $RESTORE_ROOT"
    [ -d "$R" ] && chflags -R noschg "$R"
    rm -rf "$R" "$WORKDIR/before.mtree"
    tar -xpf "$RESTORE_ROOT" -C "$WORKDIR"
    REUSE_ROOT=1
fi

if [ "${REUSE_ROOT:-}" = 1 ] && [ -f "$WORKDIR/before.mtree" ]; then
    echo "==> reusing the build root $R"
    mount -t devfs devfs "$R/dev"
else
# --- 1. the NextBSD build root ------------------------------------------------
echo "==> NextBSD build root ($ARCH): $R"
[ -d "$R" ] && chflags -R noschg "$R"
rm -rf "$R"
# Apple's /private layout before pkg installs anything (as nextbsd build.sh).
mkdir -p "$R/private/etc" "$R/private/var" "$R/private/tmp"
for d in etc var tmp; do ln -s "private/$d" "$R/$d"; done

mkdir -p "$WORKDIR/repos"
cat > "$WORKDIR/repos/NextBSD.conf" <<CONF
NextBSD: { url: "$NEXTBSD_REPO", enabled: yes, signature_type: none }
CONF
$PKG update -f
# shellcheck disable=SC2086
$PKG install -y $REQS

# The admin-owned /etc NextBSD's images get from nextbsd-overlays (accounts,
# login classes), as nextbsd build.sh lays it: GNUstep's build tools look the
# building user up (NSUserName).
rm -rf "$WORKDIR/nextbsd-overlays"
git clone -q --depth 1 https://github.com/nextbsd/nextbsd-overlays "$WORKDIR/nextbsd-overlays"
cp -R "$WORKDIR/nextbsd-overlays/rootfs/." "$R/"
chmod 0600 "$R/private/etc/master.passwd"
pwd_mkdb -p -d "$R/etc" "$R/etc/master.passwd"
cap_mkdb "$R/etc/login.conf"

mkdir -p "$R/dev" "$R/root" "$R/build"
mount -t devfs devfs "$R/dev"
cp /etc/resolv.conf "$R/private/etc/resolv.conf"
# The CA trust store, for fetching sources over https (as nextbsd build.sh).
env DESTDIR="$R" certctl rehash
# The tree as a NextBSD package set laid it, for step 3.
cat > "$EXCLUDE" <<'EX'
./dev
./tmp
./private/tmp
./var
./private/var
./root
./build
./System
./private/etc/resolv.conf
EX
mtree -c -k type,sha256digest,link -p "$R" -X "$EXCLUDE" > "$WORKDIR/before.mtree"
fi

# --- 2. build -----------------------------------------------------------------
rm -rf "$R/build/desktop"
mkdir -p "$R/build/desktop"
(cd "$HERE" && tar -cf - --exclude .build .) | tar -xf - -C "$R/build/desktop"
# Keep downloaded sources between runs.
mkdir -p "$WORKDIR/dl" "$R/build/desktop/.build"
ln -s /build/dl "$R/build/desktop/.build/dl"
mkdir -p "$R/build/dl"
cp -p "$WORKDIR"/dl/* "$R/build/dl/" 2>/dev/null || true

chroot "$R" /usr/bin/env -i HOME=/root USER=root LOGNAME=root TERM=dumb \
    PATH=/sbin:/bin:/usr/sbin:/usr/bin \
    /bin/sh /build/desktop/build-desktop.sh "$@"
cp -p "$R"/build/dl/* "$WORKDIR/dl/" 2>/dev/null || true

if [ -n "${SAVE_ROOT:-}" ]; then
    umount "$R/dev"
    echo "==> saving the build root to $SAVE_ROOT"
    # Not /build: sources and objects; the next run unpacks its own.
    tar --zstd -cf "$SAVE_ROOT" -C "$WORKDIR" --exclude root/build \
        root before.mtree mtree.exclude repos
    ls -lh "$SAVE_ROOT"
    exit 0
fi

# --- 3. checks ----------------------------------------------------------------
echo "==> checks"
changed=$(mtree -f "$WORKDIR/before.mtree" -p "$R" -X "$EXCLUDE" 2>&1 || true)
[ -z "$changed" ] || die "the build changed files outside /System:
$changed"
pkg -r "$R" check -s -q -a || die "the build modified files NextBSD packages own"

# --- 4. package ---------------------------------------------------------------
echo "==> StepBSD-desktop $VERSION"
P=$WORKDIR/pkg
rm -rf "$P"
mkdir -p "$P"
# What the build added: everything under /System no package owns.
pkg -r "$R" query '%Fp' | grep '^/System/' | sort -u > "$P/owned-files"
pkg -r "$R" query '%Dn' | grep '^/System' | sort -u > "$P/owned-dirs"
(cd "$R" && find ./System \( -type f -o -type l \) | sed 's|^\.||' | sort) |
    comm -23 - "$P/owned-files" > "$P/files"
(cd "$R" && find ./System -mindepth 1 -type d | sed 's|^\.||' | sort) |
    comm -23 - "$P/owned-dirs" > "$P/dirs"
[ -s "$P/files" ] || die "the build installed nothing"
# Nothing writable by anyone but root: gnustep-base ignores such preference
# files, and nothing in /System should be.
sort "$P/files" "$P/dirs" > "$P/all"
writable=$( (cd "$R" && find ./System ! -type l \( -perm -g+w -o -perm -o+w \)) |
    sed 's|^\.||' | sort | comm -12 - "$P/all")
[ -z "$writable" ] || die "files writable by group or others:
$writable"
{
    cat "$P/files"
    sed 's/^/@dir /' "$P/dirs"
} > "$P/plist"

# Depend on the NextBSD packages the desktop links (not the build toolchain,
# nor contrib's sudo, zsh and pico), at the versions it was built against.
deps=$(for d in $(echo "$REQS" | tr ' ' '\n' | grep -v -x -e NextBSD-toolchain -e NextBSD-contrib); do
    $PKG query '    "%n": { origin: "%o", version: "%v" },' "$d"
done)
cat > "$P/manifest" <<MANIFEST
name: StepBSD-desktop
version: "$VERSION"
origin: stepbsd/desktop
comment: "StepBSD desktop: GNUstep and the Gershwin desktop in /System"
desc: <<EOD
GNUstep (libobjc2, gnustep-make, -base, -gui, -back, libs-av) and the
Gershwin desktop (Workspace, SystemPreferences, Terminal, TextEdit,
WindowManager, the Eau theme and components), built from the pinned sources
in StepBSD's stepbsd/desktop on NextBSD, installed in /System with
gnustep-make's gershwin layout.
EOD
maintainer: "rtp@beeksiwaais.fr"
www: "https://github.com/beeksiwaais/StepBSD"
abi: "FreeBSD:15:$ABIARCH"
arch: "freebsd:15:$ABIARCH"
prefix: /
deps: {
$deps
}
MANIFEST
rm -f "$OUT"/StepBSD-desktop-*.pkg
pkg create -M "$P/manifest" -p "$P/plist" -r "$R" -o "$OUT"
pkg repo "$OUT"
echo "==> $(wc -l < "$P/files" | tr -d ' ') files; repository in $OUT"
ls -l "$OUT"
