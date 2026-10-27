#!/bin/sh
#
# build-desktop.sh — build StepBSD's desktop: the Gershwin GNUstep desktop,
# rebuilt here from pinned sources the way gershwin-developer builds it
# (Library/Scripts/install-system-domain.sh), into /System with gnustep-make's
# `gershwin` layout.
#
# This follows NextBSD's E24 plan (nextbsd-userland wiki, "E24: GNUstep &
# Gershwin requirements"): GNUstep and the desktop are built on a NextBSD
# system with NextBSD-toolchain (Q1, D10, D11) against NextBSD's own libraries
# only (NextBSD-xlibs, -mesa, -xlibre, -gnustep-support, -printing-support and
# the base's Apple libxml2/libxslt/libffi/curl and ICU); no FreeBSD packages,
# no D-Bus, no Avahi (DNS-SD is mDNSResponder's), no ImageMagick.
#
# Runs as root inside such a system: mkroot.sh assembles one from NextBSD
# packages and runs this in it with chroot. Each component, in COMPONENTS
# order, is fetched from sources.lock (SHA-256 checked, cached in .build/dl),
# unpacked in .build/src, patched from patches/<name>/series and built and
# installed with its own build system straight into /System, where the next
# component finds it — as gershwin-developer does. mkroot.sh packages what the
# run added.
#
# usage: build-desktop.sh [component ...]     (default: every component)

set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
B=$HERE/.build

COMPONENTS="
gershwin-system
gershwin-assets
swift-corelibs-libdispatch
tools-make
libobjc2
libs-base
libs-gui
libs-back
plistupdate
libs-av
gershwin-systempreferences
gershwin-workspace
gershwin-eau-theme
gershwin-terminal
gershwin-textedit
gershwin-windowmanager
gershwin-components
"

# The source archive a component builds from, when it is not its own.
source_of() {
    case $1 in
    plistupdate) echo gershwin-components ;;
    *)           echo "$1" ;;
    esac
}

MAKE_CMD=gmake
CPUS=$(sysctl -n hw.ncpu)
export CC=clang CXX=clang++ OBJC=clang

# This is an on-machine build (E24 Q1) and the components test `uname -s`
# for NextBSD (Menu, ...). In mkroot's chroot the kernel is the FreeBSD build
# host's; uname(1) honours UNAME_s, so they see what a NextBSD machine says.
export UNAME_s=NextBSD

# NextBSD's X11 is in /usr/X11 (E23), outside the compiler's default paths.
# Components that use X through pkg-config find it; the ones that just
# #import <X11/...> need it searched, as gershwin-developer does for OpenBSD's
# /usr/X11R6. CPATH and LIBRARY_PATH come after every -I/-L a build passes.
# At run time rtld already searches /usr/X11/lib.
export CPATH=/usr/X11/include LIBRARY_PATH=/usr/X11/lib

# config.guess does not know NextBSD; gershwin-developer passes the same.
case $(uname -m) in
amd64) BUILD_FLAG=--build=x86_64-nextbsd-freebsd ;;
arm64) BUILD_FLAG=--build=aarch64-nextbsd-freebsd ;;
*)     BUILD_FLAG=--build=$(uname -m)-nextbsd-freebsd ;;
esac
# Without it CMake cannot match NextBSD to a platform module and builds
# libraries with no SONAME.
CMAKE_SYSTEM_FLAG=-DCMAKE_SYSTEM_NAME=FreeBSD

die() {
    echo "build-desktop.sh: $*" >&2
    exit 1
}

# --- fetch, verify, unpack, patch -------------------------------------------

lock_field() {
    awk -v n="$1" -v f="$2" '!/^#/ && $1 == n { print $f; exit }' "$HERE/sources.lock"
}

