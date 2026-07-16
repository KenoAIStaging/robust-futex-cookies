#!/bin/bash
# Build a minimal busybox initramfs. Any files given as arguments are copied
# into /tests inside the image. /init runs /tests/run.sh if present, prints
# TESTRUN-EXIT:<code>, then powers off.
set -e
WORK=/workspace/robust-futex-work
ROOT="$WORK/initramfs/root"
rm -rf "$ROOT"
mkdir -p "$ROOT"/{bin,sbin,proc,sys,dev,tmp,tests,etc}
cp /usr/bin/busybox "$ROOT/bin/busybox"
# Debian glibc runtime for dynamically linked test binaries
mkdir -p "$ROOT/lib/x86_64-linux-gnu" "$ROOT/lib64"
cp /lib/x86_64-linux-gnu/{libc.so.6,libpthread.so.0,libdl.so.2,librt.so.1,libm.so.6,libgcc_s.so.1} \
   "$ROOT/lib/x86_64-linux-gnu/"
cp /lib64/ld-linux-x86-64.so.2 "$ROOT/lib64/"
for a in sh mount umount poweroff sleep cat echo ls dmesg mkdir ps grep sed head tail nproc taskset; do
    ln -sf busybox "$ROOT/bin/$a"
done
cat > "$ROOT/init" <<'EOF'
#!/bin/sh
export PATH=/bin:/sbin
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t tmpfs tmpfs /tmp
mount -t devtmpfs devtmpfs /dev 2>/dev/null
echo "=== BOOT-OK ==="
rc=0
if [ -x /tests/run.sh ]; then
    /tests/run.sh
    rc=$?
fi
echo "TESTRUN-EXIT:$rc"
poweroff -f
EOF
chmod +x "$ROOT/init"
for f in "$@"; do
    cp -r "$f" "$ROOT/tests/"
done
[ -f "$ROOT/tests/run.sh" ] && chmod +x "$ROOT/tests/run.sh"
(cd "$ROOT" && find . | cpio -o -H newc --quiet | gzip -1) > "$WORK/initramfs/initramfs.cpio.gz"
echo "initramfs: $WORK/initramfs/initramfs.cpio.gz ($(du -h "$WORK/initramfs/initramfs.cpio.gz" | cut -f1))"
