# TLA+ specifications for cookie based robust futexes

Two specifications model the protocols implemented by the kernel series
and the rfmutex reference library, at an abstraction level that includes
the parts where the historical bugs live: death at arbitrary points,
delayed (non atomic) kernel exit cleanup, the shared entry cookie slot,
the RSEQ guard / membarrier fence semantics and counter wraparound with
a miniature cookie space (4 values, generation period 2 — the model
analogue of the 30-bit space with the generation in bit 29).

- `ExplicitCookie.tla` — the explicit cookie protocol (registry/OFD
  allocation): unique-per-live-thread identifiers, robust list pending
  and queued entry handling, kernel cleanup, cookie reuse only after
  the previous holder's cleanup (which is what the registry slot locks
  and OFD lock lifetimes guarantee).

- `CounterMutex.tla` — the per mutex reservation counter protocol: RSEQ
  guard ("no event since armed" detector), the vDSO cmpxchg helper with
  its abort fixup semantics, the membarrier fence, the quiesced
  generation gate, the exit time pending op fixups, plus everything
  from the explicit model.

Ghost state (`owner`, `corrupt`) tracks true ownership so the two key
safety properties are directly checkable:

- `NoCorruption` — the kernel exit cleanup never modifies a lock which
  a live task holds (the PID namespace corruption class).
- `Exclusion` — every task which believes it holds the lock is the
  unique ghost owner and the lock word carries its identifier.
- `Recovery` (liveness) — a lock whose owner died is eventually
  recovered (requires weak fairness on the kernel cleanup).

## Results matrix

Run: `java -cp tla2tools.jar tlc2.TLC -workers N -deadlock MC<name>`.

| Config                | Models                                            | Result |
|-----------------------|---------------------------------------------------|--------|
| MCExplicitOK          | final ABI, unique cookies (3 threads)             | PASS (incl. Recovery) |
| MCExplicitTid         | classic TID protocol, TID collision across pidns  | Exclusion **violated** (the original kernel bug) |
| MCExplicitOldABI      | pending op attributed via shared entry cookie     | Exclusion **violated** (why list_op_pending_cookie exists) |
| MCCounterOK           | final counter protocol (3 threads)                | PASS |
| MCCounterOKLive       | final counter protocol (2 threads, + liveness)    | PASS (incl. Recovery) |
| MCCounterNoExitFixup  | no exit time pending fixups (3 threads)           | Exclusion **violated** (fatal-signal death windows; the fence cannot reach a dead task) |
| MCCounterOrigDesign   | entry cookie attribution, fence on, no exit fixup | Exclusion **violated** (the design as originally sketched) |
| MCCounterOldABI       | entry cookie attribution + exit fixups + fence    | Recovery **violated** (a contender overwriting the entry cookie makes a dead owner uncleanable: waiters hang) |
| MCCounterNoFence      | final ABI, fence disabled                         | PASS (see below) |
| MCCounterNoGate       | final ABI, no generation gate (fence never runs)  | PASS (see below) |
| MCCounterBit1         | final ABI, 1-bit blindly stored epoch marker      | PASS (see below) |

## Notable findings

1. **The exit time fixups are required, the fence alone is not
   sufficient.** A task killed by an unhandled fatal signal never
   returns to user space, so no RSEQ or signal fixup runs. Its armed
   `list_op_pending` survives until the robust exit walk, which can run
   arbitrarily late — after the lock was released and re-acquired under
   a numerically identical wrapped cookie. TLC produced this as a
   counterexample (death between a committed vdso unlock and the
   pending disarm) against a design believed correct; a second window
   (death inside the cmpxchg helper before commit) was found during
   model construction. Both are fixed in kernel patch 3 by applying the
   signal delivery fixups against the dead task's register frame before
   the exit walk. Identifiers that are unique among live tasks (TIDs,
   registry/OFD cookies) are immune, because they cannot be reused
   before their holder's cleanup completed.

2. **With the final ABI the fence is not needed for kernel-side
   safety.** Once the pending op is attributed through the task private
   `list_op_pending_cookie`, the entry cookie is written only by the
   owner, and the exit fixups are in place, every attribution the exit
   walk can make is self-consistent, and lock word ownership itself is
   serialized by the cmpxchg regardless of cookie values — so
   `MCCounterNoFence`/`NoGate`/`Bit1` pass. The reservation guard and
   quiescence fence remain part of the implemented protocol: they keep
   reservation lifetimes bounded by construction rather than by the
   above (subtle) global argument, at negligible cost (one fence per
   2^29 acquisitions per mutex). But per the model they are defense in
   depth for the final ABI, not the load bearing wall they were in the
   original entry-cookie design.

3. **The model checker earns its keep only if it can fail.** Every
   "violated" row above doubles as a validation of the specification's
   abstraction level: the spec finds the historical TID bug, both
   variants of the entry-cookie ABI defect (corruption without exit
   fixups, robustness loss with them) and the exit fixup windows.

## Files

- `ExplicitCookie.tla`, `CounterMutex.tla` — the specifications.
- `MC*.tla` / `MC*.cfg` — model instances (constants per the matrix).
- `tla2tools.jar` — TLC 1.8.0 (needs Java 11+).
