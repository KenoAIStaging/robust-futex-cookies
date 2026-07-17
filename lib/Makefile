# SPDX-License-Identifier: MIT
#
# Conventional overridable variables. To build against not-yet-installed
# kernel headers, point KHDR at the usr/include of a built tree, e.g.:
#
#   make CC=gcc KHDR=/path/to/kernel-build/usr/include
#
LIBDIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
KHDR ?=
CPPFLAGS += $(if $(KHDR),-I$(KHDR)) -I$(LIBDIR)
CFLAGS ?= -O2 -g -Wall -Wextra -Wno-unused-parameter
CFLAGS += -pthread
LDLIBS += -ldl -lpthread

all: test_rfmutex bench_rfmutex

test_rfmutex: $(LIBDIR)test_rfmutex.c $(LIBDIR)rfmutex.c $(LIBDIR)rfmutex.h
	$(CC) $(CPPFLAGS) $(CFLAGS) $(LDFLAGS) $(LIBDIR)test_rfmutex.c $(LIBDIR)rfmutex.c -o $@ $(LDLIBS)

bench_rfmutex: $(LIBDIR)../bench/bench_rfmutex.c $(LIBDIR)rfmutex.c $(LIBDIR)rfmutex.h
	$(CC) $(CPPFLAGS) $(CFLAGS) $(LDFLAGS) $(LIBDIR)../bench/bench_rfmutex.c $(LIBDIR)rfmutex.c -o $@ $(LDLIBS)

clean:
	rm -f test_rfmutex bench_rfmutex

.PHONY: all clean
