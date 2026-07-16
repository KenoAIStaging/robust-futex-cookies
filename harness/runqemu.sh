#!/bin/bash
# Boot the built kernel with the test initramfs under QEMU (TCG).
# Usage: runqemu.sh [-c cpus] [-t timeout_sec] [-k bzImage]
CPUS=8
TIMEOUT=600
KERNEL=/workspace/.kbuild/arch/x86/boot/bzImage
while getopts "c:t:k:" o; do
    case $o in
        c) CPUS=$OPTARG;;
        t) TIMEOUT=$OPTARG;;
        k) KERNEL=$OPTARG;;
    esac
done
WORK=/workspace/robust-futex-work
timeout --foreground "$TIMEOUT" qemu-system-x86_64 \
    -kernel "$KERNEL" \
    -initrd "$WORK/initramfs/initramfs.cpio.gz" \
    -m 4G -smp "$CPUS" \
    -nographic -no-reboot \
    -append "console=ttyS0 panic=-1 rseq_debug=0 quiet loglevel=4" \
    2>&1
