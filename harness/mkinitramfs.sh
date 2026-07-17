#!/bin/bash
# SPDX-License-Identifier: MIT
#
# Build a minimal busybox initramfs for the QEMU test harness.
#
# Usage: mkinitramfs.sh <runner.sh> [file...]
#
# The first argument is mandatory and becomes /tests/run.sh inside the
# image; all further files are copied to /tests. The guest init mounts
# the pseudo filesystems, runs /tests/run.sh and prints
# TESTRUN-EXIT:<code>; a missing or non-executable runner is reported
# as TESTRUN-EXIT:127 (fail closed), see runqemu.sh.
#
# Environment:
#   OUT                Output image (default: <repo>/initramfs/initramfs.cpio.gz)
#   SOURCE_DATE_EPOCH  Timestamp stamped on every file (default: 0), making
#                      the image byte-reproducible for identical inputs.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="$(dirname "$HERE")"
OUT="${OUT:-$WORK/initramfs/initramfs.cpio.gz}"
EPOCH="${SOURCE_DATE_EPOCH:-0}"

if [ $# -lt 1 ]; then
    echo "usage: $0 <runner.sh> [file...]" >&2
    exit 2
fi
RUNNER="$1"
shift
[ -f "$RUNNER" ] || { echo "runner '$RUNNER' does not exist" >&2; exit 2; }

# Preflight: every required tool and runtime input must exist
for tool in busybox cpio gzip find sort touch sha256sum xargs; do
    command -v "$tool" >/dev/null || { echo "missing tool: $tool" >&2; exit 3; }
done
GLIBC_DIR=/lib/x86_64-linux-gnu
LIBS=(libc.so.6 libpthread.so.0 libdl.so.2 librt.so.1 libm.so.6 libgcc_s.so.1)
for l in "${LIBS[@]}"; do
    [ -e "$GLIBC_DIR/$l" ] || { echo "missing runtime library: $GLIBC_DIR/$l" >&2; exit 3; }
done
[ -e /lib64/ld-linux-x86-64.so.2 ] || { echo "missing dynamic loader" >&2; exit 3; }

# Isolated scratch root, removed on any exit; nothing outside it is touched
ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT

mkdir -p "$ROOT"/{bin,sbin,proc,sys,dev,tmp,tests,etc}
cp "$(command -v busybox)" "$ROOT/bin/busybox"
mkdir -p "$ROOT/lib/x86_64-linux-gnu" "$ROOT/lib64"
for l in "${LIBS[@]}"; do
    cp "$GLIBC_DIR/$l" "$ROOT/lib/x86_64-linux-gnu/"
done
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
if [ -x /tests/run.sh ]; then
    /tests/run.sh
    rc=$?
else
    echo "=== NO RUNNER ==="
    rc=127
fi
echo "TESTRUN-EXIT:$rc"
poweroff -f
EOF
chmod 755 "$ROOT/init"

cp "$RUNNER" "$ROOT/tests/run.sh"
chmod 755 "$ROOT/tests/run.sh"
for f in "$@"; do
    cp -r "$f" "$ROOT/tests/"
done

# Reproducibility: fixed timestamps, sorted file order, numeric root
# ownership, and no gzip name/mtime header.
find "$ROOT" -depth -print0 | xargs -0 touch -h -d "@$EPOCH"
mkdir -p "$(dirname "$OUT")"
TMPOUT="$(mktemp -p "$(dirname "$OUT")")"
(cd "$ROOT" && find . -print0 | LC_ALL=C sort -z | \
    cpio -o0 -H newc -R +0:+0 --renumber-inodes --ignore-devno --quiet | gzip -n -1) > "$TMPOUT"

# Validate before publishing: gzip integrity and the required members.
# (The member list goes through a file: grep -q would close the pipe
# early and trip pipefail.)
gzip -t "$TMPOUT"
zcat "$TMPOUT" | cpio -t --quiet > "$ROOT/members"
grep -qx "init" "$ROOT/members"
grep -qx "tests/run.sh" "$ROOT/members"
mv -f "$TMPOUT" "$OUT"

echo "initramfs: $OUT ($(du -h "$OUT" | cut -f1)) sha256:$(sha256sum "$OUT" | cut -d' ' -f1)"
