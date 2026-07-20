//! zruncon - Run command with specified SELinux security context
//!
//! A Zig implementation of runcon.
//! Run a program in a specified SELinux security context.
//!
//! Usage: zruncon CONTEXT COMMAND [ARG]...
//!        zruncon [-c] [-u USER] [-r ROLE] [-t TYPE] [-l RANGE] COMMAND [ARG]...

const std = @import("std");

const VERSION = "1.0.0";

// C functions
extern "c" fn write(fd: c_int, buf: [*]const u8, count: usize) isize;
extern "c" fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;
extern "c" fn dlopen(filename: ?[*:0]const u8, flags: c_int) ?*anyopaque;
extern "c" fn dlsym(handle: ?*anyopaque, symbol: [*:0]const u8) ?*anyopaque;
extern "c" fn dlerror() ?[*:0]const u8;
extern "c" fn dlclose(handle: ?*anyopaque) c_int;

const RTLD_NOW: c_int = 2;

fn writeStderr(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    _ = write(2, msg.ptr, msg.len);
}

fn writeStdout(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    _ = write(1, msg.ptr, msg.len);
}

// SELinux function types
const SetconFn = *const fn ([*:0]const u8) callconv(.c) c_int;
const GetconFn = *const fn (*?[*:0]u8) callconv(.c) c_int;
const FreeconFn = *const fn (?[*:0]u8) callconv(.c) void;
const ContextNewFn = *const fn ([*:0]const u8) callconv(.c) ?*anyopaque;
const ContextFreeFn = *const fn (?*anyopaque) callconv(.c) void;
const ContextStrFn = *const fn (?*anyopaque) callconv(.c) ?[*:0]const u8;
const ContextSetFn = *const fn (?*anyopaque, [*:0]const u8) callconv(.c) c_int;

const SELinuxLib = struct {
    handle: ?*anyopaque,
    setcon: SetconFn,
    getcon: GetconFn,
    freecon: FreeconFn,
    context_new: ContextNewFn,
    context_free: ContextFreeFn,
    context_str: ContextStrFn,
    context_user_set: ContextSetFn,
    context_role_set: ContextSetFn,
    context_type_set: ContextSetFn,
    context_range_set: ContextSetFn,

    fn load() ?SELinuxLib {
        const handle = dlopen("libselinux.so.1", RTLD_NOW) orelse
            dlopen("libselinux.so", RTLD_NOW) orelse return null;

        // A partially-stripped / ABI-mismatched libselinux can load but be
        // missing symbols we depend on. In a privilege-transition tool we must
        // never proceed with a half-resolved library: if ANY required symbol is
        // absent, treat SELinux as unavailable rather than risk calling setcon()
        // with an unbuilt (garbage) context pointer. See finding uninit-read.
        return SELinuxLib{
            .handle = handle,
            .setcon = @ptrCast(@alignCast(dlsym(handle, "setcon") orelse return null)),
            .getcon = @ptrCast(@alignCast(dlsym(handle, "getcon") orelse return null)),
            .freecon = @ptrCast(@alignCast(dlsym(handle, "freecon") orelse return null)),
            .context_new = @ptrCast(@alignCast(dlsym(handle, "context_new") orelse return null)),
            .context_free = @ptrCast(@alignCast(dlsym(handle, "context_free") orelse return null)),
            .context_str = @ptrCast(@alignCast(dlsym(handle, "context_str") orelse return null)),
            .context_user_set = @ptrCast(@alignCast(dlsym(handle, "context_user_set") orelse return null)),
            .context_role_set = @ptrCast(@alignCast(dlsym(handle, "context_role_set") orelse return null)),
            .context_type_set = @ptrCast(@alignCast(dlsym(handle, "context_type_set") orelse return null)),
            .context_range_set = @ptrCast(@alignCast(dlsym(handle, "context_range_set") orelse return null)),
        };
    }

    fn close(self: *SELinuxLib) void {
        if (self.handle) |h| {
            _ = dlclose(h);
            self.handle = null;
        }
    }
};

