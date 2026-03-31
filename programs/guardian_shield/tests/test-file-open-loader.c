// SPDX-License-Identifier: GPL-2.0
/*
 * Guardian Shield - eBPF-based System Security Framework
 *
 * Copyright (c) 2025 Richard Tune / Quantum Encoding Ltd
 * Author: Richard Tune
 * Contact: info@quantumencoding.io
 * Website: https://quantumencoding.io
 *
 * License: Dual License - MIT (Non-Commercial) / Commercial License
 *
 * NON-COMMERCIAL USE (MIT License):
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction for NON-COMMERCIAL purposes, including
 * without limitation the rights to use, copy, modify, merge, publish, distribute,
 * sublicense, and/or sell copies of the Software for non-commercial purposes,
 * and to permit persons to whom the Software is furnished to do so, subject to
 * the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in all
 * copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 * SOFTWARE.
 *
 * COMMERCIAL USE:
 * Commercial use of this software requires a separate commercial license.
 * Contact info@quantumencoding.io for commercial licensing terms.
 */


#include <stdio.h>

#include <unistd.h>
#include <bpf/libbpf.h>
#include <bpf/bpf.h>

int main(void) {
    struct bpf_object *obj = bpf_object__open("src/zig-sentinel/ebpf/test-file-open.bpf.o");
    if (!obj) {
        printf("Failed to open\n");
        return 1;
    }

    if (bpf_object__load(obj) != 0) {
        printf("Failed to load\n");
        return 1;
    }

    struct bpf_program *prog = bpf_object__find_program_by_name(obj, "test_file_open");
    if (!prog) {
        printf("Failed to find program\n");
        return 1;
    }

    struct bpf_link *link = bpf_program__attach_lsm(prog);
    if (!link) {
        printf("Failed to attach\n");
        return 1;
    }

    printf("✓ file_open LSM hook attached\n");
    printf("Now open any file and check: sudo dmesg | grep FILE_OPEN\n");
    printf("Sleeping for 15 seconds...\n");
    sleep(15);

    bpf_link__destroy(link);
    bpf_object__close(obj);
    return 0;
}
