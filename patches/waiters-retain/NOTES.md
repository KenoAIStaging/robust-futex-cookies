# FUTEX_WAITERS retention across a contended robust unlock (v3 approach)

Replaces the exit-walk replay approach (series patches 1-2 / the standalone
`futex: Prevent robust futex exit race more` patch) after tglx's objection
to handling this in the exit processing. Instead the kernel robust unlock
(`FUTEX_ROBUST_UNLOCK`, tglx's unreleased v7.2-rc1 ABI, commit
3ca9595d9fb6) stores `FUTEX_WAITERS` instead of `0` when waiters remain
queued after the wakeup, keeping acquisitions on the contended path so the
next unlock wakes the next waiter. No exit-walk changes: the existing
owner-part-zero pending-op wake in `handle_futex_death()` covers a woken
waiter dying on the released word.

Patches apply to 58717b2a1365 (post 7.2-rc4). Note this does NOT fix the
legacy glibc store-0-then-FUTEX_WAKE protocol (the kernel never writes the
word there); the story for legacy binaries is adoption of
FUTEX_ROBUST_UNLOCK.

## Validation

- TLA+: `tla/WaitersRetain.tla` (explicit kernel hash bucket queue,
  futex_wait modeled as snapshot + atomic revalidate-and-enqueue).
  - MCWRetainOK: PASS exhaustive w/ liveness (32.9M generated / 9.2M
    distinct, depth 60): TypeOK/QOK/Exclusion/WtrInv + WaiterServed.
  - MCWRetainNoRetain (store 0, current mainline): WaiterServed violated -
    reproduces the woken-waiter-killed strand.
  - MCWRetainUnsync (count/store/wake unsynchronized): WaiterServed
    violated - a waiter enqueues between count and store (revalidation
    still matches) and is stranded uncounted. This is why the store must
    live inside the hash bucket lock section.
  - MCWRetainNoExitWake: WaiterServed violated - retention depends on the
    existing handle_futex_death() owner-zero pending wake.
- QEMU (TCG, 8 vCPU, base 58717b2a1365 + patches):
  - Patched kernel: futex robust_list selftests 18/18 across 5 runs
    (3 runs with SLEEP_US/FUTEX_TIMEOUT bumped to 10ms/10s as in the
    series tree; base-tree timing makes test_robustness TCG-flaky
    independently of these patches - it fails on the unpatched kernel
    too).
  - Unpatched base kernel (negative control): the new
    test_futex_robust_unlock_retains_waiters fails 3/3 with
    "Expected atomic_load(futex) (0) == FUTEX_WAITERS" - the test
    detects the old semantics.
