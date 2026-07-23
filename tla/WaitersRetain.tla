\* SPDX-License-Identifier: MIT
--------------------------- MODULE WaitersRetain ---------------------------
(***************************************************************************)
(* The mainline FUTEX_ROBUST_UNLOCK protocol (no cookies, one namespace)  *)
(* with the proposed "retain FUTEX_WAITERS" kernel unlock semantics: the  *)
(* kernel robust unlock releases the futex word to FUTEX_WAITERS instead  *)
(* of 0 when waiters remain queued after the wake, so that the wakeup     *)
(* chain lives in the futex word instead of in the woken (killable)       *)
(* waiter.                                                                 *)
(*                                                                         *)
(* Atomicity map - each action is exactly one of:                          *)
(*                                                                         *)
(*   (i) a single 32-bit atomic on the futex word in user space            *)
(*       (TryAcquire, SetWtr, VdsoTry) - naturally one action;             *)
(*                                                                         *)
(*   (ii) one hb->lock critical section - sound to model as one atomic     *)
(*       action because the queue is touched exclusively under hb->lock    *)
(*       and the sections serialize against each other:                    *)
(*         FutexWait   = futex_wait_setup(): futex_q_lock(),               *)
(*                       futex_get_value_locked() revalidation against    *)
(*                       the user supplied val, futex_queue()             *)
(*                       (-EWOULDBLOCK path modeled as the EAGAIN         *)
(*                       branch);                                          *)
(*         RelSyscall  = futex_robust_unlock_wake(): count queued          *)
(*                       waiters, release store, collect wakeups, all     *)
(*                       inside one spin_lock(&hb->lock) section (the     *)
(*                       pagefault retry re-runs the whole section        *)
(*                       without observable intermediate state, so it     *)
(*                       needs no extra step);                             *)
(*         WalkEntryWake / WalkPendingWake / RelWake                       *)
(*                     = futex_wake(..., 1): one locked wake walk;         *)
(*                                                                         *)
(*   (iii) a lockless kernel access in handle_futex_death(), modeled as    *)
(*       its own step so its raciness against (i) and (ii) is explored:    *)
(*         WalkEntryRead/WalkPendingRead = the get_user() snapshot;        *)
(*         WalkEntryChk/WalkPendingChk   = branch decisions on that        *)
(*                       snapshot; the OWNER_DIED store is the cmpxchg     *)
(*                       whose success requires the word to still equal    *)
(*                       the snapshot, with failure looping back to the    *)
(*                       re-read (the kernel's nval != uval retry).        *)
(*       The wake that follows a successful cmpxchg (or the owner-zero     *)
(*       pending branch) is a separate futex_wake() call and therefore a   *)
(*       separate action.                                                  *)
(*                                                                         *)
(* Userspace snapshots (expw) model the value argument userspace passes    *)
(* to futex_wait() being read before the syscall.                          *)
(*                                                                         *)
(* Threads loop forever: idle -> lock -> hold -> unlock -> idle, may die  *)
(* at any point outside idle, are cleaned up by the kernel exit walk       *)
(* (mainline exit_robust_list(): list entries then the pending op;         *)
(* handle_futex_death() owner match sets OWNER_DIED preserving WAITERS     *)
(* and wakes one waiter; a pending op on an ownerless word wakes one       *)
(* waiter; NO foreign-owner replay), and reincarnate afterwards.           *)
(*                                                                         *)
(* Switches:                                                               *)
(*                                                                         *)
(*   RetainWaiters = TRUE stores FUTEX_WAITERS on kernel robust unlock    *)
(*     when waiters remain queued; FALSE stores 0 unconditionally (the    *)
(*     current mainline semantics). With FALSE, TLC finds the lost        *)
(*     wakeup: the woken waiter is killed before re-acquiring, a third    *)
(*     thread re-acquires through the uncontended fast path and its later *)
(*     unlock takes the vDSO fast path, stranding the remaining sleeper.  *)
(*                                                                         *)
(*   SyncStore = TRUE performs remaining-waiter count, release store and  *)
(*     wake in one atomic action (all under the hash bucket lock, as the  *)
(*     patched kernel does). FALSE splits count / store / wake into       *)
(*     separate steps, modeling a release store not serialized with       *)
(*     futex_wait() enqueueing (e.g. the store performed before taking    *)
(*     the hash bucket lock, as the pre-patch futex_robust_unlock()       *)
(*     does). TLC then finds a waiter which enqueues - legitimately, its  *)
(*     revalidation still matches - between the count and the store, is   *)
(*     not accounted for, and is stranded the same way.                   *)
(*                                                                         *)
(*   ExitWakeOwnerZero = TRUE is handle_futex_death()'s existing wake     *)
(*     for a pending op on a word whose owner part is 0 (commit           *)
(*     ca16d5bee598 as generalized by the FUTEX_ROBUST_UNLOCK series).    *)
(*     The retained-WAITERS protocol depends on it: it is what replays    *)
(*     the wakeup when the woken waiter dies while the word is released   *)
(*     (owner part 0, WAITERS possibly still set). FALSE lets TLC          *)
(*     demonstrate that dependency.                                        *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS
    Threads,            \* set of thread identifiers (naturals, TID values)
    RetainWaiters,      \* BOOLEAN: retain WAITERS on kernel robust unlock
    SyncStore,          \* BOOLEAN: count+store+wake atomic under hb lock
    ExitWakeOwnerZero   \* BOOLEAN: pending-op wake on owner part == 0

VARIABLES
    word,       \* futex word: [own : Nat, od : BOOLEAN, wtr : BOOLEAN]
    q,          \* kernel hash bucket queue: FIFO sequence of threads
    pc,         \* thread program counters
    alive,      \* thread liveness
    pending,    \* robust_list_head::list_op_pending armed (per thread)
    enq,        \* mutex entry queued in the thread's robust list
    assume_w,   \* glibc assume_other_futex_waiters: re-assert WAITERS
    waited,     \* the thread slept at least once in this lock attempt
    expw,       \* futex_wait() expected value (userspace word snapshot)
    srem,       \* SyncStore=FALSE only: unlock's counted "waiters remain"
    wpc,        \* kernel exit walk program counter (per thread)
    wsnap       \* exit walk get_user() snapshot of the futex word

vars == <<word, q, pc, alive, pending, enq, assume_w, waited, expw, srem,
          wpc, wsnap>>

PCs == {"idle", "acq", "waitpre", "sleeping", "acquired", "enqueued", "own",
        "rel", "relslow", "relscan", "relstore", "relwake", "unlocked"}

WPCs == {"run", "e_read", "e_chk", "e_wake", "p_read", "p_chk", "p_wake",
         "done"}

Word == [own : Threads \cup {0}, od : BOOLEAN, wtr : BOOLEAN]

ZeroWord == [own |-> 0, od |-> FALSE, wtr |-> FALSE]

Range(s) == {s[i] : i \in DOMAIN s}

TypeOK ==
    /\ word \in Word
    /\ q \in Seq(Threads)
    /\ pc \in [Threads -> PCs]
    /\ alive \in [Threads -> BOOLEAN]
    /\ pending \in [Threads -> BOOLEAN]
    /\ enq \in [Threads -> BOOLEAN]
    /\ assume_w \in [Threads -> BOOLEAN]
    /\ waited \in [Threads -> BOOLEAN]
    /\ expw \in [Threads -> Word]
    /\ srem \in [Threads -> BOOLEAN]
    /\ wpc \in [Threads -> WPCs]
    /\ wsnap \in [Threads -> Word]

Init ==
    /\ word = ZeroWord
    /\ q = <<>>
    /\ pc = [t \in Threads |-> "idle"]
    /\ alive = [t \in Threads |-> TRUE]
    /\ pending = [t \in Threads |-> FALSE]
    /\ enq = [t \in Threads |-> FALSE]
    /\ assume_w = [t \in Threads |-> FALSE]
    /\ waited = [t \in Threads |-> FALSE]
    /\ expw = [t \in Threads |-> ZeroWord]
    /\ srem = [t \in Threads |-> FALSE]
    /\ wpc = [t \in Threads |-> "run"]
    /\ wsnap = [t \in Threads |-> ZeroWord]

(***************************************************************************)
(* Lock operation                                                          *)
(***************************************************************************)

\* Arm the pending op before touching the lock word.
StartAcq(t) ==
    /\ alive[t] /\ pc[t] = "idle"
    /\ pending' = [pending EXCEPT ![t] = TRUE]
    /\ assume_w' = [assume_w EXCEPT ![t] = FALSE]
    /\ waited' = [waited EXCEPT ![t] = FALSE]
    /\ pc' = [pc EXCEPT ![t] = "acq"]
    /\ UNCHANGED <<word, q, alive, enq, expw, srem, wpc, wsnap>>

\* The acquisition cmpxchg (userspace, atomicity class (i)): take a word
\* whose owner part is 0 - free, free-but-contended (own 0, WAITERS set:
\* the retained state) or dead owner (OWNER_DIED). WAITERS is preserved;
\* assume_other_futex_waiters re-asserts it after this thread (may have)
\* shared the bit.
TryAcquire(t) ==
    /\ alive[t] /\ pc[t] = "acq"
    /\ word.own = 0
    /\ word' = [own |-> t, od |-> FALSE,
                wtr |-> word.wtr \/ assume_w[t]]
    /\ pc' = [pc EXCEPT ![t] = "acquired"]
    /\ UNCHANGED <<q, alive, pending, enq, assume_w, waited, expw, srem,
                   wpc, wsnap>>

\* Contended trylock style give-up. A thread which already slept never
\* gives up: it would discard the wakeup it consumed.
FailAcq(t) ==
    /\ alive[t] /\ pc[t] = "acq" /\ ~waited[t]
    /\ word.own # 0
    /\ pending' = [pending EXCEPT ![t] = FALSE]
    /\ pc' = [pc EXCEPT ![t] = "idle"]
    /\ UNCHANGED <<word, q, alive, enq, assume_w, waited, expw, srem,
                   wpc, wsnap>>

\* Contended: set the WAITERS bit (userspace cmpxchg, class (i)) and
\* snapshot the resulting value as the futex_wait() val argument.
SetWtr(t) ==
    /\ alive[t] /\ pc[t] = "acq"
    /\ word.own # 0 /\ ~word.wtr
    /\ word' = [word EXCEPT !.wtr = TRUE]
    /\ expw' = [expw EXCEPT ![t] = [word EXCEPT !.wtr = TRUE]]
    /\ assume_w' = [assume_w EXCEPT ![t] = TRUE]
    /\ pc' = [pc EXCEPT ![t] = "waitpre"]
    /\ UNCHANGED <<q, alive, pending, enq, waited, srem, wpc, wsnap>>

\* Contended, WAITERS already set: snapshot the word for futex_wait().
SnapWait(t) ==
    /\ alive[t] /\ pc[t] = "acq"
    /\ word.own # 0 /\ word.wtr
    /\ expw' = [expw EXCEPT ![t] = word]
    /\ assume_w' = [assume_w EXCEPT ![t] = TRUE]
    /\ pc' = [pc EXCEPT ![t] = "waitpre"]
    /\ UNCHANGED <<word, q, alive, pending, enq, waited, srem, wpc, wsnap>>

\* futex_wait() = futex_wait_setup(), atomicity class (ii): one hb->lock
\* section which revalidates the word against the val argument via
\* futex_get_value_locked() and either enqueues (futex_queue()) or
\* returns -EWOULDBLOCK. This under-lock revalidation is the
\* synchronization the release store relies on.
FutexWait(t) ==
    /\ alive[t] /\ pc[t] = "waitpre"
    /\ IF word = expw[t]
       THEN /\ q' = Append(q, t)
            /\ waited' = [waited EXCEPT ![t] = TRUE]
            /\ pc' = [pc EXCEPT ![t] = "sleeping"]
       ELSE /\ q' = q
            /\ waited' = waited
            /\ pc' = [pc EXCEPT ![t] = "acq"]
    /\ UNCHANGED <<word, alive, pending, enq, assume_w, expw, srem, wpc,
                   wsnap>>

\* Queue the entry in the robust list, then disarm the pending op.
Enqueue(t) ==
    /\ alive[t] /\ pc[t] = "acquired"
    /\ enq' = [enq EXCEPT ![t] = TRUE]
    /\ pc' = [pc EXCEPT ![t] = "enqueued"]
    /\ UNCHANGED <<word, q, alive, pending, assume_w, waited, expw, srem,
                   wpc, wsnap>>

DisarmAcq(t) ==
    /\ alive[t] /\ pc[t] = "enqueued"
    /\ pending' = [pending EXCEPT ![t] = FALSE]
    /\ pc' = [pc EXCEPT ![t] = "own"]
    /\ UNCHANGED <<word, q, alive, enq, assume_w, waited, expw, srem,
                   wpc, wsnap>>

(***************************************************************************)
(* Unlock operation                                                        *)
(***************************************************************************)

\* Arm the pending op and dequeue the entry from the robust list.
StartRel(t) ==
    /\ alive[t] /\ pc[t] = "own"
    /\ pending' = [pending EXCEPT ![t] = TRUE]
    /\ enq' = [enq EXCEPT ![t] = FALSE]
    /\ pc' = [pc EXCEPT ![t] = "rel"]
    /\ UNCHANGED <<word, q, alive, assume_w, waited, expw, srem, wpc,
                   wsnap>>

\* The vDSO try_unlock (userspace cmpxchg, class (i)): expects exactly
\* the own TID - no WAITERS, no OWNER_DIED. On failure fall back to the
\* syscall.
VdsoTry(t) ==
    /\ alive[t] /\ pc[t] = "rel"
    /\ IF word = [own |-> t, od |-> FALSE, wtr |-> FALSE]
       THEN /\ word' = ZeroWord
            /\ pc' = [pc EXCEPT ![t] = "unlocked"]
       ELSE /\ word' = word
            /\ pc' = [pc EXCEPT
                        ![t] = IF SyncStore THEN "relslow" ELSE "relscan"]
    /\ UNCHANGED <<q, alive, pending, enq, assume_w, waited, expw, srem,
                   wpc, wsnap>>

\* The kernel robust unlock, synchronized variant (class (ii)): wake one
\* waiter, count the remaining ones and perform the release store in a
\* single hash bucket lock critical section, as
\* futex_robust_unlock_wake() does. The pagefault retry in the
\* implementation re-runs the whole section (nothing modified before the
\* store succeeds), so it needs no separate step.
RelSyscall(t) ==
    /\ SyncStore
    /\ alive[t] /\ pc[t] = "relslow"
    /\ IF q = <<>>
       THEN /\ word' = ZeroWord
            /\ q' = q
            /\ pc' = [pc EXCEPT ![t] = "unlocked"]
       ELSE /\ q' = Tail(q)
            /\ word' = [own |-> 0, od |-> FALSE,
                        wtr |-> RetainWaiters /\ Tail(q) # <<>>]
            /\ pc' = [pc EXCEPT ![t] = "unlocked", ![Head(q)] = "acq"]
    /\ UNCHANGED <<alive, pending, enq, assume_w, waited, expw, srem,
                   wpc, wsnap>>

\* The kernel robust unlock, unsynchronized variant: the remaining
\* waiter count, the release store and the wake are separate steps, so
\* a waiter whose revalidation still matches the pre-release word can
\* enqueue between the count and the store.
RelScan(t) ==
    /\ ~SyncStore
    /\ alive[t] /\ pc[t] = "relscan"
    /\ srem' = [srem EXCEPT ![t] = Len(q) > 1]
    /\ pc' = [pc EXCEPT ![t] = "relstore"]
    /\ UNCHANGED <<word, q, alive, pending, enq, assume_w, waited, expw,
                   wpc, wsnap>>

RelStore(t) ==
    /\ ~SyncStore
    /\ alive[t] /\ pc[t] = "relstore"
    /\ word' = [own |-> 0, od |-> FALSE, wtr |-> RetainWaiters /\ srem[t]]
    /\ pc' = [pc EXCEPT ![t] = "relwake"]
    /\ UNCHANGED <<q, alive, pending, enq, assume_w, waited, expw, srem,
                   wpc, wsnap>>

RelWake(t) ==
    /\ ~SyncStore
    /\ alive[t] /\ pc[t] = "relwake"
    /\ IF q = <<>>
       THEN /\ q' = q
            /\ pc' = [pc EXCEPT ![t] = "unlocked"]
       ELSE /\ q' = Tail(q)
            /\ pc' = [pc EXCEPT ![t] = "unlocked", ![Head(q)] = "acq"]
    /\ UNCHANGED <<word, alive, pending, enq, assume_w, waited, expw, srem,
                   wpc, wsnap>>

\* Disarm the pending op after the release store.
FinishRel(t) ==
    /\ alive[t] /\ pc[t] = "unlocked"
    /\ pending' = [pending EXCEPT ![t] = FALSE]
    /\ pc' = [pc EXCEPT ![t] = "idle"]
    /\ UNCHANGED <<word, q, alive, enq, assume_w, waited, expw, srem,
                   wpc, wsnap>>

(***************************************************************************)
(* Death and kernel exit walk                                              *)
(*                                                                         *)
(* exit_robust_list() processes the queued list entries first, then the   *)
(* pending op. handle_futex_death() itself is lockless: get_user()        *)
(* snapshot, branch decisions on the snapshot, an OWNER_DIED cmpxchg      *)
(* which retries from the re-read when the word changed underneath        *)
(* (nval != uval), and a subsequent futex_wake() which is its own hash    *)
(* bucket lock section. Each of these is a separate action here.          *)
(***************************************************************************)

\* Death at any point outside idle. A sleeping task is removed from the
\* hash bucket queue when the fatal signal takes it out of futex_wait().
\* The split unlock (SyncStore = FALSE) is still a single syscall which
\* a fatal signal cannot interrupt midway - the split only relaxes the
\* ordering of the store against the queue - so death is not allowed at
\* its internal steps.
Die(t) ==
    /\ alive[t]
    /\ pc[t] \notin {"idle", "relscan", "relstore", "relwake"}
    /\ alive' = [alive EXCEPT ![t] = FALSE]
    /\ q' = SelectSeq(q, LAMBDA e : e # t)
    /\ wpc' = [wpc EXCEPT ![t] = "e_read"]
    /\ UNCHANGED <<word, pc, pending, enq, assume_w, waited, expw, srem,
                   wsnap>>

\* List entry step, get_user() snapshot. The walk skips an entry which
\* equals list_op_pending and a thread whose robust list is empty.
WalkEntryRead(t) ==
    /\ ~alive[t] /\ wpc[t] = "e_read"
    /\ IF enq[t] /\ ~pending[t]
       THEN /\ wsnap' = [wsnap EXCEPT ![t] = word]
            /\ wpc' = [wpc EXCEPT ![t] = "e_chk"]
       ELSE /\ wsnap' = wsnap
            /\ wpc' = [wpc EXCEPT ![t] = "p_read"]
    /\ UNCHANGED <<word, q, pc, alive, pending, enq, assume_w, waited,
                   expw, srem>>

\* List entry step, branch + OWNER_DIED cmpxchg (pending_op == false:
\* no owner-zero wake). A snapshot owner mismatch is a one-shot
\* decision; the cmpxchg retries through the re-read when the word
\* changed. The wake decision uses the snapshot's WAITERS bit, as the
\* kernel keys the wake on uval.
WalkEntryChk(t) ==
    /\ ~alive[t] /\ wpc[t] = "e_chk"
    /\ IF wsnap[t].own # t
       THEN /\ word' = word
            /\ wpc' = [wpc EXCEPT ![t] = "p_read"]
       ELSE IF word = wsnap[t]
       THEN /\ word' = [own |-> 0, od |-> TRUE, wtr |-> wsnap[t].wtr]
            /\ wpc' = [wpc EXCEPT
                         ![t] = IF wsnap[t].wtr THEN "e_wake" ELSE "p_read"]
       ELSE /\ word' = word
            /\ wpc' = [wpc EXCEPT ![t] = "e_read"]
    /\ wsnap' = [wsnap EXCEPT ![t] = ZeroWord]
    /\ UNCHANGED <<q, pc, alive, pending, enq, assume_w, waited, expw,
                   srem>>

\* The futex_wake(1) after a successful OWNER_DIED store (class (ii)).
WalkEntryWake(t) ==
    /\ ~alive[t] /\ wpc[t] = "e_wake"
    /\ IF q = <<>>
       THEN /\ q' = q
            /\ pc' = pc
       ELSE /\ q' = Tail(q)
            /\ pc' = [pc EXCEPT ![Head(q)] = "acq"]
    /\ wpc' = [wpc EXCEPT ![t] = "p_read"]
    /\ UNCHANGED <<word, alive, pending, enq, assume_w, waited, expw, srem,
                   wsnap>>

\* Pending op step, get_user() snapshot.
WalkPendingRead(t) ==
    /\ ~alive[t] /\ wpc[t] = "p_read"
    /\ IF pending[t]
       THEN /\ wsnap' = [wsnap EXCEPT ![t] = word]
            /\ wpc' = [wpc EXCEPT ![t] = "p_chk"]
       ELSE /\ wsnap' = wsnap
            /\ wpc' = [wpc EXCEPT ![t] = "done"]
    /\ UNCHANGED <<word, q, pc, alive, pending, enq, assume_w, waited,
                   expw, srem>>

\* Pending op step, branch + cmpxchg (pending_op == true): an ownerless
\* snapshot (owner part 0 - released, WAITERS and OWNER_DIED
\* irrelevant) gets the wakeup replayed without touching the word; an
\* owner match sets OWNER_DIED preserving WAITERS and wakes; a foreign
\* owner is left alone (one-shot, no replay).
WalkPendingChk(t) ==
    /\ ~alive[t] /\ wpc[t] = "p_chk"
    /\ IF wsnap[t].own = 0
       THEN /\ word' = word
            /\ wpc' = [wpc EXCEPT
                         ![t] = IF ExitWakeOwnerZero THEN "p_wake"
                                ELSE "done"]
       ELSE IF wsnap[t].own = t
       THEN IF word = wsnap[t]
            THEN /\ word' = [own |-> 0, od |-> TRUE, wtr |-> wsnap[t].wtr]
                 /\ wpc' = [wpc EXCEPT
                              ![t] = IF wsnap[t].wtr THEN "p_wake"
                                     ELSE "done"]
            ELSE /\ word' = word
                 /\ wpc' = [wpc EXCEPT ![t] = "p_read"]
       ELSE /\ word' = word
            /\ wpc' = [wpc EXCEPT ![t] = "done"]
    /\ wsnap' = [wsnap EXCEPT ![t] = ZeroWord]
    /\ UNCHANGED <<q, pc, alive, pending, enq, assume_w, waited, expw,
                   srem>>

