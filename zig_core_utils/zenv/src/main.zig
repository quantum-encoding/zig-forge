//! zenv - High-performance environment variable utility
//!
//! Run a program in a modified environment, or display environment variables.
//!
//! Usage: zenv [OPTION]... [-] [NAME=VALUE]... [COMMAND [ARG]...]

const std = @import("std");
const libc = std.c;

const VERSION = "1.0.0";

extern "c" fn chdir(path: [*:0]const u8) c_int;
extern "c" fn execve(path: [*:0]const u8, argv: [*:null]const ?[*:0]const u8, envp: [*:null]const ?[*:0]const u8) c_int;
extern "c" fn access(path: [*:0]const u8, mode: c_int) c_int;
const X_OK: c_int = 1;

const Config = struct {
    null_terminate: bool = false,
    ignore_env: bool = false,
    unset_vars: std.ArrayListUnmanaged([]const u8) = .empty,
    set_vars: std.ArrayListUnmanaged([]const u8) = .empty,
    command: ?[]const []const u8 = null,
    chdir_path: ?[]const u8 = null,
    argv0: ?[]const u8 = null,
};

/// Map a GNU `-S` backslash-escape character to its literal byte.
/// Returns null for escapes with no single-byte expansion (only `\c` today,
/// which the caller handles as "terminate parsing").
fn escapeByte(c: u8) ?u8 {
    return switch (c) {
        't' => '\t',
        'n' => '\n',
        'r' => '\r',
        'f' => 0x0c, // form feed
        'v' => 0x0b, // vertical tab
        '\\' => '\\',
        '#' => '#',
        else => c, // unrecognized: keep the char literally (GNU errors; we are lenient)
    };
}

/// Split a `-S`/`--split-string` argument into words the way GNU `env` does.
///
/// Rules mirrored from GNU coreutils `env.c` (`parse_split_string`):
///  - Unquoted whitespace (space, tab, newline) separates words.
///  - Single quotes preserve everything literally (no escapes, no `#`).
///  - Double quotes group text; backslash escapes are still processed inside.
///  - Backslash escapes `\t \n \r \f \v \\ \#` expand to their literal byte and
///    do NOT act as separators (so `a\tb` is a single word containing a tab).
///  - `\c` terminates parsing entirely (the shebang "stop here" escape).
///  - `#` at the start of a word begins a comment running to end of string.
///
/// Returns allocated slices that must be freed.
fn splitString(s: []const u8, allocator: std.mem.Allocator) ![][]const u8 {
    var result: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (result.items) |item| allocator.free(item);
        result.deinit(allocator);
    }

    var current: std.ArrayListUnmanaged(u8) = .empty;
    defer current.deinit(allocator);

    var in_single_quote = false;
    var in_double_quote = false;
    // A word is "active" once any character (or an opening quote) has been seen
    // for it; used to decide whether `#` starts a comment (only at word start).
    var word_active = false;
    var i: usize = 0;

    while (i < s.len) : (i += 1) {
        const c = s[i];

        // Backslash escapes: processed everywhere EXCEPT inside single quotes.
        if (c == '\\' and !in_single_quote) {
            if (i + 1 >= s.len) {
                // Trailing backslash: keep it literally.
                try current.append(allocator, '\\');
                word_active = true;
                continue;
            }
            const next = s[i + 1];
            if (next == 'c') {
                // \c — stop parsing entirely, flushing any word in progress.
                if (word_active) {
                    const word = try allocator.dupe(u8, current.items);
                    try result.append(allocator, word);
                    current.clearRetainingCapacity();
                }
                return result.toOwnedSlice(allocator);
            }
            try current.append(allocator, escapeByte(next) orelse next);
            word_active = true;
            i += 1; // consume the escaped char
            continue;
        }

        if (c == '\'' and !in_double_quote) {
            in_single_quote = !in_single_quote;
            word_active = true;
            continue;
        }

        if (c == '"' and !in_single_quote) {
            in_double_quote = !in_double_quote;
            word_active = true;
            continue;
        }

        if ((c == ' ' or c == '\t' or c == '\n') and !in_single_quote and !in_double_quote) {
            if (word_active) {
                const word = try allocator.dupe(u8, current.items);
                try result.append(allocator, word);
                current.clearRetainingCapacity();
                word_active = false;
            }
            continue;
        }

        // `#` at the start of a word (unquoted) begins a comment to end of string.
        if (c == '#' and !in_single_quote and !in_double_quote and !word_active) {
            break;
        }

        try current.append(allocator, c);
        word_active = true;
    }

    // Don't forget last word
    if (word_active) {
        const word = try allocator.dupe(u8, current.items);
        try result.append(allocator, word);
    }

    return result.toOwnedSlice(allocator);
}

