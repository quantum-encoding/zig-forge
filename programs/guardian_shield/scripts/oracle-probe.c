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


// Forges ground truth about which LSM hooks are viable


#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <time.h>
#include <bpf/libbpf.h>
#include <bpf/bpf.h>

#define MAX_HOOKS 256
#define MAX_HOOK_NAME 64
#define TEMPLATE_PATH "/home/founder/github_public/guardian-shield/oracle-probe-template.bpf.c"
#define REPORT_PATH "/home/founder/github_public/guardian-shield/oracle-report.txt"
#define WORK_DIR "/tmp/oracle-probe"

typedef enum {
    HOOK_UNKNOWN = 0,
    HOOK_LOAD_FAILED,
    HOOK_ATTACH_FAILED,
    HOOK_ATTACHED_NO_FIRE,
    HOOK_VIABLE
} hook_status_t;

typedef struct {
    char name[MAX_HOOK_NAME];
    hook_status_t status;
    int error_code;
    char error_msg[256];
} hook_result_t;

static hook_result_t results[MAX_HOOKS];
static int hook_count = 0;

// Forward declarations
static int extract_lsm_hooks(void);
static int test_hook(const char *hook_name, hook_result_t *result);
static int generate_bpf_source(const char *hook_name, char *out_path, size_t out_size);
static int compile_bpf_source(const char *src_path, const char *obj_path);
static int load_and_attach_bpf(const char *obj_path, const char *hook_name, hook_result_t *result);
static int check_hook_fired(const char *hook_name);
static void trigger_test_actions(void);
static void generate_report(void);
static void cleanup_work_dir(void);

// libbpf logging
static int libbpf_print_fn(enum libbpf_print_level level, const char *format, va_list args)
{
    if (level == LIBBPF_DEBUG)
        return 0;
    return vfprintf(stderr, format, args);
}

int main(int argc, char **argv)
{
    struct stat st;

    printf("═══════════════════════════════════════════════════════════\n");
    printf("   THE ORACLE PROBE - LSM Hook Reconnaissance Protocol\n");
    printf("═══════════════════════════════════════════════════════════\n\n");

    if (geteuid() != 0) {
        fprintf(stderr, "ERROR: Oracle Probe requires root privileges\n");
        return 1;
    }

    // Set up libbpf logging
    libbpf_set_print(libbpf_print_fn);

    // Create work directory
    if (stat(WORK_DIR, &st) == -1) {
        if (mkdir(WORK_DIR, 0755) == -1) {
            fprintf(stderr, "ERROR: Failed to create work directory: %s\n", strerror(errno));
            return 1;
        }
    }

    printf("[Phase 1] Extracting LSM hooks from BTF...\n");
    if (extract_lsm_hooks() < 0) {
        fprintf(stderr, "ERROR: Failed to extract LSM hooks\n");
        return 1;
    }
    printf("           Discovered %d LSM hooks\n\n", hook_count);

    printf("[Phase 2] Systematic hook testing...\n");
    for (int i = 0; i < hook_count; i++) {
        printf("  [%3d/%3d] Testing hook: %-30s ", i + 1, hook_count, results[i].name);
        fflush(stdout);

        test_hook(results[i].name, &results[i]);

        switch (results[i].status) {
            case HOOK_VIABLE:
                printf("✓ VIABLE\n");
                break;
            case HOOK_ATTACHED_NO_FIRE:
                printf("○ ATTACHED (no fire)\n");
                break;
            case HOOK_ATTACH_FAILED:
                printf("✗ ATTACH_FAIL (errno=%d)\n", results[i].error_code);
                break;
            case HOOK_LOAD_FAILED:
                printf("✗ LOAD_FAIL (errno=%d)\n", results[i].error_code);
                break;
            default:
                printf("? UNKNOWN\n");
                break;
        }
    }

    printf("\n[Phase 3] Generating reconnaissance report...\n");
    generate_report();
    printf("           Report: %s\n\n", REPORT_PATH);

    printf("═══════════════════════════════════════════════════════════\n");
    printf("   Oracle Probe Complete - Ground Truth Established\n");
    printf("═══════════════════════════════════════════════════════════\n");

    cleanup_work_dir();
    return 0;
}