\* The futex_wake(1) of the pending op handling (class (ii)).
WalkPendingWake(t) ==
    /\ ~alive[t] /\ wpc[t] = "p_wake"
    /\ IF q = <<>>
       THEN /\ q' = q
            /\ pc' = pc
       ELSE /\ q' = Tail(q)
            /\ pc' = [pc EXCEPT ![Head(q)] = "acq"]
    /\ wpc' = [wpc EXCEPT ![t] = "done"]
    /\ UNCHANGED <<word, alive, pending, enq, assume_w, waited, expw, srem,
                   wsnap>>

\* Recycle the thread as a fresh incarnation once the walk finished.
Reincarnate(t) ==
    /\ ~alive[t] /\ wpc[t] = "done"
    /\ alive' = [alive EXCEPT ![t] = TRUE]
    /\ pc' = [pc EXCEPT ![t] = "idle"]
    /\ pending' = [pending EXCEPT ![t] = FALSE]
    /\ enq' = [enq EXCEPT ![t] = FALSE]
    /\ assume_w' = [assume_w EXCEPT ![t] = FALSE]
    /\ waited' = [waited EXCEPT ![t] = FALSE]
    /\ expw' = [expw EXCEPT ![t] = ZeroWord]
    /\ srem' = [srem EXCEPT ![t] = FALSE]
    /\ wpc' = [wpc EXCEPT ![t] = "run"]
    /\ wsnap' = [wsnap EXCEPT ![t] = ZeroWord]
    /\ UNCHANGED <<word, q>>

