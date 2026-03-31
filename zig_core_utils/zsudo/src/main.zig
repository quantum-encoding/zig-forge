//! zsudo - Zig implementation of sudo
//!
//! Execute commands as another user (typically root) with authentication.
//!
//! Features:
//! - PAM authentication
//! - Run as specified user (-u)
//! - Preserve or sanitize environment (-E)
//! - Login shell mode (-i)
//! - Shell mode (-s)
//! - Credential caching with timeout
//! - Basic sudoers-style authorization
//!
//! SECURITY NOTE: This binary must be installed setuid root to function:
//!   chown root:root zsudo && chmod 4755 zsudo

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const libc = std.c;

// Additional C functions not in std.c
extern "c" fn fopen(path: [*:0]const u8, mode: [*:0]const u8) ?*anyopaque;
extern "c" fn fclose(stream: *anyopaque) c_int;
extern "c" fn fgets(buf: [*]u8, size: c_int, stream: *anyopaque) ?[*]u8;
extern "c" fn tcgetattr(fd: c_int, termios_p: *Termios) c_int;
extern "c" fn tcsetattr(fd: c_int, action: c_int, termios_p: *const Termios) c_int;
extern "c" fn time(t: ?*i64) i64;
extern "c" fn mkdir(path: [*:0]const u8, mode: libc.mode_t) c_int;
extern "c" fn unlink(path: [*:0]const u8) c_int;

const TCSANOW: c_int = 0;
const ECHO_FLAG: u32 = 8;

const Termios = switch (builtin.os.tag) {
    .macos => extern struct {
        c_iflag: c_ulong,
        c_oflag: c_ulong,
        c_cflag: c_ulong,
        c_lflag: c_ulong,
        c_cc: [20]u8,
        c_ispeed: c_ulong,
        c_ospeed: c_ulong,
    },
    else => extern struct {
        c_iflag: u32,
        c_oflag: u32,
        c_cflag: u32,
        c_lflag: u32,
        c_line: u8,
        c_cc: [32]u8,
        __c_ispeed: u32,
        __c_ospeed: u32,
    },
};

const Timespec = extern struct {
    tv_sec: i64,
    tv_nsec: i64,
};

const StatBuf = switch (builtin.os.tag) {
    .macos => extern struct {
        st_dev: i32,
        st_mode: u16,
        st_nlink: u16,
        st_ino: u64,
        st_uid: u32,
        st_gid: u32,
        st_rdev: i32,
        st_atimespec: Timespec,
        st_mtimespec: Timespec,
        st_ctimespec: Timespec,
        st_birthtimespec: Timespec,
        st_size: i64,
        st_blocks: i64,
        st_blksize: i32,
        st_flags: u32,
        st_gen: u32,
        st_lspare: i32,
        st_qspare: [2]i64,
    },
    else => extern struct {
        st_dev: u64,
        st_ino: u64,
        st_nlink: u64,
        st_mode: u32,
        st_uid: u32,
        st_gid: u32,
        __pad0: u32,
        st_rdev: u64,
        st_size: i64,
        st_blksize: i64,
        st_blocks: i64,
        st_atime: i64,
        st_atime_nsec: i64,
        st_mtime: i64,
        st_mtime_nsec: i64,
        st_ctime: i64,
        st_ctime_nsec: i64,
        __unused: [3]i64,
    },
};

// PAM types and functions
const pam_handle_t = opaque {};
const pam_message = extern struct {
    msg_style: c_int,
    msg: [*:0]const u8,
};
const pam_response = extern struct {
    resp: ?[*:0]u8,
    resp_retcode: c_int,
};
const PamConvFn = *const fn (c_int, [*]const *const pam_message, [*]*pam_response, ?*anyopaque) callconv(.c) c_int;
const pam_conv = extern struct {
    conv: ?PamConvFn,
    appdata_ptr: ?*anyopaque,
};

// PAM constants
const PAM_SUCCESS: c_int = 0;
const PAM_PROMPT_ECHO_OFF: c_int = 1;
const PAM_PROMPT_ECHO_ON: c_int = 2;
const PAM_ERROR_MSG: c_int = 3;
const PAM_TEXT_INFO: c_int = 4;

