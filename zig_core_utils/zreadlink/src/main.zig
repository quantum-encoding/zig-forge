//! zreadlink - Print symbolic link target or canonical path
//!
//! High-performance readlink implementation in Zig.
//!
//! Canonicalization modes follow GNU coreutils `readlink` semantics
//! (coreutils/lib/canonicalize.c, canonicalize_filename_mode):
//!   -e (canon_exist)   CAN_EXISTING     — every path component must exist
//!   -f (canonicalize)  CAN_ALL_BUT_LAST — all but the LAST component must exist
//!   -m (canon_missing) CAN_MISSING      — no component need exist
//! They are NOT interchangeable: libc realpath() only implements -e.

const std = @import("std");
const libc = std.c;

const VERSION = "1.0.0";

extern "c" fn readlink(path: [*:0]const u8, buf: [*]u8, bufsiz: usize) isize;
extern "c" fn getcwd(buf: [*]u8, size: usize) ?[*:0]u8;
extern "c" fn strerror(errnum: c_int) [*:0]const u8;

const E_NOENT: c_int = @intFromEnum(std.c.E.NOENT);
const E_NOMEM: c_int = @intFromEnum(std.c.E.NOMEM);
const E_LOOP: c_int = @intFromEnum(std.c.E.LOOP);
const MAXSYMLINKS: usize = 40;

const Mode = enum {
    raw, // Just read symlink
    canonicalize, // -f: all but last component must exist
    canon_exist, // -e: all components must exist
    canon_missing, // -m: allow all components missing
};

const Config = struct {
    mode: Mode = .raw,
    no_newline: bool = false,
    zero: bool = false,
    verbose: bool = false, // -v: emit error diagnostics (GNU default is silent)
    files: std.ArrayListUnmanaged([]const u8) = .empty,
};

fn writeStdout(data: []const u8) void {
    _ = libc.write(libc.STDOUT_FILENO, data.ptr, data.len);
}

fn writeStderr(data: []const u8) void {
    _ = libc.write(libc.STDERR_FILENO, data.ptr, data.len);
}

fn setErrno(e: c_int) void {
    libc._errno().* = e;
}

fn errno() c_int {
    return libc._errno().*;
}

fn printUsage() void {
    const usage =
        \\Usage: zreadlink [OPTION]... FILE...
        \\Print value of a symbolic link or canonical file name.
        \\
        \\Options:
        \\  -f, --canonicalize            Canonicalize; all but the last component must exist
        \\  -e, --canonicalize-existing   Like -f, but all components must exist
        \\  -m, --canonicalize-missing    Like -f, but no components need exist
        \\  -n, --no-newline              Do not output the trailing delimiter
        \\  -q, --quiet, -s, --silent     Suppress most error messages (default)
        \\  -v, --verbose                 Report error messages
        \\  -z, --zero                    End each output line with NUL, not newline
        \\      --help                    Display this help and exit
        \\      --version                 Output version information and exit
        \\
    ;
    writeStdout(usage);
}

fn printVersion() void {
    writeStdout("zreadlink " ++ VERSION ++ "\n");
}

/// Read a symlink target, growing the buffer until it fits so targets of any
/// length are returned in full (no silent truncation). Returns an allocated
/// slice on success; null with errno set on failure.
fn readLinkAlloc(a: std.mem.Allocator, path_z: [*:0]const u8) ?[]u8 {
    var size: usize = 256;
    while (size <= (1 << 20)) : (size *= 2) {
        const buf = a.alloc(u8, size) catch {
            setErrno(E_NOMEM);
            return null;
        };
        const n = readlink(path_z, buf.ptr, buf.len);
        if (n < 0) {
            const e = errno();
            a.free(buf);
            setErrno(e);
            return null;
        }
        const len: usize = @intCast(n);
        if (len < size) {
            // Full target captured (< size means it was not truncated).
            const out = a.dupe(u8, buf[0..len]) catch {
                a.free(buf);
                setErrno(E_NOMEM);
                return null;
            };
            a.free(buf);
            return out;
        }
        a.free(buf); // truncated; retry with a larger buffer
    }
    setErrno(E_NOMEM);
    return null;
}

/// Drop the last path component from an absolute `rname` buffer, never rising
/// above root. "/a/b" -> "/a"; "/a" -> "/"; "/" -> "/".
fn popComponent(rname: *std.ArrayListUnmanaged(u8)) void {
    if (rname.items.len == 0) return;
    var i = rname.items.len;
    while (i > 0 and rname.items[i - 1] != '/') : (i -= 1) {}
    // i is the index just past the last '/'; the component runs [i..end].
    if (i <= 1) {
        rname.items.len = 1; // keep leading "/"
    } else {
        rname.items.len = i - 1; // drop the component and its leading '/'
    }
}

