//! zmktemp - Create temporary file or directory
//!
//! Safely create a temporary file or directory with a unique name.
//! Behaviour mirrors GNU coreutils `mktemp` (see gnu_parity_test.zig).

const std = @import("std");
const posix = std.posix;
const libc = std.c;

const VERSION = "1.0.0";

extern "c" fn arc4random_buf(buf: [*]u8, nbytes: usize) void;
extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;

const Config = struct {
    directory: bool = false,
    dry_run: bool = false,
    quiet: bool = false,
    tmpdir: ?[]const u8 = null,
    tmpdir_given: bool = false, // -p / --tmpdir was passed
    use_tmpdir_prefix: bool = false, // -t was passed
    suffix: ?[]const u8 = null, // --suffix value (explicit)
    template: []const u8 = "tmp.XXXXXXXXXX",
    template_given: bool = false,
};

fn writeStdout(data: []const u8) void {
    _ = libc.write(libc.STDOUT_FILENO, data.ptr, data.len);
}

fn writeStderr(data: []const u8) void {
    _ = libc.write(libc.STDERR_FILENO, data.ptr, data.len);
}

fn printUsage() void {
    const usage =
        \\Usage: zmktemp [OPTION]... [TEMPLATE]
        \\Create a temporary file or directory, safely, and print its name.
        \\
        \\TEMPLATE must contain at least 3 consecutive 'X's in last component.
        \\If TEMPLATE is not specified, tmp.XXXXXXXXXX is used, and --tmpdir is
        \\implied. Files are created u+rw, and directories u+rwx, minus umask
        \\restrictions.
        \\
        \\Options:
        \\  -d, --directory       Create a directory, not a file
        \\  -u, --dry-run         Do not create anything; print name only
        \\  -q, --quiet           Suppress diagnostics about errors
        \\  -p DIR, --tmpdir[=DIR]  Interpret TEMPLATE relative to DIR (default: $TMPDIR or /tmp)
        \\  -t                    Interpret TEMPLATE relative to $TMPDIR
        \\      --suffix=SUFF     Append SUFF to TEMPLATE (must not contain a slash)
        \\      --help            Display this help and exit
        \\      --version         Output version information and exit
        \\
    ;
    // GNU writes --help/--version to stdout.
    writeStdout(usage);
}

fn printVersion() void {
    writeStdout("zmktemp " ++ VERSION ++ "\n");
}

fn getTmpDir() []const u8 {
    if (getenv("TMPDIR")) |val| {
        const s = std.mem.span(val);
        if (s.len > 0) return s;
    }
    return "/tmp";
}

/// Fill `out` with `n` random alphanumeric characters, using rejection
/// sampling so the 62-char alphabet is unbiased (256 mod 62 = 8).
fn fillRandom(out: []u8) void {
    const chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
    // Largest multiple of 62 that fits in a byte: 62*4 = 248. Reject >= 248.
    const limit: u8 = 248;
    var i: usize = 0;
    var pool: [64]u8 = undefined;
    var pool_len: usize = 0;
    var pool_pos: usize = 0;
    while (i < out.len) {
        if (pool_pos >= pool_len) {
            arc4random_buf(&pool, pool.len);
            pool_len = pool.len;
            pool_pos = 0;
        }
        const b = pool[pool_pos];
        pool_pos += 1;
        if (b >= limit) continue; // reject to avoid modulo bias
        out[i] = chars[b % chars.len];
        i += 1;
    }
}

const XRun = struct { start: usize, len: usize };

/// Find the LAST maximal run of consecutive 'X' in `s`, matching GNU/mktemp(3):
/// the trailing X-run is substituted and anything after it is an implicit suffix.
fn findLastXRun(s: []const u8) ?XRun {
    var best: ?XRun = null;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == 'X') {
            const start = i;
            while (i < s.len and s[i] == 'X') : (i += 1) {}
            best = XRun{ .start = start, .len = i - start };
        } else {
            i += 1;
        }
    }
    return best;
}

const GenError = error{ TooFewX, SuffixMustEndX, BufferTooSmall };