// PAM functions
extern "c" fn pam_start(service: [*:0]const u8, user: [*:0]const u8, conv: *const pam_conv, pamh: **pam_handle_t) c_int;
extern "c" fn pam_end(pamh: *pam_handle_t, status: c_int) c_int;
extern "c" fn pam_authenticate(pamh: *pam_handle_t, flags: c_int) c_int;
extern "c" fn pam_acct_mgmt(pamh: *pam_handle_t, flags: c_int) c_int;
extern "c" fn pam_setcred(pamh: *pam_handle_t, flags: c_int) c_int;
extern "c" fn pam_strerror(pamh: ?*pam_handle_t, errnum: c_int) [*:0]const u8;

// System functions
extern "c" fn getpwnam(name: [*:0]const u8) ?*const Passwd;
extern "c" fn getpwuid(uid: libc.uid_t) ?*const Passwd;
extern "c" fn getgrnam(name: [*:0]const u8) ?*const Group;
extern "c" fn getgrouplist(user: [*:0]const u8, group: libc.gid_t, groups: [*]libc.gid_t, ngroups: *c_int) c_int;
extern "c" fn initgroups(user: [*:0]const u8, group: libc.gid_t) c_int;
extern "c" fn syslog(priority: c_int, format: [*:0]const u8, ...) void;
extern "c" fn openlog(ident: [*:0]const u8, option: c_int, facility: c_int) void;
extern "c" fn ttyname(fd: c_int) ?[*:0]const u8;
extern "c" fn isatty(fd: c_int) c_int;
extern "c" fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;
extern "c" fn stat(path: [*:0]const u8, buf: *StatBuf) c_int;
extern var environ: [*:null]?[*:0]const u8;

const Passwd = switch (builtin.os.tag) {
    .macos => extern struct {
        pw_name: [*:0]const u8,
        pw_passwd: [*:0]const u8,
        pw_uid: libc.uid_t,
        pw_gid: libc.gid_t,
        pw_change: i64,
        pw_class: [*:0]const u8,
        pw_gecos: [*:0]const u8,
        pw_dir: [*:0]const u8,
        pw_shell: [*:0]const u8,
        pw_expire: i64,
        pw_fields: c_int,
    },
    else => extern struct {
        pw_name: [*:0]const u8,
        pw_passwd: [*:0]const u8,
        pw_uid: libc.uid_t,
        pw_gid: libc.gid_t,
        pw_gecos: [*:0]const u8,
        pw_dir: [*:0]const u8,
        pw_shell: [*:0]const u8,
    },
};

const Group = extern struct {
    gr_name: [*:0]const u8,
    gr_passwd: [*:0]const u8,
    gr_gid: libc.gid_t,
    gr_mem: [*:null]?[*:0]const u8,
};

// Syslog constants
const LOG_AUTH: c_int = 4 << 3;
const LOG_PID: c_int = 0x01;
const LOG_NOTICE: c_int = 5;
const LOG_WARNING: c_int = 4;
const LOG_ERR: c_int = 3;

// Credential cache file
const TIMESTAMP_DIR = "/run/zsudo";
const TIMESTAMP_TIMEOUT: i64 = 5 * 60; // 5 minutes

const Config = struct {
    target_user: []const u8 = "root",
    preserve_env: bool = false,
    login_shell: bool = false,
    shell_mode: bool = false,
    validate_only: bool = false,
    invalidate: bool = false,
    list_privs: bool = false,
    command: []const []const u8 = &.{},
    set_home: bool = true,
    stdin_password: bool = false,
};

// Simple I/O helpers
fn writeStderr(msg: []const u8) void {
    _ = libc.write(libc.STDERR_FILENO, msg.ptr, msg.len);
}

fn writeStdout(msg: []const u8) void {
    _ = libc.write(libc.STDOUT_FILENO, msg.ptr, msg.len);
}

// Global for PAM conversation
var g_password: ?[]const u8 = null;
var g_stdin_password: bool = false;

