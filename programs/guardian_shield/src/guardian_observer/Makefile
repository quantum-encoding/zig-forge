# Guardian Observer Makefile

CC = clang
CFLAGS = -O2 -g -Wall
BPF_CFLAGS = -g -target bpf -D__TARGET_ARCH_x86 -I/usr/include/bpf

LIBBPF = -lbpf
INCLUDES = -I/usr/include

TARGETS = guardian-observer guardian-observer.bpf.o

all: $(TARGETS)

# Compile eBPF program
guardian-observer.bpf.o: guardian-observer.bpf.c
	$(CC) $(BPF_CFLAGS) -c $< -o $@

# Compile userspace program
guardian-observer: guardian-observer.c guardian-judge.c guardian-observer.bpf.o
	$(CC) $(CFLAGS) $(INCLUDES) -o $@ guardian-observer.c guardian-judge.c $(LIBBPF)

clean:
	rm -f $(TARGETS)

install: all
	sudo cp guardian-observer /usr/local/bin/
	sudo cp guardian-observer.bpf.o /usr/local/lib/
	sudo setcap cap_bpf,cap_perfmon,cap_net_admin,cap_sys_resource=eip /usr/local/bin/guardian-observer

.PHONY: all clean install
