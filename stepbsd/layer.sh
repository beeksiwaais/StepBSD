# stepbsd/layer.sh — the StepBSD layer on top of the NextBSD rootfs.
#
# SOURCED by build.sh (pkg assembly mode), right after its pkglist.txt step and
# before it drops pkg's residue, so it shares build.sh's shell and variables:
#   ROOT  repo root        RF       staged rootfs      ARCH / ABIARCH
#   NBREPO                 dir holding the NextBSD.conf pkg repo (step 2)
#   ABI / OSVERSION / IGNORE_OSVERSION / ASSUME_ALWAYS_YES  (exported)
# and reads:
#   STEPBSD_PKGDIR   the StepBSD pkg repository for this arch: StepBSD-desktop,
#                    built by stepbsd/desktop/package.sh
#                    (default: $ROOT/stepbsd-packages)
#   STEPBSD_PKG_URL  where installed systems fetch that repository from
#
# StepBSD follows NextBSD's E24 plan for GNUstep and the Gershwin desktop: the
# image holds NextBSD packages and StepBSD-desktop (GNUstep and Gershwin built
# from source on NextBSD, in /System) and nothing from FreeBSD's package
# repository, which it no longer configures (E24 "End state").
#
# It also defines stepbsd_identity, which build.sh calls after it writes the
# NextBSD version identity, to brand the image.
#
# Everything StepBSD adds to NextBSD is here and under stepbsd/, so a merge
# from upstream nextbsd/nextbsd only ever touches build.sh's hook lines.