/// Result of the command-line parse. Pure data — no I/O — so it can be unit
/// tested against documented GNU runcon semantics without SELinux present.
pub const ParseError = enum {
    none,
    help,
    version,
    unrecognized_option,
    missing_arg,
    missing_command,
};

pub const ParsedArgs = struct {
    context: ?[]const u8 = null,
    user: ?[]const u8 = null,
    role: ?[]const u8 = null,
    typ: ?[]const u8 = null,
    range: ?[]const u8 = null,
    compute: bool = false,
    /// Index into args where the command (+ its args) begins.
    cmd_start: usize = 0,
    err: ParseError = .none,
    /// For unrecognized_option: the offending token. For missing_arg: the
    /// single short-option letter (e.g. "u") whose argument is missing.
    bad_option: []const u8 = "",
};

/// Parse argv (args[0] is the program name) exactly like GNU runcon.
///
/// GNU rule (coreutils src/runcon.c): after option parsing, if NONE of
/// -c/-u/-r/-t/-l was supplied the first operand is the complete CONTEXT and
/// the command starts at the next operand; otherwise the first operand starts
/// the command. There is NO "looks like a context because it has a colon"
/// heuristic — that would exec an attacker/typo-controlled first operand.
pub fn parseArgs(args: []const []const u8) ParsedArgs {
    var p: ParsedArgs = .{};

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "--help")) {
            return .{ .err = .help };
        } else if (std.mem.eql(u8, arg, "--version")) {
            return .{ .err = .version };
        } else if (std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "--compute")) {
            p.compute = true;
        } else if (std.mem.eql(u8, arg, "-u") or std.mem.eql(u8, arg, "--user")) {
            i += 1;
            if (i >= args.len) return .{ .err = .missing_arg, .bad_option = "u" };
            p.user = args[i];
        } else if (std.mem.eql(u8, arg, "-r") or std.mem.eql(u8, arg, "--role")) {
            i += 1;
            if (i >= args.len) return .{ .err = .missing_arg, .bad_option = "r" };
            p.role = args[i];
        } else if (std.mem.eql(u8, arg, "-t") or std.mem.eql(u8, arg, "--type")) {
            i += 1;
            if (i >= args.len) return .{ .err = .missing_arg, .bad_option = "t" };
            p.typ = args[i];
        } else if (std.mem.eql(u8, arg, "-l") or std.mem.eql(u8, arg, "--range")) {
            i += 1;
            if (i >= args.len) return .{ .err = .missing_arg, .bad_option = "l" };
            p.range = args[i];
        } else if (std.mem.startsWith(u8, arg, "--user=")) {
            p.user = arg[7..];
        } else if (std.mem.startsWith(u8, arg, "--role=")) {
            p.role = arg[7..];
        } else if (std.mem.startsWith(u8, arg, "--type=")) {
            p.typ = arg[7..];
        } else if (std.mem.startsWith(u8, arg, "--range=")) {
            p.range = arg[8..];
        } else if (std.mem.eql(u8, arg, "--")) {
            p.cmd_start = i + 1;
            break;
        } else if (arg.len > 0 and arg[0] == '-') {
            return .{ .err = .unrecognized_option, .bad_option = arg };
        } else {
            // First non-option operand. GNU: it is the CONTEXT iff no component
            // option (-c/-u/-r/-t/-l) preceded it; otherwise it starts the command.
            if (!(p.compute or p.user != null or p.role != null or p.typ != null or p.range != null)) {
                p.context = arg;
                p.cmd_start = i + 1;
            } else {
                p.cmd_start = i;
            }
            break;
        }
    }

    if (p.cmd_start == 0 or p.cmd_start >= args.len) {
        p.err = .missing_command;
    }
    return p;
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    // Collect args into a slice
    var args_list: std.ArrayListUnmanaged([]const u8) = .empty;
    defer args_list.deinit(allocator);
    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    while (args_iter.next()) |arg| {
        try args_list.append(allocator, arg);
    }
    const args = args_list.items;

    const parsed = parseArgs(args);
    switch (parsed.err) {
        .help => {
            printHelp();
            return;
        },
        .version => {
            writeStdout("zruncon {s}\n", .{VERSION});
            return;
        },
        .unrecognized_option => {
            writeStderr("zruncon: unrecognized option '{s}'\n", .{parsed.bad_option});
            std.process.exit(1);
        },
        .missing_arg => {
            writeStderr("zruncon: option requires an argument -- '{s}'\n", .{parsed.bad_option});
            std.process.exit(1);
        },
        .missing_command => {
            writeStderr("zruncon: missing command\n", .{});
            writeStderr("Try 'zruncon --help' for more information.\n", .{});
            std.process.exit(1);
        },
        .none => {},
    }

    const context = parsed.context;
    const user = parsed.user;
    const role = parsed.role;
    const typ = parsed.typ;
    const range = parsed.range;
    const cmd_start = parsed.cmd_start;

    // Load SELinux library
    var selib = SELinuxLib.load() orelse {
        writeStderr("zruncon: SELinux library not available\n", .{});
        writeStderr("Note: SELinux must be installed for this utility to work.\n", .{});
        std.process.exit(1);
    };
    defer selib.close();

    // Build the context
    var final_context_buf: [4097]u8 = undefined;
    // Optional so it can NEVER reach setcon() unassigned. See finding uninit-read.
    var final_context: ?[*:0]const u8 = null;
    var ctx_handle: ?*anyopaque = null;

    if (context) |ctx| {
        if (user != null or role != null or typ != null or range != null) {
            // Modify provided context
            if (ctx.len >= final_context_buf.len) {
                writeStderr("zruncon: context too long\n", .{});
                std.process.exit(1);
            }
            @memcpy(final_context_buf[0..ctx.len], ctx);
            final_context_buf[ctx.len] = 0;

            ctx_handle = selib.context_new(@ptrCast(&final_context_buf));
            if (ctx_handle == null) {
                writeStderr("zruncon: invalid context '{s}'\n", .{ctx});
                std.process.exit(1);
            }

            applyContextModifications(&selib, ctx_handle, user, role, typ, range);

            if (selib.context_str(ctx_handle)) |str| {
                final_context = str;
            } else {
                writeStderr("zruncon: failed to construct context\n", .{});
                std.process.exit(1);
            }
        } else {
            // Use context as-is
            if (ctx.len >= final_context_buf.len) {
                writeStderr("zruncon: context too long\n", .{});
                std.process.exit(1);
            }
            @memcpy(final_context_buf[0..ctx.len], ctx);
            final_context_buf[ctx.len] = 0;
            final_context = @ptrCast(&final_context_buf);
        }
    } else if (user != null or role != null or typ != null or range != null) {
        // Build from current context
        var cur_context: ?[*:0]u8 = null;
        if (selib.getcon(&cur_context) != 0 or cur_context == null) {
            writeStderr("zruncon: cannot get current context\n", .{});
            std.process.exit(1);
        }
        defer selib.freecon(cur_context);

        ctx_handle = selib.context_new(cur_context.?);
        if (ctx_handle == null) {
            writeStderr("zruncon: invalid current context\n", .{});
            std.process.exit(1);
        }

        applyContextModifications(&selib, ctx_handle, user, role, typ, range);

        if (selib.context_str(ctx_handle)) |str| {
            final_context = str;
        } else {
            writeStderr("zruncon: failed to construct context\n", .{});
            std.process.exit(1);
        }
    } else {
        writeStderr("zruncon: must specify -c, -t, -u, -r, or -l, or a context\n", .{});
        std.process.exit(1);
    }

    defer {
        if (ctx_handle != null) {
            selib.context_free(ctx_handle);
        }
    }

    // Set the context. final_context is guaranteed assigned by every path that
    // reaches here; guard anyway rather than dereference undefined memory.
    const ctx_ptr = final_context orelse {
        writeStderr("zruncon: failed to construct context\n", .{});
        std.process.exit(1);
    };
    if (selib.setcon(ctx_ptr) != 0) {
        writeStderr("zruncon: cannot set security context\n", .{});
        std.process.exit(1);
    }

    // Build argv for exec
    const cmd_args = args[cmd_start..];
    var argv = try allocator.alloc(?[*:0]const u8, cmd_args.len + 1);
    defer allocator.free(argv);

    for (cmd_args, 0..) |arg, idx| {
        const arg_z = try allocator.allocSentinel(u8, arg.len, 0);
        @memcpy(arg_z[0..arg.len], arg);
        argv[idx] = arg_z.ptr;
    }
    argv[cmd_args.len] = null;

    // Execute the command
    _ = execvp(argv[0].?, @ptrCast(argv.ptr));

    // If we get here, exec failed. GNU runcon distinguishes 127 (not found,
    // ENOENT) from 126 (found but not invokable: EACCES, ENOEXEC, EISDIR, ...).
    const e = std.c._errno().*;
    const exit_status: u8 = if (e == @intFromEnum(std.c.E.NOENT)) 127 else 126;
    writeStderr("zruncon: failed to execute '{s}'\n", .{cmd_args[0]});
    std.process.exit(exit_status);
}

