---------------------------- MODULE CounterMutex ----------------------------
(***************************************************************************)
(* The counter based robust futex protocol: every lock operation reserves *)
(* a fresh owner cookie from a per-mutex counter. Because the cookie      *)
(* space is finite, values repeat; the protocol must guarantee that a     *)
(* reservation which was outpaced by a full counter wrap can never be     *)
(* used to attribute (or acquire) the lock.                               *)
(*                                                                         *)
(* Protocol elements modeled:                                              *)
(*                                                                         *)
(*  - The RSEQ event detector ("guard"): armed before the reservation;    *)
(*    cleared by any preemption/signal (Preempt) and, on all threads, by  *)
(*    the membarrier fence. The VDSO cmpxchg helper commits only when the *)
(*    guard is still armed; an event inside the helper aborts it (kernel  *)
(*    fixup), which is modeled by the commit step observing the cleared   *)
(*    guard.                                                              *)
(*                                                                         *)
(*  - The generation gate: cookie values repeat every C reservations and  *)
(*    the generation g = ctr \div GP flips every GP reservations (2*GP =  *)
(*    C, mirroring the 30-bit cookie space with the generation in bit     *)
(*    29). A reservation of generation g may only proceed once a fence    *)
(*    ran after generation g began (tracked in q_gen).                    *)
(*                                                                         *)
(*  - The robust list pending op and queued entry, the thread private     *)
(*    pending cookie, death at arbitrary points and the kernel exit       *)
(*    cleanup, as in the ExplicitCookie model.                            *)
(*                                                                         *)
(* Switches (all TRUE/"casmax" models the implemented protocol):          *)
(*                                                                         *)
(*  FenceOn:   the membarrier fence clears all guards. FALSE models a     *)
(*    quiescence which advances q_gen without actually fencing anybody.   *)
(*                                                                         *)
(*  GateKind:  "casmax" - q_gen is a monotonic generation number,         *)
(*                        advanced with a CAS-max after the fence.        *)
(*             "bit1"   - q_gen holds only the generation parity and is   *)
(*                        blindly stored after the fence (the "top bit"   *)
(*                        design sketch). A stale fencer can regress it.  *)
(*             "none"   - no gate: reservations proceed immediately and   *)
(*                        no fence ever runs.                             *)
(*                                                                         *)
(*  ExitFixup: the kernel disarms an uncommitted pending op of a task     *)
(*    which died inside the VDSO helper (fatal signal, never returned to  *)
(*    user space). FALSE models the kernel without that exit time fixup.  *)
(*                                                                         *)
(*  PendingViaHead: as in ExplicitCookie.                                 *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS
    Threads,
    C,              \* cookie space size (values 0..C-1, 0 is invalid)
    GP,             \* generation period: gen = ctr \div GP, 2*GP = C
    MaxCtr,         \* state constraint bound for the counter
    GateKind,       \* "casmax" | "bit1" | "none"
    FenceOn,        \* BOOLEAN
    ExitFixup,      \* BOOLEAN
    PendingViaHead  \* BOOLEAN

NONE == "none_"

Max(a, b) == IF a >= b THEN a ELSE b

VARIABLES
    ctr,        \* the per-mutex reservation counter (monotonic in the model)
    qgen,       \* quiesced generation marker (semantics per GateKind)
    word,       \* the futex word: [own : Nat, od : BOOLEAN]
    ecookie,    \* entry cookie slot embedded in the mutex
    pc, alive, guard,
    res,        \* the thread's reserved cookie
    rgen,       \* the generation of the reservation
    pending, pcookie, enq, cleaned,
    owner,      \* ghost
    corrupt     \* ghost

vars == <<ctr, qgen, word, ecookie, pc, alive, guard, res, rgen, pending,
          pcookie, enq, cleaned, owner, corrupt>>

PCs == {"idle", "armed", "reserved", "fence", "fstore", "setpc", "ready",
        "inhelper", "acquired", "cookied", "own", "rel", "unlocked"}

TypeOK ==
    /\ ctr \in Nat /\ qgen \in Nat
    /\ word \in [own : 0..C-1, od : BOOLEAN]
    /\ ecookie \in 0..C-1
    /\ pc \in [Threads -> PCs]
    /\ alive \in [Threads -> BOOLEAN]
    /\ guard \in [Threads -> BOOLEAN]
    /\ res \in [Threads -> 0..C-1]
    /\ rgen \in [Threads -> Nat]
    /\ pending \in [Threads -> BOOLEAN]
    /\ pcookie \in [Threads -> 0..C-1]
    /\ enq \in [Threads -> BOOLEAN]
    /\ cleaned \in [Threads -> BOOLEAN]
    /\ owner \in Threads \cup {NONE}
    /\ corrupt \in BOOLEAN

Init ==
    /\ ctr = 1 /\ qgen = 0
    /\ word = [own |-> 0, od |-> FALSE]
    /\ ecookie = 0
    /\ pc = [t \in Threads |-> "idle"]
    /\ alive = [t \in Threads |-> TRUE]
    /\ guard = [t \in Threads |-> FALSE]
    /\ res = [t \in Threads |-> 0]
    /\ rgen = [t \in Threads |-> 0]
    /\ pending = [t \in Threads |-> FALSE]
    /\ pcookie = [t \in Threads |-> 0]
    /\ enq = [t \in Threads |-> FALSE]
    /\ cleaned = [t \in Threads |-> FALSE]
    /\ owner = NONE
    /\ corrupt = FALSE

unch_kernel == UNCHANGED <<cleaned, corrupt>>

(***************************************************************************)
(* Lock operation                                                          *)
(***************************************************************************)

\* Store the guard descriptor into TLS::rseq::rseq_cs.
Arm(t) ==
    /\ alive[t] /\ pc[t] = "idle"
    /\ guard' = [guard EXCEPT ![t] = TRUE]
    /\ pc' = [pc EXCEPT ![t] = "armed"]
    /\ UNCHANGED <<ctr, qgen, word, ecookie, alive, res, rgen, pending,
                   pcookie, enq, owner>> /\ unch_kernel

\* atomic_fetch_add on the counter.
Reserve(t) ==
    /\ alive[t] /\ pc[t] = "armed"
    /\ res' = [res EXCEPT ![t] = ctr % C]
    /\ rgen' = [rgen EXCEPT ![t] = ctr \div GP]
    /\ ctr' = ctr + 1
    /\ pc' = [pc EXCEPT ![t] = "reserved"]
    /\ UNCHANGED <<qgen, word, ecookie, alive, guard, pending, pcookie, enq,
                   owner>> /\ unch_kernel

\* Cookie 0 is invalid (0 == unlocked); skip it.
ZeroSkip(t) ==
    /\ alive[t] /\ pc[t] = "reserved" /\ res[t] = 0
    /\ guard' = [guard EXCEPT ![t] = FALSE]
    /\ pc' = [pc EXCEPT ![t] = "idle"]
    /\ UNCHANGED <<ctr, qgen, word, ecookie, alive, res, rgen, pending,
                   pcookie, enq, owner>> /\ unch_kernel

GateOK(t) ==
    CASE GateKind = "casmax" -> qgen >= rgen[t]
      [] GateKind = "bit1"   -> qgen = rgen[t] % 2
      [] GateKind = "none"   -> TRUE

GatePass(t) ==
    /\ alive[t] /\ pc[t] = "reserved" /\ res[t] # 0
    /\ GateOK(t)
    /\ pc' = [pc EXCEPT ![t] = "setpc"]
    /\ UNCHANGED <<ctr, qgen, word, ecookie, alive, guard, res, rgen, pending,
                   pcookie, enq, owner>> /\ unch_kernel

\* Gate failed: disarm the guard (the fence is a system call) and go
\* quiesce. The reservation is discarded, the operation restarts.
GateFail(t) ==
    /\ alive[t] /\ pc[t] = "reserved" /\ res[t] # 0
    /\ ~GateOK(t)
    /\ guard' = [guard EXCEPT ![t] = FALSE]
    /\ pc' = [pc EXCEPT ![t] = "fence"]
    /\ UNCHANGED <<ctr, qgen, word, ecookie, alive, res, rgen, pending,
                   pcookie, enq, owner>> /\ unch_kernel

\* membarrier(MEMBARRIER_CMD_SHARED_EXPEDITED_RSEQ): every task which can
\* possibly hold a reservation for this mutex loses its guard. When the
\* IPI arrives, a target either has not committed yet (its guard is
\* cleared / its in-helper operation is aborted by the kernel fixup) or
\* its cmpxchg already committed (the publication is visible).
DoFence(t) ==
    /\ alive[t] /\ pc[t] = "fence"
    /\ guard' = IF FenceOn THEN [u \in Threads |-> FALSE] ELSE guard
    /\ pc' = [pc EXCEPT ![t] = "fstore"]
    /\ UNCHANGED <<ctr, qgen, word, ecookie, alive, res, rgen, pending,
                   pcookie, enq, owner>> /\ unch_kernel

\* Advance the quiesced generation marker. This is a separate step from
\* the fence: the fencing thread can be delayed arbitrarily in between,
\* which is exactly what breaks the blind "bit1" store.
StoreGate(t) ==
    /\ alive[t] /\ pc[t] = "fstore"
    /\ qgen' = CASE GateKind = "casmax" -> Max(qgen, rgen[t])
                 [] GateKind = "bit1"   -> rgen[t] % 2
                 [] GateKind = "none"   -> qgen
    /\ pc' = [pc EXCEPT ![t] = "idle"]
    /\ UNCHANGED <<ctr, word, ecookie, alive, guard, res, rgen, pending,
                   pcookie, enq, owner>> /\ unch_kernel

\* Publish the pending cookie (final ABI) or the entry cookie (rejected
\* ABI) for the upcoming attempt.
SetPCookie(t) ==
    /\ alive[t] /\ pc[t] = "setpc"
    /\ pcookie' = [pcookie EXCEPT ![t] = res[t]]
    /\ ecookie' = IF PendingViaHead THEN ecookie ELSE res[t]
    /\ pc' = [pc EXCEPT ![t] = "ready"]
    /\ UNCHANGED <<ctr, qgen, word, alive, guard, res, rgen, pending, enq,
                   owner>> /\ unch_kernel

\* Enter the VDSO helper: the pending op is armed first.
VdsoArm(t) ==
    /\ alive[t] /\ pc[t] = "ready"
    /\ pending' = [pending EXCEPT ![t] = TRUE]
    /\ pc' = [pc EXCEPT ![t] = "inhelper"]
    /\ UNCHANGED <<ctr, qgen, word, ecookie, alive, guard, res, rgen, pcookie,
                   enq, owner>> /\ unch_kernel

\* The guarded cmpxchg. An RSEQ event before this step cleared the guard
\* (including events inside the helper: the kernel fixup aborts the
\* operation, which is equivalent to observing the cleared guard here).
VdsoCommit(t) ==
    /\ alive[t] /\ pc[t] = "inhelper"
    /\ IF ~guard[t] \/ word.own # 0
       THEN /\ pending' = [pending EXCEPT ![t] = FALSE]
            /\ pc' = [pc EXCEPT ![t] = "idle"]
            /\ guard' = [guard EXCEPT ![t] = FALSE]
            /\ UNCHANGED <<word, owner>>
       ELSE /\ word' = [own |-> res[t], od |-> word.od]
            /\ owner' = t
            /\ pc' = [pc EXCEPT ![t] = "acquired"]
            /\ guard' = [guard EXCEPT ![t] = FALSE]
            /\ UNCHANGED pending
    /\ UNCHANGED <<ctr, qgen, ecookie, alive, res, rgen, pcookie, enq>>
    /\ unch_kernel

\* The owner writes the entry cookie (owner exclusive).
WriteEntryCookie(t) ==
    /\ alive[t] /\ pc[t] = "acquired"
    /\ ecookie' = res[t]
    /\ pc' = [pc EXCEPT ![t] = "cookied"]
    /\ UNCHANGED <<ctr, qgen, word, alive, guard, res, rgen, pending, pcookie,
                   enq, owner>> /\ unch_kernel

Enqueue(t) ==
    /\ alive[t] /\ pc[t] = "cookied"
    /\ enq' = [enq EXCEPT ![t] = TRUE]
    /\ pending' = [pending EXCEPT ![t] = FALSE]
    /\ pc' = [pc EXCEPT ![t] = "own"]
    /\ UNCHANGED <<ctr, qgen, word, ecookie, alive, guard, res, rgen, pcookie,
                   owner>> /\ unch_kernel

(***************************************************************************)
(* Unlock                                                                  *)
(***************************************************************************)

StartRel(t) ==
    /\ alive[t] /\ pc[t] = "own"
    /\ pending' = [pending EXCEPT ![t] = TRUE]
    /\ pcookie' = [pcookie EXCEPT ![t] = res[t]]
    /\ enq' = [enq EXCEPT ![t] = FALSE]
    /\ pc' = [pc EXCEPT ![t] = "rel"]
    /\ UNCHANGED <<ctr, qgen, word, ecookie, alive, guard, res, rgen,
                   owner>> /\ unch_kernel

Release1(t) ==
    /\ alive[t] /\ pc[t] = "rel"
    /\ word' = [own |-> 0, od |-> FALSE]
    /\ owner' = NONE
    /\ pc' = [pc EXCEPT ![t] = "unlocked"]
    /\ UNCHANGED <<ctr, qgen, ecookie, alive, guard, res, rgen, pending,
                   pcookie, enq>> /\ unch_kernel

Release2(t) ==
    /\ alive[t] /\ pc[t] = "unlocked"
    /\ pending' = [pending EXCEPT ![t] = FALSE]
    /\ pc' = [pc EXCEPT ![t] = "idle"]
    /\ UNCHANGED <<ctr, qgen, word, ecookie, alive, guard, res, rgen, pcookie,
                   enq, owner>> /\ unch_kernel

(***************************************************************************)
(* Events, death and kernel cleanup                                        *)
(***************************************************************************)

\* Any RSEQ event (preemption, signal, migration) clears the guard.
Preempt(t) ==
    /\ alive[t] /\ guard[t]
    /\ guard' = [guard EXCEPT ![t] = FALSE]
    /\ UNCHANGED <<ctr, qgen, word, ecookie, pc, alive, res, rgen, pending,
                   pcookie, enq, owner>> /\ unch_kernel

Die(t) ==
    /\ alive[t]
    /\ alive' = [alive EXCEPT ![t] = FALSE]
    /\ UNCHANGED <<ctr, qgen, word, ecookie, pc, guard, res, rgen, pending,
                   pcookie, enq, owner>> /\ unch_kernel

PendingId(t) == IF PendingViaHead THEN pcookie[t] ELSE ecookie

\* Does the exit time fixup disarm the pending op? When the task died
\* inside the VDSO cmpxchg helper before the cmpxchg committed
\* ("inhelper"), or inside the VDSO try_unlock helper after the unlock
\* committed but before the pending op was disarmed ("unlocked").
PendingDisarmedAtExit(t) == ExitFixup /\ pc[t] \in {"inhelper", "unlocked"}

KernelCleanup(t) ==
    /\ ~alive[t] /\ ~cleaned[t]
    /\ cleaned' = [cleaned EXCEPT ![t] = TRUE]
    /\ LET pend_valid == pending[t] /\ ~PendingDisarmedAtExit(t)
           match == IF pend_valid
                    THEN word.own # 0 /\ word.own = PendingId(t)
                    ELSE enq[t] /\ word.own # 0 /\ word.own = ecookie
       IN IF match
          THEN /\ word' = [own |-> 0, od |-> TRUE]
               /\ corrupt' = corrupt \/ (owner # NONE /\ owner # t)
               /\ owner' = IF owner = t THEN NONE ELSE owner
          ELSE UNCHANGED <<word, corrupt, owner>>
    /\ UNCHANGED <<ctr, qgen, ecookie, pc, alive, guard, res, rgen, pending,
                   pcookie, enq>>

Reincarnate(t) ==
    /\ ~alive[t] /\ cleaned[t]
    /\ alive' = [alive EXCEPT ![t] = TRUE]
    /\ cleaned' = [cleaned EXCEPT ![t] = FALSE]
    /\ pc' = [pc EXCEPT ![t] = "idle"]
    /\ guard' = [guard EXCEPT ![t] = FALSE]
    /\ pending' = [pending EXCEPT ![t] = FALSE]
    /\ enq' = [enq EXCEPT ![t] = FALSE]
    /\ owner' = IF owner = t THEN NONE ELSE owner
    /\ UNCHANGED <<ctr, qgen, word, ecookie, res, rgen, pcookie, corrupt>>

Next ==
    \E t \in Threads :
        \/ Arm(t) \/ Reserve(t) \/ ZeroSkip(t) \/ GatePass(t) \/ GateFail(t)
        \/ DoFence(t) \/ StoreGate(t) \/ SetPCookie(t) \/ VdsoArm(t)
        \/ VdsoCommit(t) \/ WriteEntryCookie(t) \/ Enqueue(t)
        \/ StartRel(t) \/ Release1(t) \/ Release2(t)
        \/ Preempt(t) \/ Die(t) \/ KernelCleanup(t) \/ Reincarnate(t)

Spec == Init /\ [][Next]_vars /\ \A t \in Threads : WF_vars(KernelCleanup(t))

Constraint == ctr <= MaxCtr

(***************************************************************************)
(* Properties                                                              *)
(***************************************************************************)

NoCorruption == ~corrupt

Holding(t) == alive[t] /\ pc[t] \in {"acquired", "cookied", "own", "rel"}

Exclusion ==
    \A t \in Threads : Holding(t) => owner = t /\ word.own = res[t]

Recovery ==
    \A t \in Threads : (owner = t /\ ~alive[t]) ~> (word.own = 0)

=============================================================================
