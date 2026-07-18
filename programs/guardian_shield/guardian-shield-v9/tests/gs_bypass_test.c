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
// Vectors that need a destination or malicious source (move-out, clobber) place
// it in the protected dir's PARENT with a pid-unique name (gs_exfil_<pid>,
// gs_attacker_<pid>) and clean up after themselves. The parent is used, not
// /tmp, because rename()/renameat2() CANNOT cross filesystems: a cross-fs move
// returns EXDEV from the VFS *before* security_path_rename is ever consulted, so
// it would never reach the LSM. exfil-by-rename is inherently intra-filesystem
// (a cross-fs "move" is really copy+unlink, and the unlink/write vectors above
// already cover that), so the same-fs parent is the correct target for the
// rename hook.
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

#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
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

static const char *V_UNLINK    = "gs_victim_unlink";
static const char *V_UNLINKAT  = "gs_victim_unlinkat";
static const char *V_TRUNCATE  = "gs_victim_truncate";
static const char *V_IOURING   = "gs_victim_iouring";
static const char *V_RENAME    = "gs_victim_rename";
static const char *V_CREATE    = "gs_victim_create";
static const char *V_MOVEOUT   = "gs_victim_moveout";
static const char *V_CLOBBER   = "gs_victim_clobber";
static const char *V_OVERWRITE = "gs_victim_overwrite";

static int join(char *out, size_t n, const char *dir, const char *name) {
    int r = snprintf(out, n, "%s/%s", dir, name);
    return (r > 0 && (size_t)r < n) ? 0 : -1;
}

// Parent directory of `path` (strip trailing slash, then the last component).
// Used to place the rename move-out dest / clobber source on the SAME
// filesystem as the protected dir (rename can't cross filesystems -> EXDEV
// before the LSM). Falls back to "." if the parent would be empty.
static void parent_dir(const char *path, char *out, size_t n) {
    snprintf(out, n, "%s", path);
    size_t len = strlen(out);
    while (len > 1 && out[len - 1] == '/')   // strip trailing slashes (keep root)
        out[--len] = '\0';
    char *slash = strrchr(out, '/');
    if (!slash) {                            // no '/', relative name
        snprintf(out, n, ".");
    } else if (slash == out) {               // parent is root
        out[1] = '\0';
    } else {
        *slash = '\0';
    }
}

// True if errno indicates the LSM blocked us.
static bool is_blocked_errno(int e) { return e == EPERM || e == EACCES; }

// Remove any files matching a glob (best-effort cleanup of stale temp state).
static void clean_glob(const char *pattern) {
    glob_t g;
    if (glob(pattern, 0, NULL, &g) == 0) {
        for (size_t i = 0; i < g.gl_pathc; i++)
            unlink(g.gl_pathv[i]);
    }
    globfree(&g);
}

