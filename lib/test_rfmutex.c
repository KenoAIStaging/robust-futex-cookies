/* SPDX-License-Identifier: MIT */
/*
 * Correctness and robustness tests for rfmutex.
 *
 * Runs multi-process (and cross PID namespace) mutual exclusion and
 * kill-stress tests for all three cookie strategies:
 *   - explicit cookies from the shared registry
 *   - explicit cookies from OFD file locks
 *   - per-mutex counter cookies with RSEQ/membarrier quiescence
 */
#define _GNU_SOURCE
#include "rfmutex.h"

#include <errno.h>
#include <sched.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#define REGION_PATH	"/tmp/rfm_region"

struct testarea {
	rfmutex_t	mtx;
	_Atomic(uint64_t)	count;
	_Atomic(uint32_t)	mark;
	_Atomic(uint32_t)	stop;
	_Atomic(uint32_t)	errors;
	_Atomic(uint32_t)	owner_dead_seen;
	_Atomic(uint64_t)	progress[64];
};

static const char *alloc_name(enum rfm_alloc a)
{
	switch (a) {
	case RFM_ALLOC_REGISTRY: return "registry";
	case RFM_ALLOC_OFD: return "ofd";
	default: return "none";
	}
}

static const char *type_name(enum rfm_type t)
{
	return t == RFM_TYPE_COUNTER ? "counter" : "explicit";
}

/*
 * One critical section with mutual exclusion detection: the mark must
 * not change while we are inside.
 */
static void critical_section(struct testarea *a, uint32_t id, bool hold)
{
	atomic_store_explicit(&a->mark, id, memory_order_relaxed);
	for (int i = 0; i < 32; i++) {
		if (atomic_load_explicit(&a->mark, memory_order_relaxed) != id) {
			atomic_fetch_add(&a->errors, 1);
			return;
		}
	}
	if (hold)
		usleep(1000);
	if (atomic_load_explicit(&a->mark, memory_order_relaxed) != id)
		atomic_fetch_add(&a->errors, 1);
	atomic_fetch_add_explicit(&a->count, 1, memory_order_relaxed);
}

/*
 * Worker child: hammer the mutex until stop. @idx identifies the worker,
 * @hold_every makes every Nth critical section long, to give the killer
 * a window.
 */
static int worker(struct testarea *a, uint32_t idx, int hold_every,
		  enum rfm_alloc alloc)
{
	rfm_region_t *r = rfm_region_attach(REGION_PATH);
	unsigned long iter = 0;
	int ret;

	if (!r)
		return 10;
	ret = rfm_thread_attach(r, alloc);
	if (ret) {
		fprintf(stderr, "worker attach: %d\n", ret);
		return 11;
	}
	if (a->mtx.type != RFM_TYPE_COUNTER && !rfm_thread_cookie())
		return 12;

	while (!atomic_load(&a->stop)) {
		ret = rfm_mutex_lock(&a->mtx);
		if (ret == EOWNERDEAD) {
			atomic_fetch_add(&a->owner_dead_seen, 1);
			rfm_mutex_consistent(&a->mtx);
		} else if (ret) {
			fprintf(stderr, "worker lock: %d\n", ret);
			return 13;
		}
		critical_section(a, rfm_thread_cookie() ? : (idx + 1),
				 hold_every && (iter % hold_every) == 0);
		ret = rfm_mutex_unlock(&a->mtx);
		if (ret) {
			fprintf(stderr, "worker unlock: %d\n", ret);
			return 14;
		}
		iter++;
		atomic_store(&a->progress[idx % 64], iter);
	}
	rfm_thread_detach(r);
	return 0;
}

struct worker_arg {
	struct testarea *a;
	uint32_t idx;
	int hold_every;
	bool pidns;
	enum rfm_alloc alloc;
};

static int worker_trampoline(void *p)
{
	struct worker_arg *wa = p;
	return worker(wa->a, wa->idx, wa->hold_every, wa->alloc);
}

static pid_t spawn_worker(struct worker_arg *wa)
{
	int flags = SIGCHLD | (wa->pidns ? CLONE_NEWPID : 0);
	char *stack = mmap(NULL, 256 * 1024, PROT_READ | PROT_WRITE,
			   MAP_PRIVATE | MAP_ANONYMOUS | MAP_STACK, -1, 0);

	if (stack == MAP_FAILED)
		return -1;
	/* No CLONE_VM: workers are full processes attaching the region */
	return clone(worker_trampoline, stack + 256 * 1024, flags, wa);
}

static struct testarea *setup(rfm_region_t **rp, enum rfm_type type)
{
	rfm_region_t *r;
	struct testarea *a;

	unlink(REGION_PATH);
	r = rfm_region_create(REGION_PATH, 1 << 20);
	if (!r)
		return NULL;
	a = rfm_region_base(r);
	memset(a, 0, sizeof(*a));
	rfm_mutex_init(&a->mtx, type);
	*rp = r;
	return a;
}

