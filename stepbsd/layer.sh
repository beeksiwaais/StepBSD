# stepbsd/layer.sh — the StepBSD layer on top of the NextBSD rootfs.
#
# SOURCED by build.sh (pkg assembly mode), right after its pkglist.txt step and
# before it drops pkg's residue, so it shares build.sh's shell and variables:
#   ROOT  repo root        RF       staged rootfs      ARCH / ABIARCH
#   FBSD_REPOS             dir holding the FreeBSD.conf pkg repo (step 5)
#   ABI / OSVERSION / IGNORE_OSVERSION / ASSUME_ALWAYS_YES  (exported)
# and reads:
#   STEPBSD_PKGDIR   the StepBSD pkg repository for this arch, built from
#                    stepbsd/ports.txt by stepbsd/build-ports.sh
#                    (default: $ROOT/stepbsd-packages)
#   STEPBSD_PKG_URL  where images fetch that repository from once published
#
# It also defines stepbsd_identity, which build.sh calls after it writes the
# NextBSD version identity, to brand the image.
#
# Everything StepBSD adds to NextBSD is here and under stepbsd/, so a merge
# from upstream nextbsd/nextbsd only ever touches build.sh's hook lines.

STEPBSD=$ROOT/stepbsd
STEPBSD_PKGDIR=${STEPBSD_PKGDIR:-$ROOT/stepbsd-packages}
STEPBSD_PKG_URL=${STEPBSD_PKG_URL:-https://github.com/beeksiwaais/StepBSD/releases/download/packages-${ARCH}}

# Names from a stepbsd/*.txt list: comments and blank lines dropped, and lines
# tagged @<arch> kept only for that pkg ABI arch.
stepbsd_list() {
    sed -e 's/#.*//' "$1" | awk -v a="$ABIARCH" '
        NF == 0 { next }
        NF == 1 { print $1; next }
        $2 == "@" a { print $1 }'
}

# Every NEEDED soname of every ELF object in the rootfs that no .so in the
# rootfs provides, one per line as "<soname> <first object needing it>".
stepbsd_missing_libs() {
    _prov=$(mktemp) _need=$(mktemp)
    find "$RF" \( -name '*.so' -o -name '*.so.*' \) \( -type f -o -type l \) \
        -exec basename {} \; 2>/dev/null | sort -u > "$_prov"
    find "$RF/bin" "$RF/sbin" "$RF/lib" "$RF/libexec" "$RF/usr/bin" \
         "$RF/usr/sbin" "$RF/usr/lib" "$RF/usr/libexec" "$RF/usr/local" \
         -type f -perm -u+x -o -type f -name '*.so*' 2>/dev/null |
    while IFS= read -r f; do
        readelf -d "$f" 2>/dev/null |
            sed -n "s|.*(NEEDED).*\[\(.*\)\].*|\1 ${f#"$RF"}|p"
    done | sort -u -k1,1 > "$_need"
    awk 'NR == FNR { have[$1] = 1; next } !($1 in have)' "$_prov" "$_need"
    rm -f "$_prov" "$_need"
}

echo "==> [stepbsd] GNUstep desktop layer ($ABIARCH)"

# 1. Packages. Two repositories: StepBSD's own (the ports in stepbsd/ports.txt,
#    built with StepBSD's options) at priority 10, and FreeBSD's (build.sh step
#    5) at 0, so a port StepBSD builds always comes from StepBSD. The local
#    repository is named StepBSD like the published one the image points at,
#    so pkg upgrade on an installed system keeps following it.
[ -s "$STEPBSD_PKGDIR/packagesite.pkg" ] || {
    echo "ERROR: [stepbsd] no StepBSD pkg repository at $STEPBSD_PKGDIR" >&2
    echo "       (build it with: sh stepbsd/build-ports.sh $STEPBSD_PKGDIR)" >&2
    exit 1
}
STEPBSD_REPOS=$(mktemp -d)
cp "$FBSD_REPOS/FreeBSD.conf" "$STEPBSD_REPOS/"
cat > "$STEPBSD_REPOS/StepBSD.conf" <<CONF
StepBSD: {
  url: "file://$STEPBSD_PKGDIR",
  signature_type: none,
  priority: 10,
  enabled: yes
}
CONF
STEPBSD_PKGS=$(stepbsd_list "$STEPBSD/packages.txt" | tr '\n' ' ')
echo "==> [stepbsd] pkg install: $STEPBSD_PKGS"
pkg -r "$RF" -o REPOS_DIR="$STEPBSD_REPOS" update -f
# shellcheck disable=SC2086
pkg -r "$RF" -o REPOS_DIR="$STEPBSD_REPOS" install -y $STEPBSD_PKGS
rm -rf "$STEPBSD_REPOS"

for _p in gnustep-base gnustep-gui gnustep-back windowmaker gworkspace xlibre-server; do
    pkg -r "$RF" info -e "$_p" || { echo "ERROR: [stepbsd] $_p is not installed" >&2; exit 1; }
done
# Every port in ports.txt came from the StepBSD repository.
for _o in $(sed -e 's/#.*//' "$STEPBSD/ports.txt" | awk 'NF { print $1 }'); do
    _r=$(pkg -r "$RF" query '%R' "$_o")
    [ "$_r" = StepBSD ] || {
        echo "ERROR: [stepbsd] $_o came from repository '$_r', not StepBSD" >&2
        exit 1
    }
done
if pkg -r "$RF" info -e ImageMagick7; then
    echo "ERROR: [stepbsd] ImageMagick7 is installed; something still depends on it:" >&2
    pkg -r "$RF" query '%rn' ImageMagick7 >&2
    exit 1
fi

# The repository the shipped image upgrades StepBSD's ports from.
cat > "$RF/usr/local/etc/pkg/repos/StepBSD.conf" <<CONF
StepBSD: {
  url: "$STEPBSD_PKG_URL",
  signature_type: none,
  priority: 10,
  enabled: yes
}
CONF

# 2. Every shared library any program or library in the image needs is in the
#    image: the FreeBSD packages against NextBSD's base, and StepBSD's builds.
echo "==> [stepbsd] shared-library closure"
STEPBSD_MISSING=$(stepbsd_missing_libs)
if [ -n "$STEPBSD_MISSING" ]; then
    echo "ERROR: [stepbsd] libraries needed but not in the image:" >&2
    echo "$STEPBSD_MISSING" | sed 's/^/      /' >&2
    exit 1
fi
echo "    every NEEDED library has a provider"

# 3. The StepBSD overlay: installer, session, launchd jobs.
echo "==> [stepbsd] overlay"
cp -R "$STEPBSD/overlay/." "$RF/"
chown -R 0:0 "$RF/System/Library/LaunchDaemons"
chmod 0644 "$RF"/System/Library/LaunchDaemons/org.stepbsd.*.plist \
           "$RF"/System/Library/LaunchDaemons/org.gnustep.*.plist
chmod 0555 "$RF/usr/local/bin/startstep" "$RF/usr/local/sbin/stepbsd-install" \
           "$RF/usr/local/libexec/stepbsd/xsession" "$RF/usr/local/libexec/stepbsd/boot"

# Login shells source the StepBSD profile: sh through /etc/profile, zsh (the
# admin user's shell) through /etc/zprofile in sh emulation.
if ! grep -q stepbsd "$RF/private/etc/profile" 2>/dev/null; then
    cat >> "$RF/private/etc/profile" <<'PROF'

# StepBSD: GNUstep environment, desktop autostart on ttyv0.
[ -r /usr/local/etc/stepbsd/profile.sh ] && . /usr/local/etc/stepbsd/profile.sh
PROF
fi
if ! grep -q stepbsd "$RF/private/etc/zprofile" 2>/dev/null; then
    cat >> "$RF/private/etc/zprofile" <<'PROF'

# StepBSD: GNUstep environment, desktop autostart on ttyv0.
[[ -r /usr/local/etc/stepbsd/profile.sh ]] && emulate sh -c '. /usr/local/etc/stepbsd/profile.sh'
PROF
fi

# 4. Linker hints and the caches a package post-install would build: the
#    org.stepbsd.boot script, run once in a chroot when the rootfs is the build
#    VM's own arch. A cross-built (arm64) image runs it on its first boot.
if [ "$ABIARCH" = "$(uname -p)" ]; then
    echo "==> [stepbsd] native: linker hints + caches in chroot"
    mkdir -p "$RF/dev"
    mount -t devfs devfs "$RF/dev"
    chroot "$RF" /usr/local/libexec/stepbsd/boot ||
        echo "WARN: [stepbsd] chroot boot script failed; the first boot retries" >&2
    umount "$RF/dev"
    ls -l "$RF/private/var/run/ld-elf.so.hints" 2>/dev/null || true
else
    echo "==> [stepbsd] cross lane ($ABIARCH): linker hints + caches on first boot"
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
    cat > "$RF/etc/motd" <<'MOTD'

Welcome to StepBSD: NextBSD with the GNUstep desktop.

  startstep          start the GNUstep desktop (automatic on the first console)
  sudo stepbsd-install
                     install StepBSD from the live ISO onto a disk

MOTD
}
