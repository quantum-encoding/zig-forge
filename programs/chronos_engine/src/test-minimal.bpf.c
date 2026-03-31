// Minimal eBPF test - just count write syscalls
#include "../zig-sentinel/ebpf/vmlinux.h"
#include "../zig-sentinel/ebpf/bpf/bpf_helpers.h"

struct {
    __uint(type, BPF_MAP_TYPE_ARRAY);
    __uint(max_entries, 1);
    __type(key, __u32);
    __type(value, __u64);
} test_counter SEC(".maps");

SEC("tracepoint/syscalls/sys_enter_write")
int test_write(struct trace_event_raw_sys_enter *ctx)
{
    __u32 key = 0;
    __u64 *counter = bpf_map_lookup_elem(&test_counter, &key);
    if (counter) {
        __sync_fetch_and_add(counter, 1);
    }
    return 0;
}

char LICENSE[] SEC("license") = "GPL";
