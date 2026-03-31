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
    setcon: ?SetconFn,
    getcon: ?GetconFn,
    freecon: ?FreeconFn,
    context_new: ?ContextNewFn,
    context_free: ?ContextFreeFn,
    context_str: ?ContextStrFn,
    context_user_set: ?ContextSetFn,
    context_role_set: ?ContextSetFn,
    context_type_set: ?ContextSetFn,
    context_range_set: ?ContextSetFn,

    fn load() ?SELinuxLib {
        const handle = dlopen("libselinux.so.1", RTLD_NOW) orelse
            dlopen("libselinux.so", RTLD_NOW) orelse return null;

        return SELinuxLib{
            .handle = handle,
            .setcon = @ptrCast(@alignCast(dlsym(handle, "setcon"))),
            .getcon = @ptrCast(@alignCast(dlsym(handle, "getcon"))),
            .freecon = @ptrCast(@alignCast(dlsym(handle, "freecon"))),
            .context_new = @ptrCast(@alignCast(dlsym(handle, "context_new"))),
            .context_free = @ptrCast(@alignCast(dlsym(handle, "context_free"))),
            .context_str = @ptrCast(@alignCast(dlsym(handle, "context_str"))),
            .context_user_set = @ptrCast(@alignCast(dlsym(handle, "context_user_set"))),
            .context_role_set = @ptrCast(@alignCast(dlsym(handle, "context_role_set"))),
            .context_type_set = @ptrCast(@alignCast(dlsym(handle, "context_type_set"))),
            .context_range_set = @ptrCast(@alignCast(dlsym(handle, "context_range_set"))),
        };
    }

    fn close(self: *SELinuxLib) void {
        if (self.handle) |h| {
            _ = dlclose(h);
            self.handle = null;
        }
    }
};

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

    // Options
    var context: ?[]const u8 = null;
    var user: ?[]const u8 = null;
    var role: ?[]const u8 = null;
    var typ: ?[]const u8 = null;
    var range: ?[]const u8 = null;
    var cmd_start: usize = 0;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "--help")) {
            printHelp();
            return;
        } else if (std.mem.eql(u8, arg, "--version")) {
            writeStdout("zruncon {s}\n", .{VERSION});
            return;
        } else if (std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "--compute")) {
            // compute flag - not fully implemented
        } else if (std.mem.eql(u8, arg, "-u") or std.mem.eql(u8, arg, "--user")) {
            i += 1;
            if (i >= args.len) {
                writeStderr("zruncon: option requires an argument -- 'u'\n", .{});
                std.process.exit(1);
            }
            user = args[i];
        } else if (std.mem.eql(u8, arg, "-r") or std.mem.eql(u8, arg, "--role")) {
            i += 1;
            if (i >= args.len) {
                writeStderr("zruncon: option requires an argument -- 'r'\n", .{});
                std.process.exit(1);
            }
            role = args[i];
        } else if (std.mem.eql(u8, arg, "-t") or std.mem.eql(u8, arg, "--type")) {
            i += 1;
            if (i >= args.len) {
                writeStderr("zruncon: option requires an argument -- 't'\n", .{});
                std.process.exit(1);
            }
            typ = args[i];
        } else if (std.mem.eql(u8, arg, "-l") or std.mem.eql(u8, arg, "--range")) {
            i += 1;
            if (i >= args.len) {
                writeStderr("zruncon: option requires an argument -- 'l'\n", .{});
                std.process.exit(1);
            }
            range = args[i];
        } else if (std.mem.startsWith(u8, arg, "--user=")) {
            user = arg[7..];
        } else if (std.mem.startsWith(u8, arg, "--role=")) {
            role = arg[7..];
        } else if (std.mem.startsWith(u8, arg, "--type=")) {
            typ = arg[7..];
        } else if (std.mem.startsWith(u8, arg, "--range=")) {
            range = arg[8..];
        } else if (std.mem.eql(u8, arg, "--")) {
            cmd_start = i + 1;
            break;
        } else if (arg.len > 0 and arg[0] == '-') {
            writeStderr("zruncon: unrecognized option '{s}'\n", .{arg});
            std.process.exit(1);
        } else {
            // First non-option - could be context or command
            if (context == null and user == null and role == null and typ == null and range == null) {
                // Check if it looks like a context (contains :)
                if (std.mem.indexOf(u8, arg, ":") != null) {
                    context = arg;
                } else {
                    cmd_start = i;
                    break;
                }
            } else {
                cmd_start = i;
                break;
            }
        }
    }

    if (cmd_start == 0 or cmd_start >= args.len) {
        writeStderr("zruncon: missing command\n", .{});
        writeStderr("Try 'zruncon --help' for more information.\n", .{});
        std.process.exit(1);
    }

    // Load SELinux library
    var selib = SELinuxLib.load() orelse {
        writeStderr("zruncon: SELinux library not available\n", .{});
        writeStderr("Note: SELinux must be installed for this utility to work.\n", .{});
        std.process.exit(1);
    };
    defer selib.close();

    // Build the context
    var final_context_buf: [4097]u8 = undefined;
    var final_context: [*:0]const u8 = undefined;
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

            if (selib.context_new) |context_new| {
                ctx_handle = context_new(@ptrCast(&final_context_buf));
                if (ctx_handle == null) {
                    writeStderr("zruncon: invalid context '{s}'\n", .{ctx});
                    std.process.exit(1);
                }

                applyContextModifications(&selib, ctx_handle, user, role, typ, range);

                if (selib.context_str) |context_str| {
                    if (context_str(ctx_handle)) |str| {
                        final_context = str;
                    } else {
                        writeStderr("zruncon: failed to construct context\n", .{});
                        std.process.exit(1);
                    }
                }
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
        if (selib.getcon) |getcon| {
            var cur_context: ?[*:0]u8 = null;
            if (getcon(&cur_context) != 0 or cur_context == null) {
                writeStderr("zruncon: cannot get current context\n", .{});
                std.process.exit(1);
            }
            defer if (selib.freecon) |freecon| freecon(cur_context);

            if (selib.context_new) |context_new| {
                ctx_handle = context_new(cur_context.?);
                if (ctx_handle == null) {
                    writeStderr("zruncon: invalid current context\n", .{});
                    std.process.exit(1);
                }

                applyContextModifications(&selib, ctx_handle, user, role, typ, range);

                if (selib.context_str) |context_str| {
                    if (context_str(ctx_handle)) |str| {
                        final_context = str;
                    } else {
                        writeStderr("zruncon: failed to construct context\n", .{});
                        std.process.exit(1);
                    }
                }
            }
        }
    } else {
        writeStderr("zruncon: must specify context or context components\n", .{});
        std.process.exit(1);
    }

    defer {
        if (ctx_handle != null) {
            if (selib.context_free) |context_free| context_free(ctx_handle);
        }
    }

    // Set the context
    if (selib.setcon) |setcon| {
        if (setcon(final_context) != 0) {
            writeStderr("zruncon: cannot set security context\n", .{});
            std.process.exit(1);
        }
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

    // If we get here, exec failed
    writeStderr("zruncon: failed to execute '{s}'\n", .{cmd_args[0]});
    std.process.exit(127);
}