static int extract_lsm_hooks(void)
{
    FILE *fp;
    char cmd[512];
    char line[256];
    char *start, *end;

    // Use bpftool to dump BTF and filter for bpf_lsm_ functions
    snprintf(cmd, sizeof(cmd),
             "bpftool btf dump file /sys/kernel/btf/vmlinux 2>/dev/null | "
             "grep \"FUNC 'bpf_lsm_\"");

    fp = popen(cmd, "r");
    if (!fp) {
        fprintf(stderr, "Failed to execute bpftool: %s\n", strerror(errno));
        return -1;
    }

    hook_count = 0;
    while (fgets(line, sizeof(line), fp) != NULL && hook_count < MAX_HOOKS) {
        // Line format: [72263] FUNC 'bpf_lsm_bprm_check_security' type_id=67429 linkage=static
        // Extract hook name between 'bpf_lsm_' and closing '
        start = strstr(line, "bpf_lsm_");
        if (!start) continue;

        start += 8; // Skip "bpf_lsm_"
        end = strchr(start, '\'');
        if (!end) continue;

        size_t len = end - start;
        if (len > 0 && len < MAX_HOOK_NAME) {
            strncpy(results[hook_count].name, start, len);
            results[hook_count].name[len] = '\0';
            results[hook_count].status = HOOK_UNKNOWN;
            results[hook_count].error_code = 0;
            results[hook_count].error_msg[0] = 0;
            hook_count++;
        }
    }

    pclose(fp);
    return hook_count > 0 ? 0 : -1;
}

static int test_hook(const char *hook_name, hook_result_t *result)
{
    char src_path[512];
    char obj_path[512];
    int ret;

    // Generate BPF source
    if (generate_bpf_source(hook_name, src_path, sizeof(src_path)) < 0) {
        result->status = HOOK_LOAD_FAILED;
        result->error_code = errno;
        snprintf(result->error_msg, sizeof(result->error_msg), "Failed to generate source");
        return -1;
    }

    // Compile BPF source
    snprintf(obj_path, sizeof(obj_path), "%s/oracle_%s.bpf.o", WORK_DIR, hook_name);
    if (compile_bpf_source(src_path, obj_path) < 0) {
        result->status = HOOK_LOAD_FAILED;
        result->error_code = errno;
        snprintf(result->error_msg, sizeof(result->error_msg), "Compilation failed");
        unlink(src_path);
        return -1;
    }

    // Load and attach BPF program
    ret = load_and_attach_bpf(obj_path, hook_name, result);

    // Cleanup
    unlink(src_path);
    unlink(obj_path);

    return ret;
}

static int generate_bpf_source(const char *hook_name, char *out_path, size_t out_size)
{
    FILE *template_fp, *out_fp;
    char line[512];
    char *pos;

    snprintf(out_path, out_size, "%s/oracle_%s.bpf.c", WORK_DIR, hook_name);

    template_fp = fopen(TEMPLATE_PATH, "r");
    if (!template_fp) {
        fprintf(stderr, "Failed to open template: %s\n", strerror(errno));
        return -1;
    }

    out_fp = fopen(out_path, "w");
    if (!out_fp) {
        fprintf(stderr, "Failed to create source file: %s\n", strerror(errno));
        fclose(template_fp);
        return -1;
    }

    // Read template and substitute HOOK_NAME
    while (fgets(line, sizeof(line), template_fp) != NULL) {
        // Replace all occurrences of HOOK_NAME
        char modified[1024];
        char *search_pos = line;
        char *dest = modified;
        int remaining = sizeof(modified);

        while ((pos = strstr(search_pos, "HOOK_NAME")) != NULL) {
            int prefix_len = pos - search_pos;
            if (prefix_len + strlen(hook_name) >= remaining) break;

            strncpy(dest, search_pos, prefix_len);
            dest += prefix_len;
            remaining -= prefix_len;

            strncpy(dest, hook_name, remaining);
            dest += strlen(hook_name);
            remaining -= strlen(hook_name);

            search_pos = pos + 9; // strlen("HOOK_NAME")
        }

        if (remaining > 0) {
            strncpy(dest, search_pos, remaining - 1);
            dest[remaining - 1] = 0;
        }

        fputs(modified, out_fp);
    }

    fclose(template_fp);
    fclose(out_fp);
    return 0;
}