Cleanup(t) ==
    \/ WalkEntryRead(t) \/ WalkEntryChk(t) \/ WalkEntryWake(t)
    \/ WalkPendingRead(t) \/ WalkPendingChk(t) \/ WalkPendingWake(t)

Next ==
    \E t \in Threads :
        \/ StartAcq(t) \/ TryAcquire(t) \/ FailAcq(t)
        \/ SetWtr(t) \/ SnapWait(t) \/ FutexWait(t)
        \/ Enqueue(t) \/ DisarmAcq(t)
        \/ StartRel(t) \/ VdsoTry(t)
        \/ RelSyscall(t) \/ RelScan(t) \/ RelStore(t) \/ RelWake(t)
        \/ FinishRel(t)
        \/ Die(t) \/ Cleanup(t) \/ Reincarnate(t)

\* Weak fairness on the completion of operations already in flight;
\* starting new work (StartAcq, Reincarnate), giving up (FailAcq) and
\* dying are never forced.
ThreadStep(t) ==
    \/ TryAcquire(t) \/ SetWtr(t) \/ SnapWait(t) \/ FutexWait(t)
    \/ Enqueue(t) \/ DisarmAcq(t)
    \/ StartRel(t) \/ VdsoTry(t)
    \/ RelSyscall(t) \/ RelScan(t) \/ RelStore(t) \/ RelWake(t)
    \/ FinishRel(t)

