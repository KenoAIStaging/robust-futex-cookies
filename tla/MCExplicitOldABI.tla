---- MODULE MCExplicitOldABI ----
EXTENDS ExplicitCookie
CONSTANTS t1, t2, t3
MCThreads == {t1, t2, t3}
MCId == [t \in MCThreads |-> IF t = t1 THEN 1 ELSE IF t = t2 THEN 2 ELSE 3]
=============================