fn hasMoreComponents(remaining: []const u8, pos: usize) bool {
    var i = pos;
    while (i < remaining.len) : (i += 1) {
        if (remaining[i] != '/') return true;
    }
    return false;
}

/// GNU `canonicalize_filename_mode`: resolve `name` component-by-component,
/// following symlinks, honoring the existence requirement of `mode`.
/// Returns an allocated absolute path on success; null with errno set on
/// failure. Missing-component rules:
///   canon_exist   -> fail on the first missing component
///   canonicalize  -> fail only if a missing component is NOT the last one
///   canon_missing -> never fail on a missing component
fn canonicalize(a: std.mem.Allocator, name: []const u8, mode: Mode) ?[]u8 {
    if (name.len == 0) {
        setErrno(E_NOENT);
        return null;
    }

    var rname: std.ArrayListUnmanaged(u8) = .empty;
    defer rname.deinit(a);

    if (name[0] == '/') {
        rname.append(a, '/') catch {
            setErrno(E_NOMEM);
            return null;
        };
    } else {
        var cwd_buf: [4096]u8 = undefined;
        const cwd = getcwd(&cwd_buf, cwd_buf.len) orelse return null;
        rname.appendSlice(a, std.mem.span(cwd)) catch {
            setErrno(E_NOMEM);
            return null;
        };
    }

    var remaining: std.ArrayListUnmanaged(u8) = .empty;
    defer remaining.deinit(a);
    remaining.appendSlice(a, name) catch {
        setErrno(E_NOMEM);
        return null;
    };

    var symlinks: usize = 0;
    var pos: usize = 0;
    var missing = false; // once a component is absent, resolve the tail lexically

    while (pos < remaining.items.len) {
        while (pos < remaining.items.len and remaining.items[pos] == '/') pos += 1;
        if (pos >= remaining.items.len) break;
        const start = pos;
        while (pos < remaining.items.len and remaining.items[pos] != '/') pos += 1;
        const comp = remaining.items[start..pos];

        if (std.mem.eql(u8, comp, ".")) continue;
        if (std.mem.eql(u8, comp, "..")) {
            popComponent(&rname);
            continue;
        }

        if (rname.items.len == 0 or rname.items[rname.items.len - 1] != '/') {
            rname.append(a, '/') catch {
                setErrno(E_NOMEM);
                return null;
            };
        }
        rname.appendSlice(a, comp) catch {
            setErrno(E_NOMEM);
            return null;
        };

        if (missing) continue; // parent already absent -> pure lexical build

        const rz = a.dupeZ(u8, rname.items) catch {
            setErrno(E_NOMEM);
            return null;
        };
        defer a.free(rz);

        var st: std.c.Stat = undefined;
        const rc = std.c.fstatat(std.c.AT.FDCWD, rz, &st, std.c.AT.SYMLINK_NOFOLLOW);
        if (rc != 0) {
            const e = errno();
            if (e == E_NOENT) {
                const more = hasMoreComponents(remaining.items, pos);
                if (mode == .canon_exist) {
                    setErrno(E_NOENT);
                    return null;
                }
                if (mode == .canonicalize and more) {
                    setErrno(E_NOENT);
                    return null;
                }
                missing = true;
                continue;
            }
            setErrno(e);
            return null;
        }

        if (std.c.S.ISLNK(st.mode)) {
            symlinks += 1;
            if (symlinks > MAXSYMLINKS) {
                setErrno(E_LOOP);
                return null;
            }
            const link = readLinkAlloc(a, rz) orelse return null;
            defer a.free(link);

            popComponent(&rname); // remove the symlink component itself
            if (link.len > 0 and link[0] == '/') {
                rname.clearRetainingCapacity();
                rname.append(a, '/') catch {
                    setErrno(E_NOMEM);
                    return null;
                };
            }

            // new remaining = link + '/' + (unconsumed tail of old remaining)
            var newrem: std.ArrayListUnmanaged(u8) = .empty;
            newrem.appendSlice(a, link) catch {
                newrem.deinit(a);
                setErrno(E_NOMEM);
                return null;
            };
            newrem.append(a, '/') catch {
                newrem.deinit(a);
                setErrno(E_NOMEM);
                return null;
            };
            newrem.appendSlice(a, remaining.items[pos..]) catch {
                newrem.deinit(a);
                setErrno(E_NOMEM);
                return null;
            };
            remaining.deinit(a);
            remaining = newrem;
            pos = 0;
        }
    }

    if (rname.items.len == 0) {
        rname.append(a, '/') catch {
            setErrno(E_NOMEM);
            return null;
        };
    }
    if (rname.items.len > 1 and rname.items[rname.items.len - 1] == '/') {
        rname.items.len -= 1;
    }
    return a.dupe(u8, rname.items) catch {
        setErrno(E_NOMEM);
        return null;
    };
}