fn writeAll(fd: c_int, msg: []const u8) void {
    // A single write(2) may transfer fewer bytes than requested (e.g. a full
    // pipe). Loop until the whole slice is written so output is never silently
    // truncated.
    var off: usize = 0;
    while (off < msg.len) {
        const n = libc.write(fd, msg.ptr + off, msg.len - off);
        if (n <= 0) return; // EOF or error; nothing more we can do here
        off += @intCast(n);
    }
}

fn writeStdout(msg: []const u8) void {
    writeAll(libc.STDOUT_FILENO, msg);
}

fn writeStderr(msg: []const u8) void {
    writeAll(libc.STDERR_FILENO, msg);
}

fn printUsage() void {
    const usage =
        \\Usage: zenv [OPTION]... [-] [NAME=VALUE]... [COMMAND [ARG]...]
        \\
        \\Set each NAME to VALUE in the environment and run COMMAND.
        \\
        \\Options:
        \\  -i, --ignore-environment  Start with an empty environment
        \\  -0, --null                End each output line with NUL, not newline
        \\  -u, --unset=NAME          Remove variable from the environment
        \\  -C, --chdir=DIR           Change working directory to DIR
        \\  -S, --split-string=S      Split S into arguments (supports quotes)
        \\  -a, --argv0=ARG           Pass ARG as the zeroth argument of COMMAND
        \\      --help                Display this help and exit
        \\      --version             Output version information and exit
        \\
        \\A mere - implies -i. If no COMMAND, print the resulting environment.
        \\
        \\Examples:
        \\  zenv                      # Print all environment variables
        \\  zenv -i                   # Print empty environment
        \\  zenv FOO=bar              # Print env with FOO=bar added
        \\  zenv -u HOME              # Print env without HOME
        \\  zenv PATH=/bin ls         # Run 'ls' with modified PATH
        \\  zenv -i HOME=/tmp bash    # Run bash with minimal env
        \\  zenv -S'FOO=x BAR=y cmd'  # Split string into multiple args
        \\
    ;
    // GNU coreutils writes --help to stdout with exit status 0.
    writeStdout(usage);
}

fn printVersion() void {
    // GNU coreutils writes --version to stdout with exit status 0.
    writeStdout("zenv " ++ VERSION ++ " - High-performance environment utility\n");
}

