/* SPDX-License-Identifier: (LGPL-2.1 OR BSD-2-Clause) */
/*
 * bpf_core_read.h - BPF CO-RE (Compile Once - Run Everywhere) macros
 *
 * Minimal version for Grimoire BPF compilation.
 */

#ifndef __BPF_CORE_READ_H
#define __BPF_CORE_READ_H

/* CO-RE field access (simplified - no actual CO-RE relocation) */
#define BPF_CORE_READ(dst, sz, src) \
    bpf_probe_read_kernel(dst, sz, (const void *)(src))

/* Preserve access index (for CO-RE) */
#ifndef __bpf__
#define __bpf__
#endif

/* BPF CO-RE type ID (stub) */
#define bpf_core_type_id_kernel(type) 0

#endif /* __BPF_CORE_READ_H */
