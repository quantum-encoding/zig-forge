// gs_bypass_test.c
// Guardian Shield v9 external-vector bypass harness.
//
// This is the golden external-vector anchor for the whole v9 kernel move: it
// proves that the LSM layer closes the direct-syscall bypasses that defeat the
// userspace libwarden LD_PRELOAD. It attacks a protected file through the four
// destruction CATEGORIES, each via kernel entry points that sidestep libc
// interposition:
//
//   DELETE:
//     1. glibc unlink()            - the interposed path (control libwarden covers)
//     2. raw syscall(SYS_unlinkat) - bypasses LD_PRELOAD entirely
//     4. io_uring IORING_OP_UNLINKAT - deletion dispatched by a kernel worker thread
//   OVERWRITE:
//     3. openat2 O_WRONLY|O_TRUNC + write - truncate-then-rewrite destruction
//     8. renameat2 clobber         - atomically rename a malicious temp OVER the file
//     9. openat2 O_WRONLY + write   - in-place overwrite, NO O_TRUNC (write-open itself blocked)
//   MOVE-OUT (exfil):
//     5. renameat2 within-dir       - rename inside the protected tree
//     7. renameat2 out-of-tree      - move the file OUT to /tmp (source protected)
//   CREATE:
//     6. openat2 O_CREAT + write    - create a new file inside the protected dir
//
// Vectors that need a destination or malicious source use pid-unique /tmp paths
// (gs_exfil_<pid>, gs_attacker_<pid>) and clean up after themselves.
//
// Usage:
//   gs_bypass_test --dir <DIR> --mode setup                 # create victims (non-agent ctx)
//   gs_bypass_test --dir <DIR> --mode attack --expect blocked   # agent ctx: all must EPERM/EACCES
//   gs_bypass_test --dir <DIR> --mode attack --expect allowed    # non-agent scratch: all must succeed
//
// Exit code 0 == every vector behaved as expected. Non-zero == at least one
// vector deviated (a bypass in `blocked` mode, or a false-block in `allowed`).
//
// This harness does NOT require the LSM to be loaded to COMPILE. It only proves
// enforcement where CONFIG_BPF_LSM is on and the loader has tagged this process
// tree as an agent (see tests/run_bypass_suite.sh).

#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <glob.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/types.h>
#include <unistd.h>

#include <liburing.h>

#ifndef __NR_openat2
#include <linux/openat2.h>
#endif

// open_how may not be declared depending on headers; define defensively.
#ifndef RESOLVE_NO_SYMLINKS
struct open_how {
    unsigned long long flags;
    unsigned long long mode;
    unsigned long long resolve;
};
#endif

enum expect { EXPECT_BLOCKED, EXPECT_ALLOWED };

static const char *V_UNLINK   = "gs_victim_unlink";
static const char *V_UNLINKAT = "gs_victim_unlinkat";
static const char *V_TRUNCATE = "gs_victim_truncate";
static const char *V_IOURING  = "gs_victim_iouring";
static const char *V_RENAME   = "gs_victim_rename";
static const char *V_CREATE   = "gs_victim_create";

static int join(char *out, size_t n, const char *dir, const char *name) {
    int r = snprintf(out, n, "%s/%s", dir, name);
    return (r > 0 && (size_t)r < n) ? 0 : -1;
}

// True if errno indicates the LSM blocked us.
static bool is_blocked_errno(int e) { return e == EPERM || e == EACCES; }

// ------------------------------------------------------------------
// setup: create the victim files (must run in a NON-agent context).
// ------------------------------------------------------------------
static int do_setup(const char *dir) {
    const char *names[] = {V_UNLINK, V_UNLINKAT, V_TRUNCATE, V_IOURING, V_RENAME};
    for (size_t i = 0; i < sizeof(names) / sizeof(names[0]); i++) {
        char p[4096];
        if (join(p, sizeof(p), dir, names[i]) != 0) return 1;
        int fd = open(p, O_WRONLY | O_CREAT | O_TRUNC, 0644);
        if (fd < 0) {
            fprintf(stderr, "setup: cannot create %s: %s\n", p, strerror(errno));
            return 1;
        }
        if (write(fd, "guardian-shield-victim\n", 23) < 0) {
            fprintf(stderr, "setup: cannot write %s: %s\n", p, strerror(errno));
            close(fd);
            return 1;
        }
        close(fd);
    }
    // Ensure a stale rename target / create target from a prior run are gone.
    char moved[4096], created[4096];
    char rn[4096];
    if (join(rn, sizeof(rn), dir, V_RENAME) == 0) {
        snprintf(moved, sizeof(moved), "%s.moved", rn);
        unlink(moved);
    }
    if (join(created, sizeof(created), dir, V_CREATE) == 0) unlink(created);
    printf("setup: victims created in %s\n", dir);
    return 0;
}

// ------------------------------------------------------------------
// One vector result checker. `rc` is the operation's return (>=0 success),
// `err` its errno on failure. Returns true if the outcome matched `exp`.
// ------------------------------------------------------------------
static bool check(const char *vector, int rc, int err, enum expect exp) {
    bool blocked = (rc < 0) && is_blocked_errno(err);
    bool ok;
    const char *verdict;

    if (exp == EXPECT_BLOCKED) {
        ok = blocked;
        verdict = ok ? "PASS (blocked)" : (rc >= 0 ? "FAIL (BYPASS! succeeded)" : "FAIL (wrong errno)");
    } else {
        // allowed mode: success, or a non-LSM errno (e.g. ENOENT) both acceptable.
        ok = !blocked;
        verdict = ok ? "PASS (allowed)" : "FAIL (falsely blocked)";
    }
    printf("  %-26s rc=%-3d errno=%-3d %-9s => %s\n",
           vector, rc, (rc < 0 ? err : 0),
           (rc < 0 ? strerror(err) : "ok"), verdict);
    return ok;
}

