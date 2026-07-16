/* SPDX-License-Identifier: MIT */
#define _GNU_SOURCE
#include "rfmutex.h"

#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/futex.h>
#include <linux/membarrier.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <unistd.h>

/* ---------------------------------------------------------------------
 * Kernel ABI definitions (until they show up in installed uapi headers)
 */
#ifndef ROBUST_LIST_COOKIE
struct robust_list_head2 {
	struct robust_list_head head;
	unsigned long flags;
	long cookie_offset;
	uint32_t list_op_pending_cookie;
	uint32_t __reserved;
};
#define ROBUST_LIST_COOKIE	(0x1UL)
#endif

#ifndef MEMBARRIER_CMD_SHARED_EXPEDITED_RSEQ
#define MEMBARRIER_CMD_SHARED_EXPEDITED_RSEQ		(1 << 10)
#define MEMBARRIER_CMD_REGISTER_SHARED_EXPEDITED_RSEQ	(1 << 11)
#endif

#ifndef FUTEX_ROBUST_UNLOCK
#define FUTEX_ROBUST_UNLOCK	512
#endif

#define RSEQ_SIG	0x53053053

struct rseq_area {
	uint32_t cpu_id_start;
	uint32_t cpu_id;
	_Atomic(uint64_t) rseq_cs;
	uint32_t flags;
} __attribute__((aligned(32)));

struct rseq_cs_desc {
	uint32_t version;
	uint32_t flags;
	uint64_t start_ip;
	uint64_t post_commit_offset;
	uint64_t abort_ip;
} __attribute__((aligned(32)));

/*
 * An "empty" critical section descriptor: its IP range never contains
 * executed code, so any RSEQ event just clears TLS::rseq::rseq_cs. Used
 * as the "no RSEQ event since armed" detector for cookie reservations.
 */
static const struct rseq_cs_desc rfm_guard_cs = {
	.start_ip = 4096,
	.post_commit_offset = 0,
};

/* ---------------------------------------------------------------------
 * Syscall and vDSO glue
 */
static int sys_futex(volatile void *uaddr, int op, uint32_t val,
		     void *timeout_or_val2, void *uaddr2, uint32_t val3)
{
	return syscall(SYS_futex, uaddr, op, val, timeout_or_val2, uaddr2, val3);
}

static int sys_set_robust_list2(struct robust_list_head2 *head)
{
	return syscall(SYS_set_robust_list, head, sizeof(*head));
}

static int sys_membarrier(int cmd, unsigned int flags, int cpu_id, void *addr)
{
	return syscall(__NR_membarrier, cmd, flags, cpu_id, addr);
}

static int sys_rseq(volatile struct rseq_area *rs, uint32_t len, int flags, uint32_t sig)
{
	return syscall(SYS_rseq, rs, len, flags, sig);
}

/* glibc >= 2.35 registers rseq itself and exports these */
extern __attribute__((weak)) ptrdiff_t __rseq_offset;
extern __attribute__((weak)) unsigned int __rseq_size;

typedef uint32_t (*vdso_try_unlock_t)(_Atomic(uint32_t) *lock, uint32_t tid,
				      struct robust_list **pop);
typedef uint32_t (*vdso_cmpxchg_rseq_t)(struct robust_list **pending_ptr, uint64_t pending,
					_Atomic(uint32_t) *lock, uint32_t expect,
					uint32_t set, volatile struct rseq_area *rseq);

static vdso_try_unlock_t vdso_try_unlock;
static vdso_cmpxchg_rseq_t vdso_cmpxchg_rseq;

static void *vdso_sym(const char *name)
{
	static const char *vdso_names[] = {
		"linux-vdso.so.1", "linux-gate.so.1",
	};
	for (unsigned int i = 0; i < 2; i++) {
		void *h = dlopen(vdso_names[i], RTLD_LAZY | RTLD_LOCAL | RTLD_NOLOAD);
		if (h)
			return dlsym(h, name);
	}
	return NULL;
}

/* ---------------------------------------------------------------------
 * Per thread state
 */
struct rfm_tls {
	struct robust_list_head2 h;
	volatile struct rseq_area *rseq;
	struct rseq_area own_rseq;
	uint32_t cookie;	/* explicit mode thread cookie, 0 if none */
	int ofd_fd;
	rfmutex_t *slot;	/* registry slot held, if any */
	int attached;
};