static int compile_bpf_source(const char *src_path, const char *obj_path)
{
    char cmd[1024];
    int ret;

    snprintf(cmd, sizeof(cmd),
             "clang -target bpf -D__TARGET_ARCH_x86 -O2 -g -Wall "
             "-I/usr/include -I/usr/include/x86_64-linux-gnu "
             "-c %s -o %s 2>/dev/null",
             src_path, obj_path);

    ret = system(cmd);
    if (WIFEXITED(ret)) {
        return WEXITSTATUS(ret) == 0 ? 0 : -1;
    }
    return -1;
}

static int load_and_attach_bpf(const char *obj_path, const char *hook_name, hook_result_t *result)
{
    struct bpf_object *obj = NULL;
    struct bpf_program *prog = NULL;
    struct bpf_link *link = NULL;
    int ret = -1;

    // Open BPF object
    obj = bpf_object__open(obj_path);
    if (!obj) {
        result->status = HOOK_LOAD_FAILED;
        result->error_code = errno;
        snprintf(result->error_msg, sizeof(result->error_msg), "bpf_object__open failed");
        return -1;
    }

    // Load BPF object
    if (bpf_object__load(obj)) {
        result->status = HOOK_LOAD_FAILED;
        result->error_code = errno;
        snprintf(result->error_msg, sizeof(result->error_msg), "bpf_object__load failed");
        goto cleanup;
    }

    // Find the program
    prog = bpf_object__find_program_by_name(obj, hook_name);
    if (!prog) {
        // Try with oracle_ prefix
        char prog_name[128];
        snprintf(prog_name, sizeof(prog_name), "oracle_%s", hook_name);
        prog = bpf_object__find_program_by_name(obj, prog_name);
    }

    if (!prog) {
        result->status = HOOK_LOAD_FAILED;
        result->error_code = ENOENT;
        snprintf(result->error_msg, sizeof(result->error_msg), "Program not found in object");
        goto cleanup;
    }

    // Attach LSM hook
    link = bpf_program__attach_lsm(prog);
    if (!link) {
        result->status = HOOK_ATTACH_FAILED;
        result->error_code = errno;
        snprintf(result->error_msg, sizeof(result->error_msg), "bpf_program__attach_lsm failed");
        goto cleanup;
    }

    // Hook attached successfully - now test if it fires
    // Clear dmesg first (best effort)
    system("dmesg -C 2>/dev/null");

    // Wait a moment for attachment to stabilize
    usleep(100000); // 100ms

    // Trigger test actions
    trigger_test_actions();

    // Wait for events to propagate
    usleep(500000); // 500ms

    // Check if hook fired
    if (check_hook_fired(hook_name) > 0) {
        result->status = HOOK_VIABLE;
        snprintf(result->error_msg, sizeof(result->error_msg), "Hook confirmed firing");
        ret = 0;
    } else {
        result->status = HOOK_ATTACHED_NO_FIRE;
        snprintf(result->error_msg, sizeof(result->error_msg), "Attached but no fire detected");
        ret = 0; // Not an error, just no fire
    }

    bpf_link__destroy(link);

cleanup:
    if (obj)
        bpf_object__close(obj);
    return ret;
}