/// Substitute the trailing X-run in `full` and append the effective suffix.
/// `explicit_suffix` is the value of --suffix if given; otherwise null (and the
/// chars trailing the X-run become the implicit suffix, per GNU).
fn buildName(full: []const u8, explicit_suffix: ?[]const u8, out: []u8) GenError![]const u8 {
    const run = findLastXRun(full) orelse return GenError.TooFewX;
    if (run.len < 3) return GenError.TooFewX;

    const run_end = run.start + run.len;
    const implicit_suffix = full[run_end..];

    if (explicit_suffix != null and implicit_suffix.len != 0) {
        return GenError.SuffixMustEndX;
    }

    const tail: []const u8 = explicit_suffix orelse implicit_suffix;
    const prefix = full[0..run.start];
    const total = prefix.len + run.len + tail.len;
    if (total >= out.len) return GenError.BufferTooSmall;

    @memcpy(out[0..prefix.len], prefix);
    fillRandom(out[prefix.len .. prefix.len + run.len]);
    @memcpy(out[prefix.len + run.len .. total], tail);
    return out[0..total];
}

fn createTempFile(path: []const u8) bool {
    var path_buf: [4096]u8 = undefined;
    const path_z = std.fmt.bufPrintZ(&path_buf, "{s}", .{path}) catch return false;
    // Platform-correct flags via the typed std.c.O bitfield: O_CREAT|O_EXCL|O_RDWR.
    // O_EXCL is the anti-symlink / TOCTOU guarantee, so it must actually reach the
    // kernel on Darwin too (hardcoded Linux numeric literals silently mis-map here).
    const flags: libc.O = .{ .ACCMODE = .RDWR, .CREAT = true, .EXCL = true };
    const fd = libc.open(path_z, flags, @as(libc.mode_t, 0o600));
    if (fd < 0) return false;
    _ = libc.close(fd);
    return true;
}

fn createTempDir(path: []const u8) bool {
    var path_buf: [4096]u8 = undefined;
    const path_z = std.fmt.bufPrintZ(&path_buf, "{s}", .{path}) catch return false;
    return libc.mkdir(path_z, @as(libc.mode_t, 0o700)) == 0;
}

fn hasSlash(s: []const u8) bool {
    return std.mem.indexOfScalar(u8, s, '/') != null;
}

