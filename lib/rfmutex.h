/* SPDX-License-Identifier: MIT */
/*
 * rfmutex - PID namespace agnostic robust mutexes based on the
 * ROBUST_LIST_COOKIE kernel extension.
 *
 * Instead of the TID, the futex lock word holds a 30-bit cookie which
 * identifies the owner. Three cookie assignment strategies are provided:
 *
 *  RFM_ALLOC_REGISTRY: Per-thread cookies allocated from a registry table
 *	in the shared memory region. Each allocated slot is held locked
 *	(word == cookie) by its owning thread and registered on the
 *	thread's robust list, so the kernel marks it FUTEX_OWNER_DIED on
 *	thread death and the cookie becomes reclaimable.
 *
 *  RFM_ALLOC_OFD: Per-thread cookies allocated with OFD (open file
 *	description) byte range locks on the shared region's backing
 *	file. The kernel releases the locks when the file descriptors are
 *	closed, which happens automatically on process death.
 *
 *  RFM_TYPE_COUNTER mutexes need no cookie allocation at all: each lock
 *	operation reserves a fresh cookie from a per-mutex counter. The
 *	reservation is only valid while no RSEQ event occurs between the
 *	reservation and the lock word cmpxchg, which is guaranteed by
 *	the __vdso_futex_robust_list64_cmpxchg_rseq() helper. Counter
 *	wraparound is fenced with MEMBARRIER_CMD_SHARED_EXPEDITED_RSEQ.
 *
 * Limitations (this is a reference implementation):
 *  - Registering the rfmutex robust list head replaces any robust list
 *    the libc registered for the thread, so glibc robust mutexes must
 *    not be used in threads attached to rfmutex.
 *  - No PI support (cookies cannot work with kernel PI ownership).
 *  - pthread_mutex_consistent() semantics are simplified: rfm_unlock()
 *    of an inconsistent mutex passes FUTEX_OWNER_DIED on to the next
 *    owner instead of poisoning the mutex.
 */
#ifndef RFMUTEX_H
#define RFMUTEX_H

#include <stdatomic.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

enum rfm_type {
	RFM_TYPE_EXPLICIT = 0,	/* thread cookie from registry/OFD allocator */
	RFM_TYPE_COUNTER  = 1,	/* per-mutex reservation counter */
};

enum rfm_alloc {
	RFM_ALLOC_NONE = 0,	/* only RFM_TYPE_COUNTER mutexes usable */
	RFM_ALLOC_REGISTRY,
	RFM_ALLOC_OFD,
};

typedef struct rfmutex {
	_Atomic(uint32_t)	word;		/* futex word */
	uint32_t		type;
	_Atomic(uint64_t)	counter;	/* cookie reservation counter */
	_Atomic(uint64_t)	q_gen;		/* highest quiesced generation */
	_Atomic(uintptr_t)	next;		/* robust list entry (kernel ABI) */
	uintptr_t		prev;		/* library private list backlink */
	_Atomic(uint32_t)	cookie;		/* entry cookie (kernel ABI) */
	uint32_t		__pad;
} rfmutex_t;

/*
 * A shared memory region with a registry header. Mutexes live anywhere
 * in the region after the header; the application manages that space.
 */
typedef struct rfm_region rfm_region_t;

#define RFM_REGISTRY_SLOTS	1024

/* Region management. The region is a shared mapping of a file. */
rfm_region_t *rfm_region_create(const char *path, size_t size);
rfm_region_t *rfm_region_attach(const char *path);
void *rfm_region_base(rfm_region_t *r);	/* usable space after header */
size_t rfm_region_size(rfm_region_t *r);
void rfm_region_detach(rfm_region_t *r);

/*
 * Thread attach: registers the robust list (and rseq/membarrier on first
 * use) and allocates a cookie according to @alloc. Must be called in
 * every thread before it uses rfmutexes of the region.
 */
int rfm_thread_attach(rfm_region_t *r, enum rfm_alloc alloc);
void rfm_thread_detach(rfm_region_t *r);
uint32_t rfm_thread_cookie(void);	/* explicit cookie of this thread, 0 if none */

/* Mutex API. Returns 0, EOWNERDEAD (lock acquired, previous owner died),
 * EBUSY (trylock only) or a negative errno on hard failure. */
int rfm_mutex_init(rfmutex_t *m, enum rfm_type type);
int rfm_mutex_lock(rfmutex_t *m);
int rfm_mutex_trylock(rfmutex_t *m);
int rfm_mutex_unlock(rfmutex_t *m);
int rfm_mutex_consistent(rfmutex_t *m);

#ifdef __cplusplus
}
#endif

#endif /* RFMUTEX_H */