static __thread struct rfm_tls rfm_tls;

#define RFM_TID_MASK	0x3fffffffU
#define RFM_WAITERS	0x80000000U
#define RFM_OWNER_DIED	0x40000000U

/* Entry pointer for the kernel: address of the ->next member */
static inline _Atomic(uintptr_t) *rfm_entry(rfmutex_t *m)
{
	return &m->next;
}

static inline rfmutex_t *rfm_from_entry(uintptr_t e)
{
	return (rfmutex_t *)((char *)e - offsetof(rfmutex_t, next));
}

static int rfm_thread_init_common(void)
{
	struct rfm_tls *t = &rfm_tls;

	if (t->attached)
		return 0;

	if (!vdso_try_unlock) {
		vdso_try_unlock = vdso_sym("__vdso_futex_robust_list64_try_unlock");
		vdso_cmpxchg_rseq = vdso_sym("__vdso_futex_robust_list64_cmpxchg_rseq");
		if (!vdso_try_unlock || !vdso_cmpxchg_rseq)
			return -ENOSYS;
	}

	/* rseq registration (needed for RFM_TYPE_COUNTER) */
	if (!sys_rseq(&t->own_rseq, sizeof(t->own_rseq), 0, RSEQ_SIG)) {
		t->rseq = &t->own_rseq;
	} else if (errno == EBUSY && &__rseq_offset && __rseq_size) {
		char *tp;
		__asm__("mov %%fs:0, %0" : "=r" (tp));
		t->rseq = (volatile struct rseq_area *)(tp + __rseq_offset);
	} else {
		return -errno;
	}

	/* Robust list head with cookie support */
	memset(&t->h, 0, sizeof(t->h));
	t->h.head.list.next = (struct robust_list *)&t->h.head.list;
	t->h.head.futex_offset = (ssize_t)offsetof(rfmutex_t, word) -
				 (ssize_t)offsetof(rfmutex_t, next);
	t->h.head.list_op_pending = NULL;
	t->h.flags = ROBUST_LIST_COOKIE;
	t->h.cookie_offset = (ssize_t)offsetof(rfmutex_t, cookie) -
			     (ssize_t)offsetof(rfmutex_t, next);
	if (sys_set_robust_list2(&t->h))
		return -errno;

	/* membarrier registration (needed for RFM_TYPE_COUNTER quiescence) */
	if (sys_membarrier(MEMBARRIER_CMD_REGISTER_SHARED_EXPEDITED_RSEQ, 0, 0, NULL))
		return -errno;

	t->attached = 1;
	return 0;
}

/* ---------------------------------------------------------------------
 * Robust list queueing. The list is thread private; the only concurrent
 * reader is the kernel at task death, so the ordering requirement is
 * that the list is well formed at every instant: the entry's forward
 * link is published before the entry becomes reachable.
 */
static void rfm_enqueue(struct rfm_tls *t, rfmutex_t *m)
{
	uintptr_t head = (uintptr_t)&t->h.head.list;
	uintptr_t first = (uintptr_t)t->h.head.list.next;

	atomic_store_explicit(&m->next, first, memory_order_relaxed);
	m->prev = head;
	if (first != head)
		rfm_from_entry(first)->prev = (uintptr_t)rfm_entry(m);
	/* Publish */
	atomic_store_explicit((_Atomic(uintptr_t) *)&t->h.head.list.next,
			      (uintptr_t)rfm_entry(m), memory_order_release);
}

static void rfm_dequeue(struct rfm_tls *t, rfmutex_t *m)
{
	uintptr_t head = (uintptr_t)&t->h.head.list;
	uintptr_t next = atomic_load_explicit(&m->next, memory_order_relaxed);

	/* Unlink: the predecessor's forward link skips this entry */
	atomic_store_explicit((_Atomic(uintptr_t) *)m->prev, next,
			      memory_order_release);
	if (next != head)
		rfm_from_entry(next)->prev = m->prev;
}

/* ---------------------------------------------------------------------
 * Common slow path helpers
 */
