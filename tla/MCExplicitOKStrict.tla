---- MODULE MCExplicitOKStrict ----
EXTENDS ExplicitCookie
CONSTANTS t1, t2, t3
MCThreads == {t1, t2, t3}
\* Two cookies for three threads: forces lease contention and reuse
MCCookies == {1, 2, 3}
MCId == [t \in MCThreads |-> 1]  \* unused (UseAllocator)
=============================