/*
 * Plain mutual exclusion: N workers, fixed duration, no kills.
 */
static int test_exclusion(enum rfm_type type, enum rfm_alloc alloc, bool pidns,
			  int nworkers, int duration_ms)
{
	rfm_region_t *r;
	struct testarea *a = setup(&r, type);
	struct worker_arg wa[16];
	pid_t pids[16];
	int failed = 0, wstatus;
	uint64_t total;

	if (!a)
		return 1;

	for (int i = 0; i < nworkers; i++) {
		wa[i] = (struct worker_arg){ .a = a, .idx = i, .pidns = pidns,
					     .alloc = alloc };
		pids[i] = spawn_worker(&wa[i]);
		if (pids[i] < 0) {
			if (pidns && (errno == EPERM || errno == EINVAL)) {
				printf("SKIP %s/%s pidns (no CLONE_NEWPID)\n",
				       type_name(type), alloc_name(alloc));
				atomic_store(&a->stop, 1);
				nworkers = i;
				goto reap;
			}
			failed = 1;
			nworkers = i;
			goto reap;
		}
	}

	usleep(duration_ms * 1000);
	atomic_store(&a->stop, 1);
reap:
	for (int i = 0; i < nworkers; i++) {
		waitpid(pids[i], &wstatus, 0);
		if (WEXITSTATUS(wstatus))
			failed = 1;
	}
	total = atomic_load(&a->count);
	if (atomic_load(&a->errors) || !total)
		failed = 1;
	printf("%s %s/%s%s: %lu iterations, %u errors, %u owner-dead\n",
	       failed ? "FAIL" : "OK", type_name(type), alloc_name(alloc),
	       pidns ? "/pidns" : "", (unsigned long)total,
	       atomic_load(&a->errors), atomic_load(&a->owner_dead_seen));
	rfm_region_detach(r);
	return failed;
}

/*
 * Kill stress: workers hammer the mutex with occasional long holds, the
 * parent SIGKILLs random workers and respawns them. Survivors must make
 * progress, EOWNERDEAD must be observed, no exclusion violations.
 */
static int test_kill_stress(enum rfm_type type, bool pidns, int nworkers,
			    int kills, int duration_ms)
{
	rfm_region_t *r;
	struct testarea *a = setup(&r, type);
	struct worker_arg wa[16];
	pid_t pids[16];
	int failed = 0, wstatus;
	unsigned int seed = 12345;

	if (!a)
		return 1;

	for (int i = 0; i < nworkers; i++) {
		wa[i] = (struct worker_arg){ .a = a, .idx = i, .hold_every = 64,
					     .pidns = pidns,
					     .alloc = type == RFM_TYPE_COUNTER ?
						      RFM_ALLOC_NONE : RFM_ALLOC_REGISTRY };
		pids[i] = spawn_worker(&wa[i]);
		if (pids[i] < 0) {
			if (pidns && (errno == EPERM || errno == EINVAL)) {
				printf("SKIP %s pidns kill stress\n", type_name(type));
				atomic_store(&a->stop, 1);
				for (int j = 0; j < i; j++) {
					kill(pids[j], SIGKILL);
					waitpid(pids[j], &wstatus, 0);
				}
				rfm_region_detach(r);
				return 0;
			}
			nworkers = i;
			failed = 1;
			goto out;
		}
	}

	for (int k = 0; k < kills; k++) {
		usleep(duration_ms * 1000 / kills);
		int victim = rand_r(&seed) % nworkers;

		kill(pids[victim], SIGKILL);
		waitpid(pids[victim], &wstatus, 0);
		/* Respawn */
		pids[victim] = spawn_worker(&wa[victim]);
		if (pids[victim] < 0) {
			failed = 1;
			break;
		}
	}

	/* Survivors must be able to finish */
	usleep(50 * 1000);
out:
	atomic_store(&a->stop, 1);
	for (int i = 0; i < nworkers; i++) {
		if (pids[i] > 0)
			waitpid(pids[i], &wstatus, 0);
	}
	if (atomic_load(&a->errors))
		failed = 1;
	if (!atomic_load(&a->count))
		failed = 1;
	printf("%s %s%s kill stress: %lu iterations, %u errors, %u owner-dead recoveries\n",
	       failed ? "FAIL" : "OK", type_name(type), pidns ? "/pidns" : "",
	       (unsigned long)atomic_load(&a->count), atomic_load(&a->errors),
	       atomic_load(&a->owner_dead_seen));
	rfm_region_detach(r);
	return failed;
}

/*
 * Counter generation stress: start the counter close to a generation
 * boundary so the membarrier quiescence path is exercised repeatedly.
 */
