// SPDX-License-Identifier: MIT
/*
 * Racing reproducer for the robust futex lost wakeup (see
 * robust_lost_wakeup.c for the deterministic variant and the full
 * writeup). This program races the real protocol steps instead of
 * constructing the post-race state:
 *
 *   - Two waiter processes run an honest miniature robust mutex loop
 *     (arm list_op_pending, acquire or re-arm FUTEX_WAITERS and
 *     FUTEX_WAIT, glibc-style "assume other waiters" preservation
 *     after having waited, honest unlock with wake).
 *
 *   - The parent, holding the lock with both waiters asleep, performs
 *     a robust unlock (store 0 + FUTEX_WAKE(1)), immediately
 *     re-acquires through the uncontended fast path and SIGKILLs one
 *     of the waiters - with 50% probability the one which the wake
 *     went to, before it ever gets scheduled again.
 *
 *   - The parent then unlocks honestly: no FUTEX_WAITERS in the value
 *     means no wake. On an unfixed kernel the surviving waiter is now
 *     stranded: asleep on a free futex with nobody left to wake it.
 *
 * Detection is conservative: a round only counts as a reproduction if
 * the survivor sits in state 'S' with a frozen progress counter while
 * the futex word stays free for a full grace period. On a fixed
 * kernel the dying waiter's exit walk replays the consumed wakeup and
 * no round can strand the survivor.
 *
 * Exit status: 1 lost wakeup reproduced (unfixed kernel),
 *              0 not reproduced within the round/time budget,
 *              2 setup error.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <linux/futex.h>
#include <sched.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/syscall.h>
#include <sys/time.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#define NWAITERS	2
#define MAX_ROUNDS	2000
#define BUDGET_SEC	20
#define GRACE_MS	2000	/* survivor frozen this long => stranded */

struct shared {
	_Atomic(uint32_t)	word;
	_Atomic(uint64_t)	count[NWAITERS];
};

static struct shared *sh;

static int sys_futex(_Atomic(uint32_t) *uaddr, int op, uint32_t val,
		     const struct timespec *timeout)
{
	return syscall(SYS_futex, uaddr, op, val, timeout, NULL, 0);
}

static void die(const char *what)
{
	perror(what);
	exit(2);
}

