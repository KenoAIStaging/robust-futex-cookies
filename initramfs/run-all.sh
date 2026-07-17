\* SPDX-License-Identifier: MIT
#!/bin/sh
# SPDX-License-Identifier: MIT
# The checked-in guest runner for the full validation: kernel futex and
# membarrier selftests plus the rfmutex library suite. Duration can be
# tuned via the RFM_TEST_MS kernel-independent default below.
cd /tests || exit 1
./robust_list || exit 1
./membarrier_shared_rseq_test || exit 1
./test_rfmutex ${RFM_TEST_MS:-200} || exit 1
