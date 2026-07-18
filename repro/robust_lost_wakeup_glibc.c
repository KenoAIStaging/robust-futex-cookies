// SPDX-License-Identifier: MIT
/*
 * glibc reproduction of the robust futex lost wakeup (see
 * robust_lost_wakeup.c for the full writeup): the same race as
 * robust_lost_wakeup_race.c, but using nothing except stock
 * pthread_mutex_t with PTHREAD_MUTEX_ROBUST + PTHREAD_PROCESS_SHARED.
 *
 *   - Two waiter processes loop pthread_mutex_lock() / unlock() on a
 *     robust process shared mutex in a MAP_SHARED page. While blocked,
 *     glibc has their list_op_pending armed and FUTEX_WAITERS set.
 *
 *   - The parent, holding the mutex with both waiters blocked, calls
 *     pthread_mutex_unlock() (glibc's robust unlock: store 0 over the
 *     whole futex word - wiping FUTEX_WAITERS - then FUTEX_WAKE(1)),
 *     immediately re-locks through the uncontended fast path and
 *     SIGKILLs one waiter - with 50% probability the one the wakeup
 *     went to, before glibc's lock loop in that process ever runs
 *     again to re-arm FUTEX_WAITERS.
 *
 *   - The parent unlocks again: the futex word carries no
 *     FUTEX_WAITERS, so glibc takes the uncontended path and wakes
 *     nobody. On an unfixed kernel the surviving waiter now sleeps
 *     forever inside pthread_mutex_lock() on a free mutex.
 *
 * Strand detection uses only the pthread API plus /proc: the survivor
 * sits in state 'S' with a frozen progress counter for a full grace
 * period while pthread_mutex_trylock() in the parent succeeds - the
 * mutex is demonstrably free and demonstrably being slept on.
 *
 * Exit status: 1 lost wakeup reproduced (unfixed kernel),
 *              0 not reproduced within the round/time budget,
 *              2 setup error.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#define NWAITERS	2
#define MAX_ROUNDS	2000
#define BUDGET_SEC	20
#define GRACE_MS	2000	/* survivor frozen this long => stranded */

struct shared {
	pthread_mutex_t		mutex;
	_Atomic(uint64_t)	count[NWAITERS];
};

static struct shared *sh;

static void die(const char *what)
{
	perror(what);
	exit(2);
}