fn parseArgs(args: []const []const u8, allocator: std.mem.Allocator) !Config {
    var config = Config{};
    var i: usize = 0;

    // Storage for split string arguments (need to track for later processing)
    // Note: strings in extra_args are transferred to config.set_vars, not freed here
    var extra_args: std.ArrayListUnmanaged([]const u8) = .empty;
    defer extra_args.deinit(allocator);
    var extra_idx: usize = 0;

    while (i < args.len or extra_idx < extra_args.items.len) {
        // Get next argument from either original args or extra_args from -S
        var arg: []const u8 = undefined;

        if (extra_idx < extra_args.items.len) {
            arg = extra_args.items[extra_idx];
            extra_idx += 1;
        } else {
            arg = args[i];
            i += 1;
        }

        // Check for - alone (implies -i)
        if (std.mem.eql(u8, arg, "-")) {
            config.ignore_env = true;
            continue;
        }

        // Options start with -
        if (arg.len > 0 and arg[0] == '-') {
            if (std.mem.eql(u8, arg, "-i") or std.mem.eql(u8, arg, "--ignore-environment")) {
                config.ignore_env = true;
            } else if (std.mem.eql(u8, arg, "-0") or std.mem.eql(u8, arg, "--null")) {
                config.null_terminate = true;
            } else if (std.mem.eql(u8, arg, "-u") or std.mem.eql(u8, arg, "--unset")) {
                if (extra_idx < extra_args.items.len) {
                    try config.unset_vars.append(allocator, extra_args.items[extra_idx]);
                    extra_idx += 1;
                } else if (i < args.len) {
                    try config.unset_vars.append(allocator, args[i]);
                    i += 1;
                } else {
                    writeStderr("zenv: option '-u' requires an argument\n");
                    return error.MissingArgument;
                }
            } else if (std.mem.startsWith(u8, arg, "-u")) {
                try config.unset_vars.append(allocator, arg[2..]);
            } else if (std.mem.startsWith(u8, arg, "--unset=")) {
                try config.unset_vars.append(allocator, arg[8..]);
            } else if (std.mem.eql(u8, arg, "-C") or std.mem.eql(u8, arg, "--chdir")) {
                if (extra_idx < extra_args.items.len) {
                    config.chdir_path = extra_args.items[extra_idx];
                    extra_idx += 1;
                } else if (i < args.len) {
                    config.chdir_path = args[i];
                    i += 1;
                } else {
                    writeStderr("zenv: option '-C' requires an argument\n");
                    return error.MissingArgument;
                }
            } else if (std.mem.startsWith(u8, arg, "-C")) {
                config.chdir_path = arg[2..];
            } else if (std.mem.startsWith(u8, arg, "--chdir=")) {
                config.chdir_path = arg[8..];
            } else if (std.mem.eql(u8, arg, "-S") or std.mem.eql(u8, arg, "--split-string")) {
                if (i >= args.len) {
                    writeStderr("zenv: option '-S' requires an argument\n");
                    return error.MissingArgument;
                }
                const split_words = try splitString(args[i], allocator);
                for (split_words) |word| {
                    try extra_args.append(allocator, word);
                }
                allocator.free(split_words);
                i += 1;
            } else if (std.mem.startsWith(u8, arg, "-S")) {
                const split_words = try splitString(arg[2..], allocator);
                for (split_words) |word| {
                    try extra_args.append(allocator, word);
                }
                allocator.free(split_words);
            } else if (std.mem.startsWith(u8, arg, "--split-string=")) {
                const split_words = try splitString(arg[15..], allocator);
                for (split_words) |word| {
                    try extra_args.append(allocator, word);
                }
                allocator.free(split_words);
            } else if (std.mem.eql(u8, arg, "-a") or std.mem.eql(u8, arg, "--argv0")) {
                // Value may come from the -S split stream or the original argv.
                if (extra_idx < extra_args.items.len) {
                    config.argv0 = extra_args.items[extra_idx];
                    extra_idx += 1;
                } else if (i < args.len) {
                    config.argv0 = args[i];
                    i += 1;
                } else {
                    writeStderr("zenv: option '-a' requires an argument\n");
                    return error.MissingArgument;
                }
            } else if (std.mem.startsWith(u8, arg, "-a")) {
                config.argv0 = arg[2..];
            } else if (std.mem.startsWith(u8, arg, "--argv0=")) {
                config.argv0 = arg[8..];
            } else if (std.mem.eql(u8, arg, "--help")) {
                printUsage();
                std.process.exit(0);
            } else if (std.mem.eql(u8, arg, "--version")) {
                printVersion();
                std.process.exit(0);
            } else if (arg.len > 1 and arg[1] != '-') {
                // Combined short options like -i0
                for (arg[1..]) |ch| {
                    switch (ch) {
                        'i' => config.ignore_env = true,
                        '0' => config.null_terminate = true,
                        else => {
                            var err_buf: [64]u8 = undefined;
                            const err_msg = std.fmt.bufPrint(&err_buf, "zenv: invalid option -- '{c}'\n", .{ch}) catch "zenv: invalid option\n";
                            writeStderr(err_msg);
                            return error.InvalidOption;
                        },
                    }
                }
            } else {
                var err_buf: [256]u8 = undefined;
                const err_msg = std.fmt.bufPrint(&err_buf, "zenv: unrecognized option '{s}'\n", .{arg}) catch "zenv: unrecognized option\n";
                writeStderr(err_msg);
                return error.InvalidOption;
            }
        } else if (std.mem.indexOfScalar(u8, arg, '=') != null) {
            // NAME=VALUE assignment
            try config.set_vars.append(allocator, arg);
        } else {
            // First non-option, non-assignment token: the COMMAND begins here.
            // Tokens can arrive from two streams (the -S split words in
            // `extra_args`, then the tail of the original `args`), so we cannot
            // simply slice `args`. Splicing them the way GNU does — the split
            // words occupy the position the -S option held — the command is:
            //   [arg] ++ extra_args[extra_idx..] ++ args[i..]
            // (`arg` is the current token; whichever stream it came from has
            // already advanced past it.)
            var cmd_list: std.ArrayListUnmanaged([]const u8) = .empty;
            try cmd_list.append(allocator, arg);
            while (extra_idx < extra_args.items.len) : (extra_idx += 1) {
                try cmd_list.append(allocator, extra_args.items[extra_idx]);
            }
            while (i < args.len) : (i += 1) {
                try cmd_list.append(allocator, args[i]);
            }
            config.command = try cmd_list.toOwnedSlice(allocator);
            break;
        }
    }

    return config;
}

