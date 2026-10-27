#!/bin/sh
#
# build-ports.sh — build stepbsd/ports.txt into a pkg repository.
#
# Runs as root on FreeBSD 15 of the target architecture (CI: a vmactions VM,
# x86_64 or aarch64). The ports tree is a snapshot of freebsd-ports main, the
# tree pkg.FreeBSD.org's "latest" packages come from, and every dependency is
# installed from those packages with pkg before the build, so the result links
# exactly the libraries the image installs beside it.
#
# usage: build-ports.sh <outdir>
#   <outdir> receives the packages and the repository catalogue (pkg repo).

set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${1:?usage: build-ports.sh <outdir>}
PORTSDIR=${PORTSDIR:-/usr/ports}
PORTS_SNAPSHOT=https://codeload.github.com/freebsd/freebsd-ports/tar.gz/refs/heads/main

mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)

# Dependencies come from "latest", like the image's packages. The VM's own
# repositories (FreeBSD 15: FreeBSD-ports and FreeBSD-ports-kmods, on
# "quarterly"; older names: FreeBSD) are switched off.
mkdir -p /usr/local/etc/pkg/repos
cat > /usr/local/etc/pkg/repos/StepBSD-build.conf <<'CONF'
FreeBSD: { enabled: no }
FreeBSD-ports: { enabled: no }
FreeBSD-ports-kmods: { enabled: no }
FreeBSD-latest: { url: "https://pkg.FreeBSD.org/${ABI}/latest", mirror_type: "none", enabled: yes }
CONF
export ASSUME_ALWAYS_YES=yes
pkg update -f

if [ ! -f "$PORTSDIR/Mk/bsd.port.mk" ]; then
    echo "==> ports tree: freebsd-ports main snapshot"
    mkdir -p "$PORTSDIR"
    fetch -o - "$PORTS_SNAPSHOT" | tar -xzf - -C "$PORTSDIR" --strip-components 1
fi

export BATCH=yes DISABLE_VULNERABILITIES=yes

# The package names of a port's direct dependencies (build, lib, run, ...).
# The ports framework prints them as <portdir>[@flavor]; pkg resolves the rest
# of the closure itself.
dep_packages() {
    # shellcheck disable=SC2086
    make -C "$PORTSDIR/$1" $2 build-depends-list run-depends-list | sort -u |
    while read -r dir; do
        case $dir in
        *@*) make -C "${dir%@*}" FLAVOR="${dir#*@}" -V PKGBASE ;;
        *)   make -C "$dir" -V PKGBASE ;;
        esac
    done
}

sed -e 's/#.*//' -e '/^[[:space:]]*$/d' "$HERE/ports.txt" |
while read -r origin args; do
    echo "==> $origin $args"
    deps=$(dep_packages "$origin" "$args" | tr '\n' ' ')
    echo "    dependencies from packages: $deps"
    # shellcheck disable=SC2086
    pkg install -y $deps
    # shellcheck disable=SC2086
    make -C "$PORTSDIR/$origin" $args clean package
    find "$PORTSDIR/$origin/work/pkg" -name '*.pkg' -exec cp {} "$OUT/" \;
    # shellcheck disable=SC2086
    make -C "$PORTSDIR/$origin" $args clean
done

echo "==> pkg repo $OUT"
pkg repo "$OUT"
ls -l "$OUT"
