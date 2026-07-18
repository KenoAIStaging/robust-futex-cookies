#!/bin/bash
# SPDX-License-Identifier: MIT
#
# Top level validation driver: builds the exact artifacts, runs every
# test group and executes the TLA+ model matrix with explicit expected
# outcomes. Fails closed: any unexpected result is a nonzero exit.
#
# Usage: ./validate.sh [--quick|--exhaustive] [--skip-kernel-build]
#
#   --quick            bounded CI profile (default): selftests + library
#                      suite in QEMU, fast model configs
#   --exhaustive       additionally runs the multi-hour exhaustive
#                      counter model (MCCounterOK10)
#   --skip-kernel-build  use the existing bzImage as is
#
# Environment (defaults match the reproduction instructions in README.md):
#   KSRC   kernel source tree            (default: /workspace)
#   KBUILD kernel build directory        (default: $KSRC/.kbuild)
#   CC     compiler for user space       (default: gcc)
#   JAVA   JVM for TLC                   (default: java)
#
# A provenance manifest (tool versions, artifact hashes, per step
# results) is written to validate-manifest.txt.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
KSRC="${KSRC:-/workspace}"
KBUILD="${KBUILD:-$KSRC/.kbuild}"
CC="${CC:-gcc}"
JAVA="${JAVA:-java}"
PROFILE=quick
SKIP_KBUILD=0
for arg in "$@"; do
    case "$arg" in
        --quick) PROFILE=quick;;
        --exhaustive) PROFILE=exhaustive;;
        --skip-kernel-build) SKIP_KBUILD=1;;
        *) echo "unknown argument: $arg" >&2; exit 2;;
    esac
done

MANIFEST="$HERE/validate-manifest.txt"
FAILED=0

note() { echo "$*" | tee -a "$MANIFEST"; }
step() {
    local name="$1"; shift
    if "$@"; then
        note "PASS: $name"
    else
        note "FAIL: $name"
        FAILED=1
    fi
}

{
    echo "== validate.sh manifest =="
    echo "date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "profile: $PROFILE"
    echo "repo: $(git -C "$HERE" rev-parse HEAD 2>/dev/null || echo unknown)"
    echo "kernel tree: $(git -C "$KSRC" rev-parse HEAD 2>/dev/null || echo unknown)"
    echo "cc: $($CC --version 2>/dev/null | head -1 || echo unknown)"
    echo "java: $($JAVA -version 2>&1 | head -1 || echo unknown)"
    echo "tla2tools.jar sha256: $(sha256sum "$HERE/tla/tla2tools.jar" | cut -d' ' -f1)"
    echo "qemu: $(qemu-system-x86_64 -version 2>/dev/null | head -1 || echo unknown)"
} > "$MANIFEST"

# --- 1. kernel -----------------------------------------------------------
if [ "$SKIP_KBUILD" = 0 ]; then
    step "kernel build" make -C "$KBUILD" HOSTCC=/usr/bin/gcc -j"$(nproc)" -s
fi
[ -r "$KBUILD/arch/x86/boot/bzImage" ] || { note "FAIL: bzImage missing"; exit 1; }
note "bzImage sha256: $(sha256sum "$KBUILD/arch/x86/boot/bzImage" | cut -d' ' -f1)"

# --- 2. user space builds ------------------------------------------------
step "futex selftests" env -C "$KSRC/tools/testing/selftests/futex/functional" \
    PATH=/usr/bin:/bin:$PATH CC="$CC" make -s \
    KHDR_INCLUDES=-I"$KBUILD/usr/include" LDLIBS="-lpthread -ldl -lrt" robust_list
step "membarrier selftests" env -C "$KSRC/tools/testing/selftests/membarrier" \
    PATH=/usr/bin:/bin:$PATH CC="$CC" make -s KHDR_INCLUDES=-I"$KBUILD/usr/include"
step "rfmutex library + bench" make -s -C "$HERE/lib" clean all \
    CC="$CC" KHDR="$KBUILD/usr/include"
step "lost wakeup reproducer" "$CC" -O2 -Wall -Wextra \
    -o "$HERE/repro/robust_lost_wakeup" "$HERE/repro/robust_lost_wakeup.c"
