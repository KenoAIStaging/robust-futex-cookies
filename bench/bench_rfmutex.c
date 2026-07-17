/* SPDX-License-Identifier: MIT */
/*
 * Benchmarks: rfmutex (explicit-registry, explicit-OFD, counter) vs
 * pthread_mutex_t (default private, and robust process-shared).
 *
 * Scenarios:
 *   - uncontended: single thread lock/unlock latency
 *   - contended:   N worker processes hammering one mutex (throughput)
 */
#define _GNU_SOURCE
#include "../lib/rfmutex.h"

#include <errno.h>
#include <pthread.h>
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

/*
 * Per-run region path: isolated by PID so concurrent runs never
 * interfere and no fixed global name is ever unlinked. RFM_REGION_PATH
 * overrides it. Workers inherit the resolved value through clone/fork.
 */
static char region_path[128];
#define REGION_PATH region_path

static void region_path_init(void)
{
	const char *env = getenv("RFM_REGION_PATH");

	if (env)
		snprintf(region_path, sizeof(region_path), "%s", env);
	else
		snprintf(region_path, sizeof(region_path),
			 "/tmp/rfm_bench_region.%d", (int)getpid());
}

enum impl {
	IMPL_PTHREAD,		/* default private pthread mutex */
	IMPL_PTHREAD_ROBUST,	/* robust, process shared pthread mutex */
	IMPL_RFM_REGISTRY,
	IMPL_RFM_OFD,
	IMPL_RFM_COUNTER,
	IMPL_MAX,
};

static const char *impl_names[] = {
	[IMPL_PTHREAD]		= "pthread (private)",
	[IMPL_PTHREAD_ROBUST]	= "pthread (robust, pshared)",
	[IMPL_RFM_REGISTRY]	= "rfmutex explicit/registry",
	[IMPL_RFM_OFD]		= "rfmutex explicit/OFD",
	[IMPL_RFM_COUNTER]	= "rfmutex counter/rseq",
};

struct bencharea {
	pthread_mutex_t	pm;
	rfmutex_t	rm;
	_Atomic(uint64_t) ops;
	_Atomic(uint32_t) start;
	_Atomic(uint32_t) stop;
};

static uint64_t now_ns(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec * 1000000000ULL + ts.tv_nsec;
}

/*
 * @cross_process: private pthread mutexes are not usable across
 * processes; the contended benchmark uses a process shared one.
 */
static int impl_init(struct bencharea *a, enum impl im, bool cross_process)
{
	int ret = 0;

	switch (im) {
	case IMPL_PTHREAD:
		if (cross_process) {
			pthread_mutexattr_t at;

			ret |= pthread_mutexattr_init(&at);
			ret |= pthread_mutexattr_setpshared(&at, PTHREAD_PROCESS_SHARED);
			ret |= pthread_mutex_init(&a->pm, &at);
			ret |= pthread_mutexattr_destroy(&at);
		} else {
			ret = pthread_mutex_init(&a->pm, NULL);
		}
		break;
	case IMPL_PTHREAD_ROBUST: {
		pthread_mutexattr_t at;

		ret |= pthread_mutexattr_init(&at);
		ret |= pthread_mutexattr_setpshared(&at, PTHREAD_PROCESS_SHARED);
		ret |= pthread_mutexattr_setrobust(&at, PTHREAD_MUTEX_ROBUST);
		ret |= pthread_mutex_init(&a->pm, &at);
		ret |= pthread_mutexattr_destroy(&at);
		break;
	}
	case IMPL_RFM_REGISTRY:
	case IMPL_RFM_OFD:
		ret = rfm_mutex_init(&a->rm, RFM_TYPE_EXPLICIT);
		break;
	case IMPL_RFM_COUNTER:
		ret = rfm_mutex_init(&a->rm, RFM_TYPE_COUNTER);
		break;
	default:
		abort();
	}
	return ret;
}

/*
 * POSIX leaves re-initializing a pthread mutex without an intervening
 * destroy undefined; every variant tears its object down again.
 */
static void impl_destroy(struct bencharea *a, enum impl im)
{
	if (im == IMPL_PTHREAD || im == IMPL_PTHREAD_ROBUST)
		pthread_mutex_destroy(&a->pm);
}