Spec == Init /\ [][Next]_vars
        /\ \A t \in Threads : WF_vars(Cleanup(t)) /\ WF_vars(ThreadStep(t))

(***************************************************************************)
(* Properties                                                              *)
(***************************************************************************)

\* Queue sanity: no duplicates, exactly the live sleepers.
QOK ==
    /\ \A i, j \in DOMAIN q : i # j => q[i] # q[j]
    /\ \A t \in Threads :
           (t \in Range(q)) <=> (alive[t] /\ pc[t] = "sleeping")

\* Mutual exclusion. A thread holds the lock from its acquisition
\* cmpxchg until its release store.
Holding(t) == alive[t] /\ pc[t] \in {"acquired", "enqueued", "own", "rel",
                                     "relslow", "relscan", "relstore"}

Exclusion ==
    \A t \in Threads :
        Holding(t) => (word.own = t
                       /\ \A u \in Threads \ {t} : ~Holding(u))

\* The heart of the retained-WAITERS protocol: while any waiter is
\* queued, the futex word carries the WAITERS bit, so no release ever
\* takes (and no acquirer ever re-creates) a fast path which would skip
\* the wake. Only meaningful with SyncStore (with the split unlock the
\* store legitimately precedes the dequeue of the woken waiter).
WtrInv == q # <<>> => word.wtr

\* Every sleeping waiter is eventually woken (or dies). Wake fairness
\* (which waiter) is FIFO by the queue; this asserts no waiter is
\* stranded, the property violated by the lost-wakeup bug.
WaiterServed ==
    \A t \in Threads :
        (alive[t] /\ pc[t] = "sleeping")
            ~> (~alive[t] \/ pc[t] # "sleeping")

=============================================================================