pub fn main(init: std.process.Init) void {
    var cfg = Config{};

    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    _ = args_iter.next(); // skip program name

    while (args_iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help")) {
            printUsage();
            return;
        } else if (std.mem.eql(u8, arg, "--version")) {
            printVersion();
            return;
        } else if (std.mem.eql(u8, arg, "-d") or std.mem.eql(u8, arg, "--directory")) {
            cfg.directory = true;
        } else if (std.mem.eql(u8, arg, "-u") or std.mem.eql(u8, arg, "--dry-run")) {
            cfg.dry_run = true;
        } else if (std.mem.eql(u8, arg, "-q") or std.mem.eql(u8, arg, "--quiet")) {
            cfg.quiet = true;
        } else if (std.mem.eql(u8, arg, "-t")) {
            cfg.use_tmpdir_prefix = true;
        } else if (std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--tmpdir")) {
            if (args_iter.next()) |tmpdir_arg| {
                cfg.tmpdir = tmpdir_arg;
                cfg.tmpdir_given = true;
            }
        } else if (std.mem.startsWith(u8, arg, "--tmpdir=")) {
            cfg.tmpdir = arg["--tmpdir=".len..];
            cfg.tmpdir_given = true;
        } else if (std.mem.startsWith(u8, arg, "--suffix=")) {
            cfg.suffix = arg["--suffix=".len..];
        } else if (arg.len > 1 and arg[0] == '-') {
            // Unknown option.
            if (!cfg.quiet) {
                writeStderr("zmktemp: invalid option '");
                writeStderr(arg);
                writeStderr("'\n");
            }
            std.process.exit(1);
        } else {
            cfg.template = arg;
            cfg.template_given = true;
        }
    }

    // Validate --suffix: must not contain a slash (GNU rejects it).
    if (cfg.suffix) |suf| {
        if (hasSlash(suf)) {
            if (!cfg.quiet) {
                writeStderr("zmktemp: invalid suffix '");
                writeStderr(suf);
                writeStderr("', contains directory separator\n");
            }
            std.process.exit(1);
        }
    }

    // -t rejects a template with a directory component (GNU parity).
    if (cfg.use_tmpdir_prefix and hasSlash(cfg.template)) {
        if (!cfg.quiet) {
            writeStderr("zmktemp: invalid template, '");
            writeStderr(cfg.template);
            writeStderr("', contains directory separator\n");
        }
        std.process.exit(1);
    }

    // Decide the base directory and whether to prepend it, matching GNU:
    //  - -t                     -> base = $TMPDIR (or /tmp), always prepend
    //  - -p/--tmpdir DIR        -> base = DIR, always prepend
    //  - no explicit TEMPLATE   -> base = $TMPDIR (or /tmp), prepend (implied --tmpdir)
    //  - explicit TEMPLATE only -> use TEMPLATE as-is, relative to CWD (no prepend)
    var full_buf: [4096]u8 = undefined;
    var full_template: []const u8 = undefined;

    if (cfg.use_tmpdir_prefix) {
        const base = trimTrailingSlash(getTmpDir());
        full_template = std.fmt.bufPrint(&full_buf, "{s}/{s}", .{ base, cfg.template }) catch {
            reportPathTooLong(cfg.quiet);
        };
    } else if (cfg.tmpdir_given) {
        const base = trimTrailingSlash(cfg.tmpdir.?);
        full_template = std.fmt.bufPrint(&full_buf, "{s}/{s}", .{ base, cfg.template }) catch {
            reportPathTooLong(cfg.quiet);
        };
    } else if (!cfg.template_given) {
        const base = trimTrailingSlash(getTmpDir());
        full_template = std.fmt.bufPrint(&full_buf, "{s}/{s}", .{ base, cfg.template }) catch {
            reportPathTooLong(cfg.quiet);
        };
    } else {
        full_template = cfg.template;
    }

    // Try to create a unique file/directory (bounded retries on collision).
    var name_buf: [4096]u8 = undefined;
    var attempts: usize = 0;

    while (attempts < 128) : (attempts += 1) {
        const name = buildName(full_template, cfg.suffix, &name_buf) catch |e| {
            if (!cfg.quiet) reportGenError(e, cfg.template);
            std.process.exit(1);
        };

        if (cfg.dry_run) {
            writeStdout(name);
            writeStdout("\n");
            return;
        }

        const success = if (cfg.directory)
            createTempDir(name)
        else
            createTempFile(name);

        if (success) {
            writeStdout(name);
            writeStdout("\n");
            return;
        }
    }

    if (!cfg.quiet) {
        writeStderr("zmktemp: failed to create ");
        writeStderr(if (cfg.directory) "directory" else "file");
        writeStderr(" via template '");
        writeStderr(cfg.template); // quote the user's original template, not the joined path
        writeStderr("'\n");
    }
    std.process.exit(1);
}

fn trimTrailingSlash(s: []const u8) []const u8 {
    var end = s.len;
    while (end > 1 and s[end - 1] == '/') end -= 1;
    return s[0..end];
}

fn reportPathTooLong(quiet: bool) noreturn {
    if (!quiet) writeStderr("zmktemp: path too long\n");
    std.process.exit(1);
}

fn reportGenError(e: GenError, template: []const u8) void {
    switch (e) {
        GenError.TooFewX => {
            writeStderr("zmktemp: too few X's in template '");
            writeStderr(template);
            writeStderr("'\n");
        },
        GenError.SuffixMustEndX => {
            writeStderr("zmktemp: with --suffix, template '");
            writeStderr(template);
            writeStderr("' must end in X\n");
        },
        GenError.BufferTooSmall => {
            writeStderr("zmktemp: path too long\n");
        },
    }
}