static int impl_attach(struct bencharea *a, rfm_region_t *r, enum impl im)
{
	switch (im) {
	case IMPL_RFM_REGISTRY:
		return rfm_thread_attach(r, RFM_ALLOC_REGISTRY);
	case IMPL_RFM_OFD:
		return rfm_thread_attach(r, RFM_ALLOC_OFD);
	case IMPL_RFM_COUNTER:
		return rfm_thread_attach(r, RFM_ALLOC_NONE);
	default:
		return 0;
	}
}

static inline int impl_lock(struct bencharea *a, enum impl im)
{
	int ret;

	switch (im) {
	case IMPL_PTHREAD:
	case IMPL_PTHREAD_ROBUST:
		ret = pthread_mutex_lock(&a->pm);
		if (ret == EOWNERDEAD)
			ret = pthread_mutex_consistent(&a->pm);
		break;
	default:
		ret = rfm_mutex_lock(&a->rm);
		if (ret == EOWNERDEAD)
			ret = rfm_mutex_consistent(&a->rm);
		break;
	}
	return ret;
}

static inline int impl_unlock(struct bencharea *a, enum impl im)
{
	if (im == IMPL_PTHREAD || im == IMPL_PTHREAD_ROBUST)
		return pthread_mutex_unlock(&a->pm);
	return rfm_mutex_unlock(&a->rm);
}

/* --------------------------------------------------------------------- */
struct uncontended_ctx {
	struct bencharea *a;
	rfm_region_t *r;
	enum impl im;
	unsigned long iters;
};

static int bench_uncontended_body(void *p)
{
	struct uncontended_ctx *c = p;
	struct bencharea *a = c->a;
	enum impl im = c->im;
	unsigned long errs = 0;
	uint64_t t0, t1;

	if (impl_init(a, im, false)) {
		printf("%-28s: init failed\n", impl_names[im]);
		return 1;
	}
	if (impl_attach(a, c->r, im)) {
		printf("%-28s: attach failed\n", impl_names[im]);
		impl_destroy(a, im);
		return 1;
	}

	/* warmup */
	for (unsigned long i = 0; i < 10000; i++) {
		errs += !!impl_lock(a, im);
		errs += !!impl_unlock(a, im);
	}
	t0 = now_ns();
	for (unsigned long i = 0; i < c->iters; i++) {
		errs += !!impl_lock(a, im);
		errs += !!impl_unlock(a, im);
	}
	t1 = now_ns();
	rfm_thread_detach(c->r);
	impl_destroy(a, im);
	if (errs) {
		printf("%-28s: %lu lock/unlock errors\n", impl_names[im], errs);
		return 1;
	}
	printf("%-28s: %7.1f ns/op (uncontended lock+unlock)\n",
	       impl_names[im], (double)(t1 - t0) / c->iters);
	return 0;
}

static int bench_uncontended(struct bencharea *a, rfm_region_t *r, enum impl im,
			     unsigned long iters)
{
	struct uncontended_ctx c = { a, r, im, iters };

	/*
	 * rfmutex needs to own rseq/the robust list, so run it on a
	 * libc-less thread; the pthread baselines stay on the caller.
	 */
	if (im == IMPL_PTHREAD || im == IMPL_PTHREAD_ROBUST)
		return bench_uncontended_body(&c);
	return rfm_run_libcless(bench_uncontended_body, &c);
}

/* --------------------------------------------------------------------- */
struct warg {
	enum impl im;
	int idx;
};

static int contended_loop(void *p)
{
	struct warg *wa = p;
	rfm_region_t *r;
	struct bencharea *a;
	uint64_t local = 0;

	/*
	 * Raw clone() child: pthread_atfork handlers did not run, drop
	 * the inherited attachment before re-attaching, otherwise this
	 * process would run without a registered robust list.
	 */
	rfm_thread_reset_after_fork();

	r = rfm_region_attach(REGION_PATH);
	if (!r)
		return 1;
	a = rfm_region_base(r);
	if (impl_attach(a, r, wa->im))
		return 2;

	while (!atomic_load_explicit(&a->start, memory_order_acquire))
		;
	while (!atomic_load_explicit(&a->stop, memory_order_relaxed)) {
		if (impl_lock(a, wa->im) || impl_unlock(a, wa->im))
			return 3;
		local++;
	}
	atomic_fetch_add(&a->ops, local);
	rfm_thread_detach(r);
	return 0;
}