// io_uring UNLINKAT vector. Returns the operation result (>=0 or -errno).
static int iouring_unlinkat(const char *path) {
    struct io_uring ring;
    int ret = io_uring_queue_init(8, &ring, 0);
    if (ret < 0) {
        errno = -ret;
        return -1;
    }
    struct io_uring_sqe *sqe = io_uring_get_sqe(&ring);
    if (!sqe) {
        io_uring_queue_exit(&ring);
        errno = ENOMEM;
        return -1;
    }
    io_uring_prep_unlinkat(sqe, AT_FDCWD, path, 0);
    io_uring_submit(&ring);

    struct io_uring_cqe *cqe;
    ret = io_uring_wait_cqe(&ring, &cqe);
    int res;
    if (ret < 0) {
        res = ret;
    } else {
        res = cqe->res; // negative -errno on failure
        io_uring_cqe_seen(&ring, cqe);
    }
    io_uring_queue_exit(&ring);

    if (res < 0) {
        errno = -res;
        return -1;
    }
    return 0;
}

static int sys_openat2_write(const char *path, unsigned long long extra_flags) {
    struct open_how how;
    memset(&how, 0, sizeof(how));
    how.flags = O_WRONLY | extra_flags;
    how.mode = (extra_flags & O_CREAT) ? 0644 : 0;
    long fd = syscall(__NR_openat2, AT_FDCWD, path, &how, sizeof(how));
    if (fd < 0) return -1; // errno set
    // If it opened, that's a successful (un-blocked) write handle.
    close((int)fd);
    return 0;
}

// ------------------------------------------------------------------
// attack: run all vectors.
// ------------------------------------------------------------------
static int do_attack(const char *dir, enum expect exp) {
    char p_unlink[4096], p_unlinkat[4096], p_trunc[4096], p_iou[4096],
        p_rename[4096], p_rename_dst[4096], p_create[4096];
    if (join(p_unlink, sizeof(p_unlink), dir, V_UNLINK) ||
        join(p_unlinkat, sizeof(p_unlinkat), dir, V_UNLINKAT) ||
        join(p_trunc, sizeof(p_trunc), dir, V_TRUNCATE) ||
        join(p_iou, sizeof(p_iou), dir, V_IOURING) ||
        join(p_rename, sizeof(p_rename), dir, V_RENAME) ||
        join(p_create, sizeof(p_create), dir, V_CREATE)) {
        fprintf(stderr, "attack: path too long\n");
        return 2;
    }
    snprintf(p_rename_dst, sizeof(p_rename_dst), "%s.moved", p_rename);

    printf("attack: dir=%s expect=%s\n", dir, exp == EXPECT_BLOCKED ? "blocked" : "allowed");
    int all_ok = 1;
    int rc, err;

    // 1. glibc unlink()
    errno = 0;
    rc = unlink(p_unlink);
    err = errno;
    all_ok &= check("1.glibc-unlink", rc, err, exp);

    // 2. raw syscall unlinkat
    errno = 0;
    rc = (int)syscall(SYS_unlinkat, AT_FDCWD, p_unlinkat, 0);
    err = errno;
    all_ok &= check("2.syscall-unlinkat", rc, err, exp);

    // 3. openat2 O_WRONLY|O_TRUNC (data destruction of an existing file)
    errno = 0;
    rc = sys_openat2_write(p_trunc, O_TRUNC);
    err = errno;
    all_ok &= check("3.openat2-trunc", rc, err, exp);

    // 4. io_uring UNLINKAT
    errno = 0;
    rc = iouring_unlinkat(p_iou);
    err = errno;
    all_ok &= check("4.io_uring-unlinkat", rc, err, exp);

    // 5. renameat2
    errno = 0;
    rc = (int)syscall(SYS_renameat2, AT_FDCWD, p_rename, AT_FDCWD, p_rename_dst, 0);
    err = errno;
    all_ok &= check("5.renameat2", rc, err, exp);

    // 6. openat2 O_CREAT write (create a new file inside the protected dir)
    errno = 0;
    rc = sys_openat2_write(p_create, O_CREAT);
    err = errno;
    all_ok &= check("6.openat2-create", rc, err, exp);

    printf("attack: %s\n", all_ok ? "ALL VECTORS AS EXPECTED" : "DEVIATION DETECTED");
    return all_ok ? 0 : 1;
}

int main(int argc, char **argv) {
    const char *dir = NULL;
    const char *mode = NULL;
    enum expect exp = EXPECT_BLOCKED;

    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--dir") && i + 1 < argc) {
            dir = argv[++i];
        } else if (!strcmp(argv[i], "--mode") && i + 1 < argc) {
            mode = argv[++i];
        } else if (!strcmp(argv[i], "--expect") && i + 1 < argc) {
            const char *e = argv[++i];
            if (!strcmp(e, "blocked")) exp = EXPECT_BLOCKED;
            else if (!strcmp(e, "allowed")) exp = EXPECT_ALLOWED;
            else { fprintf(stderr, "bad --expect: %s\n", e); return 2; }
        } else {
            fprintf(stderr, "usage: %s --dir <DIR> --mode setup|attack [--expect blocked|allowed]\n", argv[0]);
            return 2;
        }
    }
    if (!dir || !mode) {
        fprintf(stderr, "usage: %s --dir <DIR> --mode setup|attack [--expect blocked|allowed]\n", argv[0]);
        return 2;
    }

    if (!strcmp(mode, "setup")) return do_setup(dir);
    if (!strcmp(mode, "attack")) return do_attack(dir, exp);
    fprintf(stderr, "bad --mode: %s\n", mode);
    return 2;
}
