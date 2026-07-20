\* SPDX-License-Identifier: MIT
--------------------------- MODULE ExplicitCookie ---------------------------
(***************************************************************************)
(* Robust futex with explicit owner cookies (ROBUST_LIST_COOKIE), as used *)
(* by the rfmutex "explicit" implementation with registry or OFD cookie   *)
(* allocation.                                                             *)
(*                                                                         *)
(* The model contains one mutex, a cookie allocator whose lease is a      *)
(* second robust list entry (the registry slot), threads which attach     *)
(* (claim a cookie), acquire/release the mutex and may die at any point,  *)
(* and the kernel exit time cleanup. The cleanup is deliberately split    *)
(* into separate steps - pending op, lease slot entry, mutex entry - so   *)
(* that the walk order is part of the modeled protocol: the cookie        *)
(* becomes reusable as soon as the *slot* entry was processed, not when   *)
(* the whole walk finished.                                                *)
(*                                                                         *)
(* Switches:                                                               *)
(*                                                                         *)
(*   PendingFirst = TRUE models the fixed kernel: on a cookie list the    *)
(*     pending op is handled before any queued entry.                     *)
(*                                                                         *)
(*   PendingFirst = FALSE models the historical walk order (queued        *)
(*     entries, then the pending op). TLC finds the lease reuse           *)
(*     corruption: the slot entry releases the cookie, a new thread       *)
(*     claims it and acquires the lock the dead thread's stale pending    *)
(*     op refers to, and the late pending handling marks the live lock    *)
(*     FUTEX_OWNER_DIED (KenoAIStaging/robust-futex-cookies issue #1).    *)
(*                                                                         *)
(*   PendingViaHead = TRUE  models the final ABI: the pending op is       *)
(*     attributed via the thread private                                  *)
(*     robust_list_head2::list_op_pending_cookie.                         *)
(*                                                                         *)
(*   PendingViaHead = FALSE models the rejected ABI variant where the     *)
(*     pending op was attributed via the entry cookie embedded in the     *)
(*     (shared) mutex, written by every contender before its cmpxchg.     *)
(*     TLC finds the corruption: a loser overwrites the winner's entry    *)
(*     cookie while its own pending op is armed; if the loser dies, the   *)
(*     kernel misattributes the winner's lock.                            *)
(*                                                                         *)
(*   LeaseLast = TRUE models the documented user space obligation: the    *)
(*     lease slot entry is walked after every held lock entry (rfmutex     *)
(*     enqueues the slot at attach time and inserts later entries LIFO).  *)
(*                                                                         *)
(*   LeaseLast = FALSE lets the walk release the lease while held lock    *)
(*     entries are still unprocessed. TLC finds a corruption even with    *)
(*     PendingFirst: the freed cookie is claimed by a second thread whose *)
(*     own death misattributes (benignly) the first corpse's lock, which  *)
(*     lets a live thread re-acquire it while the first walk still holds  *)
(*     an unprocessed entry for it - and that stale entry cleanup then    *)
(*     wipes the live owner's lock.                                       *)
(*                                                                         *)
(*   WakeOnCleanup = FALSE drops the futex wake from the exit cleanup;    *)
(*     TLC then finds sleeping waiters which are never woken              *)
(*     (WaiterProgress violated).                                          *)
(*                                                                         *)
(*   WaitedBit = FALSE models an acquirer which does not re-assert the    *)
(*     WAITERS bit after being woken. The kernel robust unlock and        *)
(*     cleanup paths rewrite the whole lock word, so the bit is lost and  *)
(*     the remaining sleepers are stranded once the woken waiter unlocks  *)
(*     through the uncontended fast path (the "lost waiter" bug fixed in  *)
(*     rfmutex's rfm_lock_explicit()/rfm_lock_counter()).                 *)
(*                                                                         *)
(*   UseAllocator = FALSE disables the allocator: threads use the fixed   *)
(*     identifier FixedId[t] with no lease at all. Duplicate FixedId      *)
(*     values model the classic TID protocol with a TID collision across  *)
(*     PID namespaces; TLC then finds the original kernel bug this        *)
(*     series fixes.                                                      *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS
    Threads,        \* set of thread identifiers
    Cookies,        \* allocator pool (subset of Nat \ {0})
    UseAllocator,   \* BOOLEAN: leased cookies vs fixed identifiers
    FixedId,        \* [Threads -> Nat \ {0}]: identifiers if ~UseAllocator
    PendingViaHead, \* BOOLEAN: final ABI vs rejected entry-cookie ABI
    PendingFirst,   \* BOOLEAN: fixed vs historical kernel walk order
    LeaseLast,      \* BOOLEAN: slot entry ordered after all held locks
    WakeOnCleanup,  \* BOOLEAN: kernel cleanup wakes a waiter (real kernel)
    WaitedBit       \* BOOLEAN: a woken waiter re-asserts WAITERS on acquire

NONE == "none"

VARIABLES
    word,       \* the futex word: [own : Nat, od : BOOLEAN, wtr : BOOLEAN]
    ecookie,    \* the entry cookie slot embedded in the mutex
    pc,         \* thread program counters
    alive,      \* thread liveness
    cookie,     \* current owner identifier of the thread, 0 if none
    lease,      \* the slot entry holding the cookie is still uncleaned
    pending,    \* robust_list_head::list_op_pending armed (per thread)
    pcookie,    \* robust_list_head2::list_op_pending_cookie (per thread)
    enq,        \* mutex entry queued in the thread's robust list
    waited,     \* the thread slept at least once in this lock attempt
    done_p,     \* kernel walk: pending op processed
    done_s,     \* kernel walk: slot (lease) entry processed
    done_e,     \* kernel walk: mutex entry processed
    owner,      \* ghost: the thread which truly holds the mutex, or NONE
    corrupt     \* ghost: kernel cleanup modified a live thread's lock

vars == <<word, ecookie, pc, alive, cookie, lease, pending, pcookie, enq,
          waited, done_p, done_s, done_e, owner, corrupt>>

PCs == {"unattached", "idle", "acq", "sleeping", "acquired", "cookied",
        "enqueued", "own", "rel", "unlocked"}

TypeOK ==
    /\ word \in [own : Nat, od : BOOLEAN, wtr : BOOLEAN]
    /\ ecookie \in Nat
    /\ pc \in [Threads -> PCs]
    /\ alive \in [Threads -> BOOLEAN]
    /\ cookie \in [Threads -> Nat]
    /\ lease \in [Threads -> BOOLEAN]
    /\ pending \in [Threads -> BOOLEAN]
    /\ pcookie \in [Threads -> Nat]
    /\ enq \in [Threads -> BOOLEAN]
    /\ waited \in [Threads -> BOOLEAN]
    /\ done_p \in [Threads -> BOOLEAN]
    /\ done_s \in [Threads -> BOOLEAN]
    /\ done_e \in [Threads -> BOOLEAN]
    /\ owner \in Threads \cup {NONE}
    /\ corrupt \in BOOLEAN

Init ==
    /\ word = [own |-> 0, od |-> FALSE, wtr |-> FALSE]
    /\ ecookie = 0
    /\ pc = [t \in Threads |-> "unattached"]
    /\ alive = [t \in Threads |-> TRUE]
    /\ cookie = [t \in Threads |-> 0]
    /\ lease = [t \in Threads |-> FALSE]
    /\ pending = [t \in Threads |-> FALSE]
    /\ pcookie = [t \in Threads |-> 0]
    /\ enq = [t \in Threads |-> FALSE]
    /\ waited = [t \in Threads |-> FALSE]
    /\ done_p = [t \in Threads |-> FALSE]
    /\ done_s = [t \in Threads |-> FALSE]
    /\ done_e = [t \in Threads |-> FALSE]
    /\ owner = NONE
    /\ corrupt = FALSE

(***************************************************************************)
(* Cookie allocation                                                       *)
(***************************************************************************)

\* A cookie is free while no (live or dead-but-unwalked) slot entry
\* leases it. This is exactly what the registry slot / OFD lock provide.
Free(c) == \A u \in Threads : ~(cookie[u] = c /\ lease[u])

\* Attach: claim a cookie. With the allocator the claim is leased by the
\* thread's slot entry; with fixed identifiers (TIDs) there is no lease
\* and duplicates are possible by construction.
Attach(t) ==
    /\ alive[t] /\ pc[t] = "unattached"
    /\ IF UseAllocator
       THEN \E c \in Cookies :
                /\ Free(c)
                /\ cookie' = [cookie EXCEPT ![t] = c]
                /\ lease' = [lease EXCEPT ![t] = TRUE]
       ELSE /\ cookie' = [cookie EXCEPT ![t] = FixedId[t]]
            /\ lease' = [lease EXCEPT ![t] = FALSE]
    /\ pc' = [pc EXCEPT ![t] = "idle"]
    /\ UNCHANGED <<word, ecookie, alive, pending, pcookie, enq, waited,
                   done_p, done_s, done_e, owner, corrupt>>

(***************************************************************************)
(* Lock operation                                                          *)
(***************************************************************************)

\* Arm the pending op. In the final ABI the pending cookie is thread
\* private state in the list head. In the rejected ABI the contender
\* writes its cookie into the shared entry before the cmpxchg.
StartAcq(t) ==
    /\ alive[t] /\ pc[t] = "idle"
    /\ pending' = [pending EXCEPT ![t] = TRUE]
    /\ pcookie' = [pcookie EXCEPT ![t] = cookie[t]]
    /\ ecookie' = IF PendingViaHead THEN ecookie ELSE cookie[t]
    /\ waited' = [waited EXCEPT ![t] = FALSE]
    /\ pc' = [pc EXCEPT ![t] = "acq"]
    /\ UNCHANGED <<word, alive, cookie, lease, enq, done_p, done_s, done_e,
                   owner, corrupt>>

\* The cmpxchg: acquire a free (or dead) lock, preserving OWNER_DIED.
Acquire(t) ==
    /\ alive[t] /\ pc[t] = "acq"
    /\ word.own = 0
    /\ word' = [own |-> cookie[t], od |-> word.od,
                wtr |-> word.wtr \/ (WaitedBit /\ waited[t])]
    /\ owner' = t
    /\ pc' = [pc EXCEPT ![t] = "acquired"]
    /\ UNCHANGED <<ecookie, alive, cookie, lease, pending, pcookie, enq,
                   waited, done_p, done_s, done_e, corrupt>>

\* Contended: give up this attempt (waiting is modeled by retrying).
\* Contended: give up this attempt (the trylock path). A thread which
\* already slept never gives up: rfm_mutex_lock() loops until acquired,
\* and a woken waiter abandoning the lock would discard the wakeup it
\* consumed (its waited bit is what re-asserts WAITERS).
FailAcq(t) ==
    /\ alive[t] /\ pc[t] = "acq" /\ ~waited[t]
    /\ word.own # 0
    /\ pending' = [pending EXCEPT ![t] = FALSE]
    /\ pc' = [pc EXCEPT ![t] = "idle"]
    /\ UNCHANGED <<word, ecookie, alive, cookie, lease, pcookie, enq,
                   waited, done_p, done_s, done_e, owner, corrupt>>

\* Contended: set the WAITERS bit and go to sleep on the futex. The
\* pending op stays armed, mirroring rfm_lock_explicit()'s wait loop.
Sleep(t) ==
    /\ alive[t] /\ pc[t] = "acq"
    /\ word.own # 0
    /\ word' = [word EXCEPT !.wtr = TRUE]
    /\ waited' = [waited EXCEPT ![t] = TRUE]
    /\ pc' = [pc EXCEPT ![t] = "sleeping"]
    /\ UNCHANGED <<ecookie, alive, cookie, lease, pending, pcookie, enq,
                   done_p, done_s, done_e, owner, corrupt>>

\* One sleeping thread is woken (moved back to its retry loop)
Wake1(pcf) ==
    IF \E u \in Threads : alive[u] /\ pcf[u] = "sleeping"
    THEN {[pcf EXCEPT ![u] = "acq"] : u \in {u \in Threads : alive[u] /\ pcf[u] = "sleeping"}}
    ELSE {pcf}

\* The owner writes the entry cookie (final ABI: only after acquisition,
\* when it owns the entry exclusively).
WriteEntryCookie(t) ==
    /\ alive[t] /\ pc[t] = "acquired"
    /\ ecookie' = cookie[t]
    /\ pc' = [pc EXCEPT ![t] = "cookied"]
    /\ UNCHANGED <<word, alive, cookie, lease, pending, pcookie, enq,
                   waited, done_p, done_s, done_e, owner, corrupt>>

\* Queue the entry in the robust list. The pending op is still armed
\* until the separate disarm step: the entry can be on the list while
\* list_op_pending points at it (the kernel walk skips it there).
Enqueue(t) ==
    /\ alive[t] /\ pc[t] = "cookied"
    /\ enq' = [enq EXCEPT ![t] = TRUE]
    /\ pc' = [pc EXCEPT ![t] = "enqueued"]
    /\ UNCHANGED <<word, ecookie, alive, cookie, lease, pending, pcookie,
                   waited, done_p, done_s, done_e, owner, corrupt>>

DisarmAcq(t) ==
    /\ alive[t] /\ pc[t] = "enqueued"
    /\ pending' = [pending EXCEPT ![t] = FALSE]
    /\ pc' = [pc EXCEPT ![t] = "own"]
    /\ UNCHANGED <<word, ecookie, alive, cookie, lease, pcookie, enq,
                   waited, done_p, done_s, done_e, owner, corrupt>>

(***************************************************************************)
(* Unlock operation                                                        *)
(***************************************************************************)

\* Arm the pending op and dequeue the entry.
StartRel(t) ==
    /\ alive[t] /\ pc[t] = "own"
    /\ pending' = [pending EXCEPT ![t] = TRUE]
    /\ pcookie' = [pcookie EXCEPT ![t] = cookie[t]]
    /\ enq' = [enq EXCEPT ![t] = FALSE]
    /\ pc' = [pc EXCEPT ![t] = "rel"]
    /\ UNCHANGED <<word, ecookie, alive, cookie, lease, waited, done_p,
                   done_s, done_e, owner, corrupt>>

\* Release the lock word. Uncontended (no WAITERS): the VDSO fast path
\* cmpxchgs cookie -> 0 and nobody is woken. Contended: the kernel
\* FUTEX_ROBUST_UNLOCK path stores 0 - wiping the whole word including
\* the WAITERS bit - and wakes one waiter.
Release(t) ==
    /\ alive[t] /\ pc[t] = "rel"
    /\ word' = [own |-> 0, od |-> FALSE, wtr |-> FALSE]
    /\ owner' = NONE
    /\ IF word.wtr
       THEN pc' \in Wake1([pc EXCEPT ![t] = "unlocked"])
       ELSE pc' = [pc EXCEPT ![t] = "unlocked"]
    /\ UNCHANGED <<ecookie, alive, cookie, lease, pending, pcookie, enq,
                   waited, done_p, done_s, done_e, corrupt>>

\* Disarm the pending op after the unlock.
FinishRel(t) ==
    /\ alive[t] /\ pc[t] = "unlocked"
    /\ pending' = [pending EXCEPT ![t] = FALSE]
    /\ pc' = [pc EXCEPT ![t] = "idle"]
    /\ UNCHANGED <<word, ecookie, alive, cookie, lease, pcookie, enq,
                   waited, done_p, done_s, done_e, owner, corrupt>>

(***************************************************************************)
(* Death and kernel cleanup                                                *)
(*                                                                         *)
(* The walk is split into three separately scheduled steps. The two      *)
(* queued entries (slot, mutex entry) are processed in either order (the *)
(* fixed protocol must be safe regardless of list order); PendingFirst    *)
(* selects whether the pending op is processed before or after them.     *)
(***************************************************************************)

Die(t) ==
    /\ alive[t] /\ pc[t] # "unattached"
    /\ alive' = [alive EXCEPT ![t] = FALSE]
    \* Threads without an allocator lease have no slot entry to walk
    /\ done_s' = [done_s EXCEPT ![t] = ~lease[t]]
    /\ UNCHANGED <<word, ecookie, pc, cookie, lease, pending, pcookie, enq,
                   waited, done_p, done_e, owner, corrupt>>

\* The owner identifier the kernel uses for the dead thread's pending op.
PendingId(t) == IF PendingViaHead THEN pcookie[t] ELSE ecookie

QueuedAllowed(t) == ~PendingFirst \/ done_p[t]
PendingAllowed(t) == PendingFirst \/ (done_s[t] /\ done_e[t])

\* Process the slot entry: the kernel marks the (dead) thread's registry
\* slot FUTEX_OWNER_DIED / the OFD lock dies with the process - either
\* way the cookie lease is gone from this point on.
CleanupSlot(t) ==
    /\ ~alive[t] /\ ~done_s[t] /\ QueuedAllowed(t)
    /\ (LeaseLast => done_e[t])
    /\ done_s' = [done_s EXCEPT ![t] = TRUE]
    /\ lease' = [lease EXCEPT ![t] = FALSE]
    /\ UNCHANGED <<word, ecookie, pc, alive, cookie, pending, pcookie, enq,
                   waited, done_p, done_e, owner, corrupt>>

\* Process the mutex entry. The walk skips the entry when it equals
\* list_op_pending (it is attributed through the pending path then).
CleanupEntry(t) ==
    /\ ~alive[t] /\ ~done_e[t] /\ QueuedAllowed(t)
    /\ done_e' = [done_e EXCEPT ![t] = TRUE]
    /\ IF /\ enq[t] /\ ~pending[t]
          /\ word.own # 0 /\ word.own = ecookie
       THEN /\ word' = [own |-> 0, od |-> TRUE, wtr |-> word.wtr]
            \* Corruption means wiping a LIVE thread's lock. Wiping a
            \* dead thread's lock through a misattributed walk (a reused
            \* cookie matching the dead predecessor's stale word) is
            \* recovery, merely performed by the wrong dead thread.
            /\ corrupt' = (corrupt \/ (owner # NONE /\ owner # t /\ alive[owner]))
            /\ owner' = IF owner = NONE THEN NONE
                        ELSE IF owner = t \/ ~alive[owner] THEN NONE
                        ELSE owner
            /\ IF WakeOnCleanup /\ word.wtr
               THEN pc' \in Wake1(pc)
               ELSE pc' = pc
       ELSE UNCHANGED <<word, corrupt, owner, pc>>
    /\ UNCHANGED <<ecookie, alive, cookie, lease, pending, pcookie, enq,
                   waited, done_p, done_s>>

\* Process the pending op.
CleanupPending(t) ==
    /\ ~alive[t] /\ ~done_p[t] /\ PendingAllowed(t)
    /\ done_p' = [done_p EXCEPT ![t] = TRUE]
    /\ IF pending[t] /\ word.own # 0 /\ word.own = PendingId(t)
       THEN /\ word' = [own |-> 0, od |-> TRUE, wtr |-> word.wtr]
            \* Corruption means wiping a LIVE thread's lock. Wiping a
            \* dead thread's lock through a misattributed walk (a reused
            \* cookie matching the dead predecessor's stale word) is
            \* recovery, merely performed by the wrong dead thread.
            /\ corrupt' = (corrupt \/ (owner # NONE /\ owner # t /\ alive[owner]))
            /\ owner' = IF owner = NONE THEN NONE
                        ELSE IF owner = t \/ ~alive[owner] THEN NONE
                        ELSE owner
            /\ IF WakeOnCleanup /\ word.wtr
               THEN pc' \in Wake1(pc)
               ELSE pc' = pc
       ELSE IF pending[t]
       \* handle_futex_death()'s pending op wake cases, both without
       \* touching the futex value: a released word (the woken waiter
       \* died before taking over the lock; unconditional on the
       \* WAITERS bit - the word is free, no future unlock will carry
       \* the chain) and an owner mismatch (the woken waiter died
       \* after another owner re-acquired; that owner will unlock
       \* through the uncontended fast path, so the dying task's
       \* consumed wake up must be replayed - but only while WAITERS
       \* is not re-armed: an observed WAITERS bit is only ever
       \* cleared by an unlock which wakes, so the chain is already
       \* intact and no wake up was consumed).
       THEN /\ IF WakeOnCleanup /\ (word.own = 0 \/ ~word.wtr)
               THEN pc' \in Wake1(pc)
               ELSE pc' = pc
            /\ UNCHANGED <<word, corrupt, owner>>
       ELSE UNCHANGED <<word, corrupt, owner, pc>>
    /\ UNCHANGED <<ecookie, alive, cookie, lease, pending, pcookie, enq,
                   waited, done_s, done_e>>

\* Recycle the thread identifier as a fresh, unattached incarnation once
\* the whole walk finished. (Cookie reuse does NOT wait for this - it
\* only waits for CleanupSlot, which is the point of the model.)
Reincarnate(t) ==
    /\ ~alive[t] /\ done_p[t] /\ done_s[t] /\ done_e[t]
    /\ alive' = [alive EXCEPT ![t] = TRUE]
    /\ pc' = [pc EXCEPT ![t] = "unattached"]
    /\ cookie' = [cookie EXCEPT ![t] = 0]
    /\ pending' = [pending EXCEPT ![t] = FALSE]
    /\ pcookie' = [pcookie EXCEPT ![t] = 0]
    /\ enq' = [enq EXCEPT ![t] = FALSE]
    /\ waited' = [waited EXCEPT ![t] = FALSE]
    /\ done_p' = [done_p EXCEPT ![t] = FALSE]
    /\ done_s' = [done_s EXCEPT ![t] = FALSE]
    /\ done_e' = [done_e EXCEPT ![t] = FALSE]
    /\ owner' = IF owner = t THEN NONE ELSE owner
    /\ UNCHANGED <<word, ecookie, lease, corrupt>>

Cleanup(t) == CleanupSlot(t) \/ CleanupEntry(t) \/ CleanupPending(t)

Next ==
    \E t \in Threads :
        \/ Attach(t)
        \/ StartAcq(t) \/ Acquire(t) \/ FailAcq(t) \/ Sleep(t)
        \/ WriteEntryCookie(t) \/ Enqueue(t) \/ DisarmAcq(t)
        \/ StartRel(t) \/ Release(t) \/ FinishRel(t)
        \/ Die(t) \/ Cleanup(t) \/ Reincarnate(t)

\* The steps a live thread is assumed to eventually take (weak
\* fairness): only the COMPLETION of an operation already in flight.
\* Starting new work (Attach, StartAcq, Reincarnate) is never forced -
\* an application may simply stop using the lock, and several wake
\* related defects only manifest when nobody contends again. Die and
\* FailAcq are never forced either. A woken waiter however is forced
\* onward - acquire or back to sleep: rfm_wait_free()'s loop re-asserts
\* the WAITERS bit and re-enters futex_wait() whenever it observes an
\* owned lock; it cannot park itself without doing so.
ThreadStep(t) ==
    \/ Acquire(t) \/ WriteEntryCookie(t)
    \/ Enqueue(t) \/ DisarmAcq(t)
    \/ StartRel(t) \/ Release(t) \/ FinishRel(t)
    \/ (waited[t] /\ Sleep(t))

Spec == Init /\ [][Next]_vars
        /\ \A t \in Threads : WF_vars(Cleanup(t)) /\ WF_vars(ThreadStep(t))

(***************************************************************************)
(* Properties                                                              *)
(***************************************************************************)

\* The kernel never modifies a lock which a live thread holds.
NoCorruption == ~corrupt

\* Mutual exclusion: the ghost owner is unique by construction; every
\* thread which believes it holds the lock is the ghost owner and the
\* word carries its identifier.
Holding(t) == alive[t] /\ pc[t] \in {"acquired", "cookied", "enqueued",
                                     "own", "rel"}

Exclusion ==
    \A t \in Threads : Holding(t) => owner = t /\ word.own = cookie[t]

\* Robustness: a lock whose owner died is eventually recoverable.
Recovery ==
    \A t \in Threads :
        (owner = t /\ ~alive[t]) ~> (word.own = 0)

\* Waiter level recovery. futex wakes are deliberately modeled as
\* FUTEX_WAKE(1) with an adversarial choice of the woken waiter, so
\* per-waiter starvation freedom does NOT hold - futexes (and pthread
\* mutexes) make no wake fairness promise, and TLC readily produces the
\* starvation lasso if asked. The property robust futex users depend on
\* is that wakeups are never LOST: as long as live sleeping waiters
\* exist, wake events must keep occurring. This is what the kernel wake
\* in the exit cleanup (WakeOnCleanup) and the WAITERS re-assertion of
\* woken acquirers (WaitedBit) are for.
WakeEvent == \E u \in Threads : alive[u] /\ pc[u] = "sleeping" /\ pc'[u] = "acq"

NoLostWakeup ==
    \A t \in Threads :
        (<>[](alive[t] /\ pc[t] = "sleeping") /\ []<>(word.own = 0))
            => ([]<><<WakeEvent>>_vars)

=============================================================================