prepare() {
    src=$(source_of "$1")
    url=$(lock_field "$src" 4)
    sum=$(lock_field "$src" 3)
    [ -n "$url" ] || die "$src is not in sources.lock"
    tarball=$B/dl/$src-$(lock_field "$src" 2).tar.gz
    mkdir -p "$B/dl" "$B/src"
    if [ ! -f "$tarball" ]; then
        fetch -q -o "$tarball.part" "$url" || die "cannot fetch $url"
        mv "$tarball.part" "$tarball"
    fi
    [ "$(sha256 -q "$tarball")" = "$sum" ] ||
        die "$tarball: SHA-256 mismatch (sources.lock says $sum)"

    # A fresh tree per build, so a patch never meets an already patched tree.
    SRC=$B/src/$src
    rm -rf "$SRC"
    mkdir -p "$SRC"
    tar -xzf "$tarball" -C "$SRC" --strip-components 1
    # GitHub's archives store files group-writable (0664); a git checkout
    # under the usual umask, which gershwin-developer builds from, does not.
    # Installs copy these modes, and gnustep-base ignores a preferences file
    # anyone but its owner can write (GlobalDefaults/*.plist).
    chmod -R go-w "$SRC"
    apply_patches "$src"
}

apply_patches() {
    dir=$HERE/patches/$1
    [ -d "$dir" ] || return 0
    [ -f "$dir/series" ] || die "$dir has no series file"
    listed=$(sed -e 's/#.*//' -e '/^[[:space:]]*$/d' "$dir/series")
    for p in "$dir"/*.patch; do
        [ -e "$p" ] || continue
        echo "$listed" | grep -qx "${p##*/}" || die "${p##*/} is not in $dir/series"
    done
    for p in $listed; do
        grep -q '^Origin: ' "$dir/$p" || die "$dir/$p has no Origin: header"
        echo "    patch $1/$p"
        patch -s -p1 -N -d "$SRC" -i "$dir/$p" || die "$1/$p does not apply"
    done
}

gnustep_env() {
    # GNUstep.sh probes unset variables (ZSH_VERSION, ...).
    set +u
    . /System/Library/Makefiles/GNUstep.sh
    set -u
    export GNUSTEP_INSTALLATION_DOMAIN=SYSTEM
}

# --- components (gershwin-developer install-system-domain.sh, in order) ------

build_gershwin_system() {
    cd "$SRC" && $MAKE_CMD install
}