static int check_hook_fired(const char *hook_name)
{
    FILE *fp;
    char cmd[512];
    char line[256];
    int count = 0;

    snprintf(cmd, sizeof(cmd),
             "dmesg | grep -c 'ORACLE_FIRE:%s' 2>/dev/null || echo 0",
             hook_name);

    fp = popen(cmd, "r");
    if (!fp) return 0;

    if (fgets(line, sizeof(line), fp) != NULL) {
        count = atoi(line);
    }

    pclose(fp);
    return count;
}

static void trigger_test_actions(void)
{
    // Fork a child process to trigger various LSM hooks
    pid_t pid = fork();

    if (pid == 0) {
        // Child process - perform actions that might trigger hooks

        // File operations
        int fd = open("/etc/passwd", O_RDONLY);
        if (fd >= 0) close(fd);

        // Try to exec something benign
        char *args[] = {"/bin/true", NULL};
        execve("/bin/true", args, NULL);

        // If exec fails, exit
        exit(0);
    } else if (pid > 0) {
        // Parent - wait for child
        int status;
        waitpid(pid, &status, 0);
    }

    // Also trigger actions in parent
    int fd = open("/tmp/oracle-test", O_CREAT | O_WRONLY | O_TRUNC, 0644);
    if (fd >= 0) {
        write(fd, "test", 4);
        close(fd);
        unlink("/tmp/oracle-test");
    }
}