fn printEnvironment(config: *const Config) void {
    const terminator: []const u8 = if (config.null_terminate) "\x00" else "\n";

    if (config.ignore_env) {
        // Only print set_vars
        for (config.set_vars.items) |var_str| {
            writeStdout(var_str);
            writeStdout(terminator);
        }
    } else {
        // Iterate through std.c.environ directly
        var env_idx: usize = 0;
        while (std.c.environ[env_idx]) |env_entry| : (env_idx += 1) {
            const env_str = std.mem.span(env_entry);

            // Find '=' to extract key
            const eq_pos = std.mem.indexOfScalar(u8, env_str, '=') orelse continue;
            const key = env_str[0..eq_pos];

            // Check if this var should be unset
            var should_skip = false;
            for (config.unset_vars.items) |unset_name| {
                if (std.mem.eql(u8, key, unset_name)) {
                    should_skip = true;
                    break;
                }
            }

            // Check if this var is being overridden
            for (config.set_vars.items) |set_str| {
                if (std.mem.indexOfScalar(u8, set_str, '=')) |set_eq_pos| {
                    if (std.mem.eql(u8, key, set_str[0..set_eq_pos])) {
                        should_skip = true;
                        break;
                    }
                }
            }

            if (!should_skip) {
                writeStdout(env_str);
                writeStdout(terminator);
            }
        }

        // Print set_vars
        for (config.set_vars.items) |var_str| {
            writeStdout(var_str);
            writeStdout(terminator);
        }
    }
}

/// _PATH_DEFPATH — the compiled-in default GNU/BSD uses when PATH is unset.
const DEFAULT_PATH = "/usr/bin:/bin";

/// Compute the PATH value of the environment zenv is about to hand the child —
/// NOT the inherited process PATH. GNU env resolves the command against the PATH
/// of the modified environment, so `-i PATH=/x cmd` and `PATH=/x cmd` must search
/// /x. Precedence: a `PATH=` in set_vars wins (last one), otherwise the inherited
/// PATH (unless -i or `-u PATH`), otherwise null (caller falls back to default).
fn effectivePath(config: *const Config) ?[]const u8 {
    var result: ?[]const u8 = null;

    if (!config.ignore_env) {
        var path_unset = false;
        for (config.unset_vars.items) |name| {
            if (std.mem.eql(u8, name, "PATH")) {
                path_unset = true;
                break;
            }
        }
        if (!path_unset) {
            var env_idx: usize = 0;
            while (std.c.environ[env_idx]) |env_entry| : (env_idx += 1) {
                const env_str = std.mem.span(env_entry);
                if (std.mem.startsWith(u8, env_str, "PATH=")) {
                    result = env_str[5..];
                    break;
                }
            }
        }
    }

    // set_vars override the inherited value; last assignment wins.
    for (config.set_vars.items) |set_str| {
        if (std.mem.startsWith(u8, set_str, "PATH=")) {
            result = set_str[5..];
        }
    }

    return result;
}

/// Find an executable using `search_path` (the effective child PATH), returning a
/// null-terminated path if found. When `search_path` is null (no PATH in the
/// child environment) GNU falls back to _PATH_DEFPATH.
fn findExecutable(cmd: []const u8, search_path: ?[]const u8, path_buf: []u8) ?[*:0]const u8 {
    // If the command contains a slash, use it directly
    if (std.mem.indexOfScalar(u8, cmd, '/') != null) {
        const path_z = std.fmt.bufPrintZ(path_buf, "{s}", .{cmd}) catch return null;
        if (access(path_z.ptr, X_OK) == 0) {
            return path_z.ptr;
        }
        return null;
    }

    const path_val = search_path orelse DEFAULT_PATH;
    var path_iter = std.mem.splitScalar(u8, path_val, ':');
    while (path_iter.next()) |dir| {
        if (dir.len == 0) continue;
        const full_path = std.fmt.bufPrintZ(path_buf, "{s}/{s}", .{ dir, cmd }) catch continue;
        if (access(full_path.ptr, X_OK) == 0) {
            return full_path.ptr;
        }
    }
    return null;
}

