# PID namespace agnostic robust futexes

A Linux kernel patch series, reference user space implementation,
benchmarks and TLA+ verification for making **robust futexes work across
PID namespaces** by replacing the TID in the lock word with a user space
managed **owner cookie**.

The kernel series (8 patches, `patches/`) applies on top of mainline
after the 7.2 `FUTEX_ROBUST_UNLOCK`/vDSO robust-unlock work and adds:

0. A standalone fix (patches 1-2, independently applicable): the exit
   time robust list walk now replays the wakeup a dying waiter may
   have consumed. A robust unlock wipes `FUTEX_WAITERS` and wakes one
   waiter; if that waiter is killed before acting on the wakeup while
   a third task re-acquired the futex, the remaining waiters slept
   forever on current kernels (deterministic and racing reproducers
   in `repro/`). The replay fires only while `FUTEX_WAITERS` is not
   re-armed - an observed bit is only ever cleared by an unlock which
   wakes, so it already guarantees a wakeup from the live owner.
1. `ROBUST_LIST_COOKIE` — an extensible robust list head
   (`struct robust_list_head2`, selected by size) which makes the exit
   time cleanup compare the futex word against per-entry cookies and a
   task private pending op cookie instead of the exiting task's TID.
2. `__vdso_futex_robust_list{64,32}_cmpxchg_rseq()` — an RSEQ guarded
   lock acquisition helper, so that cookies can be drawn from a finite
   per lock reservation counter without a wrapped (reused) cookie value
   ever being published or misattributed. Includes exit time fixups for
   tasks killed inside the vDSO critical sections.
3. `MEMBARRIER_CMD_SHARED_EXPEDITED_RSEQ` — an RSEQ fence over every
   process that write-shares a given page, used to quiesce in flight
   cookie reservations on counter epoch changes.

## The problem, and how long it has been around