static void rfm_futex_wait(rfmutex_t *m, uint32_t val)
{
	/* Shared (non private) futex op, timeout NULL */
	sys_futex(&m->word, FUTEX_WAIT, val, NULL, NULL, 0);
}

static void rfm_wake_all_robust(struct rfm_tls *t, rfmutex_t *m)
{
	/* Unlock (store 0), clear pending op and wake one waiter */
	sys_futex(&m->word, FUTEX_WAKE | FUTEX_ROBUST_UNLOCK, 1, NULL,
		  &t->h.head.list_op_pending, 0);
}

/*
 * Wait until the lock word looks free (0 or FUTEX_OWNER_DIED), setting
 * the waiters bit while blocking. Returns the last observed value.
 */
static uint32_t rfm_wait_free(rfmutex_t *m)
{
	uint32_t w = atomic_load_explicit(&m->word, memory_order_relaxed);

	for (;;) {
		if (!(w & RFM_TID_MASK))
			return w;
		if (!(w & RFM_WAITERS)) {
			if (!atomic_compare_exchange_weak_explicit(&m->word, &w,
					w | RFM_WAITERS, memory_order_relaxed,
					memory_order_relaxed))
				continue;
			w |= RFM_WAITERS;
		}
		rfm_futex_wait(m, w);
		w = atomic_load_explicit(&m->word, memory_order_relaxed);
	}
}

/* ---------------------------------------------------------------------
 * Explicit cookie mutex (registry / OFD allocated thread cookie)
 *
 * Pure user space robust protocol, analogous to the classic TID based
 * one: arm list_op_pending (with the thread's pending cookie), cmpxchg
 * the lock word, queue the entry.
 */
static int rfm_lock_explicit(rfmutex_t *m, bool try_only)
{
	struct rfm_tls *t = &rfm_tls;
	uint32_t c = t->cookie;
	uint32_t w, waited = 0;
	int dead;

	if (!c)
		return -EINVAL;

	t->h.list_op_pending_cookie = c;
	atomic_signal_fence(memory_order_seq_cst);
	t->h.head.list_op_pending = (struct robust_list *)rfm_entry(m);
	atomic_signal_fence(memory_order_seq_cst);

	for (;;) {
		w = atomic_load_explicit(&m->word, memory_order_relaxed);
		if ((w & RFM_TID_MASK) == 0) {
			/*
			 * Free or dead: acquire, preserving flag bits. A
			 * thread which ever waited must acquire with the
			 * waiters bit set: the kernel side unlock wipes
			 * the whole word, so other sleeping waiters would
			 * otherwise never be woken again.
			 */
			dead = !!(w & RFM_OWNER_DIED);
			if (atomic_compare_exchange_strong_explicit(&m->word, &w,
					c | waited | (w & (RFM_WAITERS | RFM_OWNER_DIED)),
					memory_order_acquire, memory_order_relaxed))
				break;
			continue;
		}

		if (try_only) {
			t->h.head.list_op_pending = NULL;
			return EBUSY;
		}
		rfm_wait_free(m);
		waited = RFM_WAITERS;
	}

	atomic_store_explicit(&m->cookie, c, memory_order_relaxed);
	rfm_enqueue(t, m);
	atomic_signal_fence(memory_order_seq_cst);
	t->h.head.list_op_pending = NULL;
	return dead ? EOWNERDEAD : 0;
}

/* ---------------------------------------------------------------------
 * Counter mutex: per acquisition cookie from the per-mutex counter.
 *
 * The 64-bit counter provides the 30-bit cookie in its low bits.
 * "Generation" g = counter >> 29 changes whenever the top bit of the
 * 30-bit cookie space flips. Before a reservation of generation g may
 * be published, all reservations of generation g-2 (which are the ones
 * that can collide numerically) must be dead. This is ensured by
 * fencing (MEMBARRIER_CMD_SHARED_EXPEDITED_RSEQ on the lock word) at
 * least once after entering generation g: the fence aborts every
 * in-flight reservation, and q_gen only advances monotonically
 * (CAS-max), so a stale fencer cannot regress it.
 *
 * The reservation itself is protected by the rseq_cs event detector and
 * the vDSO cmpxchg helper: any RSEQ event between reserving the cookie
 * and the cmpxchg makes the operation fail.
 */