static int contended_worker(void *p)
{
	struct warg *wa = p;

	/* rfmutex work runs on a libc-less thread (owns rseq/robust list). */
	if (wa->im == IMPL_PTHREAD || wa->im == IMPL_PTHREAD_ROBUST)
		return contended_loop(p);
	return rfm_run_libcless(contended_loop, p);
}

static int bench_contended(struct bencharea *a, enum impl im, int nworkers,
			   int duration_ms)
{
	struct warg wa[nworkers];
	pid_t pids[nworkers];
	int wstatus, failed = 0, spawned = 0;
	uint64_t t0, t1;

	if (impl_init(a, im, true)) {
		printf("%-28s: init failed\n", impl_names[im]);
		return 1;
	}
	atomic_store(&a->ops, 0);
	atomic_store(&a->start, 0);
	atomic_store(&a->stop, 0);

	for (int i = 0; i < nworkers; i++) {
		char *stack = mmap(NULL, 256 * 1024, PROT_READ | PROT_WRITE,
				   MAP_PRIVATE | MAP_ANONYMOUS | MAP_STACK, -1, 0);

		if (stack == MAP_FAILED) {
			printf("%-28s: worker stack mmap failed\n", impl_names[im]);
			failed = 1;
			break;
		}
		wa[i] = (struct warg){ .im = im, .idx = i };
		pids[i] = clone(contended_worker, stack + 256 * 1024, SIGCHLD, &wa[i]);
		if (pids[i] < 0) {
			printf("%-28s: clone failed: %s\n", impl_names[im],
			       strerror(errno));
			failed = 1;
			break;
		}
		spawned++;
	}

	usleep(50000);	/* let workers attach */
	t0 = now_ns();
	atomic_store_explicit(&a->start, 1, memory_order_release);
	usleep(duration_ms * 1000);
	atomic_store(&a->stop, 1);
	t1 = now_ns();

	for (int i = 0; i < spawned; i++) {
		if (waitpid(pids[i], &wstatus, 0) != pids[i] ||
		    !WIFEXITED(wstatus) || WEXITSTATUS(wstatus)) {
			printf("%-28s: worker %d failed (status %d)\n",
			       impl_names[im], i, wstatus);
			failed = 1;
		}
	}
	impl_destroy(a, im);

	if (failed || spawned != nworkers)
		return 1;
	printf("%-28s: %8.0f kops/s (%d workers contended)\n",
	       im == IMPL_PTHREAD ? "pthread (pshared)" : impl_names[im],
	       (double)atomic_load(&a->ops) * 1e6 / (t1 - t0), nworkers);
	return 0;
}

int main(int argc, char **argv)
{
	region_path_init();

	unsigned long iters = argc > 1 ? strtoul(argv[1], NULL, 0) : 300000;
	int duration = argc > 2 ? atoi(argv[2]) : 1000;
	int nworkers = argc > 3 ? atoi(argv[3]) : 4;
	rfm_region_t *r;
	struct bencharea *a;
	int failed = 0;

	if (!iters || duration <= 0 || nworkers < 1 || nworkers > 128) {
		fprintf(stderr, "usage: %s [iters] [duration_ms] [workers 1..128]\n",
			argv[0]);
		return 2;
	}

	unlink(REGION_PATH);
	r = rfm_region_create(REGION_PATH, 1 << 20);
	if (!r) {
		perror("region");
		return 1;
	}
	a = rfm_region_base(r);
	memset(a, 0, sizeof(*a));

	printf("== uncontended (%lu iterations) ==\n", iters);
	for (int im = 0; im < IMPL_MAX; im++)
		failed |= bench_uncontended(a, r, im, iters);

	printf("== contended (%d workers, %d ms) ==\n", nworkers, duration);
	for (int im = 0; im < IMPL_MAX; im++)
		failed |= bench_contended(a, im, nworkers, duration);

	if (failed)
		printf("BENCHMARK FAILED\n");
	return failed;
}