/// Apply -u/-r/-t/-l overrides onto an selinux context handle.
///
/// GNU runcon aborts (EXIT_FAILURE) with a specific diagnostic when any
/// component set fails — a privilege tool must not silently transition to a
/// context different from what the operator asked for. Order matches
/// coreutils src/runcon.c: user, type, range, role.
fn applyContextModifications(selib: *const SELinuxLib, ctx_handle: ?*anyopaque, user: ?[]const u8, role: ?[]const u8, typ: ?[]const u8, range: ?[]const u8) void {
    var buf: [4097]u8 = undefined;
    if (user) |u| {
        const z = toZ(&buf, u) orelse fail("user", u);
        if (selib.context_user_set(ctx_handle, z) != 0) fail("user", u);
    }
    if (typ) |t| {
        const z = toZ(&buf, t) orelse fail("type", t);
        if (selib.context_type_set(ctx_handle, z) != 0) fail("type", t);
    }
    if (range) |l| {
        const z = toZ(&buf, l) orelse fail("range", l);
        if (selib.context_range_set(ctx_handle, z) != 0) fail("range", l);
    }
    if (role) |r| {
        const z = toZ(&buf, r) orelse fail("role", r);
        if (selib.context_role_set(ctx_handle, z) != 0) fail("role", r);
    }
}

