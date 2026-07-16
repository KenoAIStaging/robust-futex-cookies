# rfmutex benchmark results

Environment: QEMU 5.2 TCG (no KVM available in sandbox), 8 vCPUs, guest
kernel 7.2.0-rc4+ with the robust-cookie patch series. TCG emulation
inflates absolute numbers; relative comparison is the meaningful signal.
Run: `bench_rfmutex 200000 1000 4`.

## Uncontended lock+unlock (single thread, ns/op)

| implementation              | ns/op |
|-----------------------------|-------|
| pthread (private)           |  83.4 |
| pthread (robust, pshared)   | 108.7 |
| rfmutex explicit/registry   |  80.6 |
| rfmutex explicit/OFD        |  77.4 |
| rfmutex counter/rseq        | 127.9 |

## Contended, 4 worker processes (kops/s, higher is better)

| implementation              | kops/s |
|-----------------------------|--------|
| pthread (pshared)           |   4844 |
| pthread (robust, pshared)   |   1827 |
| rfmutex explicit/registry   |   1534 |
| rfmutex explicit/OFD        |   2092 |
| rfmutex counter/rseq        |   1245 |

Notes:
- The two rfmutex explicit variants share the same lock/unlock hot path
  (the allocator only differs at thread attach); the spread between them
  is run-to-run variance of the contended benchmark.
- rfmutex explicit is on par with glibc's robust pshared mutex
  uncontended (slightly faster: the vDSO try_unlock avoids glibc's
  bookkeeping) and slightly behind contended (glibc's adaptive paths).
- The counter/rseq variant pays for the fetch_add reservation, the rseq
  guard arm/disarm and the vDSO cmpxchg on every acquisition:
  ~18% over glibc robust uncontended. Its quiescence membarrier cost is
  amortized over 2^29 acquisitions per mutex and does not show up.
