--------------------------- MODULE ExplicitCookie ---------------------------
(***************************************************************************)
(* Robust futex with explicit owner cookies (ROBUST_LIST_COOKIE), as used *)
(* by the rfmutex "explicit" implementation with registry or OFD cookie   *)
(* allocation.                                                            *)
(*                                                                         *)
(* The model contains one mutex, a set of threads which acquire/release   *)
(* it and may die at any point, and the kernel exit time cleanup which    *)
(* walks the dead thread's robust list state (queued entry and pending    *)
(* op) and marks the lock word FUTEX_OWNER_DIED when the owner identifier *)
(* matches.                                                               *)
(*                                                                         *)
(* Switches:                                                               *)
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
(*   Id: the owner identifier per thread. Unique values model correctly   *)
(*     allocated cookies. Duplicate values model the classic TID based    *)
(*     protocol with a TID collision across PID namespaces; TLC then      *)
(*     finds the original kernel bug this series fixes.                   *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS
    Threads,            \* set of thread identifiers
    Id,                 \* [Threads -> Nat \ {0}]: owner identifier (cookie/TID)
    PendingViaHead      \* BOOLEAN: final ABI vs rejected entry-cookie ABI

NONE == "none"

VARIABLES
    word,       \* the futex word: [own : Nat, od : BOOLEAN]
    ecookie,    \* the entry cookie slot embedded in the mutex
    pc,         \* thread program counters
    alive,      \* thread liveness
    pending,    \* robust_list_head::list_op_pending armed (per thread)
    pcookie,    \* robust_list_head2::list_op_pending_cookie (per thread)
    enq,        \* entry queued in the thread's robust list (per thread)
    cleaned,    \* kernel cleanup for a dead thread has run
    owner,      \* ghost: the thread which truly holds the mutex, or NONE
    corrupt     \* ghost: kernel cleanup modified a live thread's lock

vars == <<word, ecookie, pc, alive, pending, pcookie, enq, cleaned, owner, corrupt>>

TypeOK ==
    /\ word \in [own : Nat, od : BOOLEAN]
    /\ ecookie \in Nat
    /\ pc \in [Threads -> {"idle", "acq", "acquired", "cookied", "own",
                           "rel", "unlocked"}]
    /\ alive \in [Threads -> BOOLEAN]
    /\ pending \in [Threads -> BOOLEAN]
    /\ pcookie \in [Threads -> Nat]
    /\ enq \in [Threads -> BOOLEAN]
    /\ cleaned \in [Threads -> BOOLEAN]
    /\ owner \in Threads \cup {NONE}
    /\ corrupt \in BOOLEAN

Init ==
    /\ word = [own |-> 0, od |-> FALSE]
    /\ ecookie = 0
    /\ pc = [t \in Threads |-> "idle"]
    /\ alive = [t \in Threads |-> TRUE]
    /\ pending = [t \in Threads |-> FALSE]
    /\ pcookie = [t \in Threads |-> 0]
    /\ enq = [t \in Threads |-> FALSE]
    /\ cleaned = [t \in Threads |-> FALSE]
    /\ owner = NONE
    /\ corrupt = FALSE

(***************************************************************************)
(* Lock operation                                                          *)
(***************************************************************************)

\* Arm the pending op. In the final ABI the pending cookie is thread
\* private state in the list head. In the rejected ABI the contender
\* writes its cookie into the shared entry before the cmpxchg.
StartAcq(t) ==
    /\ alive[t] /\ pc[t] = "idle"
    /\ pending' = [pending EXCEPT ![t] = TRUE]
    /\ pcookie' = [pcookie EXCEPT ![t] = Id[t]]
    /\ ecookie' = IF PendingViaHead THEN ecookie ELSE Id[t]
    /\ pc' = [pc EXCEPT ![t] = "acq"]
    /\ UNCHANGED <<word, alive, enq, cleaned, owner, corrupt>>

\* The cmpxchg: acquire a free (or dead) lock, preserving OWNER_DIED.
Acquire(t) ==
    /\ alive[t] /\ pc[t] = "acq"
    /\ word.own = 0
    /\ word' = [own |-> Id[t], od |-> word.od]
    /\ owner' = t
    /\ pc' = [pc EXCEPT ![t] = "acquired"]
    /\ UNCHANGED <<ecookie, alive, pending, pcookie, enq, cleaned, corrupt>>

\* Contended: give up this attempt (waiting is modeled by retrying).
FailAcq(t) ==
    /\ alive[t] /\ pc[t] = "acq"
    /\ word.own # 0
    /\ pending' = [pending EXCEPT ![t] = FALSE]
    /\ pc' = [pc EXCEPT ![t] = "idle"]
    /\ UNCHANGED <<word, ecookie, alive, pcookie, enq, cleaned, owner, corrupt>>

\* The owner writes the entry cookie (final ABI: only after acquisition,
\* when it owns the entry exclusively).
WriteEntryCookie(t) ==
    /\ alive[t] /\ pc[t] = "acquired"
    /\ ecookie' = Id[t]
    /\ pc' = [pc EXCEPT ![t] = "cookied"]
    /\ UNCHANGED <<word, alive, pending, pcookie, enq, cleaned, owner, corrupt>>

\* Queue the entry in the robust list and disarm the pending op.
Enqueue(t) ==
    /\ alive[t] /\ pc[t] = "cookied"
    /\ enq' = [enq EXCEPT ![t] = TRUE]
    /\ pending' = [pending EXCEPT ![t] = FALSE]
    /\ pc' = [pc EXCEPT ![t] = "own"]
    /\ UNCHANGED <<word, ecookie, alive, pcookie, cleaned, owner, corrupt>>

(***************************************************************************)
(* Unlock operation                                                        *)
(***************************************************************************)

\* Arm the pending op and dequeue the entry.
StartRel(t) ==
    /\ alive[t] /\ pc[t] = "own"
    /\ pending' = [pending EXCEPT ![t] = TRUE]
    /\ pcookie' = [pcookie EXCEPT ![t] = Id[t]]
    /\ enq' = [enq EXCEPT ![t] = FALSE]
    /\ pc' = [pc EXCEPT ![t] = "rel"]
    /\ UNCHANGED <<word, ecookie, alive, cleaned, owner, corrupt>>

\* Store 0 to the lock word (the kernel robust unlock stores the whole
\* word; the VDSO fast path cmpxchgs cookie -> 0: both end at 0).
Release(t) ==
    /\ alive[t] /\ pc[t] = "rel"
    /\ word' = [own |-> 0, od |-> FALSE]
    /\ owner' = NONE
    /\ pc' = [pc EXCEPT ![t] = "unlocked"]
    /\ UNCHANGED <<ecookie, alive, pending, pcookie, enq, cleaned, corrupt>>

\* Disarm the pending op after the unlock.
FinishRel(t) ==
    /\ alive[t] /\ pc[t] = "unlocked"
    /\ pending' = [pending EXCEPT ![t] = FALSE]
    /\ pc' = [pc EXCEPT ![t] = "idle"]
    /\ UNCHANGED <<word, ecookie, alive, pcookie, enq, cleaned, owner, corrupt>>

(***************************************************************************)
(* Death and kernel cleanup                                                *)
(***************************************************************************)

Die(t) ==
    /\ alive[t]
    /\ alive' = [alive EXCEPT ![t] = FALSE]
    /\ UNCHANGED <<word, ecookie, pc, pending, pcookie, enq, cleaned, owner,
                   corrupt>>

\* The owner identifier the kernel uses for the dead thread's pending op.
PendingId(t) == IF PendingViaHead THEN pcookie[t] ELSE ecookie

\* Kernel exit cleanup. The robust list walk skips a queued entry which
\* equals list_op_pending, so with a single mutex exactly one attribution
\* applies: the pending op if armed, the queued entry otherwise.
\*
\* A cleanup which modifies a lock word owned by a live thread is the
\* corruption this whole exercise is about.
KernelCleanup(t) ==
    /\ ~alive[t] /\ ~cleaned[t]
    /\ cleaned' = [cleaned EXCEPT ![t] = TRUE]
    /\ LET match == IF pending[t]
                    THEN word.own # 0 /\ word.own = PendingId(t)
                    ELSE enq[t] /\ word.own # 0 /\ word.own = ecookie
       IN IF match
          THEN /\ word' = [own |-> 0, od |-> TRUE]
               /\ corrupt' = corrupt \/ (owner # NONE /\ owner # t)
               /\ owner' = IF owner = t THEN NONE ELSE owner
          ELSE UNCHANGED <<word, corrupt, owner>>
    /\ UNCHANGED <<ecookie, pc, alive, pending, pcookie, enq>>

\* Rebirth with the same cookie: models the allocator handing the cookie
\* of a fully cleaned up dead thread to a new thread (registry slot
\* reclaim, OFD lock release). Only possible after the kernel cleanup.
Reincarnate(t) ==
    /\ ~alive[t] /\ cleaned[t]
    /\ alive' = [alive EXCEPT ![t] = TRUE]
    /\ cleaned' = [cleaned EXCEPT ![t] = FALSE]
    /\ pc' = [pc EXCEPT ![t] = "idle"]
    /\ pending' = [pending EXCEPT ![t] = FALSE]
    /\ enq' = [enq EXCEPT ![t] = FALSE]
    /\ owner' = IF owner = t THEN NONE ELSE owner
    /\ UNCHANGED <<word, ecookie, pcookie, corrupt>>

Next ==
    \E t \in Threads :
        \/ StartAcq(t) \/ Acquire(t) \/ FailAcq(t) \/ WriteEntryCookie(t)
        \/ Enqueue(t) \/ StartRel(t) \/ Release(t) \/ FinishRel(t)
        \/ Die(t) \/ KernelCleanup(t) \/ Reincarnate(t)

Spec == Init /\ [][Next]_vars /\ \A t \in Threads : WF_vars(KernelCleanup(t))

(***************************************************************************)
(* Properties                                                              *)
(***************************************************************************)

\* The kernel never modifies a lock which a live thread holds.
NoCorruption == ~corrupt

\* Mutual exclusion: the ghost owner is unique by construction; every
\* thread which believes it holds the lock is the ghost owner and the
\* word carries its identifier.
Holding(t) == alive[t] /\ pc[t] \in {"acquired", "cookied", "own", "rel"}

Exclusion ==
    \A t \in Threads : Holding(t) => owner = t /\ word.own = Id[t]

\* Robustness: a lock whose owner died is eventually recoverable.
Recovery ==
    \A t \in Threads :
        (owner = t /\ ~alive[t]) ~> (word.own = 0)

=============================================================================
