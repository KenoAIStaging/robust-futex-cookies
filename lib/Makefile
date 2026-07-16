CC := /usr/bin/gcc
KHDR := /workspace/.kbuild/usr/include
CFLAGS := -O2 -g -Wall -Wextra -Wno-unused-parameter -pthread -I$(KHDR) -I.
LDLIBS := -ldl -lpthread

all: test_rfmutex bench_rfmutex

test_rfmutex: test_rfmutex.c rfmutex.c rfmutex.h
	env PATH=/usr/bin:/bin $(CC) $(CFLAGS) test_rfmutex.c rfmutex.c -o $@ $(LDLIBS)

bench_rfmutex: ../bench/bench_rfmutex.c rfmutex.c rfmutex.h
	env PATH=/usr/bin:/bin $(CC) $(CFLAGS) ../bench/bench_rfmutex.c rfmutex.c -o $@ $(LDLIBS)

clean:
	rm -f test_rfmutex bench_rfmutex