fn applyContextModifications(selib: *const SELinuxLib, ctx_handle: ?*anyopaque, user: ?[]const u8, role: ?[]const u8, typ: ?[]const u8, range: ?[]const u8) void {
    if (user) |u| {
        var u_z: [256]u8 = undefined;
        if (u.len < u_z.len) {
            @memcpy(u_z[0..u.len], u);
            u_z[u.len] = 0;
            if (selib.context_user_set) |f| _ = f(ctx_handle, @ptrCast(&u_z));
        }
    }
    if (role) |r| {
        var r_z: [256]u8 = undefined;
        if (r.len < r_z.len) {
            @memcpy(r_z[0..r.len], r);
            r_z[r.len] = 0;
            if (selib.context_role_set) |f| _ = f(ctx_handle, @ptrCast(&r_z));
        }
    }
    if (typ) |t| {
        var t_z: [256]u8 = undefined;
        if (t.len < t_z.len) {
            @memcpy(t_z[0..t.len], t);
            t_z[t.len] = 0;
            if (selib.context_type_set) |f| _ = f(ctx_handle, @ptrCast(&t_z));
        }
    }
    if (range) |l| {
        var l_z: [256]u8 = undefined;
        if (l.len < l_z.len) {
            @memcpy(l_z[0..l.len], l);
            l_z[l.len] = 0;
            if (selib.context_range_set) |f| _ = f(ctx_handle, @ptrCast(&l_z));
        }
    }
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