fn pamConversation(
    num_msg: c_int,
    messages: [*]const *const pam_message,
    responses: [*]*pam_response,
    _: ?*anyopaque,
) callconv(.c) c_int {
    const allocator = std.heap.c_allocator;

    const resp_array = allocator.alloc(pam_response, @intCast(num_msg)) catch return 1;

    var i: usize = 0;
    while (i < @as(usize, @intCast(num_msg))) : (i += 1) {
        const msg = messages[i];
        resp_array[i] = .{ .resp = null, .resp_retcode = 0 };

        switch (msg.msg_style) {
            PAM_PROMPT_ECHO_OFF => {
                // Password prompt
                if (g_password) |pwd| {
                    const pwd_copy = allocator.allocSentinel(u8, pwd.len, 0) catch return 1;
                    @memcpy(pwd_copy, pwd);
                    resp_array[i].resp = pwd_copy.ptr;
                } else {
                    return 1;
                }
            },
            PAM_PROMPT_ECHO_ON => {
                // Username prompt (shouldn't happen normally)
                resp_array[i].resp = null;
            },
            PAM_ERROR_MSG, PAM_TEXT_INFO => {
                // Display message
                writeStderr(std.mem.span(msg.msg));
                writeStderr("\n");
            },
            else => {},
        }
    }

    responses[0] = @ptrCast(resp_array.ptr);
    return PAM_SUCCESS;
}

fn readPassword(prompt: []const u8) ?[]const u8 {
    const stdin_fd: c_int = 0;

    if (g_stdin_password) {
        // -S mode: read password from stdin without prompt or echo changes
        var buf: [256]u8 = undefined;
        const n = posix.read(0, &buf) catch return null;
        if (n == 0) return null;

        var len = n;
        if (len > 0 and buf[len - 1] == '\n') len -= 1;

        const allocator = std.heap.c_allocator;
        const result = allocator.alloc(u8, len) catch return null;
        @memcpy(result, buf[0..len]);
        @memset(&buf, 0);
        return result;
    }

    // Disable echo for password input
    var termios_buf: Termios = undefined;

    const has_tty = isatty(stdin_fd) != 0;
    var old_termios: Termios = undefined;

    if (has_tty) {
        if (tcgetattr(stdin_fd, &termios_buf) != 0) {
            return null;
        }
        old_termios = termios_buf;
        termios_buf.c_lflag &= ~@as(@TypeOf(termios_buf.c_lflag), ECHO_FLAG);
        _ = tcsetattr(stdin_fd, TCSANOW, &termios_buf);
    }

    defer {
        if (has_tty) {
            _ = tcsetattr(stdin_fd, TCSANOW, &old_termios);
            writeStderr("\n");
        }
    }

    writeStderr(prompt);

    var buf: [256]u8 = undefined;
    const n = posix.read(0, &buf) catch return null;
    if (n == 0) return null;

    // Remove trailing newline
    var len = n;
    if (len > 0 and buf[len - 1] == '\n') len -= 1;

    const allocator = std.heap.c_allocator;
    const result = allocator.alloc(u8, len) catch return null;
    @memcpy(result, buf[0..len]);

    // Clear buffer
    @memset(&buf, 0);

    return result;
}

fn authenticateUser(username: []const u8) bool {
    const allocator = std.heap.c_allocator;

    // Check timestamp cache first
    if (checkTimestamp(username)) {
        return true;
    }

    // Prompt for password
    var prompt_buf: [256]u8 = undefined;
    const prompt = std.fmt.bufPrint(&prompt_buf, "[zsudo] password for {s}: ", .{username}) catch return false;

    const password = readPassword(prompt) orelse return false;
    defer {
        // Securely clear password
        const pw_slice = @as([*]u8, @ptrCast(@constCast(password.ptr)))[0..password.len];
        @memset(pw_slice, 0);
        allocator.free(password);
    }

    g_password = password;
    defer {
        g_password = null;
    }

    // PAM authentication
    const conv = pam_conv{
        .conv = &pamConversation,
        .appdata_ptr = null,
    };

    const username_z = allocator.dupeZ(u8, username) catch return false;
    defer allocator.free(username_z);

    var pamh: *pam_handle_t = undefined;
    var ret = pam_start("sudo", username_z.ptr, &conv, &pamh);
    if (ret != PAM_SUCCESS) {
        writeStderr("zsudo: PAM initialization failed\n");
        return false;
    }
    defer _ = pam_end(pamh, ret);

    ret = pam_authenticate(pamh, 0);
    if (ret != PAM_SUCCESS) {
        const err = pam_strerror(pamh, ret);
        writeStderr("zsudo: authentication failed: ");
        writeStderr(std.mem.span(err));
        writeStderr("\n");
        logAuthFailure(username);
        return false;
    }

    ret = pam_acct_mgmt(pamh, 0);
    if (ret != PAM_SUCCESS) {
        const err = pam_strerror(pamh, ret);
        writeStderr("zsudo: account validation failed: ");
        writeStderr(std.mem.span(err));
        writeStderr("\n");
        return false;
    }

    // Update timestamp
    updateTimestamp(username);

    return true;
}

