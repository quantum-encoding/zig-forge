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
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <bpf/libbpf.h>
#include <bpf/bpf.h>
#include <linux/types.h>

int main(void) {
    const char *obj_path = "/home/founder/github_public/guardian-shield/src/zig-sentinel/ebpf/inquisitor-simple.bpf.o";

    printf("Loading BPF object: %s\n", obj_path);

    struct bpf_object *obj = bpf_object__open(obj_path);
    if (!obj) {
        fprintf(stderr, "Failed to open BPF object\n");
        return 1;
    }

    // Find the LSM program
    struct bpf_program *prog = bpf_object__find_program_by_name(obj, "inquisitor_bprm_check");
    if (!prog) {
        fprintf(stderr, "Failed to find program\n");
        bpf_object__close(obj);
        return 1;
    }

    // Check the program type
    enum bpf_prog_type type = bpf_program__type(prog);
    printf("Program type: %d (BPF_PROG_TYPE_LSM = %d)\n", type, BPF_PROG_TYPE_LSM);

    // Load the object
    if (bpf_object__load(obj) != 0) {
        fprintf(stderr, "Failed to load object\n");
        bpf_object__close(obj);
        return 1;
    }

    printf("Object loaded successfully\n");

    int prog_fd = bpf_program__fd(prog);
    printf("Program FD: %d\n", prog_fd);

    // Try to attach using LSM-specific attach function
    printf("Attempting to attach LSM program using bpf_program__attach_lsm()...\n");

    // Clear errno before attach
    errno = 0;
    struct bpf_link *link = bpf_program__attach_lsm(prog);
    int attach_errno = errno;

    printf("attach returned: %p, errno: %d (%s)\n", link, attach_errno, strerror(attach_errno));

    if (!link) {
        fprintf(stderr, "Failed to attach LSM: %m\n");
        bpf_object__close(obj);
        return 1;
    }

    printf("✓ Attach succeeded! Link created.\n");

    // Try to get link info
    int link_fd = bpf_link__fd(link);
    printf("Link FD: %d\n", link_fd);

    // Get link ID
    struct bpf_link_info info = {};
    __u32 info_len = sizeof(info);
    if (bpf_obj_get_info_by_fd(link_fd, &info, &info_len) == 0) {
        printf("Link ID: %u\n", info.id);
        printf("Link type: %u\n", info.type);
        printf("Link prog_id: %u\n", info.prog_id);
    } else {
        printf("Failed to get link info: %m\n");
    }

    // Get the maps
    struct bpf_map *blacklist_map = bpf_object__find_map_by_name(obj, "blacklist_map");
    struct bpf_map *config_map = bpf_object__find_map_by_name(obj, "config_map");

    if (!blacklist_map || !config_map) {
        fprintf(stderr, "Failed to find maps\n");
        bpf_link__destroy(link);
        bpf_object__close(obj);
        return 1;
    }

    int blacklist_fd = bpf_map__fd(blacklist_map);
    int config_fd = bpf_map__fd(config_map);

    printf("Blacklist FD: %d, Config FD: %d\n", blacklist_fd, config_fd);

    // Configure enforcement mode (1 = enforce)
    __u32 key = 0;
    __u32 value = 1;
    if (bpf_map_update_elem(config_fd, &key, &value, BPF_ANY) != 0) {
        fprintf(stderr, "Failed to set enforcement mode\n");
    } else {
        printf("✓ Enforcement mode: ENFORCE\n");
    }

    // Configure logging (1 = log all)
    key = 1;
    value = 1;
    if (bpf_map_update_elem(config_fd, &key, &value, BPF_ANY) != 0) {
        fprintf(stderr, "Failed to set log mode\n");
    } else {
        printf("✓ Log mode: LOG ALL\n");
    }

    // Add test-target to blacklist
    struct {
        char pattern[64];
        __u8 exact_match;
        __u8 enabled;
        __u16 reserved;
    } entry = {0};

    strcpy(entry.pattern, "test-target");
    entry.exact_match = 1;
    entry.enabled = 1;

    key = 0;
    if (bpf_map_update_elem(blacklist_fd, &key, &entry, BPF_ANY) != 0) {
        fprintf(stderr, "Failed to add blacklist entry\n");
    } else {
        printf("✓ Blacklisted: 'test-target' (exact match)\n");
    }

    printf("\nInquisitor is now ACTIVE and ENFORCING!\n");
    printf("Try to execute './test-target' in another terminal\n");
    printf("Sleeping for 30 seconds...\n");
    sleep(30);

    bpf_link__destroy(link);
    bpf_object__close(obj);
    return 0;
}
