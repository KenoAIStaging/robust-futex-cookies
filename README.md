# PID namespace agnostic robust futexes — work area

Companion artifacts for the kernel series on branch
`kf/futex-robust-cookies-v2` (6 patches on top of `upstream/master`,
formatted in `patches/`).

## Layout

- `patches/` — `git format-patch` output including the cover letter.
- `lib/` — `rfmutex`, the reference robust mutex library implementing
  all three cookie assignment schemes on top of the new kernel ABI:
  - explicit cookies from a registry table in the shared region
    (slots held via robust futexes, reclaimed on holder death),
  - explicit cookies from OFD byte range locks on the region file
    (released by the kernel when the fds die with the process),
  - per mutex 30-bit reservation counter cookies validated with the
    vDSO cmpxchg helper and quiesced with
    MEMBARRIER_CMD_SHARED_EXPEDITED_RSEQ on generation changes (the
    generation bookkeeping is widened to 64 bit + a CAS-max quiesced
    marker so a stale fencer cannot regress it).
  `test_rfmutex.c` runs mutual exclusion, cross PID namespace, kill
  stress (EOWNERDEAD recovery) and counter generation tests.
- `bench/` — benchmarks vs. pthread mutexes; results in
  `bench/RESULTS.md`.
- `tla/` — TLA+ specifications, model instances and results; see
  `tla/README.md`. The models found two genuine bugs during
  development (both fixed in kernel patch 3) and validate the final
  design.
- `harness/` — QEMU/initramfs test harness:
  - `mkinitramfs.sh run.sh file...` builds a busybox+glibc initramfs
    with the given files under `/tests`.
  - `runqemu.sh [-c cpus] [-t timeout]` boots
    `/workspace/.kbuild/arch/x86/boot/bzImage` with it (TCG; the
    sandbox has no /dev/kvm).

## Reproducing the full validation

    # kernel
    cd /workspace/.kbuild && make HOSTCC=/usr/bin/gcc -j100

    # selftests (Debian toolchain; BB2's glibc is too old)
    cd /workspace/tools/testing/selftests/futex/functional
    env PATH=/usr/bin:/bin:/opt/bb2-tools/bin CC=gcc make \
        KHDR_INCLUDES=-I/workspace/.kbuild/usr/include \
        LDLIBS="-lpthread -ldl -lrt" robust_list
    cd /workspace/tools/testing/selftests/membarrier
    env PATH=/usr/bin:/bin:/opt/bb2-tools/bin CC=gcc make \
        KHDR_INCLUDES=-I/workspace/.kbuild/usr/include

    # library tests + benchmarks
    cd /workspace/robust-futex-work/lib && make

    # run everything in QEMU
    cd /workspace/robust-futex-work
    cat > /tmp/run.sh <<'EOF'
    #!/bin/sh
    cd /tests
    ./robust_list || exit 1
    ./membarrier_shared_rseq_test || exit 1
    ./test_rfmutex 300 || exit 1
    EOF
    ./harness/mkinitramfs.sh /tmp/run.sh /tmp/robust_list \
        /tmp/membarrier_shared_rseq_test /tmp/test_rfmutex
    ./harness/runqemu.sh -c 8 -t 600

    # model checking
    cd tla && java -cp tla2tools.jar tlc2.TLC -workers 32 -deadlock MCExplicitOK