fn checkTimestamp(username: []const u8) bool {
    var path_buf: [256]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ TIMESTAMP_DIR, username }) catch return false;

    const path_z = std.heap.c_allocator.dupeZ(u8, path) catch return false;
    defer std.heap.c_allocator.free(path_z);

    var stat_buf: StatBuf = undefined;
    if (stat(path_z.ptr, &stat_buf) != 0) {
        return false;
    }

    const now = time(null);
    const mtime = switch (builtin.os.tag) {
        .macos => stat_buf.st_mtimespec.tv_sec,
        else => stat_buf.st_mtime,
    };

    return (now - mtime) < TIMESTAMP_TIMEOUT;
}

fn updateTimestamp(username: []const u8) void {
    const allocator = std.heap.c_allocator;

    // Create directory if it doesn't exist
    const dir_z = allocator.dupeZ(u8, TIMESTAMP_DIR) catch return;
    defer allocator.free(dir_z);

    _ = mkdir(dir_z.ptr, 0o700);

    var path_buf: [256]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ TIMESTAMP_DIR, username }) catch return;
    const path_z = allocator.dupeZ(u8, path) catch return;
    defer allocator.free(path_z);

    // Create or update timestamp file
    const fd = libc.open(path_z.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(libc.mode_t, 0o600));
    if (fd >= 0) {
        _ = libc.close(fd);
    }
}

fn invalidateTimestamp(username: []const u8) void {
    const allocator = std.heap.c_allocator;

    var path_buf: [256]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ TIMESTAMP_DIR, username }) catch return;
    const path_z = allocator.dupeZ(u8, path) catch return;
    defer allocator.free(path_z);

    _ = unlink(path_z.ptr);
}

fn logAuthFailure(username: []const u8) void {
    const allocator = std.heap.c_allocator;
    const username_z = allocator.dupeZ(u8, username) catch return;
    defer allocator.free(username_z);

    openlog("zsudo", LOG_PID, LOG_AUTH);
    syslog(LOG_WARNING, "authentication failure for %s", username_z.ptr);
}

fn logCommand(username: []const u8, target_user: []const u8, command: []const []const u8) void {
    const allocator = std.heap.c_allocator;

    var cmd_buf: [1024]u8 = undefined;
    var pos: usize = 0;
    for (command) |arg| {
        if (pos > 0 and pos < cmd_buf.len) {
            cmd_buf[pos] = ' ';
            pos += 1;
        }
        const to_copy = @min(arg.len, cmd_buf.len - pos);
        @memcpy(cmd_buf[pos..][0..to_copy], arg[0..to_copy]);
        pos += to_copy;
    }

    const username_z = allocator.dupeZ(u8, username) catch return;
    defer allocator.free(username_z);

    const target_z = allocator.dupeZ(u8, target_user) catch return;
    defer allocator.free(target_z);

    const cmd_z = allocator.dupeZ(u8, cmd_buf[0..pos]) catch return;
    defer allocator.free(cmd_z);

    openlog("zsudo", LOG_PID, LOG_AUTH);
    syslog(LOG_NOTICE, "%s : command=%s ; USER=%s", username_z.ptr, cmd_z.ptr, target_z.ptr);
}

/// Resolve a group name to its GID by parsing /etc/group directly.
/// This avoids a Zig std.c bug where getgrnam() is declared with wrong return type.
fn resolveGroupGid(name: []const u8) ?libc.gid_t {
    const allocator = std.heap.c_allocator;
    const path_z = allocator.dupeZ(u8, "/etc/group") catch return null;
    defer allocator.free(path_z);

    const f = fopen(path_z.ptr, "r");
    if (f == null) return null;
    defer _ = fclose(f.?);

    var buf: [4096]u8 = undefined;
    while (fgets(&buf, @intCast(buf.len), f.?) != null) {
        var len: usize = 0;
        while (len < buf.len and buf[len] != 0 and buf[len] != '\n') : (len += 1) {}
        const line = buf[0..len];

        // Format: name:password:gid:members
        // Find first ':'
        const first_colon = std.mem.indexOf(u8, line, ":") orelse continue;
        const group_name = line[0..first_colon];

        if (!std.mem.eql(u8, group_name, name)) continue;

        // Skip password field
        const rest = line[first_colon + 1 ..];
        const second_colon = std.mem.indexOf(u8, rest, ":") orelse continue;
        const after_passwd = rest[second_colon + 1 ..];
        const third_colon = std.mem.indexOf(u8, after_passwd, ":");
        const gid_str = if (third_colon) |tc| after_passwd[0..tc] else after_passwd;

        return std.fmt.parseInt(libc.gid_t, gid_str, 10) catch continue;
    }
    return null;
}