Robust futexes ([merged in 2.6.17, 2006](https://lwn.net/Articles/172149/);
[original patch posting](https://lwn.net/Articles/172134/);
[kernel docs](https://docs.kernel.org/locking/robust-futexes.html)) let
the kernel recover locks held by tasks that die: user space stores the
owner's TID in the low 30 bits of the lock word, and at exit the kernel
walks the thread's robust list and marks any lock whose owner field
matches the dying thread's TID with `FUTEX_OWNER_DIED`.

That identification breaks as soon as the same lock is visible from more
than one PID namespace: TIDs are only unique per namespace, so a task
dying in one namespace can be misidentified as the owner of a lock held
by a live task in another namespace — the kernel then clears the owner
field, sets `FUTEX_OWNER_DIED` and wakes a waiter on a perfectly healthy
lock, silently breaking mutual exclusion.

This was understood *before PID namespaces were merged*:

- **Nov 2007, LWN: [Process IDs in a multi-namespace world](https://lwn.net/Articles/257297/)**
  (Jonathan Corbet) — covering the discussion at the time PID namespaces
  went into 2.6.24 ([companion article on the merge](https://lwn.net/Articles/259217/)).
  Ingo Molnar, reviving questions Ulrich Drepper had raised in early
  2006, called robust futexes "the biggest sticking point": the owner
  TID is stored by the user space fast path, so "there is no way to let
  the kernel perform magic PID translation without destroying the
  performance feature that was the motivation for futexes in the first
  place." Molnar and Drepper argued for holding PID namespaces back
  until a solution existed; the feature shipped anyway and the problem
  has been documented-but-unsolved ever since.

The libc side has repeatedly rediscovered and re-documented the
limitation rather than being able to fix it:

- **Oct 2017, libc-alpha: ["Supporting CLONE_NEWPID namespaces and
  process-shared mutexes supported?"](https://inbox.sourceware.org/libc-alpha/4ad034eb-6eed-400e-9e9e-d30776157fad@redhat.com/)**
  (Carlos O'Donell; [Adhemerval Zanella's summary](https://inbox.sourceware.org/libc-alpha/a01cfbbf-59ea-36ea-0aef-53d9170828bf@linaro.org/)) —
  "We use tid's in the internals of a mutex to identify owner. This is
  considered unique for the system (though it has an ABA pid-reuse
  problem)"; futexes have "no namespace isolation", leaving shared
  `pthread_mutex_t`/`rwlock`/`cond` broken under `CLONE_NEWPID`. The
  conclusion was merely to "document the pitfalls and limitation" of
  process-shared synchronization across PID namespaces.
- **Feb 2025, musl: ["pthread_mutex_t shared between processes with
  different pid namespaces"](https://inbox.vuxu.org/musl/1bd9cb5599cbc4d55b342b1b4cb4b138b9c48a5b.camel@gmail.com/)**
  (Daniele Personal, with [Rich Felker's analysis](https://inbox.vuxu.org/musl/20250210181402.GA10433@brightrain.aerifal.cx/)) —
  robustness fundamentally cannot work across namespaces with the
  current protocol because the kernel side has to honor it; Felker notes
  a fix "would require at least having a new robust list" ABI. That new
  ABI is what this repository implements.

Adjacent data points of the same TID-in-lock-word disease: 32-bit
bionic keeps a 16-bit owner TID in `pthread_mutex_t` and
[aborts once PIDs exceed 65535](https://github.com/waydroid/waydroid/issues/2071);
glibc's robust mutex docs carry the namespace caveat to this day.

### Recent kernel-side groundwork this series builds on

- **2024–2025: André Almeida's `set_robust_list2` series**
  ([v5 posting via LWN](https://lwn.net/Articles/1027135/),
  [v6 posting](https://lore.kernel.org/all/20251122-tonyk-robust_futex-v6-0-05fea005a0fd@igalia.com/),
  [LPC 2025 talk](https://lpc.events/event/19/contributions/2108/)) —
  established the appetite and mechanism for extending the frozen robust
  list ABI (arm64 32-bit lists for emulators like FEX, multiple lists
  per task, the undocumented 2048 entry limit), though not the namespace
  identity problem.
- **Feb 2026, LWN: [API changes for the futex robust list](https://lwn.net/Articles/1056387/)**
  (Jake Edge) — LPC coverage including the robust *unlock* race
  (kernel writing into re-mapped memory), with glibc (Carlos O'Donell)
  and musl (Rich Felker) participation.
- **Mar–Jun 2026: Thomas Gleixner's `FUTEX_ROBUST_UNLOCK` + vDSO
  `__vdso_futex_robust_list{64,32}_try_unlock()` series**
  ([analysis](https://lore.kernel.org/lkml/20260316162316.356674433@kernel.org/),
  [vDSO patch](https://lore.kernel.org/all/20260602090535.883796247@kernel.org/)),
  merged for 7.2 — introduced the per-mm vDSO critical section
  bookkeeping and signal time fixup machinery that this series extends
  to the lock side, and the size-extensible `set_robust_list()`
  convention (`robust_list_head` grows, glibc detects by size) that
  `struct robust_list_head2` uses.

To my knowledge no previous attempt addressed the owner *identity*
itself — prior work either documented the limitation (libc), extended
the list mechanics (set_robust_list2), or fixed adjacent races
(FUTEX_ROBUST_UNLOCK). Replacing the TID with a user space managed
cookie, plus the reservation/quiescence machinery needed to mint
cookies for POSIX mutexes without global coordination, is the new part.

## Verification

- Kernel selftests: 38 futex tests (including a live PID namespace
  corruption reproducer and its cookie-based fix, exit-walk ordering
  tests which demonstrably fail on a kernel without the
  pending-before-entries cleanup order, and the classic-protocol
  lost wakeup test of patch 2, which demonstrably fails on an
  unfixed kernel) and 4 membarrier tests, run under QEMU.
- `repro/robust_lost_wakeup.c`: a standalone deterministic reproducer
  for the lost wakeup fixed by patch 1 - the waiter times out (would
  hang forever) on unfixed kernels, verified against the unfixed 6.8
  host kernel, and is woken on the patched kernel under QEMU.
- `repro/robust_lost_wakeup_race.c`: the same bug hit by racing the
  real protocol (honest waiter loops, robust unlock, fast path
  re-acquire, SIGKILL of the possibly-woken waiter): strands a waiter
  on a free futex within a handful of kill rounds on the unfixed 6.8
  host, and cannot strand one on the patched kernel (run as a
  negative control in the QEMU guest suite).
- `rfmutex` (in `lib/`): mutual exclusion, cross PID namespace and
  SIGKILL stress tests with EOWNERDEAD recovery for all three cookie
  assignment schemes, plus lifecycle tests (concurrent first attach,
  non-owner unlock rejection, fork reset, OFD inode identity across
  renames, cookie lease release on thread exit, fd 0 handling).
- TLA+ (in `tla/`, results matrix in `tla/README.md`): the final design
  passes exhaustively (3 threads, full cookie wrap: 3.5e9 states) and
  the specifications demonstrably catch seven distinct broken variants,
  including the historical TID bug and both exit-walk ordering defects.
  Model checking found four genuine bugs during development: two exit
  fixup windows (fixed in patch 5), the requirement that the cookie
  lease entry is walked last (patch 3's pending-first order plus a
  documented user space list order obligation) and the classic
  protocol lost wakeup fixed by the standalone patch 1.
- Benchmarks vs. pthread mutexes in `bench/RESULTS.md`.

## Repository layout

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
- `repro/` — the standalone lost wakeup reproducer (see
  Verification above); built and run by `validate.sh`.
- `tla/` — TLA+ specifications, model instances and results; see
  `tla/README.md`. The models found genuine bugs during development
  (fixed in kernel patches 1 and 5) and validate the final design.
- `harness/` — QEMU/initramfs test harness:
  - `mkinitramfs.sh run.sh file...` builds a busybox+glibc initramfs
    with the given files under `/tests`.
  - `runqemu.sh [-c cpus] [-t timeout]` boots
    `/workspace/.kbuild/arch/x86/boot/bzImage` with it (TCG; the
    sandbox has no /dev/kvm).

## Reproducing the full validation

The patches in `patches/` apply with `git am` onto mainline commit
58717b2a1365 (post 7.2-rc4, containing the FUTEX_ROBUST_UNLOCK work).

The checked-in driver runs every validation group with explicit
expected outcomes (including the TLA+ configurations which *must*
produce counterexamples) and records a provenance manifest
(`validate-manifest.txt`, tool versions and artifact hashes):

    KSRC=/path/to/kernel-tree KBUILD=/path/to/kernel-build ./validate.sh
    ./validate.sh --exhaustive     # adds the multi-hour MCCounterOK10 run
    ./validate.sh --skip-kernel-build

Individual pieces (all paths overridable, see each script's header):

    # kernel
    make -C "$KBUILD" HOSTCC=gcc -j"$(nproc)"

    # selftests
    make -C "$KSRC/tools/testing/selftests/futex/functional" CC=gcc \
        KHDR_INCLUDES=-I"$KBUILD/usr/include" LDLIBS="-lpthread -ldl -lrt" robust_list
    make -C "$KSRC/tools/testing/selftests/membarrier" CC=gcc \
        KHDR_INCLUDES=-I"$KBUILD/usr/include"

    # library tests + benchmarks
    make -C lib CC=gcc KHDR="$KBUILD/usr/include"

    # QEMU run with the checked-in runner
    ./harness/mkinitramfs.sh initramfs/run-all.sh \
        "$KSRC/tools/testing/selftests/futex/functional/robust_list" \
        "$KSRC/tools/testing/selftests/membarrier/membarrier_shared_rseq_test" \
        lib/test_rfmutex repro/robust_lost_wakeup
    ./harness/runqemu.sh -c "$(nproc)" -t 900 -k "$KBUILD/arch/x86/boot/bzImage"

    # model checking (single configuration)
    cd tla && java -cp tla2tools.jar tlc2.TLC -workers "$(nproc)" -deadlock MCExplicitOK