#define RFM_COOKIE_MASK	0x3fffffffULL
#define RFM_GEN_SHIFT	29

static void rfm_quiesce(rfmutex_t *m, uint64_t gen)
{
	uint64_t q = atomic_load_explicit(&m->q_gen, memory_order_relaxed);

	if (sys_membarrier(MEMBARRIER_CMD_SHARED_EXPEDITED_RSEQ, 0, 0,
			   (void *)&m->word)) {
		/* Cannot happen on a registered thread with a valid mapping */
		abort();
	}
	/* Monotonic CAS-max: a stale fencer must not regress q_gen */
	while (q < gen) {
		if (atomic_compare_exchange_weak_explicit(&m->q_gen, &q, gen,
				memory_order_release, memory_order_relaxed))
			break;
	}
}

static int rfm_lock_counter(rfmutex_t *m, bool try_only)
{
	struct rfm_tls *t = &rfm_tls;
	uint64_t raw, gen;
	uint32_t c, w, set, waited = 0;
	int dead;

	for (;;) {
		w = atomic_load_explicit(&m->word, memory_order_relaxed);
		if (w & RFM_TID_MASK) {
			/* Held by a live owner */
			if (try_only)
				return EBUSY;
			w = rfm_wait_free(m);
			waited = RFM_WAITERS;
		}

		/*
		 * Arm the RSEQ event detector, then reserve a cookie.
		 * No system calls are allowed from here to the vDSO call.
		 */
		atomic_store_explicit(&t->rseq->rseq_cs,
				      (uint64_t)(uintptr_t)&rfm_guard_cs,
				      memory_order_relaxed);
		raw = atomic_fetch_add_explicit(&m->counter, 1, memory_order_seq_cst);
		c = (uint32_t)(raw & RFM_COOKIE_MASK);
		gen = raw >> RFM_GEN_SHIFT;

		if (c == 0 ||
		    atomic_load_explicit(&m->q_gen, memory_order_acquire) < gen) {
			/* Disarm and quiesce the new generation */
			atomic_store_explicit(&t->rseq->rseq_cs, 0,
					      memory_order_relaxed);
			if (c != 0)
				rfm_quiesce(m, gen);
			continue;
		}

		/*
		 * Re-read the lock word for the expected value: 0 or a
		 * dead owner (OWNER_DIED with cleared owner bits).
		 */
		w = atomic_load_explicit(&m->word, memory_order_relaxed);
		dead = 0;
		if (w & RFM_TID_MASK) {
			/* Became owned meanwhile: disarm and wait/retry */
			atomic_store_explicit(&t->rseq->rseq_cs, 0,
					      memory_order_relaxed);
			if (try_only)
				return EBUSY;
			continue;
		}
		/* See rfm_lock_explicit() about the waited bit */
		set = c | waited | (w & (RFM_WAITERS | RFM_OWNER_DIED));
		dead = !!(w & RFM_OWNER_DIED);

		t->h.list_op_pending_cookie = c;
		atomic_signal_fence(memory_order_seq_cst);

		if (vdso_cmpxchg_rseq(&t->h.head.list_op_pending,
				      (uint64_t)(uintptr_t)rfm_entry(m),
				      &m->word, w, set, t->rseq)) {
			atomic_store_explicit(&t->rseq->rseq_cs, 0,
					      memory_order_relaxed);
			break;
		}
		atomic_store_explicit(&t->rseq->rseq_cs, 0, memory_order_relaxed);
		/* Aborted or contended: retry with a fresh reservation */
	}

	atomic_store_explicit(&m->cookie, c, memory_order_relaxed);
	rfm_enqueue(t, m);
	atomic_signal_fence(memory_order_seq_cst);
	t->h.head.list_op_pending = NULL;
	return dead ? EOWNERDEAD : 0;
}

/* ---------------------------------------------------------------------
 * Common unlock
 */