/// NUL-terminate `s` into `buf`; null if it does not fit (over-length
/// components are reported, never silently dropped).
fn toZ(buf: *[4097]u8, s: []const u8) ?[*:0]const u8 {
    if (s.len >= buf.len) return null;
    @memcpy(buf[0..s.len], s);
    buf[s.len] = 0;
    return @ptrCast(buf);
}

fn fail(comptime what: []const u8, value: []const u8) noreturn {
    writeStderr("zruncon: failed to set new " ++ what ++ " {s}\n", .{value});
    std.process.exit(1);
}

fn printHelp() void {
    writeStdout(
        \\Usage: zruncon CONTEXT COMMAND [ARG]...
        \\   or: zruncon [-c] [-u USER] [-r ROLE] [-t TYPE] [-l RANGE] COMMAND [ARG]...
        \\Run COMMAND with specified SELinux security context.
        \\
        \\Options:
        \\  -c, --compute         compute process context before modifying
        \\  -u, --user=USER       set user identity in context
        \\  -r, --role=ROLE       set role in context
        \\  -t, --type=TYPE       set type in context
        \\  -l, --range=RANGE     set range in context
        \\      --help            display this help and exit
        \\      --version         output version information and exit
        \\
        \\A security context has the form: user:role:type:range
        \\
        \\Examples:
        \\  zruncon system_u:system_r:unconfined_t:s0 /bin/sh
        \\  zruncon -t httpd_t /usr/sbin/httpd
        \\  zruncon -u system_u -r system_r id
        \\
        \\Note: SELinux must be enabled and libselinux must be installed.
        \\The caller must have permission to transition to the specified context.
        \\
    , .{});
}

test {
    _ = @import("gnu_parity_test.zig");
}
