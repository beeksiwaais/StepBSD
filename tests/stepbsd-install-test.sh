#!/bin/sh
#
# stepbsd-install-test.sh — end-to-end test of a StepBSD ISO in qemu:
#
#   1. install  boot the live ISO (UEFI), run stepbsd-install onto a blank
#               16 GiB virtio disk
#   2. check    boot the installed disk (amd64: legacy BIOS, pmbr + gptboot;
#               arm64: UEFI) and check the root file system, GNUstep at run
#               time and the launchd jobs
#   3. gui      boot the installed disk with UEFI like a real machine (no
#               serial console), let the admin autologin start the desktop on
#               ttyv0, and take a screenshot; fail if the screen is still the
#               text console
#
# Phases 1 and 2 are driven over the serial console by
# tests/stepbsd-install-test.exp.
#
# usage: [ARCH=amd64|arm64] tests/stepbsd-install-test.sh path/to/StepBSD-<arch>-*.iso[.zip]
# ARCH defaults to the one in the ISO's name. Run it on a host of the same
# architecture (KVM when available, TCG otherwise).
# Logs and screenshots go to $OUT (default tests/out).

set -eu

ISO=${1:?usage: stepbsd-install-test.sh path/to/StepBSD-<arch>-*.iso[.zip]}
case "${ARCH:-$ISO}" in
*arm64*|*aarch64*) ARCH=arm64 ;;
*)                 ARCH=amd64 ;;
esac
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${OUT:-tests/out}
GUI_WAIT=${GUI_WAIT:-150}
NEXTBSD_CI_TAG=v0.3.5
mkdir -p "$OUT"

case "$ISO" in
*.zip)
    MEMBER=$(unzip -Z1 "$ISO" | grep -E '\.iso$' | head -1)
    [ -n "$MEMBER" ] || { echo "FAIL: no .iso in $ISO" >&2; exit 1; }
    echo "==> extracting $MEMBER"
    unzip -p "$ISO" "$MEMBER" > "$OUT/live.iso"
    ISO=$OUT/live.iso
    ;;
esac

[ -d nextbsd-ci/.git ] || git clone -q --depth 1 --branch "$NEXTBSD_CI_TAG" \
    https://github.com/nextbsd/nextbsd-ci.git nextbsd-ci
HARNESS=$(pwd)/nextbsd-ci/harness

if [ -e /dev/kvm ]; then sudo chmod 666 /dev/kvm 2>/dev/null || true; fi
if [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
    ACCEL="-accel kvm -cpu host"
else
    ACCEL="-accel tcg -cpu max"
fi

case "$ARCH" in
amd64)
    QEMU=qemu-system-x86_64
    MACHINE=q35
    FWS="/usr/share/ovmf/OVMF.fd /usr/share/OVMF/OVMF_CODE.fd /usr/share/qemu/OVMF.fd
         /opt/homebrew/share/qemu/edk2-x86_64-code.fd"
    NIC="-nic user,model=e1000"
    CD="-cdrom $ISO -boot d"
    # The installed disk is checked through the BIOS path (SeaBIOS: pmbr +
    # gptboot); the desktop phase covers UEFI.
    CHECK_FW=no
    VIDEO="-vga std"
    ;;
arm64)
    QEMU=qemu-system-aarch64
    MACHINE=virt
    FWS="/usr/share/qemu-efi-aarch64/QEMU_EFI.fd /usr/share/AAVMF/AAVMF_CODE.fd
         /opt/homebrew/share/qemu/edk2-aarch64-code.fd"
    # The arm64 QEMU packages ship no PXE ROM for virtio-net.
    NIC="-netdev user,id=net0 -device virtio-net-pci,netdev=net0,romfile="
    CD="-drive file=$ISO,format=raw,if=none,id=cd0,media=cdrom -device virtio-scsi-pci -device scsi-cd,drive=cd0,bootindex=0"
    # arm64 is UEFI only.
    CHECK_FW=yes
    VIDEO="-device virtio-gpu-pci -device qemu-xhci -device usb-kbd -device usb-tablet"
    ;;
esac

FW=
for f in $FWS; do
    [ -f "$f" ] && { FW=$f; break; }
done
[ -n "$FW" ] || { echo "FAIL: no UEFI firmware for $QEMU" >&2; exit 1; }
echo "==> $ARCH: $QEMU -machine $MACHINE $ACCEL, UEFI firmware $FW"

DISK=$OUT/disk.qcow2
rm -f "$DISK"
qemu-img create -q -f qcow2 "$DISK" 16G
# shellcheck disable=SC2086
set -- $QEMU -machine $MACHINE $ACCEL -m 4096 -smp 2 $NIC \
    -drive "file=$DISK,format=qcow2,if=virtio"

echo "==> phase 1: install from the live ISO"
expect "$HERE/stepbsd-install-test.exp" "$HARNESS" install \
    "$@" -bios "$FW" $CD -nographic 2>&1 | tee "$OUT/install.log"
grep -q 'STEPBSD-TEST-PASS: install' "$OUT/install.log" || { echo "FAIL: phase 1" >&2; exit 1; }

if [ "$CHECK_FW" = yes ]; then CHECK_BOOT="-bios $FW"; BOOTKIND=UEFI; else CHECK_BOOT=; BOOTKIND=BIOS; fi
echo "==> phase 2: check the installed system ($BOOTKIND boot)"
# shellcheck disable=SC2086
expect "$HERE/stepbsd-install-test.exp" "$HARNESS" check \
    "$@" $CHECK_BOOT -nographic 2>&1 | tee "$OUT/check.log"
grep -q 'STEPBSD-TEST-PASS: check' "$OUT/check.log" || { echo "FAIL: phase 2" >&2; exit 1; }

echo "==> phase 3: desktop on the installed system (UEFI boot, ${GUI_WAIT}s)"
MON=$OUT/monitor.sock
rm -f "$MON"
"$@" -bios "$FW" $VIDEO -display none -serial "file:$OUT/gui-serial.log" \
    -monitor "unix:$MON,server,nowait" &
QPID=$!
monitor() {
    python3 -I - "$MON" "$1" <<'PY'
import socket, sys, time
s = socket.socket(socket.AF_UNIX)
s.connect(sys.argv[1])
time.sleep(0.5); s.recv(65536)
s.sendall((sys.argv[2] + "\n").encode())
time.sleep(2)
PY
}
sleep "$GUI_WAIT"
monitor "screendump $OUT/desktop.ppm"
sleep 2
monitor quit || true
wait "$QPID" || true

python3 -I "$HERE/ppm2png.py" "$OUT/desktop.ppm" "$OUT/desktop.png"
echo "==> PASS: StepBSD $ARCH installs, boots and starts its desktop"