static void generate_report(void)
{
    FILE *fp;
    int viable_count = 0;
    int attached_no_fire = 0;
    int attach_failed = 0;
    int load_failed = 0;

    fp = fopen(REPORT_PATH, "w");
    if (!fp) {
        fprintf(stderr, "Failed to create report: %s\n", strerror(errno));
        return;
    }

    fprintf(fp, "═══════════════════════════════════════════════════════════════════\n");
    fprintf(fp, "  THE ORACLE PROTOCOL - LSM Hook Reconnaissance Report\n");
    fprintf(fp, "═══════════════════════════════════════════════════════════════════\n");
    fprintf(fp, "Generated: %s", ctime(&(time_t){time(NULL)}));
    fprintf(fp, "Kernel: Linux 6.17.1-arch1-1\n");
    fprintf(fp, "Total Hooks Tested: %d\n\n", hook_count);

    // Count statistics
    for (int i = 0; i < hook_count; i++) {
        switch (results[i].status) {
            case HOOK_VIABLE: viable_count++; break;
            case HOOK_ATTACHED_NO_FIRE: attached_no_fire++; break;
            case HOOK_ATTACH_FAILED: attach_failed++; break;
            case HOOK_LOAD_FAILED: load_failed++; break;
            default: break;
        }
    }

    fprintf(fp, "SUMMARY STATISTICS:\n");
    fprintf(fp, "-------------------------------------------------------------------\n");
    fprintf(fp, "  VIABLE (confirmed firing):    %3d hooks\n", viable_count);
    fprintf(fp, "  ATTACHED (no fire detected):  %3d hooks\n", attached_no_fire);
    fprintf(fp, "  ATTACH_FAILED:                %3d hooks\n", attach_failed);
    fprintf(fp, "  LOAD_FAILED:                  %3d hooks\n", load_failed);
    fprintf(fp, "\n");

    // Viable hooks
    fprintf(fp, "═══════════════════════════════════════════════════════════════════\n");
    fprintf(fp, "VIABLE HOOKS (Confirmed Firing)\n");
    fprintf(fp, "═══════════════════════════════════════════════════════════════════\n");
    for (int i = 0; i < hook_count; i++) {
        if (results[i].status == HOOK_VIABLE) {
            fprintf(fp, "  ✓ %s\n", results[i].name);
        }
    }
    fprintf(fp, "\n");

    // Attached but no fire
    fprintf(fp, "═══════════════════════════════════════════════════════════════════\n");
    fprintf(fp, "ATTACHED HOOKS (No Fire Detected)\n");
    fprintf(fp, "═══════════════════════════════════════════════════════════════════\n");
    fprintf(fp, "These hooks attach successfully but did not fire during testing.\n");
    fprintf(fp, "They may require specific conditions or may be inactive.\n\n");
    for (int i = 0; i < hook_count; i++) {
        if (results[i].status == HOOK_ATTACHED_NO_FIRE) {
            fprintf(fp, "  ○ %s\n", results[i].name);
        }
    }
    fprintf(fp, "\n");

    // Failed hooks
    fprintf(fp, "═══════════════════════════════════════════════════════════════════\n");
    fprintf(fp, "FAILED HOOKS (Load or Attach Failures)\n");
    fprintf(fp, "═══════════════════════════════════════════════════════════════════\n");
    for (int i = 0; i < hook_count; i++) {
        if (results[i].status == HOOK_ATTACH_FAILED || results[i].status == HOOK_LOAD_FAILED) {
            fprintf(fp, "  ✗ %-30s [errno=%d] %s\n",
                    results[i].name, results[i].error_code, results[i].error_msg);
        }
    }
    fprintf(fp, "\n");

    // Recommendations
    fprintf(fp, "═══════════════════════════════════════════════════════════════════\n");
    fprintf(fp, "RECOMMENDATIONS FOR PROCESS EXECUTION INTERCEPTION\n");
    fprintf(fp, "═══════════════════════════════════════════════════════════════════\n");
    fprintf(fp, "Based on reconnaissance, the following hooks are recommended:\n\n");

    // Look for process-related hooks
    const char *exec_hooks[] = {"bprm_check_security", "bprm_committed_creds",
                                 "bprm_committing_creds", "task_alloc", "task_fix_setuid"};
    const char *file_hooks[] = {"file_open", "file_permission", "mmap_file"};

    fprintf(fp, "Process Execution Hooks:\n");
    for (int i = 0; i < sizeof(exec_hooks)/sizeof(exec_hooks[0]); i++) {
        for (int j = 0; j < hook_count; j++) {
            if (strcmp(results[j].name, exec_hooks[i]) == 0) {
                if (results[j].status == HOOK_VIABLE) {
                    fprintf(fp, "  ✓ RECOMMENDED: %s (confirmed viable)\n", results[j].name);
                } else {
                    fprintf(fp, "  ○ ALTERNATIVE: %s (status: ", results[j].name);
                    switch (results[j].status) {
                        case HOOK_ATTACHED_NO_FIRE: fprintf(fp, "attached, no fire)\n"); break;
                        case HOOK_ATTACH_FAILED: fprintf(fp, "attach failed)\n"); break;
                        case HOOK_LOAD_FAILED: fprintf(fp, "load failed)\n"); break;
                        default: fprintf(fp, "unknown)\n"); break;
                    }
                }
                break;
            }
        }
    }

    fprintf(fp, "\nFile-based Execution Detection:\n");
    for (int i = 0; i < sizeof(file_hooks)/sizeof(file_hooks[0]); i++) {
        for (int j = 0; j < hook_count; j++) {
            if (strcmp(results[j].name, file_hooks[i]) == 0) {
                if (results[j].status == HOOK_VIABLE) {
                    fprintf(fp, "  ✓ RECOMMENDED: %s (confirmed viable)\n", results[j].name);
                }
                break;
            }
        }
    }

    fprintf(fp, "\n");
    fprintf(fp, "═══════════════════════════════════════════════════════════════════\n");
    fprintf(fp, "END OF REPORT\n");
    fprintf(fp, "═══════════════════════════════════════════════════════════════════\n");

    fclose(fp);
}

static void cleanup_work_dir(void)
{
    char cmd[512];
    snprintf(cmd, sizeof(cmd), "rm -f %s/oracle_* 2>/dev/null", WORK_DIR);
    system(cmd);
}