fn runCommand(config: *const Config, allocator: std.mem.Allocator) !void {
    const cmd = config.command orelse return;
    if (cmd.len == 0) return;

    // Build environment
    var env_list: std.ArrayListUnmanaged(?[*:0]const u8) = .empty;
    defer env_list.deinit(allocator);

    if (!config.ignore_env) {
        // Add current environment (excluding unset ones and overrides)
        // Iterate through std.c.environ directly
        var env_idx: usize = 0;
        while (std.c.environ[env_idx]) |env_entry| : (env_idx += 1) {
            const env_str = std.mem.span(env_entry);
            var should_skip = false;

            // Find the '=' separator to get the key
            const eq_pos = std.mem.indexOfScalar(u8, env_str, '=') orelse continue;
            const key = env_str[0..eq_pos];

            // Check unset list
            for (config.unset_vars.items) |unset_name| {
                if (std.mem.eql(u8, key, unset_name)) {
                    should_skip = true;
                    break;
                }
            }

            // Check override list
            for (config.set_vars.items) |set_str| {
                if (std.mem.indexOfScalar(u8, set_str, '=')) |set_eq_pos| {
                    if (std.mem.eql(u8, key, set_str[0..set_eq_pos])) {
                        should_skip = true;
                        break;
                    }
                }
            }

            if (!should_skip) {
                // Copy the environment string with null terminator
                const env_z = try allocator.allocSentinel(u8, env_str.len, 0);
                @memcpy(env_z, env_str);
                try env_list.append(allocator, env_z.ptr);
            }
        }
    }

    // Add set_vars
    for (config.set_vars.items) |var_str| {
        const env_z = try allocator.allocSentinel(u8, var_str.len, 0);
        @memcpy(env_z, var_str);
        try env_list.append(allocator, env_z.ptr);
    }

    // Null terminate the env array
    try env_list.append(allocator, null);

    // chdir (if requested) is applied by the caller before we get here.

    // Build argv - need to convert slices to null-terminated strings.
    // -a/--argv0 overrides the zeroth argument handed to the child, but the
    // executable is still located from the real command name (cmd[0]).
    var argv: std.ArrayListUnmanaged(?[*:0]const u8) = .empty;
    const argv0 = config.argv0 orelse cmd[0];
    {
        const arg0_z = try allocator.dupeZ(u8, argv0);
        try argv.append(allocator, arg0_z.ptr);
    }
    for (cmd[1..]) |arg| {
        const arg_z = try allocator.dupeZ(u8, arg);
        try argv.append(allocator, arg_z.ptr);
    }
    try argv.append(allocator, null);

    // Find the executable using the PATH of the *modified* environment.
    const search_path = effectivePath(config);
    var exec_path_buf: [4096]u8 = undefined;
    const exec_path = findExecutable(cmd[0], search_path, &exec_path_buf) orelse {
        var err_buf: [256]u8 = undefined;
        const err_msg = std.fmt.bufPrint(&err_buf, "zenv: '{s}': No such file or directory\n", .{cmd[0]}) catch "zenv: command not found\n";
        writeStderr(err_msg);
        std.process.exit(127);
    };

    // Execute command - execve never returns on success
    _ = execve(exec_path, @ptrCast(argv.items.ptr), @ptrCast(env_list.items.ptr));

    // If we get here, exec failed
    var err_buf: [256]u8 = undefined;
    const err_msg = std.fmt.bufPrint(&err_buf, "zenv: '{s}': cannot execute\n", .{cmd[0]}) catch "zenv: exec failed\n";
    writeStderr(err_msg);
    std.process.exit(126);
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

    var config = parseArgs(args[1..], allocator) catch {
        std.process.exit(125);
    };
    defer config.unset_vars.deinit(allocator);
    defer config.set_vars.deinit(allocator);

    // GNU honors -C/--chdir even when no COMMAND is supplied (and errors if the
    // directory change fails), so apply it before either branch.
    if (config.chdir_path) |path| {
        var path_buf: [4096]u8 = undefined;
        const path_z = std.fmt.bufPrintZ(&path_buf, "{s}", .{path}) catch {
            writeStderr("zenv: path too long\n");
            std.process.exit(125);
        };
        if (chdir(path_z) != 0) {
            var err_buf: [4352]u8 = undefined;
            const err_msg = std.fmt.bufPrint(&err_buf, "zenv: cannot change directory to '{s}'\n", .{path}) catch "zenv: cannot change directory\n";
            writeStderr(err_msg);
            std.process.exit(125);
        }
    }

    if (config.command) |_| {
        try runCommand(&config, allocator);
    } else {
        printEnvironment(&config);
    }
}