static int rfm_unlock_common(rfmutex_t *m, uint32_t c)
{
	struct rfm_tls *t = &rfm_tls;

	t->h.list_op_pending_cookie = c;
	atomic_signal_fence(memory_order_seq_cst);
	t->h.head.list_op_pending = (struct robust_list *)rfm_entry(m);
	atomic_signal_fence(memory_order_seq_cst);

	rfm_dequeue(t, m);

	/*
	 * Fast path: uncontended, consistent lock word. The vDSO helper
	 * clears the pending op atomically with a successful cmpxchg.
	 */
	if (vdso_try_unlock(&m->word, c, &t->h.head.list_op_pending) != c) {
		/* Contended or OWNER_DIED set: kernel unlock + wake */
		rfm_wake_all_robust(t, m);
	}
	return 0;
}

/* ---------------------------------------------------------------------
 * Public API
 */
int rfm_mutex_init(rfmutex_t *m, enum rfm_type type)
{
	memset(m, 0, sizeof(*m));
	m->type = type;
	/* Cookie 0 is skipped, start the counter at 1 */
	atomic_store_explicit(&m->counter, 1, memory_order_relaxed);
	return 0;
}

int rfm_mutex_lock(rfmutex_t *m)
{
	if (m->type == RFM_TYPE_COUNTER)
		return rfm_lock_counter(m, false);
	return rfm_lock_explicit(m, false);
}

int rfm_mutex_trylock(rfmutex_t *m)
{
	if (m->type == RFM_TYPE_COUNTER)
		return rfm_lock_counter(m, true);
	return rfm_lock_explicit(m, true);
}

int rfm_mutex_unlock(rfmutex_t *m)
{
	uint32_t c;

	if (m->type == RFM_TYPE_COUNTER)
		c = atomic_load_explicit(&m->cookie, memory_order_relaxed);
	else
		c = rfm_tls.cookie;

	if (!c || (atomic_load_explicit(&m->word, memory_order_relaxed) &
		   RFM_TID_MASK) != c)
		return -EPERM;

	return rfm_unlock_common(m, c);
}

int rfm_mutex_consistent(rfmutex_t *m)
{
	uint32_t w = atomic_load_explicit(&m->word, memory_order_relaxed);

	for (;;) {
		if (!(w & RFM_OWNER_DIED))
			return -EINVAL;
		if (atomic_compare_exchange_weak_explicit(&m->word, &w,
				w & ~RFM_OWNER_DIED, memory_order_relaxed,
				memory_order_relaxed))
			return 0;
	}
}

/* ---------------------------------------------------------------------
 * Region and cookie allocators
 */
struct rfm_region_hdr {
	uint32_t magic;
	uint32_t nslots;
	rfmutex_t slots[RFM_REGISTRY_SLOTS];
};

#define RFM_MAGIC	0x52464d31	/* "RFM1" */

struct rfm_region {
	struct rfm_region_hdr *hdr;
	size_t size;
	char path[256];
};

rfm_region_t *rfm_region_create(const char *path, size_t size)
{
	rfm_region_t *r;
	int fd;

	size += sizeof(struct rfm_region_hdr);
	fd = open(path, O_RDWR | O_CREAT, 0666);
	if (fd < 0)
		return NULL;
	if (ftruncate(fd, size)) {
		close(fd);
		return NULL;
	}

	r = calloc(1, sizeof(*r));
	r->size = size;
	snprintf(r->path, sizeof(r->path), "%s", path);
	r->hdr = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
	close(fd);
	if (r->hdr == MAP_FAILED) {
		free(r);
		return NULL;
	}

	memset(r->hdr, 0, sizeof(struct rfm_region_hdr));
	for (unsigned int i = 0; i < RFM_REGISTRY_SLOTS; i++)
		rfm_mutex_init(&r->hdr->slots[i], RFM_TYPE_EXPLICIT);
	r->hdr->nslots = RFM_REGISTRY_SLOTS;
	atomic_thread_fence(memory_order_seq_cst);
	r->hdr->magic = RFM_MAGIC;
	return r;
}