step "lost wakeup race reproducer" "$CC" -O2 -Wall -Wextra \
    -o "$HERE/repro/robust_lost_wakeup_race" "$HERE/repro/robust_lost_wakeup_race.c"
step "lost wakeup glibc reproducer" "$CC" -O2 -Wall -Wextra \
    -o "$HERE/repro/robust_lost_wakeup_glibc" "$HERE/repro/robust_lost_wakeup_glibc.c" \
    -lpthread

# --- 3. QEMU test run ----------------------------------------------------
step "initramfs" "$HERE/harness/mkinitramfs.sh" "$HERE/initramfs/run-all.sh" \
    "$KSRC/tools/testing/selftests/futex/functional/robust_list" \
    "$KSRC/tools/testing/selftests/membarrier/membarrier_shared_rseq_test" \
    "$HERE/lib/test_rfmutex" \
    "$HERE/lib/bench_rfmutex" \
    "$HERE/repro/robust_lost_wakeup" \
    "$HERE/repro/robust_lost_wakeup_race" \
    "$HERE/repro/robust_lost_wakeup_glibc"
note "initramfs sha256: $(sha256sum "$HERE/initramfs/initramfs.cpio.gz" | cut -d' ' -f1)"
step "QEMU guest tests" "$HERE/harness/runqemu.sh" -c "$(nproc)" -t 900

# The benchmark smoke run happens inside the QEMU guest (run-all.sh):
# rfmutex requires the patched kernel, so it cannot run on the host.
# Published numbers in bench/RESULTS.md are from full length guest runs.

# --- 5. TLA+ model matrix ------------------------------------------------
# name:expected:deadlockflag. "pass" = no error found; "violation" = TLC
# must report an invariant or temporal property violation (a spec which
# cannot fail proves nothing). "nodl" runs with deadlock checking
# enabled (the waiter-model configs have no intentional terminal
# states); "dl" passes -deadlock (the counter model's bounded counter
# makes exhausted-counter states terminal by design, and the
# violation-expected configs stop at their counterexample anyway).
MODELS_QUICK="
MCExplicitOK:pass:nodl
MCExplicitOKStrict:pass:nodl
MCExplicitNoWake:violation:nodl
MCExplicitLostWaiter:violation:nodl
MCExplicitLeaseABA:violation:dl
MCExplicitLeaseOrder:violation:dl
MCExplicitOldABI:violation:dl
MCExplicitTid:violation:dl
MCCounterOKLive:pass:dl
MCCounterNoFence:pass:dl
MCCounterNoGate:pass:dl
MCCounterBit1:pass:dl
MCCounterNoExitFixup:violation:dl
MCCounterOrigDesign:violation:dl
MCCounterOldABI:violation:dl
"
MODELS_EXHAUSTIVE="MCCounterOK10:pass:dl"

run_model() {
    local name="$1" expect="$2" dl="$3"
    local log="$HERE/tla/runs/$name.log"
    local dlflag=""
    [ "$dl" = dl ] && dlflag="-deadlock"
    mkdir -p "$HERE/tla/runs"
    (cd "$HERE/tla" && $JAVA -XX:+UseParallelGC -cp tla2tools.jar tlc2.TLC \
        -workers "$(nproc)" $dlflag "$name") > "$log" 2>&1
    local outcome=fail
    if grep -q "Model checking completed. No error has been found" "$log"; then
        outcome=pass
    elif grep -qE "^Error: (Invariant|Temporal property).*violated" "$log"; then
        outcome=violation
    elif grep -q "Deadlock reached" "$log"; then
        outcome=deadlock
    fi
    note "model $name: $outcome (expected $expect; $(grep -oE '[0-9,]+ states generated' "$log" | tail -1))"
    [ "$outcome" = "$expect" ]
}

MODELS="$MODELS_QUICK"
[ "$PROFILE" = exhaustive ] && MODELS="$MODELS_QUICK $MODELS_EXHAUSTIVE"
for m in $MODELS; do
    IFS=: read -r mname mexpect mdl <<< "$m"
    step "model $mname" run_model "$mname" "$mexpect" "$mdl"
done

# --- summary -------------------------------------------------------------
if [ "$FAILED" = 0 ]; then
    note "== VALIDATION PASSED =="
else
    note "== VALIDATION FAILED =="
fi
exit $FAILED
