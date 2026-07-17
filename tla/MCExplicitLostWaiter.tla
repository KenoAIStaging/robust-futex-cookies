---- MODULE MCExplicitLostWaiter ----
EXTENDS ExplicitCookie
CONSTANTS t1, t2, t3
MCThreads == {t1, t2, t3}
MCCookies == {1, 2, 3}
MCId == [t \in MCThreads |-> 1]  \* unused (UseAllocator)
=============================