fn processFile(a: std.mem.Allocator, path: []const u8, cfg: *const Config) bool {
    const result: ?[]u8 = switch (cfg.mode) {
        .raw => blk: {
            const path_z = a.dupeZ(u8, path) catch {
                setErrno(E_NOMEM);
                break :blk null;
            };
            defer a.free(path_z);
            break :blk readLinkAlloc(a, path_z);
        },
        else => canonicalize(a, path, cfg.mode),
    };

    if (result) |target| {
        defer a.free(target);
        writeStdout(target);
        if (cfg.zero) {
            writeStdout("\x00");
        } else if (!cfg.no_newline) {
            writeStdout("\n");
        }
        return true;
    } else {
        // Capture errno before any further syscall clobbers it.
        const e = errno();
        if (cfg.verbose) {
            writeStderr("zreadlink: ");
            writeStderr(path);
            writeStderr(": ");
            writeStderr(std.mem.span(strerror(e)));
            writeStderr("\n");
        }
        return false;
    }
}

fn applyShort(cfg: *Config, ch: u8) bool {
    switch (ch) {
        'f' => cfg.mode = .canonicalize,
        'e' => cfg.mode = .canon_exist,
        'm' => cfg.mode = .canon_missing,
        'n' => cfg.no_newline = true,
        'z' => cfg.zero = true,
        'v' => cfg.verbose = true,
        'q', 's' => cfg.verbose = false,
        else => return false,
    }
    return true;
}

pub fn main(init: std.process.Init) void {
    const a = init.gpa;
    var cfg = Config{};
    defer cfg.files.deinit(a);

    var no_more_opts = false;
    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    _ = args_iter.next(); // skip program name

    while (args_iter.next()) |arg| {
        if (!no_more_opts and std.mem.eql(u8, arg, "--")) {
            no_more_opts = true;
            continue;
        }

        // Operands: everything after `--`, a bare `-`, or non-dash args.
        if (no_more_opts or arg.len == 0 or arg[0] != '-' or arg.len == 1) {
            cfg.files.append(a, arg) catch {
                writeStderr("zreadlink: out of memory\n");
                std.process.exit(1);
            };
            continue;
        }

        // Long options.
        if (std.mem.startsWith(u8, arg, "--")) {
            if (std.mem.eql(u8, arg, "--help")) {
                printUsage();
                std.process.exit(0);
            } else if (std.mem.eql(u8, arg, "--version")) {
                printVersion();
                std.process.exit(0);
            } else if (std.mem.eql(u8, arg, "--canonicalize")) {
                cfg.mode = .canonicalize;
            } else if (std.mem.eql(u8, arg, "--canonicalize-existing")) {
                cfg.mode = .canon_exist;
            } else if (std.mem.eql(u8, arg, "--canonicalize-missing")) {
                cfg.mode = .canon_missing;
            } else if (std.mem.eql(u8, arg, "--no-newline")) {
                cfg.no_newline = true;
            } else if (std.mem.eql(u8, arg, "--verbose")) {
                cfg.verbose = true;
            } else if (std.mem.eql(u8, arg, "--quiet") or std.mem.eql(u8, arg, "--silent")) {
                cfg.verbose = false;
            } else if (std.mem.eql(u8, arg, "--zero")) {
                cfg.zero = true;
            } else {
                writeStderr("zreadlink: unrecognized option '");
                writeStderr(arg);
                writeStderr("'\n");
                writeStderr("Try 'zreadlink --help' for more information.\n");
                std.process.exit(1);
            }
            continue;
        }

        // Bundled short options, e.g. -nf, -fz.
        for (arg[1..]) |ch| {
            if (!applyShort(&cfg, ch)) {
                writeStderr("zreadlink: invalid option -- '");
                writeStderr(&[_]u8{ch});
                writeStderr("'\n");
                writeStderr("Try 'zreadlink --help' for more information.\n");
                std.process.exit(1);
            }
        }
    }

    if (cfg.files.items.len == 0) {
        writeStderr("zreadlink: missing operand\n");
        writeStderr("Try 'zreadlink --help' for more information.\n");
        std.process.exit(1);
    }

    var all_ok = true;
    for (cfg.files.items) |path| {
        if (!processFile(a, path, &cfg)) {
            all_ok = false;
        }
    }

    if (!all_ok) {
        std.process.exit(1);
    }
}