static uint64_t now_ms(void)
{
	struct timespec ts;

	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (uint64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

static char proc_state(pid_t pid)
{
	char path[64], buf[128], *state;
	FILE *f;

	snprintf(path, sizeof(path), "/proc/%d/stat", pid);
	f = fopen(path, "r");
	if (!f)
		return '?';
	state = fgets(buf, sizeof(buf), f) ? strrchr(buf, ')') : NULL;
	fclose(f);
	return (state && state[1] == ' ') ? state[2] : '?';
}

/*
 * Honest miniature robust mutex participant. The only concession to
 * the test is that the loop never terminates - the parent kills it.
 */
static int waiter(int idx)
{
	static struct robust_list_head head;
	uint32_t tid = gettid(), assume, v, zero;

	head.list.next = &head.list;
	head.futex_offset = 0;
	head.list_op_pending = NULL;
	if (syscall(SYS_set_robust_list, &head, sizeof(head)))
		die("set_robust_list");

	for (;;) {
		/* arm the pending op for the whole lock operation */
		head.list_op_pending = (struct robust_list *)&sh->word;
		assume = 0;
		for (;;) {
			zero = 0;
			if (atomic_compare_exchange_strong(&sh->word, &zero,
							   tid | assume))
				break;
			v = zero;	/* current value */
			if (!(v & FUTEX_WAITERS)) {
				if (!atomic_compare_exchange_strong(&sh->word,
							&v, v | FUTEX_WAITERS))
					continue;
				v |= FUTEX_WAITERS;
			}
			sys_futex(&sh->word, FUTEX_WAIT, v, NULL);
			/* glibc's assume_other_futex_waiters: the robust
			 * unlock wiped the bit, re-assert it on acquisition */
			assume = FUTEX_WAITERS;
		}
		head.list_op_pending = NULL;

		atomic_fetch_add(&sh->count[idx], 1);

		v = atomic_exchange(&sh->word, 0);
		if (v & FUTEX_WAITERS)
			sys_futex(&sh->word, FUTEX_WAKE, 1, NULL);
	}
	return 0;	/* unreachable */
}

static pid_t spawn_waiter(int idx)
{
	pid_t pid = fork();

	if (pid < 0)
		die("fork");
	if (!pid)
		exit(waiter(idx));
	return pid;
}

int main(void)
{
	pid_t self = getpid(), pids[NWAITERS];
	unsigned int seed = 12345;
	uint64_t deadline;
	int round, kills = 0;

	sh = mmap(NULL, sizeof(*sh), PROT_READ | PROT_WRITE,
		  MAP_SHARED | MAP_ANONYMOUS, -1, 0);
	if (sh == MAP_FAILED)
		die("mmap");

	/* round starting state: parent holds the lock */
	atomic_store(&sh->word, self);

	for (int i = 0; i < NWAITERS; i++)
		pids[i] = spawn_waiter(i);

	deadline = now_ms() + BUDGET_SEC * 1000;
	for (round = 1; round <= MAX_ROUNDS && now_ms() < deadline; round++) {
		uint32_t expect;
		uint64_t t0;
		int victim, survivor, status;

		/* wait until both waiters queued: word contended, both 'S' */
		for (;;) {
			if (atomic_load(&sh->word) == ((uint32_t)self | FUTEX_WAITERS) &&
			    proc_state(pids[0]) == 'S' &&
			    proc_state(pids[1]) == 'S')
				break;
			if (now_ms() >= deadline)
				goto out_budget;
		}

		/* A: robust unlock - store 0, wake one */
		atomic_store(&sh->word, 0);
		sys_futex(&sh->word, FUTEX_WAKE, 1, NULL);

		/* D: uncontended fast path re-acquire */
		expect = 0;
		if (!atomic_compare_exchange_strong(&sh->word, &expect, self)) {
			/* a waiter won the race to the word - void round;
			 * wait for it to release and take the lock back */
			for (;;) {
				expect = 0;
				if (atomic_compare_exchange_strong(&sh->word,
								   &expect, self))
					break;
				sched_yield();
			}
			continue;
		}

		/* the woken waiter (if it was B) has not run yet: kill one */
		victim = rand_r(&seed) % NWAITERS;
		survivor = 1 - victim;
		kill(pids[victim], SIGKILL);
		if (waitpid(pids[victim], &status, 0) != pids[victim])
			die("waitpid victim");
		kills++;

		/* D: honest unlock - no FUTEX_WAITERS means no wake */
		expect = atomic_exchange(&sh->word, 0);
		if (expect & FUTEX_WAITERS)
			sys_futex(&sh->word, FUTEX_WAKE, 1, NULL);

		/* stranded? survivor asleep + free word + frozen counter */
		uint64_t c0 = atomic_load(&sh->count[survivor]);

		t0 = now_ms();
		while (now_ms() - t0 < GRACE_MS) {
			if (atomic_load(&sh->count[survivor]) != c0 ||
			    atomic_load(&sh->word) != 0 ||
			    proc_state(pids[survivor]) != 'S')
				break;
		}
		if (now_ms() - t0 >= GRACE_MS) {
			printf("REPRODUCED: lost wakeup in round %d (%d kills): waiter\n"
			       "  pid %d asleep on a free futex for %d ms with no wakeup\n"
			       "  coming - it would sleep forever. This kernel discards the\n"
			       "  wakeup consumed by a killed robust waiter.\n",
			       round, kills, pids[survivor], GRACE_MS);
			sys_futex(&sh->word, FUTEX_WAKE, INT32_MAX, NULL);
			kill(pids[survivor], SIGKILL);
			waitpid(pids[survivor], &status, 0);
			return 1;
		}

		/* not stranded: reset to round starting state and respawn */
		for (;;) {
			expect = 0;
			if (atomic_compare_exchange_strong(&sh->word, &expect,
							   self))
				break;
			sched_yield();
		}
		pids[victim] = spawn_waiter(victim);
	}

out_budget:
	printf("not reproduced in %d rounds (%d kills): the kernel replays the\n"
	       "consumed wakeup (or the race was never hit - unexpected on a\n"
	       "multicore host).\n", round - 1, kills);
	for (int i = 0; i < NWAITERS; i++) {
		kill(pids[i], SIGKILL);
		waitpid(pids[i], NULL, 0);
	}
	return 0;
}