build_gershwin_assets() {
    mkdir -p /System/Library
    cp -R "$SRC"/Library/* /System/Library/
}

# The NON-Mach libdispatch for the desktop, installed to /System/Library/
# Libraries. NextBSD's base HAVE_MACH libdispatch (libsystem_dispatch in
# /usr/lib/system) stays for launchd/XPC/notifyd; its Mach event backend breaks
# GNUstep's fd-based dispatch sources (patches/swift-corelibs-libdispatch/
# no-mach.patch turns the <mach/mach.h> probes off).
build_swift_corelibs_libdispatch() {
    mkdir -p "$SRC/Build" && cd "$SRC/Build"
    cmake .. $CMAKE_SYSTEM_FLAG \
        -DCMAKE_INSTALL_PREFIX=/System/Library \
        -DCMAKE_INSTALL_LIBDIR=Libraries \
        -DINSTALL_DISPATCH_HEADERS_DIR=/System/Library/Headers/dispatch \
        -DINSTALL_BLOCK_HEADERS_DIR=/System/Library/Headers \
        -DINSTALL_OS_HEADERS_DIR=/System/Library/Headers/os \
        -DINSTALL_PRIVATE_HEADERS=ON \
        -DCMAKE_INSTALL_MANDIR=Documentation/man \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++ \
        -DHAVE_MACH=OFF
    $MAKE_CMD -j"$CPUS"
    $MAKE_CMD install
}

build_tools_make() {
    cd "$SRC"
    ./configure $BUILD_FLAG \
        --with-config-file=/System/Library/Preferences/GNUstep.conf \
        --with-layout=gershwin \
        --with-library-combo=ng-gnu-gnu \
        --with-objc-lib-flag=" " \
        LDFLAGS="-L/System/Library/Libraries" \
        CPPFLAGS="-I/System/Library/Headers" \
        libobjc_LIBS=" "
    $MAKE_CMD
    $MAKE_CMD install
}

build_libobjc2() {
    gnustep_env
    mkdir -p "$SRC/Build" && cd "$SRC/Build"
    cmake .. \
        -DGNUSTEP_INSTALL_TYPE=SYSTEM \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++ \
        -DEMBEDDED_BLOCKS_RUNTIME=OFF \
        -DBlocksRuntime_INCLUDE_DIR=/System/Library/Headers \
        -DBlocksRuntime_LIBRARIES=/System/Library/Libraries/libBlocksRuntime.so
    $MAKE_CMD -j"$CPUS"
    $MAKE_CMD install
}

# NSNetService over mDNSResponder's libdns_sd, in /usr/lib/system (not a
# default link directory), never Avahi (E24 D2).
build_libs_base() {
    gnustep_env
    cd "$SRC"
    ./configure $BUILD_FLAG \
        --with-dispatch-include=/usr/include \
        --with-dispatch-library=/System/Library/Libraries \
        --with-zeroconf-api=mdns \
        LDFLAGS="-L/System/Library/Libraries -L/usr/lib/system"
    $MAKE_CMD -j"$CPUS"
    $MAKE_CMD install
}

# configure finds ICU through pkg-config (icu-i18n, NextBSD's icucore) but
# checks its headers with plain CPPFLAGS, which lack ICU's directory
# (/usr/include/icucore, E24 Q2); then its fallback links -licui18n -licuuc,
# names NextBSD deliberately does not have. Hand it ICU's --cflags.
build_libs_gui() {
    gnustep_env
    cd "$SRC"
    ./configure $BUILD_FLAG CPPFLAGS="$(pkgconf --cflags icu-i18n)"
    $MAKE_CMD -j"$CPUS"
    $MAKE_CMD install
}

build_libs_back() {
    gnustep_env
    cd "$SRC"
    fonts=no ./configure $BUILD_FLAG
    $MAKE_CMD -j"$CPUS"
    $MAKE_CMD install
}

# Stamps build time and commit into every Info-gnustep.plist that gnustep-make
# installs from here on.
build_plistupdate() {
    gnustep_env
    cd "$SRC/plistupdate"
    $MAKE_CMD CPPFLAGS="-DGNUSTEP_INSTALL_TYPE=SYSTEM" -j"$CPUS"
    $MAKE_CMD install
    sh -e ./setup-integration.sh
}

build_libs_av() {
    gnustep_env
    cd "$SRC"
    $MAKE_CMD -j"$CPUS"
    $MAKE_CMD install
}

# GNUstep make projects installed into the System domain.
gnustep_project() {
    gnustep_env
    cd "$SRC"
    $MAKE_CMD CPPFLAGS="-DGNUSTEP_INSTALL_TYPE=SYSTEM" -j"$CPUS"
    $MAKE_CMD install
}

# Before the workspace: its MDIndexing preference pane links the
# PreferencePanes framework this installs.
build_gershwin_systempreferences() { gnustep_project; }

build_gershwin_workspace() {
    gnustep_env
    cd "$SRC"
    autoreconf -fi
    ./configure $BUILD_FLAG
    $MAKE_CMD -j"$CPUS"
    $MAKE_CMD install
}

build_gershwin_eau_theme()     { gnustep_project; }
build_gershwin_terminal()      { gnustep_project; }
build_gershwin_textedit()      { gnustep_project; }
build_gershwin_windowmanager() { gnustep_project; }
# Components with a .DISABLED file are skipped by the repo's own GNUmakefile.
# Menu's GNUmakefile is generated by its configure from GNUmakefile.in, which
# patches/gershwin-components/menu-optional-dbus.patch changes; the repository
# ships a generated one, and its top-level GNUmakefile's re-run of configure
# for a newer GNUmakefile.in is broken (`$$d`), so run it here.
build_gershwin_components() {
    (cd "$SRC/Menu" && ./configure)
    gnustep_project
}

# --- main ---------------------------------------------------------------------

[ "$(id -u)" -eq 0 ] || die "must run as root (it installs into /System)"
[ -d /usr/lib/system ] || die "not a NextBSD system (no /usr/lib/system)"

want=${*:-$COMPONENTS}
for c in $want; do
    echo "$COMPONENTS" | grep -qx "$c" || die "unknown component: $c"
done

for c in $COMPONENTS; do
    case " $(echo $want) " in *" $c "*) ;; *) continue ;; esac
    echo "==> $c"
    prepare "$c"
    # Each component in its own shell, so GNUstep.sh and cd stay local to it.
    # Not `( ... ) || die`: set -e is ignored on the left of ||, so a failing
    # step inside the component would not stop it.
    set +e
    ( set -e; "build_$(echo "$c" | tr - _)" )
    rc=$?
    set -e
    [ "$rc" -eq 0 ] || die "$c failed (exit $rc)"
done
echo "==> done: $(echo $want | wc -w | tr -d ' ') components"
