#!/bin/bash
# SPDX-License-Identifier: MIT
#
# Boot the built kernel with the test initramfs under QEMU (TCG) and
# propagate the *guest* test result: the run only succeeds if the guest
# booted (BOOT-OK marker), printed exactly one TESTRUN-EXIT marker with
# status 0, and neither panicked nor timed out. A clean guest poweroff
# alone is NOT success.
#
# Usage: runqemu.sh [-c cpus] [-t timeout_sec] [-k bzImage] [-i initramfs]
set -uo pipefail

CPUS=8
TIMEOUT=600
KERNEL=/workspace/.kbuild/arch/x86/boot/bzImage
HERE="$(cd "$(dirname "$0")" && pwd)"
INITRD="$(dirname "$HERE")/initramfs/initramfs.cpio.gz"
while getopts "c:t:k:i:" o; do
    case $o in
        c) CPUS=$OPTARG;;
        t) TIMEOUT=$OPTARG;;
        k) KERNEL=$OPTARG;;
        i) INITRD=$OPTARG;;
        *) exit 2;;
    esac
done
[ -r "$KERNEL" ] || { echo "kernel '$KERNEL' not readable" >&2; exit 2; }
[ -r "$INITRD" ] || { echo "initramfs '$INITRD' not readable" >&2; exit 2; }

LOG="$(mktemp)"
trap 'rm -f "$LOG"' EXIT

timeout --foreground "$TIMEOUT" qemu-system-x86_64 \
    -kernel "$KERNEL" \
    -initrd "$INITRD" \
    -m 4G -smp "$CPUS" \
    -nographic -no-reboot \
    -append "console=ttyS0 panic=-1 rseq_debug=0 quiet loglevel=4" \
    2>&1 | tee "$LOG"
QRC=${PIPESTATUS[0]}

if [ "$QRC" -eq 124 ]; then
    echo "HARNESS: FAIL (timeout after ${TIMEOUT}s)" >&2
    exit 4
fi
if [ "$QRC" -ne 0 ]; then
    echo "HARNESS: FAIL (qemu exited $QRC)" >&2
    exit 5
fi
if grep -qE "Kernel panic|BUG:|Oops:" "$LOG"; then
    echo "HARNESS: FAIL (kernel panic/oops in guest log)" >&2
    exit 6
fi
if ! grep -q "=== BOOT-OK ===" "$LOG"; then
    echo "HARNESS: FAIL (guest never booted)" >&2
    exit 7
fi
MARKERS=$(grep -c "^TESTRUN-EXIT:" "$LOG" || true)
if [ "$MARKERS" -ne 1 ]; then
    echo "HARNESS: FAIL (expected exactly one TESTRUN-EXIT marker, got $MARKERS)" >&2
    exit 8
fi
STATUS=$(grep "^TESTRUN-EXIT:" "$LOG" | sed 's/^TESTRUN-EXIT://' | tr -d '[:space:]')
if [ "$STATUS" != "0" ]; then
    echo "HARNESS: FAIL (guest tests exited $STATUS)" >&2
    exit 1
fi
echo "HARNESS: PASS"