fn isUserAuthorized(username: []const u8, target_user: []const u8) bool {
    const allocator = std.heap.c_allocator;

    // Check if user is in sudo or wheel group
    const username_z = allocator.dupeZ(u8, username) catch return false;
    defer allocator.free(username_z);

    const pw = getpwnam(username_z.ptr) orelse return false;

    var groups: [64]libc.gid_t = undefined;
    var ngroups: c_int = 64;

    const gl_ret = getgrouplist(username_z.ptr, pw.pw_gid, &groups, &ngroups);
    if (gl_ret < 0) {
        return false;
    }

    const actual_ngroups: usize = if (gl_ret > 0) @intCast(gl_ret) else @intCast(ngroups);

    // Resolve wheel and sudo group GIDs from /etc/group
    // (Cannot use getgrnam due to Zig std.c bug: returns *passwd instead of *group)
    const wheel_gid = resolveGroupGid("wheel");
    const sudo_gid = resolveGroupGid("sudo");

    for (groups[0..actual_ngroups]) |gid| {
        if (wheel_gid) |wgid| {
            if (gid == wgid) return true;
        }
        if (sudo_gid) |sgid| {
            if (gid == sgid) return true;
        }
    }

    // Check if user is root
    if (pw.pw_uid == 0) return true;

    // Check /etc/sudoers (simplified)
    if (checkSudoers(username, target_user)) return true;

    return false;
}

fn checkSudoers(username: []const u8, target_user: []const u8) bool {
    _ = target_user;
    const allocator = std.heap.c_allocator;

    // Read /etc/sudoers using C file operations
    const sudoers_path = "/etc/sudoers";
    const sudoers_z = allocator.dupeZ(u8, sudoers_path) catch return false;
    defer allocator.free(sudoers_z);

    const file = fopen(sudoers_z.ptr, "r");
    if (file == null) return false;
    defer _ = fclose(file.?);

    var buf: [4096]u8 = undefined;
    while (fgets(&buf, @intCast(buf.len), file.?) != null) {
        // Find end of line
        var len: usize = 0;
        while (len < buf.len and buf[len] != 0 and buf[len] != '\n') : (len += 1) {}

        const l = buf[0..len];

        // Skip comments and empty lines
        if (l.len == 0 or l[0] == '#') continue;

        // Simple check: username ALL=(ALL) ALL or username ALL=(ALL:ALL) ALL
        if (std.mem.startsWith(u8, l, username)) {
            if (std.mem.indexOf(u8, l, "ALL=(ALL")) |_| {
                if (std.mem.indexOf(u8, l, ") ALL") != null or
                    std.mem.indexOf(u8, l, ") NOPASSWD: ALL") != null)
                {
                    return true;
                }
            }
        }
    }

    // Also check /etc/sudoers.d/ - simplified: just check a few common files
    const sudoers_d_files = [_][]const u8{
        "/etc/sudoers.d/wheel",
        "/etc/sudoers.d/sudo",
        "/etc/sudoers.d/90-cloud-init-users",
    };

    for (sudoers_d_files) |path| {
        const path_z = allocator.dupeZ(u8, path) catch continue;
        defer allocator.free(path_z);

        const f = fopen(path_z.ptr, "r");
        if (f == null) continue;
        defer _ = fclose(f.?);

        var buf2: [4096]u8 = undefined;
        while (fgets(&buf2, @intCast(buf2.len), f.?) != null) {
            var len: usize = 0;
            while (len < buf2.len and buf2[len] != 0 and buf2[len] != '\n') : (len += 1) {}

            const l = buf2[0..len];
            if (l.len == 0 or l[0] == '#') continue;

            if (std.mem.startsWith(u8, l, username)) {
                if (std.mem.indexOf(u8, l, "ALL=(ALL")) |_| {
                    if (std.mem.indexOf(u8, l, ") ALL") != null or
                        std.mem.indexOf(u8, l, ") NOPASSWD: ALL") != null)
                    {
                        return true;
                    }
                }
            }
        }
    }

    return false;
}