// ------------------------------------------------------------------
// setup: create the victim files (must run in a NON-agent context).
// ------------------------------------------------------------------
static int do_setup(const char *dir) {
    const char *names[] = {V_UNLINK, V_UNLINKAT, V_TRUNCATE, V_IOURING,
                           V_RENAME, V_MOVEOUT, V_CLOBBER, V_OVERWRITE};
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
    // Ensure stale rename / create targets from a prior run are gone.
    char moved[4096], created[4096], rn[4096];
    if (join(rn, sizeof(rn), dir, V_RENAME) == 0) {
        snprintf(moved, sizeof(moved), "%s.moved", rn);
        unlink(moved);
    }
    if (join(created, sizeof(created), dir, V_CREATE) == 0) unlink(created);
    // Pre-clean out-of-dir move targets + malicious temp sources from prior runs.
    clean_glob("/tmp/gs_exfil_*");
    clean_glob("/tmp/gs_attacker_*");
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

// Open a path for writing via openat2(2). If `content` is non-NULL and the open
// succeeds, the bytes are written (so the "success" path is unambiguously a
// completed overwrite/destruction, not just an opened handle). Returns 0 on a
// successful open (errno untouched), -1 on failure with errno set by the kernel.
static int sys_openat2_write(const char *path, unsigned long long extra_flags,
                             const char *content) {
    struct open_how how;
    memset(&how, 0, sizeof(how));
    how.flags = O_WRONLY | extra_flags;
    how.mode = (extra_flags & O_CREAT) ? 0644 : 0;
    long fd = syscall(__NR_openat2, AT_FDCWD, path, &how, sizeof(how));
    if (fd < 0) return -1; // errno set
    if (content) {
        ssize_t w = write((int)fd, content, strlen(content));
        (void)w;
    }
    close((int)fd);
    return 0;
}

// ------------------------------------------------------------------
// attack: run all vectors.
// ------------------------------------------------------------------
static int do_attack(const char *dir, enum expect exp) {
    char p_unlink[4096], p_unlinkat[4096], p_trunc[4096], p_iou[4096],
        p_rename[4096], p_rename_dst[4096], p_create[4096],
        p_moveout[4096], p_clobber[4096], p_overwrite[4096];
    if (join(p_unlink, sizeof(p_unlink), dir, V_UNLINK) ||
        join(p_unlinkat, sizeof(p_unlinkat), dir, V_UNLINKAT) ||
        join(p_trunc, sizeof(p_trunc), dir, V_TRUNCATE) ||
        join(p_iou, sizeof(p_iou), dir, V_IOURING) ||
        join(p_rename, sizeof(p_rename), dir, V_RENAME) ||
        join(p_create, sizeof(p_create), dir, V_CREATE) ||
        join(p_moveout, sizeof(p_moveout), dir, V_MOVEOUT) ||
        join(p_clobber, sizeof(p_clobber), dir, V_CLOBBER) ||
        join(p_overwrite, sizeof(p_overwrite), dir, V_OVERWRITE)) {
        fprintf(stderr, "attack: path too long\n");
        return 2;
    }
    snprintf(p_rename_dst, sizeof(p_rename_dst), "%s.moved", p_rename);

    // pid-unique out-of-tree paths for the move-out + clobber vectors.
    long pid = (long)getpid();
    char exfil_dst[4096], attacker_src[4096];
    snprintf(exfil_dst, sizeof(exfil_dst), "/tmp/gs_exfil_%ld", pid);
    snprintf(attacker_src, sizeof(attacker_src), "/tmp/gs_attacker_%ld", pid);

    printf("attack: dir=%s expect=%s\n", dir, exp == EXPECT_BLOCKED ? "blocked" : "allowed");
    int all_ok = 1;
    int rc, err;

    // ---- DELETE ----
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

    // 4. io_uring UNLINKAT
    errno = 0;
    rc = iouring_unlinkat(p_iou);
    err = errno;
    all_ok &= check("4.io_uring-unlinkat", rc, err, exp);

    // ---- OVERWRITE ----
    // 3. openat2 O_WRONLY|O_TRUNC + write (truncate then rewrite content)
    errno = 0;
    rc = sys_openat2_write(p_trunc, O_TRUNC, "X");
    err = errno;
    all_ok &= check("3.openat2-trunc-write", rc, err, exp);

    // 9. openat2 O_WRONLY (NO O_TRUNC/O_CREAT) + write -> in-place overwrite.
    // Proves the write-open itself is blocked, not merely O_TRUNC.
    errno = 0;
    rc = sys_openat2_write(p_overwrite, 0, "MALICIOUS\n");
    err = errno;
    all_ok &= check("9.openat2-overwrite", rc, err, exp);

    // 8. clobber: write malicious temp, then atomically rename it OVER the
    // protected file. Dest is protected -> gs_path_rename blocks on the NEW path.
    {
        int afd = open(attacker_src, O_WRONLY | O_CREAT | O_TRUNC, 0644);
        if (afd >= 0) {
            ssize_t w = write(afd, "MALICIOUS-OVERWRITE\n", 20);
            (void)w;
            close(afd);
        }
        errno = 0;
        rc = (int)syscall(SYS_renameat2, AT_FDCWD, attacker_src, AT_FDCWD, p_clobber, 0);
        err = errno;
        all_ok &= check("8.rename-clobber", rc, err, exp);
        unlink(attacker_src); // clean temp source regardless (no-op if it was moved)
    }

    // ---- MOVE-OUT (exfil) ----
    // 5. renameat2 within the protected dir (source protected).
    errno = 0;
    rc = (int)syscall(SYS_renameat2, AT_FDCWD, p_rename, AT_FDCWD, p_rename_dst, 0);
    err = errno;
    all_ok &= check("5.rename-within", rc, err, exp);

    // 7. renameat2 OUT of the protected tree to /tmp (source protected ->
    // gs_path_rename blocks on the OLD path). This is the exfil-by-move shape.
    unlink(exfil_dst); // ensure a clean destination
    errno = 0;
    rc = (int)syscall(SYS_renameat2, AT_FDCWD, p_moveout, AT_FDCWD, exfil_dst, 0);
    err = errno;
    all_ok &= check("7.rename-moveout", rc, err, exp);
    if (exp == EXPECT_ALLOWED) unlink(exfil_dst); // clean up the moved file

    // ---- CREATE ----
    // 6. openat2 O_CREAT + write (create a new file inside the protected dir)
    errno = 0;
    rc = sys_openat2_write(p_create, O_CREAT, "NEW\n");
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
