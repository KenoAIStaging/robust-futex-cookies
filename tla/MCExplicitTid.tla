---- MODULE MCExplicitTid ----
EXTENDS ExplicitCookie
CONSTANTS t1, t2, t3
MCThreads == {t1, t2, t3}
\* The PID namespace scenario: t1 and t2 observe the same namespace local
\* TID. This is the classic TID based robust list protocol.
MCId == [t \in MCThreads |-> IF t = t3 THEN 2 ELSE 1]
=============================