fn executeCommand(config: *const Config, target_pw: *const Passwd) !void {
    const allocator = std.heap.c_allocator;

    // Build command
    var cmd_args: std.ArrayListUnmanaged(?[*:0]const u8) = .empty;
    defer cmd_args.deinit(allocator);

    if (config.login_shell or config.shell_mode) {
        // Use target user's shell
        try cmd_args.append(allocator, target_pw.pw_shell);

        if (config.login_shell) {
            try cmd_args.append(allocator, "-l");
        }

        if (config.command.len > 0) {
            try cmd_args.append(allocator, "-c");

            // Join command into single string
            var total_len: usize = 0;
            for (config.command) |arg| {
                total_len += arg.len + 1;
            }

            const cmd_str = try allocator.allocSentinel(u8, total_len, 0);
            var pos: usize = 0;
            for (config.command, 0..) |arg, i| {
                if (i > 0) {
                    cmd_str[pos] = ' ';
                    pos += 1;
                }
                @memcpy(cmd_str[pos..][0..arg.len], arg);
                pos += arg.len;
            }
            try cmd_args.append(allocator, cmd_str.ptr);
        }
    } else {
        // Direct command execution
        for (config.command) |arg| {
            const arg_z = try allocator.dupeZ(u8, arg);
            try cmd_args.append(allocator, arg_z.ptr);
        }
    }

    try cmd_args.append(allocator, null);

    // Set up environment
    var env_list: std.ArrayListUnmanaged(?[*:0]const u8) = .empty;
    defer env_list.deinit(allocator);

    // Basic environment
    var home_buf: [256]u8 = undefined;
    const home_env = try std.fmt.bufPrintZ(&home_buf, "HOME={s}", .{std.mem.span(target_pw.pw_dir)});
    try env_list.append(allocator, home_env.ptr);

    var user_buf: [256]u8 = undefined;
    const user_env = try std.fmt.bufPrintZ(&user_buf, "USER={s}", .{std.mem.span(target_pw.pw_name)});
    try env_list.append(allocator, user_env.ptr);

    var logname_buf: [256]u8 = undefined;
    const logname_env = try std.fmt.bufPrintZ(&logname_buf, "LOGNAME={s}", .{std.mem.span(target_pw.pw_name)});
    try env_list.append(allocator, logname_env.ptr);

    var shell_buf: [256]u8 = undefined;
    const shell_env = try std.fmt.bufPrintZ(&shell_buf, "SHELL={s}", .{std.mem.span(target_pw.pw_shell)});
    try env_list.append(allocator, shell_env.ptr);

    // Preserve PATH
    if (std.c.getenv("PATH")) |path| {
        var path_buf: [4096]u8 = undefined;
        const path_env = try std.fmt.bufPrintZ(&path_buf, "PATH={s}", .{std.mem.span(path)});
        try env_list.append(allocator, path_env.ptr);
    } else {
        try env_list.append(allocator, "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin");
    }

    // Preserve TERM
    if (std.c.getenv("TERM")) |term| {
        var term_buf: [256]u8 = undefined;
        const term_env = try std.fmt.bufPrintZ(&term_buf, "TERM={s}", .{std.mem.span(term)});
        try env_list.append(allocator, term_env.ptr);
    }

    // Preserve additional environment if -E
    if (config.preserve_env) {
        var env_ptr = std.c.environ;
        while (env_ptr[0]) |env_var| {
            // Skip already set vars
            const span = std.mem.span(env_var);
            if (!std.mem.startsWith(u8, span, "HOME=") and
                !std.mem.startsWith(u8, span, "USER=") and
                !std.mem.startsWith(u8, span, "LOGNAME=") and
                !std.mem.startsWith(u8, span, "SHELL=") and
                !std.mem.startsWith(u8, span, "PATH=") and
                !std.mem.startsWith(u8, span, "TERM=") and
                !std.mem.startsWith(u8, span, "SUDO_") and
                !std.mem.startsWith(u8, span, "LD_"))
            {
                try env_list.append(allocator, env_var);
            }
            env_ptr += 1;
        }
    }

    // Add SUDO_USER, SUDO_UID, SUDO_GID
    const calling_pw = getpwuid(libc.getuid()) orelse return error.GetpwuidFailed;

    var sudo_user_buf: [256]u8 = undefined;
    const sudo_user = try std.fmt.bufPrintZ(&sudo_user_buf, "SUDO_USER={s}", .{std.mem.span(calling_pw.pw_name)});
    try env_list.append(allocator, sudo_user.ptr);

    var sudo_uid_buf: [64]u8 = undefined;
    const sudo_uid = try std.fmt.bufPrintZ(&sudo_uid_buf, "SUDO_UID={d}", .{libc.getuid()});
    try env_list.append(allocator, sudo_uid.ptr);

    var sudo_gid_buf: [64]u8 = undefined;
    const sudo_gid = try std.fmt.bufPrintZ(&sudo_gid_buf, "SUDO_GID={d}", .{libc.getgid()});
    try env_list.append(allocator, sudo_gid.ptr);

    try env_list.append(allocator, null);

    // Change to target user's home directory if -i
    if (config.login_shell) {
        _ = libc.chdir(target_pw.pw_dir);
    }

    // Set supplementary groups
    _ = initgroups(target_pw.pw_name, target_pw.pw_gid);

    // Set GID and UID
    if (libc.setgid(target_pw.pw_gid) != 0) {
        return error.SetgidFailed;
    }

    if (libc.setuid(target_pw.pw_uid) != 0) {
        return error.SetuidFailed;
    }

    // Execute - set environ then use execvp (POSIX, unlike GNU execvpe)
    const argv_ptr: [*:null]const ?[*:0]const u8 = @ptrCast(cmd_args.items.ptr);
    environ = @ptrCast(env_list.items.ptr);

    _ = execvp(cmd_args.items[0].?, argv_ptr);

    // If we get here, exec failed
    writeStderr("zsudo: failed to execute command\n");
    std.c._exit(126);
}

