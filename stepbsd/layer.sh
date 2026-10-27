# stepbsd/layer.sh — the StepBSD layer on top of the NextBSD rootfs.
#
# SOURCED by build.sh (pkg assembly mode), right after its pkglist.txt step and
# before it drops pkg's residue, so it shares build.sh's shell and variables:
#   ROOT  repo root        RF       staged rootfs      ARCH / ABIARCH
#   FBSD_REPOS             dir holding the FreeBSD.conf pkg repo (step 5)
#   ABI / OSVERSION / IGNORE_OSVERSION / ASSUME_ALWAYS_YES  (exported)
#
# It also defines stepbsd_identity, which build.sh calls after it writes the
# NextBSD version identity, to brand the image.
#
# Everything StepBSD adds to NextBSD is here and under stepbsd/, so a merge
# from upstream nextbsd/nextbsd only ever touches build.sh's two hook lines.

STEPBSD=$ROOT/stepbsd

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

# 1. Packages, from the FreeBSD ports repo build.sh configured in step 5.
STEPBSD_PKGS=$(stepbsd_list "$STEPBSD/packages.txt" | tr '\n' ' ')
echo "==> [stepbsd] pkg install: $STEPBSD_PKGS"
pkg -r "$RF" -o REPOS_DIR="$FBSD_REPOS" update -f
# shellcheck disable=SC2086
pkg -r "$RF" -o REPOS_DIR="$FBSD_REPOS" install -y $STEPBSD_PKGS
for _p in gnustep-base gnustep-gui gnustep-back windowmaker gworkspace xlibre-server; do
    pkg -r "$RF" info -e "$_p" || { echo "ERROR: [stepbsd] $_p is not installed" >&2; exit 1; }
done

# 2. Prune the ImageMagick7 build/Python baggage (stepbsd/prune.txt). The
#    closure check before and after proves nothing that ships lost a library.
echo "==> [stepbsd] shared-library closure before pruning"
STEPBSD_MISS_BEFORE=$(stepbsd_missing_libs)
STEPBSD_PRUNE=
for _p in $(stepbsd_list "$STEPBSD/prune.txt"); do
    pkg -r "$RF" info -e "$_p" && STEPBSD_PRUNE="$STEPBSD_PRUNE $_p"
done
if [ -n "$STEPBSD_PRUNE" ]; then
    echo "==> [stepbsd] pkg delete -f:$STEPBSD_PRUNE"
    # shellcheck disable=SC2086
    pkg -r "$RF" delete -f -y $STEPBSD_PRUNE
fi
echo "==> [stepbsd] shared-library closure after pruning"
STEPBSD_MISS_AFTER=$(stepbsd_missing_libs)
if [ -n "$STEPBSD_MISS_BEFORE" ]; then
    echo "    NOTE: sonames without a provider before pruning (not caused by it):"
    echo "$STEPBSD_MISS_BEFORE" | sed 's/^/      /'
fi
STEPBSD_MISS_NEW=$(printf '%s\n' "$STEPBSD_MISS_AFTER" | while read -r _so _obj; do
    [ -n "$_so" ] || continue
    printf '%s\n' "$STEPBSD_MISS_BEFORE" | grep -q "^$_so " || echo "$_so $_obj"
done)
if [ -n "$STEPBSD_MISS_NEW" ]; then
    echo "ERROR: [stepbsd] pruning removed libraries still in use:" >&2
    echo "$STEPBSD_MISS_NEW" | sed 's/^/      /' >&2
    exit 1
fi
echo "    pruning removed no library in use"

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