rfm_region_t *rfm_region_attach(const char *path)
{
	rfm_region_t *r;
	struct stat st;
	int fd;

	fd = open(path, O_RDWR);
	if (fd < 0)
		return NULL;
	if (fstat(fd, &st)) {
		close(fd);
		return NULL;
	}

	r = calloc(1, sizeof(*r));
	r->size = st.st_size;
	snprintf(r->path, sizeof(r->path), "%s", path);
	r->hdr = mmap(NULL, r->size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
	close(fd);
	if (r->hdr == MAP_FAILED || r->hdr->magic != RFM_MAGIC) {
		free(r);
		return NULL;
	}
	return r;
}

void *rfm_region_base(rfm_region_t *r)
{
	return r->hdr + 1;
}

size_t rfm_region_size(rfm_region_t *r)
{
	return r->size - sizeof(struct rfm_region_hdr);
}

void rfm_region_detach(rfm_region_t *r)
{
	munmap(r->hdr, r->size);
	free(r);
}

/*
 * Registry allocator: claim the lowest free or dead slot. Slot k is
 * held with cookie k+1 for the lifetime of the thread and sits on the
 * thread's robust list, so the kernel marks it OWNER_DIED when the
 * thread dies without detaching.
 */
static int rfm_alloc_registry(rfm_region_t *r)
{
	struct rfm_tls *t = &rfm_tls;

	for (uint32_t k = 0; k < r->hdr->nslots; k++) {
		rfmutex_t *s = &r->hdr->slots[k];
		uint32_t c = k + 1;
		uint32_t w = atomic_load_explicit(&s->word, memory_order_relaxed);

		if (w & RFM_TID_MASK)
			continue;	/* alive owner */

		/*
		 * Free (0) or dead (OWNER_DIED): claim it with the robust
		 * pending protocol so a death in this window is cleaned up.
		 */
		t->h.list_op_pending_cookie = c;
		atomic_signal_fence(memory_order_seq_cst);
		t->h.head.list_op_pending = (struct robust_list *)rfm_entry(s);
		atomic_signal_fence(memory_order_seq_cst);

		if (atomic_compare_exchange_strong_explicit(&s->word, &w, c,
				memory_order_acquire, memory_order_relaxed)) {
			atomic_store_explicit(&s->cookie, c, memory_order_relaxed);
			rfm_enqueue(t, s);
			atomic_signal_fence(memory_order_seq_cst);
			t->h.head.list_op_pending = NULL;
			t->slot = s;
			t->cookie = c;
			return 0;
		}
		t->h.head.list_op_pending = NULL;
		k--;	/* lost the race for this slot, retry it */
	}
	return -EAGAIN;
}

/*
 * OFD allocator: cookie k is owned by whoever holds the OFD write lock
 * on byte k of the region file. The lock dies with the open file
 * description, i.e. at the latest when the process dies.
 */
static int rfm_alloc_ofd(rfm_region_t *r)
{
	struct rfm_tls *t = &rfm_tls;
	int fd = open(r->path, O_RDWR);

	if (fd < 0)
		return -errno;

	for (uint32_t k = 1; k <= RFM_REGISTRY_SLOTS; k++) {
		struct flock fl = {
			.l_type = F_WRLCK,
			.l_whence = SEEK_SET,
			.l_start = k,
			.l_len = 1,
		};
		if (!fcntl(fd, F_OFD_SETLK, &fl)) {
			t->ofd_fd = fd;
			t->cookie = k;
			return 0;
		}
		if (errno != EAGAIN && errno != EACCES) {
			close(fd);
			return -errno;
		}
	}
	close(fd);
	return -EAGAIN;
}

int rfm_thread_attach(rfm_region_t *r, enum rfm_alloc alloc)
{
	struct rfm_tls *t = &rfm_tls;
	int ret = rfm_thread_init_common();

	if (ret)
		return ret;

	switch (alloc) {
	case RFM_ALLOC_NONE:
		return 0;
	case RFM_ALLOC_REGISTRY:
		return rfm_alloc_registry(r);
	case RFM_ALLOC_OFD:
		return rfm_alloc_ofd(r);
	}
	(void)t;
	return -EINVAL;
}

void rfm_thread_detach(rfm_region_t *r)
{
	struct rfm_tls *t = &rfm_tls;

	(void)r;
	if (t->slot) {
		rfm_unlock_common(t->slot, t->cookie);
		t->slot = NULL;
	}
	if (t->ofd_fd > 0) {
		close(t->ofd_fd);
		t->ofd_fd = 0;
	}
	t->cookie = 0;
}

uint32_t rfm_thread_cookie(void)
{
	return rfm_tls.cookie;
}