static void die_ret(const char *what, int err)
{
	fprintf(stderr, "%s: %s\n", what, strerror(err));
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

/* Plain pthread lock/unlock loop; EOWNERDEAD handled like any robust user. */
static int waiter(int idx)
{
	int ret;

	for (;;) {
		ret = pthread_mutex_lock(&sh->mutex);
		if (ret == EOWNERDEAD)
			pthread_mutex_consistent(&sh->mutex);
		else if (ret)
			die_ret("pthread_mutex_lock", ret);
		atomic_fetch_add(&sh->count[idx], 1);
		ret = pthread_mutex_unlock(&sh->mutex);
		if (ret)
			die_ret("pthread_mutex_unlock", ret);
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

static void lock_owner(void)
{
	int ret = pthread_mutex_lock(&sh->mutex);

	if (ret == EOWNERDEAD)
		pthread_mutex_consistent(&sh->mutex);
	else if (ret)
		die_ret("owner lock", ret);
}

int main(void)
{
	pthread_mutexattr_t attr;
	pid_t pids[NWAITERS];
	unsigned int seed = 12345;
	uint64_t deadline, freeze[NWAITERS];
	int round, ret, kills = 0;

	sh = mmap(NULL, sizeof(*sh), PROT_READ | PROT_WRITE,
		  MAP_SHARED | MAP_ANONYMOUS, -1, 0);
	if (sh == MAP_FAILED)
		die("mmap");

	if ((ret = pthread_mutexattr_init(&attr)) ||
	    (ret = pthread_mutexattr_setpshared(&attr, PTHREAD_PROCESS_SHARED)) ||
	    (ret = pthread_mutexattr_setrobust(&attr, PTHREAD_MUTEX_ROBUST)) ||
	    (ret = pthread_mutex_init(&sh->mutex, &attr)))
		die_ret("mutex setup", ret);

	/* round starting state: parent holds the mutex */
	lock_owner();

	for (int i = 0; i < NWAITERS; i++)
		pids[i] = spawn_waiter(i);

	deadline = now_ms() + BUDGET_SEC * 1000;
	for (round = 1; round <= MAX_ROUNDS && now_ms() < deadline; round++) {
		uint64_t t0;
		int victim, survivor, status;

		/* wait until both waiters are blocked in pthread_mutex_lock */
		for (int i = 0; i < NWAITERS; i++)
			freeze[i] = atomic_load(&sh->count[i]);
		for (;;) {
			if (proc_state(pids[0]) == 'S' &&
			    proc_state(pids[1]) == 'S' &&
			    atomic_load(&sh->count[0]) == freeze[0] &&
			    atomic_load(&sh->count[1]) == freeze[1])
				break;
			for (int i = 0; i < NWAITERS; i++)
				freeze[i] = atomic_load(&sh->count[i]);
			if (now_ms() >= deadline)
				goto out_budget;
		}

		/* robust unlock: store 0 (wiping FUTEX_WAITERS), wake one */
		if ((ret = pthread_mutex_unlock(&sh->mutex)))
			die_ret("unlock", ret);

		/* uncontended fast path re-acquire; a waiter may win: void round */
		ret = pthread_mutex_trylock(&sh->mutex);
		if (ret == EBUSY) {
			lock_owner();	/* take it back once the waiter drops it */
			continue;
		}
		if (ret == EOWNERDEAD)
			pthread_mutex_consistent(&sh->mutex);
		else if (ret)
			die_ret("trylock", ret);

		/* the woken waiter (if picked) has not re-armed yet: kill one */
		victim = rand_r(&seed) % NWAITERS;
		survivor = 1 - victim;
		kill(pids[victim], SIGKILL);
		if (waitpid(pids[victim], &status, 0) != pids[victim])
			die("waitpid victim");
		kills++;

		/* glibc unlock: no FUTEX_WAITERS in the word means no wake */
		if ((ret = pthread_mutex_unlock(&sh->mutex)))
			die_ret("unlock2", ret);

		/*
		 * Stranded? The survivor stays asleep with a frozen counter
		 * although trylock proves the mutex free the whole time.
		 */
		uint64_t c0 = atomic_load(&sh->count[survivor]);

		t0 = now_ms();
		while (now_ms() - t0 < GRACE_MS) {
			if (atomic_load(&sh->count[survivor]) != c0 ||
			    proc_state(pids[survivor]) != 'S')
				break;
		}
		if (now_ms() - t0 >= GRACE_MS) {
			ret = pthread_mutex_trylock(&sh->mutex);
			if (ret == 0) {
				printf("REPRODUCED: lost wakeup in round %d (%d kills):\n"
				       "  pid %d has been sleeping inside pthread_mutex_lock() on a\n"
				       "  FREE robust mutex (trylock succeeds) for %d ms with no wakeup\n"
				       "  coming - it would sleep forever. Stock glibc robust process\n"
				       "  shared mutexes lose the wakeup consumed by a killed waiter\n"
				       "  on this kernel.\n",
				       round, kills, pids[survivor], GRACE_MS);
				kill(pids[survivor], SIGKILL);
				waitpid(pids[survivor], &status, 0);
				return 1;
			}
			if (ret == EOWNERDEAD)
				pthread_mutex_consistent(&sh->mutex);
			else if (ret == EBUSY)
				lock_owner();	/* survivor woke at the last moment */
			else
				die_ret("trylock2", ret);
		} else {
			/* survivor made progress - take the lock back */
			lock_owner();
		}
		/* round starting state again: parent holds the mutex */

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
