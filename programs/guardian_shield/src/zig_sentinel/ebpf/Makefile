# Makefile for Guardian Shield eBPF programs
# Compiles both syscall_counter and grimoire-oracle

CLANG := clang
BPFTOOL := bpftool
ARCH := $(shell uname -m | sed 's/x86_64/x86/' | sed 's/aarch64/arm64/')

BPF_CFLAGS := -target bpf -D__TARGET_ARCH_$(ARCH) -O2 -g -Wall

# syscall_counter uses <linux/bpf.h> + local shim headers in ./bpf/
SYSCALL_INCLUDES := -I. -I/usr/include -I/usr/include/$(shell uname -m)-linux-gnu

# grimoire-oracle uses vmlinux.h + system libbpf (no local shims)
GRIMOIRE_INCLUDES := -I/usr/include -I/usr/include/$(shell uname -m)-linux-gnu

PROGS := syscall_counter.bpf.o grimoire-oracle.bpf.o

.PHONY: all clean

all: $(PROGS)

syscall_counter.bpf.o: syscall_counter.bpf.c
	$(CLANG) $(BPF_CFLAGS) $(SYSCALL_INCLUDES) -c $< -o $@
	@echo "✓ Compiled: $@"

grimoire-oracle.bpf.o: grimoire-oracle.bpf.c vmlinux.h
	$(CLANG) $(BPF_CFLAGS) $(GRIMOIRE_INCLUDES) -c $< -o $@
	@echo "✓ Compiled: $@"

clean:
	rm -f *.bpf.o
	@echo "✓ Cleaned BPF objects"

install: all
	@echo "✓ BPF programs compiled and ready"