fn parseArgs(allocator: std.mem.Allocator, init: std.process.Init) !Config {
    var config = Config{};
    var cmd_args: std.ArrayListUnmanaged([]const u8) = .empty;

    // Collect args into a slice
    var args_list: std.ArrayListUnmanaged([]const u8) = .empty;
    defer args_list.deinit(allocator);
    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    while (args_iter.next()) |arg| {
        try args_list.append(allocator, arg);
    }
    const args = args_list.items;

    var i: usize = 1;
    var parsing_options = true;

    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (parsing_options and arg.len > 0 and arg[0] == '-') {
            if (std.mem.eql(u8, arg, "-u") or std.mem.eql(u8, arg, "--user")) {
                i += 1;
                if (i >= args.len) return error.MissingArgument;
                config.target_user = try allocator.dupe(u8, args[i]);
            } else if (std.mem.eql(u8, arg, "-E") or std.mem.eql(u8, arg, "--preserve-env")) {
                config.preserve_env = true;
            } else if (std.mem.eql(u8, arg, "-i") or std.mem.eql(u8, arg, "--login")) {
                config.login_shell = true;
            } else if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--shell")) {
                config.shell_mode = true;
            } else if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--validate")) {
                config.validate_only = true;
            } else if (std.mem.eql(u8, arg, "-k") or std.mem.eql(u8, arg, "--reset-timestamp")) {
                config.invalidate = true;
            } else if (std.mem.eql(u8, arg, "-l") or std.mem.eql(u8, arg, "--list")) {
                config.list_privs = true;
            } else if (std.mem.eql(u8, arg, "-S") or std.mem.eql(u8, arg, "--stdin")) {
                config.stdin_password = true;
            } else if (std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--prompt")) {
                i += 1; // consume prompt argument (ignored)
                if (i >= args.len) return error.MissingArgument;
            } else if (std.mem.eql(u8, arg, "-n") or std.mem.eql(u8, arg, "--non-interactive")) {
                // Non-interactive - will fail if password needed
            } else if (std.mem.eql(u8, arg, "-H") or std.mem.eql(u8, arg, "--set-home")) {
                config.set_home = true;
            } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
                printUsage();
                std.process.exit(0);
            } else if (std.mem.eql(u8, arg, "--version")) {
                writeStdout("zsudo 1.0.0\n");
                std.process.exit(0);
            } else if (std.mem.eql(u8, arg, "--")) {
                parsing_options = false;
            } else {
                writeStderr("zsudo: unknown option: ");
                writeStderr(arg);
                writeStderr("\n");
                return error.InvalidArgument;
            }
        } else {
            // Command starts
            parsing_options = false;
            try cmd_args.append(allocator, try allocator.dupe(u8, arg));
        }
    }

    config.command = try cmd_args.toOwnedSlice(allocator);
    return config;
}