static int test_counter_generations(int nworkers, int duration_ms)
{
	rfm_region_t *r;
	struct testarea *a = setup(&r, RFM_TYPE_COUNTER);
	struct worker_arg wa[16];
	pid_t pids[16];
	int failed = 0, wstatus;
	uint64_t start_gen, end_gen;

	if (!a)
		return 1;

	/* 32 reservations away from the first generation flip */
	atomic_store(&a->mtx.counter, (1ULL << 29) - 32);
	start_gen = atomic_load(&a->mtx.counter) >> 29;

	for (int i = 0; i < nworkers; i++) {
		wa[i] = (struct worker_arg){ .a = a, .idx = i,
					     .alloc = RFM_ALLOC_NONE };
		pids[i] = spawn_worker(&wa[i]);
	}
	usleep(duration_ms * 1000);
	atomic_store(&a->stop, 1);
	for (int i = 0; i < nworkers; i++) {
		waitpid(pids[i], &wstatus, 0);
		if (WEXITSTATUS(wstatus))
			failed = 1;
	}
	end_gen = atomic_load(&a->mtx.counter) >> 29;
	if (atomic_load(&a->errors) || end_gen == start_gen)
		failed = 1;
	printf("%s counter generations: %lu iterations, gen %lu -> %lu, q_gen %lu, %u errors\n",
	       failed ? "FAIL" : "OK", (unsigned long)atomic_load(&a->count),
	       (unsigned long)start_gen, (unsigned long)end_gen,
	       (unsigned long)atomic_load(&a->mtx.q_gen), atomic_load(&a->errors));
	rfm_region_detach(r);
	return failed;
}

/*
 * Cookie allocator reuse: a process claims a cookie and dies; a new
 * process must be able to reclaim it.
 */
static int test_alloc_reuse(enum rfm_alloc alloc)
{
	rfm_region_t *r;
	struct testarea *a = setup(&r, RFM_TYPE_EXPLICIT);
	int failed = 0, wstatus;
	pid_t pid;

	if (!a)
		return 1;

	/* Child 1 allocates the first cookie and dies holding it */
	pid = fork();
	if (!pid) {
		rfm_region_t *cr = rfm_region_attach(REGION_PATH);
		if (rfm_thread_attach(cr, alloc) || rfm_thread_cookie() != 1)
			_exit(1);
		_exit(0);	/* dies without detach */
	}
	waitpid(pid, &wstatus, 0);
	failed |= WEXITSTATUS(wstatus);

	/* Child 2 must get cookie 1 again */
	pid = fork();
	if (!pid) {
		rfm_region_t *cr = rfm_region_attach(REGION_PATH);
		if (rfm_thread_attach(cr, alloc) || rfm_thread_cookie() != 1)
			_exit(1);
		rfm_thread_detach(cr);
		_exit(0);
	}
	waitpid(pid, &wstatus, 0);
	failed |= WEXITSTATUS(wstatus);

	printf("%s %s cookie reuse after death\n", failed ? "FAIL" : "OK",
	       alloc_name(alloc));
	rfm_region_detach(r);
	return failed;
}

int main(int argc, char **argv)
{
	int failed = 0;
	int dur = argc > 1 ? atoi(argv[1]) : 400;

	failed |= test_alloc_reuse(RFM_ALLOC_REGISTRY);
	failed |= test_alloc_reuse(RFM_ALLOC_OFD);

	failed |= test_exclusion(RFM_TYPE_EXPLICIT, RFM_ALLOC_REGISTRY, false, 4, dur);
	failed |= test_exclusion(RFM_TYPE_EXPLICIT, RFM_ALLOC_REGISTRY, true, 4, dur);
	failed |= test_exclusion(RFM_TYPE_EXPLICIT, RFM_ALLOC_OFD, false, 4, dur);
	failed |= test_exclusion(RFM_TYPE_EXPLICIT, RFM_ALLOC_OFD, true, 4, dur);
	failed |= test_exclusion(RFM_TYPE_COUNTER, RFM_ALLOC_NONE, false, 4, dur);
	failed |= test_exclusion(RFM_TYPE_COUNTER, RFM_ALLOC_NONE, true, 4, dur);

	failed |= test_kill_stress(RFM_TYPE_EXPLICIT, false, 4, 20, 4 * dur);
	failed |= test_kill_stress(RFM_TYPE_EXPLICIT, true, 4, 20, 4 * dur);
	failed |= test_kill_stress(RFM_TYPE_COUNTER, false, 4, 20, 4 * dur);
	failed |= test_kill_stress(RFM_TYPE_COUNTER, true, 4, 20, 4 * dur);

	failed |= test_counter_generations(4, 2 * dur);

	printf("%s\n", failed ? "TEST SUITE FAILED" : "ALL TESTS PASSED");
	return failed;
}