STEPBSD=$ROOT/stepbsd
STEPBSD_PKGDIR=${STEPBSD_PKGDIR:-$ROOT/stepbsd-packages}
STEPBSD_PKG_URL=${STEPBSD_PKG_URL:-https://github.com/beeksiwaais/StepBSD/releases/download/packages-${ARCH}}

# Every NEEDED soname of every ELF object in the rootfs that no .so in the
# rootfs provides, one per line as "<soname> <first object needing it>".
stepbsd_missing_libs() {
    _prov=$(mktemp) _need=$(mktemp)
    find "$RF" \( -name '*.so' -o -name '*.so.*' \) \( -type f -o -type l \) \
        -exec basename {} \; 2>/dev/null | sort -u > "$_prov"
    find "$RF/bin" "$RF/sbin" "$RF/lib" "$RF/libexec" "$RF/usr/bin" \
         "$RF/usr/sbin" "$RF/usr/lib" "$RF/usr/libexec" "$RF/usr/X11" \
         "$RF/System" \
         -type f -perm -u+x -o -type f -name '*.so*' 2>/dev/null |
    while IFS= read -r f; do
        readelf -d "$f" 2>/dev/null |
            sed -n "s|.*(NEEDED).*\[\(.*\)\].*|\1 ${f#"$RF"}|p"
    done | sort -u -k1,1 > "$_need"
    awk 'NR == FNR { have[$1] = 1; next } !($1 in have)' "$_prov" "$_need"
    rm -f "$_prov" "$_need"
}

echo "==> [stepbsd] desktop layer ($ABIARCH)"

# 1. Packages: StepBSD-desktop (which pulls the NextBSD X, Mesa, GNUstep
#    support and printing packages it was built against) and the on-machine
#    toolchain (E24 D11), from the NextBSD and StepBSD repositories only.
[ -s "$STEPBSD_PKGDIR/packagesite.pkg" ] || {
    echo "ERROR: [stepbsd] no StepBSD pkg repository at $STEPBSD_PKGDIR" >&2
    echo "       (build it with: sh stepbsd/desktop/package.sh $STEPBSD_PKGDIR)" >&2
    exit 1
}
STEPBSD_REPOS=$(mktemp -d)
cp "$NBREPO/NextBSD.conf" "$STEPBSD_REPOS/"
cat > "$STEPBSD_REPOS/StepBSD.conf" <<CONF
StepBSD: { url: "file://$STEPBSD_PKGDIR", signature_type: none, enabled: yes }
CONF
pkg -r "$RF" -o REPOS_DIR="$STEPBSD_REPOS" update -f
pkg -r "$RF" -o REPOS_DIR="$STEPBSD_REPOS" install -y StepBSD-desktop NextBSD-toolchain
rm -rf "$STEPBSD_REPOS"

# No FreeBSD repository on a StepBSD system (E24 "End state"; nextbsd#545);
# build.sh step 5 still writes one for NextBSD's own images. The StepBSD
# repository takes its place next to NextBSD's.
rm -f "$RF/usr/local/etc/pkg/repos/FreeBSD.conf"
mkdir -p "$RF/usr/local/etc/pkg/repos"
cat > "$RF/usr/local/etc/pkg/repos/StepBSD.conf" <<CONF
StepBSD: {
  url: "$STEPBSD_PKG_URL",
  signature_type: none,
  enabled: yes
}
CONF
STEPBSD_FOREIGN=$(pkg -r "$RF" query '%n %R' | awk '$2 != "NextBSD" && $2 != "StepBSD"')
if [ -n "$STEPBSD_FOREIGN" ]; then
    echo "ERROR: [stepbsd] packages from outside the NextBSD and StepBSD repositories:" >&2
    echo "$STEPBSD_FOREIGN" | sed 's/^/      /' >&2
    exit 1
fi

# 2. Every shared library any program or library in the image needs is in it.
echo "==> [stepbsd] shared-library closure"
STEPBSD_MISSING=$(stepbsd_missing_libs)
if [ -n "$STEPBSD_MISSING" ]; then
    echo "ERROR: [stepbsd] libraries needed but not in the image:" >&2
    echo "$STEPBSD_MISSING" | sed 's/^/      /' >&2
    exit 1
fi
echo "    every NEEDED library has a provider"

# 3. The StepBSD overlay: the desktop's launchd jobs.
echo "==> [stepbsd] overlay"
cp -R "$STEPBSD/overlay/." "$RF/"
chown -R 0:0 "$RF/System/Library/LaunchDaemons"
chmod 0644 "$RF"/System/Library/LaunchDaemons/*.plist

# 4. GNUstep runs in the image: gnustep-base loads with every library it links
#    (rtld checks symbol versions, which the closure check cannot) and writes
#    and reads back a default. Native lanes only: a chroot cannot run another
#    architecture's binaries.
if [ "$ABIARCH" = "$(uname -p)" ]; then
    echo "==> [stepbsd] native: GNUstep run-time check"
    mkdir -p "$RF/dev"
    mount -t devfs devfs "$RF/dev"
    STEPBSD_RC=0
    chroot "$RF" /usr/bin/env -i HOME=/tmp/stepbsd-check PATH=/bin:/usr/bin /bin/sh -c '
        mkdir -p "$HOME" &&
        . /System/Library/Makefiles/GNUstep.sh &&
        defaults write StepBSDBuildCheck probe 42 &&
        defaults read StepBSDBuildCheck probe | grep -qw 42' || STEPBSD_RC=$?
    umount "$RF/dev"
    rm -rf "$RF/tmp/stepbsd-check"
    [ "$STEPBSD_RC" -eq 0 ] || {
        echo "ERROR: [stepbsd] GNUstep does not run in the image" >&2
        exit 1
    }
else
    echo "==> [stepbsd] cross lane ($ABIARCH): GNUstep run-time check left to the boot test"
fi

echo "==> [stepbsd] installed packages by size (MiB, top 15)"
pkg -r "$RF" query '%sb %n' | sort -rn | head -15 |
    awk '{ printf("    %8.1f  %s\n", $1 / 1048576, $2) }'

# Called by build.sh after it writes the NextBSD identity (step 6).
stepbsd_identity() {
    cat > "$RF/etc/os-release" <<OSREL
NAME="StepBSD"
PRETTY_NAME="StepBSD ${IMG_DATE}"
ID=stepbsd
ID_LIKE="nextbsd freebsd"
VERSION="${IMG_DATE}"
VERSION_ID="15.1"
HOME_URL="https://github.com/beeksiwaais/StepBSD"
OSREL
}