fn printUsage() void {
    const usage =
        \\Usage: zsudo [OPTIONS] [COMMAND]
        \\
        \\Execute a command as another user (default: root).
        \\
        \\Options:
        \\  -u, --user USER      Run command as USER instead of root
        \\  -E, --preserve-env   Preserve user environment
        \\  -i, --login          Start a login shell as target user
        \\  -s, --shell          Run target user's shell
        \\  -v, --validate       Validate credentials without running command
        \\  -k, --reset-timestamp  Invalidate cached credentials
        \\  -l, --list           List user's privileges
        \\  -S, --stdin          Read password from standard input
        \\  -p, --prompt PROMPT  Custom password prompt (use '' to suppress)
        \\  -n, --non-interactive  Non-interactive mode (fail if password needed)
        \\  -H, --set-home       Set HOME to target user's home directory
        \\  -h, --help           Show this help
        \\      --version        Show version
        \\
        \\Security:
        \\  This binary must be installed setuid root:
        \\    chown root:root zsudo && chmod 4755 zsudo
        \\
        \\  Authorization is checked via:
        \\    - wheel or sudo group membership
        \\    - /etc/sudoers and /etc/sudoers.d/
        \\
        \\Examples:
        \\  zsudo ls /root              # List /root as root
        \\  zsudo -u www-data whoami    # Run as www-data
        \\  zsudo -i                    # Root login shell
        \\  zsudo -E make install       # Preserve environment
        \\
    ;
    writeStdout(usage);
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    // Get real user info (before potential setuid)
    const real_uid = libc.getuid();
    const calling_pw = getpwuid(real_uid) orelse {
        writeStderr("zsudo: unable to determine calling user\n");
        std.process.exit(1);
    };
    const calling_username = std.mem.span(calling_pw.pw_name);

    const config = parseArgs(allocator, init) catch |err| {
        writeStderr("zsudo: ");
        writeStderr(@errorName(err));
        writeStderr("\n");
        std.process.exit(1);
    };

    // Handle -k (invalidate)
    if (config.invalidate) {
        invalidateTimestamp(calling_username);
        if (config.command.len == 0 and !config.validate_only) {
            return;
        }
    }

    // Handle -l (list privileges)
    if (config.list_privs) {
        if (isUserAuthorized(calling_username, config.target_user)) {
            writeStdout("User ");
            writeStdout(calling_username);
            writeStdout(" may run commands as ");
            writeStdout(config.target_user);
            writeStdout("\n");
        } else {
            writeStderr("User ");
            writeStderr(calling_username);
            writeStderr(" is not authorized to run sudo\n");
            std.process.exit(1);
        }
        return;
    }

    // Check authorization
    if (!isUserAuthorized(calling_username, config.target_user)) {
        writeStderr("zsudo: ");
        writeStderr(calling_username);
        writeStderr(" is not in the sudoers file. This incident will be reported.\n");

        openlog("zsudo", LOG_PID, LOG_AUTH);
        const username_z = allocator.dupeZ(u8, calling_username) catch {
            std.process.exit(1);
        };
        syslog(LOG_ERR, "unauthorized sudo attempt by %s", username_z.ptr);
        allocator.free(username_z);

        std.process.exit(1);
    }

    // Authenticate
    g_stdin_password = config.stdin_password;
    if (!authenticateUser(calling_username)) {
        writeStderr("zsudo: authentication failed\n");
        std.process.exit(1);
    }

    // Handle -v (validate only)
    if (config.validate_only) {
        return;
    }

    // Must have a command (unless -i or -s)
    if (config.command.len == 0 and !config.login_shell and !config.shell_mode) {
        writeStderr("zsudo: no command specified\n");
        printUsage();
        std.process.exit(1);
    }

    // Get target user info
    const target_user_z = allocator.dupeZ(u8, config.target_user) catch {
        std.process.exit(1);
    };
    defer allocator.free(target_user_z);

    const target_pw = getpwnam(target_user_z.ptr) orelse {
        writeStderr("zsudo: unknown user: ");
        writeStderr(config.target_user);
        writeStderr("\n");
        std.process.exit(1);
    };

    // Log command
    if (config.command.len > 0) {
        logCommand(calling_username, config.target_user, config.command);
    }

    // Execute command
    executeCommand(&config, target_pw) catch |err| {
        writeStderr("zsudo: ");
        writeStderr(@errorName(err));
        writeStderr("\n");
        std.process.exit(1);
    };
}
