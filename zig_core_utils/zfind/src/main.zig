//! zfind - High-performance file finder
//!
//! Compatible with GNU find:
//! - Path-based recursive search
//! - Predicate expressions with AND/OR/NOT
//! - Actions: -print, -print0, -exec, -delete
//!
//! Predicates:
//! - -name PATTERN: filename glob match
//! - -iname PATTERN: case-insensitive glob
//! - -type TYPE: file type (f, d, l, b, c, p, s)
//! - -size [+-]N[ckMG]: file size
//! - -mtime [+-]N: modification time (days)
//! - -newer FILE: newer than file
//! - -empty: empty file or directory
//! - -perm MODE: permission bits
//!
//! Operators:
//! - -a, -and: AND (default)
//! - -o, -or: OR
//! - !, -not: NOT
//! - ( ): grouping

const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const libc = std.c;
const Io = std.Io;

// Zig 0.16 compatible Mutex (Mutex was removed)
const Mutex = struct {
    inner: std.c.pthread_mutex_t = std.c.PTHREAD_MUTEX_INITIALIZER,

    pub fn lock(self: *Mutex) void {
        _ = std.c.pthread_mutex_lock(&self.inner);
    }

    pub fn unlock(self: *Mutex) void {
        _ = std.c.pthread_mutex_unlock(&self.inner);
    }
};

// Extern declarations for functions not in std.c
extern "c" fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;

// File info passed to predicates
const FileInfo = struct {
    path: []const u8,
    name: []const u8,
    mode: u32,
    size: u64,
    mtime: i64,
    nlink: u32,
    uid: u32,
    gid: u32,

    fn isDir(self: *const FileInfo) bool {
        return (self.mode & 0o170000) == 0o40000;
    }

    fn isFile(self: *const FileInfo) bool {
        return (self.mode & 0o170000) == 0o100000;
    }

    fn isLink(self: *const FileInfo) bool {
        return (self.mode & 0o170000) == 0o120000;
    }

    fn isBlockDev(self: *const FileInfo) bool {
        return (self.mode & 0o170000) == 0o60000;
    }

    fn isCharDev(self: *const FileInfo) bool {
        return (self.mode & 0o170000) == 0o20000;
    }

    fn isPipe(self: *const FileInfo) bool {
        return (self.mode & 0o170000) == 0o10000;
    }

    fn isSocket(self: *const FileInfo) bool {
        return (self.mode & 0o170000) == 0o140000;
    }
};

// Predicate types
const PredicateType = enum {
    name,
    iname,
    file_type,
    size,
    mtime,
    newer,
    empty,
    perm,
    true_pred,
    false_pred,
    user,
    group,
    path_match,
    ipath,
    regex,
};

// Comparison type for size and time
const Comparison = enum { exact, greater, less };

// Size comparison
const SizeComp = struct {
    value: i64,
    unit: u64, // bytes per unit
    comparison: Comparison,
};

// Time comparison
const TimeComp = struct {
    days: i64,
    comparison: Comparison,
};

// Permission comparison
const PermComp = struct {
    mode: u32,
    exact: bool,
};

const Predicate = struct {
    pred_type: PredicateType,
    pattern: []const u8 = "",
    size_comp: ?SizeComp = null,
    time_comp: ?TimeComp = null,
    perm_mode: u32 = 0,
    perm_exact: bool = false,
    file_type_char: u8 = 0,
    newer_mtime: i64 = 0,
    user_id: u32 = 0,
    group_id: u32 = 0,

    fn evaluate(self: *const Predicate, info: *const FileInfo, now: i64) bool {
        return switch (self.pred_type) {
            .name => globMatch(info.name, self.pattern, false),
            .iname => globMatch(info.name, self.pattern, true),
            .file_type => self.matchType(info),
            .size => self.matchSize(info),
            .mtime => self.matchMtime(info, now),
            .newer => info.mtime > self.newer_mtime,
            .empty => self.matchEmpty(info),
            .perm => self.matchPerm(info),
            .true_pred => true,
            .false_pred => false,
            .user => info.uid == self.user_id,
            .group => info.gid == self.group_id,
            .path_match => globMatch(info.path, self.pattern, false),
            .ipath => globMatch(info.path, self.pattern, true),
            .regex => regexMatch(info.name, self.pattern),
        };
    }

    fn matchType(self: *const Predicate, info: *const FileInfo) bool {
        return switch (self.file_type_char) {
            'f' => info.isFile(),
            'd' => info.isDir(),
            'l' => info.isLink(),
            'b' => info.isBlockDev(),
            'c' => info.isCharDev(),
            'p' => info.isPipe(),
            's' => info.isSocket(),
            else => false,
        };
    }

    fn matchSize(self: *const Predicate, info: *const FileInfo) bool {
        const comp = self.size_comp orelse return false;
        const file_units: i64 = @intCast(@divFloor(info.size + comp.unit - 1, comp.unit));
        return switch (comp.comparison) {
            .exact => file_units == comp.value,
            .greater => file_units > comp.value,
            .less => file_units < comp.value,
        };
    }

    fn matchMtime(self: *const Predicate, info: *const FileInfo, now: i64) bool {
        const comp = self.time_comp orelse return false;
        const secs_per_day: i64 = 86400;
        const age_days = @divFloor(now - info.mtime, secs_per_day);
        return switch (comp.comparison) {
            .exact => age_days == comp.days,
            .greater => age_days > comp.days,
            .less => age_days < comp.days,
        };
    }

    fn matchEmpty(self: *const Predicate, info: *const FileInfo) bool {
        _ = self;
        if (info.isFile()) {
            return info.size == 0;
        } else if (info.isDir()) {
            return info.nlink <= 2; // . and .. only
        }
        return false;
    }

    fn matchPerm(self: *const Predicate, info: *const FileInfo) bool {
        const file_perm = info.mode & 0o7777;
        if (self.perm_exact) {
            return file_perm == self.perm_mode;
        } else {
            return (file_perm & self.perm_mode) == self.perm_mode;
        }
    }
};

// Expression node for combining predicates
const ExprType = enum {
    predicate,
    and_expr,
    or_expr,
    not_expr,
};

const Expression = struct {
    expr_type: ExprType,
    predicate: ?Predicate = null,
    left: ?*Expression = null,
    right: ?*Expression = null,

    fn evaluate(self: *const Expression, info: *const FileInfo, now: i64) bool {
        return switch (self.expr_type) {
            .predicate => if (self.predicate) |p| p.evaluate(info, now) else true,
            .and_expr => {
                if (self.left) |l| {
                    if (!l.evaluate(info, now)) return false;
                }
                if (self.right) |r| {
                    return r.evaluate(info, now);
                }
                return true;
            },
            .or_expr => {
                if (self.left) |l| {
                    if (l.evaluate(info, now)) return true;
                }
                if (self.right) |r| {
                    return r.evaluate(info, now);
                }
                return false;
            },
            .not_expr => {
                if (self.left) |l| {
                    return !l.evaluate(info, now);
                }
                return true;
            },
        };
    }
};

// Action types
const ActionType = enum {
    print,
    print0,
    exec,
    delete,
};

const Action = struct {
    action_type: ActionType,
    exec_args: std.ArrayListUnmanaged([]const u8) = .empty,

    fn deinit(self: *Action, allocator: std.mem.Allocator) void {
        for (self.exec_args.items) |arg| {
            allocator.free(arg);
        }
        self.exec_args.deinit(allocator);
    }
};

const Config = struct {
    starting_points: std.ArrayListUnmanaged([]const u8) = .empty,
    expressions: std.ArrayListUnmanaged(*Expression) = .empty,
    actions: std.ArrayListUnmanaged(Action) = .empty,
    maxdepth: ?usize = null,
    mindepth: usize = 0,
    follow_symlinks: bool = false,
    xdev: bool = false, // Don't descend into other filesystems

    fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        for (self.starting_points.items) |p| allocator.free(p);
        self.starting_points.deinit(allocator);

        for (self.expressions.items) |e| freeExpression(allocator, e);
        self.expressions.deinit(allocator);

        for (self.actions.items) |*a| a.deinit(allocator);
        self.actions.deinit(allocator);
    }
};

fn freeExpression(allocator: std.mem.Allocator, expr: *Expression) void {
    if (expr.left) |l| freeExpression(allocator, l);
    if (expr.right) |r| freeExpression(allocator, r);
    if (expr.predicate) |p| {
        if (p.pattern.len > 0) allocator.free(p.pattern);
    }
    allocator.destroy(expr);
}

// Glob pattern matching
fn globMatch(name: []const u8, pattern: []const u8, ignore_case: bool) bool {
    var ni: usize = 0;
    var pi: usize = 0;
    var star_idx: ?usize = null;
    var match_idx: usize = 0;

    while (ni < name.len) {
        if (pi < pattern.len) {
            const pc = pattern[pi];
            const nc = if (ignore_case) toLower(name[ni]) else name[ni];
            const pc_cmp = if (ignore_case) toLower(pc) else pc;

            if (pc == '*') {
                star_idx = pi;
                match_idx = ni;
                pi += 1;
                continue;
            } else if (pc == '?' or nc == pc_cmp) {
                ni += 1;
                pi += 1;
                continue;
            }
        }

        if (star_idx) |si| {
            pi = si + 1;
            match_idx += 1;
            ni = match_idx;
        } else {
            return false;
        }
    }

    while (pi < pattern.len and pattern[pi] == '*') {
        pi += 1;
    }

    return pi == pattern.len;
}

fn toLower(ch: u8) u8 {
    return if (ch >= 'A' and ch <= 'Z') ch + 32 else ch;
}

// Simple regex matching (supports basic patterns: ., *, +, ?, ^, $, [], character classes)
fn regexMatch(text: []const u8, pattern: []const u8) bool {
    // Handle anchors
    var pat = pattern;
    var txt = text;
    var anchored_start = false;
    var anchored_end = false;

    if (pat.len > 0 and pat[0] == '^') {
        anchored_start = true;
        pat = pat[1..];
    }
    if (pat.len > 0 and pat[pat.len - 1] == '$') {
        anchored_end = true;
        pat = pat[0 .. pat.len - 1];
    }

    if (anchored_start) {
        return regexMatchHere(txt, pat, anchored_end);
    }

    // Try matching at each position
    var pos: usize = 0;
    while (pos <= txt.len) : (pos += 1) {
        if (regexMatchHere(txt[pos..], pat, anchored_end)) {
            return true;
        }
    }
    return false;
}

fn regexMatchHere(text: []const u8, pattern: []const u8, anchored_end: bool) bool {
    var t_idx: usize = 0;
    var p_idx: usize = 0;

    while (p_idx < pattern.len) {
        // Check for quantifiers
        const has_star = p_idx + 1 < pattern.len and pattern[p_idx + 1] == '*';
        const has_plus = p_idx + 1 < pattern.len and pattern[p_idx + 1] == '+';
        const has_question = p_idx + 1 < pattern.len and pattern[p_idx + 1] == '?';

        if (has_star) {
            const char_class = pattern[p_idx];
            p_idx += 2;
            // Match zero or more
            while (t_idx < text.len and matchChar(text[t_idx], char_class)) {
                t_idx += 1;
            }
            // Greedy backtrack
            while (true) {
                if (regexMatchHere(text[t_idx..], pattern[p_idx..], anchored_end)) {
                    return true;
                }
                if (t_idx == 0) break;
                t_idx -= 1;
            }
            return regexMatchHere(text, pattern[p_idx..], anchored_end);
        } else if (has_plus) {
            const char_class = pattern[p_idx];
            p_idx += 2;
            // Match one or more
            if (t_idx >= text.len or !matchChar(text[t_idx], char_class)) {
                return false;
            }
            t_idx += 1;
            while (t_idx < text.len and matchChar(text[t_idx], char_class)) {
                t_idx += 1;
            }
            // Continue matching rest
        } else if (has_question) {
            const char_class = pattern[p_idx];
            p_idx += 2;
            // Match zero or one
            if (t_idx < text.len and matchChar(text[t_idx], char_class)) {
                t_idx += 1;
            }
        } else {
            // No quantifier
            if (t_idx >= text.len) {
                return false;
            }
            if (!matchChar(text[t_idx], pattern[p_idx])) {
                return false;
            }
            t_idx += 1;
            p_idx += 1;
        }
    }

    if (anchored_end) {
        return t_idx == text.len;
    }
    return true;
}

fn matchChar(ch: u8, pattern_char: u8) bool {
    if (pattern_char == '.') return true;
    return ch == pattern_char;
}

// Parse uid/gid from string (numeric or lookup by name)
fn parseUserId(name: []const u8) ?u32 {
    // Try numeric first
    if (std.fmt.parseInt(u32, name, 10)) |uid| {
        return uid;
    } else |_| {}

    // Try looking up by name via /etc/passwd using syscall
    const fd = linux.open("/etc/passwd", .{ .ACCMODE = .RDONLY }, 0);
    if (@as(isize, @bitCast(fd)) < 0) return null;
    defer _ = linux.close(@intCast(fd));

    var buf: [8192]u8 = undefined;
    const read_result = linux.read(@intCast(fd), &buf, buf.len);
    if (@as(isize, @bitCast(read_result)) <= 0) return null;
    const content = buf[0..read_result];

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.splitScalar(u8, line, ':');
        const username = fields.next() orelse continue;
        if (std.mem.eql(u8, username, name)) {
            _ = fields.next(); // skip password field
            const uid_str = fields.next() orelse continue;
            return std.fmt.parseInt(u32, uid_str, 10) catch continue;
        }
    }
    return null;
}

fn parseGroupId(name: []const u8) ?u32 {
    // Try numeric first
    if (std.fmt.parseInt(u32, name, 10)) |gid| {
        return gid;
    } else |_| {}

    // Try looking up by name via /etc/group using syscall
    const fd = linux.open("/etc/group", .{ .ACCMODE = .RDONLY }, 0);
    if (@as(isize, @bitCast(fd)) < 0) return null;
    defer _ = linux.close(@intCast(fd));

    var buf: [8192]u8 = undefined;
    const read_result = linux.read(@intCast(fd), &buf, buf.len);
    if (@as(isize, @bitCast(read_result)) <= 0) return null;
    const content = buf[0..read_result];

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.splitScalar(u8, line, ':');
        const groupname = fields.next() orelse continue;
        if (std.mem.eql(u8, groupname, name)) {
            _ = fields.next(); // skip password
            const gid_str = fields.next() orelse continue;
            return std.fmt.parseInt(u32, gid_str, 10) catch continue;
        }
    }
    return null;
}

// Parse size string like "+10M", "-5k", "100"
fn parseSize(s: []const u8) ?SizeComp {
    if (s.len == 0) return null;

    var idx: usize = 0;
    var comparison: Comparison = .exact;

    if (s[0] == '+') {
        comparison = .greater;
        idx = 1;
    } else if (s[0] == '-') {
        comparison = .less;
        idx = 1;
    }

    if (idx >= s.len) return null;

    // Parse number
    var value: i64 = 0;
    while (idx < s.len and s[idx] >= '0' and s[idx] <= '9') {
        value = value * 10 + (s[idx] - '0');
        idx += 1;
    }

    // Parse unit
    var unit: u64 = 512; // Default: 512-byte blocks
    if (idx < s.len) {
        unit = switch (s[idx]) {
            'c' => 1,
            'w' => 2,
            'k' => 1024,
            'M' => 1024 * 1024,
            'G' => 1024 * 1024 * 1024,
            else => 512,
        };
    }

    return SizeComp{ .value = value, .unit = unit, .comparison = comparison };
}

// Parse time string like "+7", "-1", "0"
fn parseTime(s: []const u8) ?TimeComp {
    if (s.len == 0) return null;

    var idx: usize = 0;
    var comparison: Comparison = .exact;

    if (s[0] == '+') {
        comparison = .greater;
        idx = 1;
    } else if (s[0] == '-') {
        comparison = .less;
        idx = 1;
    }

    if (idx >= s.len) return null;

    var value: i64 = 0;
    while (idx < s.len and s[idx] >= '0' and s[idx] <= '9') {
        value = value * 10 + (s[idx] - '0');
        idx += 1;
    }

    return TimeComp{ .days = value, .comparison = comparison };
}

// Parse permission mode
fn parsePerm(s: []const u8) ?PermComp {
    if (s.len == 0) return null;

    var idx: usize = 0;
    var exact = true;

    if (s[0] == '-') {
        exact = false;
        idx = 1;
    } else if (s[0] == '/') {
        exact = false;
        idx = 1;
    }

    if (idx >= s.len) return null;

    // Parse octal
    var mode: u32 = 0;
    while (idx < s.len and s[idx] >= '0' and s[idx] <= '7') {
        mode = mode * 8 + (s[idx] - '0');
        idx += 1;
    }

    return PermComp{ .mode = mode, .exact = exact };
}

fn getMtime(allocator: std.mem.Allocator, path: []const u8) ?i64 {
    const path_z = allocator.dupeZ(u8, path) catch return null;
    defer allocator.free(path_z);

    var statx_buf: linux.Statx = undefined;
    const result = linux.statx(linux.AT.FDCWD, path_z.ptr, 0, linux.STATX{ .MTIME = true }, &statx_buf);
    if (result != 0) return null;
    return statx_buf.mtime.sec;
}

fn parseArgs(allocator: std.mem.Allocator, minimal_args: anytype) !Config {
    // Collect args into a slice
    var args_list: std.ArrayListUnmanaged([]const u8) = .empty;
    defer args_list.deinit(allocator);
    var args_iter = std.process.Args.Iterator.init(minimal_args);
    while (args_iter.next()) |arg| {
        try args_list.append(allocator, arg);
    }
    const args = args_list.items;

    var config = Config{};
    var i: usize = 1;
    var in_predicates = false;
    var pending_exprs = std.ArrayListUnmanaged(*Expression).empty;
    defer pending_exprs.deinit(allocator);

    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "--help")) {
            printHelp();
            std.process.exit(0);
        } else if (std.mem.eql(u8, arg, "--version")) {
            printVersion();
            std.process.exit(0);
        }

        // Global options
        if (std.mem.eql(u8, arg, "-maxdepth") and i + 1 < args.len) {
            i += 1;
            config.maxdepth = std.fmt.parseInt(usize, args[i], 10) catch 0;
            continue;
        } else if (std.mem.eql(u8, arg, "-mindepth") and i + 1 < args.len) {
            i += 1;
            config.mindepth = std.fmt.parseInt(usize, args[i], 10) catch 0;
            continue;
        } else if (std.mem.eql(u8, arg, "-L")) {
            config.follow_symlinks = true;
            continue;
        } else if (std.mem.eql(u8, arg, "-xdev") or std.mem.eql(u8, arg, "-mount")) {
            config.xdev = true;
            continue;
        }

        // Predicates and actions start with -
        if (arg.len > 0 and arg[0] == '-' and !std.mem.eql(u8, arg, "-")) {
            in_predicates = true;

            // Parse predicate
            if (std.mem.eql(u8, arg, "-name") and i + 1 < args.len) {
                i += 1;
                const expr = try allocator.create(Expression);
                expr.* = .{
                    .expr_type = .predicate,
                    .predicate = .{
                        .pred_type = .name,
                        .pattern = try allocator.dupe(u8, args[i]),
                    },
                };
                try pending_exprs.append(allocator, expr);
            } else if (std.mem.eql(u8, arg, "-iname") and i + 1 < args.len) {
                i += 1;
                const expr = try allocator.create(Expression);
                expr.* = .{
                    .expr_type = .predicate,
                    .predicate = .{
                        .pred_type = .iname,
                        .pattern = try allocator.dupe(u8, args[i]),
                    },
                };
                try pending_exprs.append(allocator, expr);
            } else if (std.mem.eql(u8, arg, "-type") and i + 1 < args.len) {
                i += 1;
                const expr = try allocator.create(Expression);
                expr.* = .{
                    .expr_type = .predicate,
                    .predicate = .{
                        .pred_type = .file_type,
                        .file_type_char = if (args[i].len > 0) args[i][0] else 0,
                    },
                };
                try pending_exprs.append(allocator, expr);
            } else if (std.mem.eql(u8, arg, "-size") and i + 1 < args.len) {
                i += 1;
                const expr = try allocator.create(Expression);
                expr.* = .{
                    .expr_type = .predicate,
                    .predicate = .{
                        .pred_type = .size,
                        .size_comp = parseSize(args[i]),
                    },
                };
                try pending_exprs.append(allocator, expr);
            } else if (std.mem.eql(u8, arg, "-mtime") and i + 1 < args.len) {
                i += 1;
                const expr = try allocator.create(Expression);
                expr.* = .{
                    .expr_type = .predicate,
                    .predicate = .{
                        .pred_type = .mtime,
                        .time_comp = parseTime(args[i]),
                    },
                };
                try pending_exprs.append(allocator, expr);
            } else if (std.mem.eql(u8, arg, "-newer") and i + 1 < args.len) {
                i += 1;
                const mtime = getMtime(allocator, args[i]) orelse 0;
                const expr = try allocator.create(Expression);
                expr.* = .{
                    .expr_type = .predicate,
                    .predicate = .{
                        .pred_type = .newer,
                        .newer_mtime = mtime,
                    },
                };
                try pending_exprs.append(allocator, expr);
            } else if (std.mem.eql(u8, arg, "-empty")) {
                const expr = try allocator.create(Expression);
                expr.* = .{
                    .expr_type = .predicate,
                    .predicate = .{ .pred_type = .empty },
                };
                try pending_exprs.append(allocator, expr);
            } else if (std.mem.eql(u8, arg, "-perm") and i + 1 < args.len) {
                i += 1;
                const perm = parsePerm(args[i]) orelse PermComp{ .mode = 0, .exact = true };
                const expr = try allocator.create(Expression);
                expr.* = .{
                    .expr_type = .predicate,
                    .predicate = .{
                        .pred_type = .perm,
                        .perm_mode = perm.mode,
                        .perm_exact = perm.exact,
                    },
                };
                try pending_exprs.append(allocator, expr);
            } else if (std.mem.eql(u8, arg, "-true")) {
                const expr = try allocator.create(Expression);
                expr.* = .{
                    .expr_type = .predicate,
                    .predicate = .{ .pred_type = .true_pred },
                };
                try pending_exprs.append(allocator, expr);
            } else if (std.mem.eql(u8, arg, "-false")) {
                const expr = try allocator.create(Expression);
                expr.* = .{
                    .expr_type = .predicate,
                    .predicate = .{ .pred_type = .false_pred },
                };
                try pending_exprs.append(allocator, expr);
            } else if (std.mem.eql(u8, arg, "-user") and i + 1 < args.len) {
                i += 1;
                const uid = parseUserId(args[i]) orelse {
                    std.debug.print("zfind: unknown user: {s}\n", .{args[i]});
                    continue;
                };
                const expr = try allocator.create(Expression);
                expr.* = .{
                    .expr_type = .predicate,
                    .predicate = .{
                        .pred_type = .user,
                        .user_id = uid,
                    },
                };
                try pending_exprs.append(allocator, expr);
            } else if (std.mem.eql(u8, arg, "-group") and i + 1 < args.len) {
                i += 1;
                const gid = parseGroupId(args[i]) orelse {
                    std.debug.print("zfind: unknown group: {s}\n", .{args[i]});
                    continue;
                };
                const expr = try allocator.create(Expression);
                expr.* = .{
                    .expr_type = .predicate,
                    .predicate = .{
                        .pred_type = .group,
                        .group_id = gid,
                    },
                };
                try pending_exprs.append(allocator, expr);
            } else if (std.mem.eql(u8, arg, "-path") and i + 1 < args.len) {
                i += 1;
                const expr = try allocator.create(Expression);
                expr.* = .{
                    .expr_type = .predicate,
                    .predicate = .{
                        .pred_type = .path_match,
                        .pattern = try allocator.dupe(u8, args[i]),
                    },
                };
                try pending_exprs.append(allocator, expr);
            } else if (std.mem.eql(u8, arg, "-ipath") and i + 1 < args.len) {
                i += 1;
                const expr = try allocator.create(Expression);
                expr.* = .{
                    .expr_type = .predicate,
                    .predicate = .{
                        .pred_type = .ipath,
                        .pattern = try allocator.dupe(u8, args[i]),
                    },
                };
                try pending_exprs.append(allocator, expr);
            } else if (std.mem.eql(u8, arg, "-regex") and i + 1 < args.len) {
                i += 1;
                const expr = try allocator.create(Expression);
                expr.* = .{
                    .expr_type = .predicate,
                    .predicate = .{
                        .pred_type = .regex,
                        .pattern = try allocator.dupe(u8, args[i]),
                    },
                };
                try pending_exprs.append(allocator, expr);
            }
            // Operators
            else if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "-or")) {
                if (pending_exprs.items.len >= 1) {
                    const left = pending_exprs.pop();
                    const expr = try allocator.create(Expression);
                    expr.* = .{
                        .expr_type = .or_expr,
                        .left = left,
                    };
                    try pending_exprs.append(allocator, expr);
                }
            } else if (std.mem.eql(u8, arg, "-a") or std.mem.eql(u8, arg, "-and")) {
                // AND is implicit between predicates, but can be explicit
            } else if (std.mem.eql(u8, arg, "!") or std.mem.eql(u8, arg, "-not")) {
                // NOT applies to next predicate - handled by wrapping
                const expr = try allocator.create(Expression);
                expr.* = .{ .expr_type = .not_expr };
                try pending_exprs.append(allocator, expr);
            }
            // Actions
            else if (std.mem.eql(u8, arg, "-print")) {
                try config.actions.append(allocator, .{ .action_type = .print });
            } else if (std.mem.eql(u8, arg, "-print0")) {
                try config.actions.append(allocator, .{ .action_type = .print0 });
            } else if (std.mem.eql(u8, arg, "-delete")) {
                try config.actions.append(allocator, .{ .action_type = .delete });
            } else if (std.mem.eql(u8, arg, "-exec")) {
                var action = Action{ .action_type = .exec };
                i += 1;
                while (i < args.len) : (i += 1) {
                    if (std.mem.eql(u8, args[i], ";")) break;
                    try action.exec_args.append(allocator, try allocator.dupe(u8, args[i]));
                }
                try config.actions.append(allocator, action);
            }
        } else if (!in_predicates) {
            // Starting point (path)
            try config.starting_points.append(allocator, try allocator.dupe(u8, arg));
        }
    }

    // Combine pending expressions with implicit AND
    while (pending_exprs.items.len > 1) {
        const right = pending_exprs.pop().?;
        const left = pending_exprs.pop().?;

        // Handle NOT wrapping
        if (left.expr_type == .not_expr and left.left == null) {
            left.left = right;
            try pending_exprs.append(allocator, left);
        } else if (right.expr_type == .or_expr and right.right == null) {
            right.right = left;
            // Need to re-add properly, this is simplified
            try pending_exprs.append(allocator, right);
        } else {
            const expr = try allocator.create(Expression);
            expr.* = .{
                .expr_type = .and_expr,
                .left = left,
                .right = right,
            };
            try pending_exprs.append(allocator, expr);
        }
    }

    // Add final expression
    if (pending_exprs.items.len > 0) {
        try config.expressions.append(allocator, pending_exprs.pop().?);
    }

    // Default starting point
    if (config.starting_points.items.len == 0) {
        try config.starting_points.append(allocator, try allocator.dupe(u8, "."));
    }

    // Default action
    if (config.actions.items.len == 0) {
        try config.actions.append(allocator, .{ .action_type = .print });
    }

    return config;
}

fn processFile(allocator: std.mem.Allocator, path: []const u8, config: *const Config, now: i64, writer: anytype) void {
    const path_z = allocator.dupeZ(u8, path) catch return;
    defer allocator.free(path_z);

    // Get file info
    var statx_buf: linux.Statx = undefined;
    const stat_flags: u32 = if (config.follow_symlinks) 0 else linux.AT.SYMLINK_NOFOLLOW;
    const stat_result = linux.statx(
        linux.AT.FDCWD,
        path_z.ptr,
        stat_flags,
        linux.STATX{ .MODE = true, .SIZE = true, .MTIME = true, .NLINK = true, .UID = true, .GID = true },
        &statx_buf,
    );

    if (stat_result != 0) return;

    // Extract filename from path
    const name = blk: {
        var last_slash: usize = 0;
        for (path, 0..) |ch, idx| {
            if (ch == '/') last_slash = idx + 1;
        }
        break :blk path[last_slash..];
    };

    const info = FileInfo{
        .path = path,
        .name = name,
        .mode = statx_buf.mode,
        .size = statx_buf.size,
        .mtime = statx_buf.mtime.sec,
        .nlink = statx_buf.nlink,
        .uid = statx_buf.uid,
        .gid = statx_buf.gid,
    };

    // Evaluate expressions (implicit AND between all)
    var matches = true;
    for (config.expressions.items) |expr| {
        if (!expr.evaluate(&info, now)) {
            matches = false;
            break;
        }
    }

    // If no expressions, everything matches
    if (config.expressions.items.len == 0) {
        matches = true;
    }

    if (matches) {
        // Execute actions
        for (config.actions.items) |action| {
            switch (action.action_type) {
                .print => {
                    writer.interface.writeAll(path) catch {};
                    writer.interface.writeAll("\n") catch {};
                },
                .print0 => {
                    writer.interface.writeAll(path) catch {};
                    writer.interface.writeByte(0) catch {};
                },
                .delete => {
                    if (info.isDir()) {
                        _ = linux.rmdir(path_z.ptr);
                    } else {
                        _ = linux.unlink(path_z.ptr);
                    }
                },
                .exec => {
                    executeCommand(allocator, path, &action);
                },
            }
        }
        writer.interface.flush() catch {};
    }
}

fn executeCommand(allocator: std.mem.Allocator, path: []const u8, action: *const Action) void {
    if (action.exec_args.items.len == 0) return;

    // Build command with {} replacement
    var argv = std.ArrayListUnmanaged(?[*:0]const u8).empty;
    defer {
        for (argv.items) |arg| {
            if (arg) |a| allocator.free(std.mem.span(a));
        }
        argv.deinit(allocator);
    }

    for (action.exec_args.items) |arg| {
        if (std.mem.eql(u8, arg, "{}")) {
            const path_z = allocator.dupeZ(u8, path) catch return;
            argv.append(allocator, path_z.ptr) catch return;
        } else {
            const arg_z = allocator.dupeZ(u8, arg) catch return;
            argv.append(allocator, arg_z.ptr) catch return;
        }
    }
    argv.append(allocator, null) catch return;

    // Fork and exec
    const pid = std.c.fork();
    if (pid == 0) {
        // Child
        _ = execvp(argv.items[0].?, @ptrCast(argv.items.ptr));
        std.c._exit(127);
    } else if (pid > 0) {
        // Parent - wait for child
        _ = std.c.waitpid(pid, null, 0);
    }
}

// Import lock-free MPMC queue
const MpmcQueue = @import("mpmc_queue.zig").MpmcQueue;

// Work item for parallel processing - fixed size for queue storage
const WorkItem = struct {
    // Smaller path buffer (1KB) for better memory efficiency
    // Most real paths are under 256 bytes
    path_buf: [1024]u8 = undefined,
    path_len: u16 = 0,
    depth: u16 = 0,

    fn getPath(self: *const WorkItem) []const u8 {
        return self.path_buf[0..self.path_len];
    }

    fn fromPath(path: []const u8, depth: usize) WorkItem {
        var item = WorkItem{};
        const len = @min(path.len, 1023);
        @memcpy(item.path_buf[0..len], path[0..len]);
        item.path_len = @intCast(len);
        item.depth = @intCast(depth);
        return item;
    }
};

// Shared state for parallel workers
const ParallelState = struct {
    allocator: std.mem.Allocator,
    config: *const Config,
    now: i64,
    work_queue: MpmcQueue(WorkItem),
    output_fd: c_int,
    output_mutex: Mutex,
    active_workers: std.atomic.Value(usize),
    // Outstanding work = items in queue + items being processed
    // Increment BEFORE pushing, decrement AFTER processing complete
    outstanding: std.atomic.Value(isize),
    shutdown: std.atomic.Value(bool),

    fn init(allocator: std.mem.Allocator, config: *const Config, now: i64) !ParallelState {
        return ParallelState{
            .allocator = allocator,
            .config = config,
            .now = now,
            .work_queue = try MpmcQueue(WorkItem).init(allocator, 65536), // 64K capacity
            .output_fd = 1, // stdout
            .output_mutex = .{},
            .active_workers = std.atomic.Value(usize).init(0),
            .outstanding = std.atomic.Value(isize).init(0),
            .shutdown = std.atomic.Value(bool).init(false),
        };
    }

    fn deinit(self: *ParallelState) void {
        self.work_queue.deinit();
    }

    fn addWork(self: *ParallelState, path: []const u8, depth: usize) void {
        _ = self.tryAddWork(path, depth);
    }

    fn tryAddWork(self: *ParallelState, path: []const u8, depth: usize) bool {
        // Increment BEFORE push to avoid race where pop happens before increment
        _ = self.outstanding.fetchAdd(1, .seq_cst);
        const item = WorkItem.fromPath(path, depth);
        self.work_queue.push(item) catch {
            // Queue full - decrement since we couldn't add
            _ = self.outstanding.fetchSub(1, .seq_cst);
            return false;
        };
        return true;
    }

    fn getWork(self: *ParallelState) ?WorkItem {
        // Don't modify outstanding here - it was incremented at addWork
        return self.work_queue.tryPop();
    }

    fn workDone(self: *ParallelState) void {
        // Decrement after processing is complete
        _ = self.outstanding.fetchSub(1, .seq_cst);
    }

    fn isAllDone(self: *ParallelState) bool {
        return self.outstanding.load(.seq_cst) <= 0;
    }

    fn writeOutput(self: *ParallelState, data: []const u8) void {
        self.output_mutex.lock();
        defer self.output_mutex.unlock();
        _ = libc.write(self.output_fd, data.ptr, data.len);
    }
};

fn workerThread(state: *ParallelState) void {
    _ = state.active_workers.fetchAdd(1, .seq_cst);
    defer _ = state.active_workers.fetchSub(1, .seq_cst);

    var idle_count: usize = 0;

    while (!state.shutdown.load(.seq_cst)) {
        if (state.getWork()) |work| {
            idle_count = 0;
            processDirectory(state, work.getPath(), work.depth);
            state.workDone();
        } else {
            // No work available
            idle_count += 1;

            if (idle_count < 50) {
                std.atomic.spinLoopHint();
            } else if (idle_count < 500) {
                std.Thread.yield() catch {};
            } else {
                // Check termination: queue empty AND no in-flight work
                if (state.isAllDone()) {
                    // Brief pause and re-check to avoid race
                    var i: usize = 0;
                    while (i < 10) : (i += 1) {
                        std.atomic.spinLoopHint();
                    }
                    if (state.isAllDone()) {
                        break;
                    }
                }
                idle_count = 50; // Back to yield level
            }
        }
    }
}

// Linux dirent64 structure for getdents64
const LinuxDirent64 = extern struct {
    d_ino: u64,
    d_off: i64,
    d_reclen: u16,
    d_type: u8,
    d_name: [256]u8, // Variable length, but we need at least 1 byte
};

// Wrapper for getdents64 - returns signed for error checking
fn getdents64(fd: i32, buf: [*]u8, count: usize) isize {
    return @bitCast(linux.getdents64(fd, buf, count));
}

fn processDirectory(state: *ParallelState, path: []const u8, depth: u16) void {
    const config = state.config;

    // Check depth limits
    if (config.maxdepth) |max| {
        if (depth > max) return;
    }

    // Process current file/directory if within mindepth
    if (depth >= config.mindepth) {
        processFileParallel(state, path);
    }

    // Check if we should descend
    if (config.maxdepth) |max| {
        if (depth >= max) return;
    }

    // Open directory with O_DIRECTORY for direct fd access
    var path_buf: [1024]u8 = undefined;
    const path_len = @min(path.len, 1023);
    @memcpy(path_buf[0..path_len], path[0..path_len]);
    path_buf[path_len] = 0;

    const fd = linux.open(@ptrCast(&path_buf), .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }, 0);
    if (@as(isize, @bitCast(fd)) < 0) return;
    defer _ = linux.close(@intCast(fd));

    // Large buffer for getdents64 - get many entries per syscall
    var buf: [32768]u8 align(8) = undefined; // 32KB buffer

    while (true) {
        const nread = getdents64(@intCast(fd), &buf, buf.len);
        if (nread <= 0) break;

        var pos: usize = 0;
        while (pos < @as(usize, @intCast(nread))) {
            const entry: *const LinuxDirent64 = @ptrCast(@alignCast(&buf[pos]));
            pos += entry.d_reclen;

            // Get null-terminated name
            const name_ptr: [*:0]const u8 = @ptrCast(&entry.d_name);
            const name = std.mem.span(name_ptr);

            // Skip . and ..
            if (name.len == 1 and name[0] == '.') continue;
            if (name.len == 2 and name[0] == '.' and name[1] == '.') continue;

            // Build full path
            var full_path_buf: [1024]u8 = undefined;
            const full_path = std.fmt.bufPrint(&full_path_buf, "{s}/{s}", .{ path, name }) catch continue;

            const d_type = entry.d_type;
            if (d_type == linux.DT.DIR) {
                if (!state.tryAddWork(full_path, depth + 1)) {
                    processDirectory(state, full_path, depth + 1);
                }
            } else if (d_type == linux.DT.UNKNOWN) {
                // Filesystem doesn't support d_type, need to stat
                var full_path_z: [1024]u8 = undefined;
                const fp_len = @min(full_path.len, 1023);
                @memcpy(full_path_z[0..fp_len], full_path[0..fp_len]);
                full_path_z[fp_len] = 0;

                var statx_buf: linux.Statx = undefined;
                const statx_result = linux.statx(
                    linux.AT.FDCWD,
                    @ptrCast(&full_path_z),
                    linux.AT.SYMLINK_NOFOLLOW,
                    linux.STATX{ .TYPE = true },
                    &statx_buf,
                );

                if (@as(isize, @bitCast(statx_result)) >= 0 and (statx_buf.mode & 0o170000) == 0o40000) {
                    if (!state.tryAddWork(full_path, depth + 1)) {
                        processDirectory(state, full_path, depth + 1);
                    }
                } else if (depth + 1 >= config.mindepth) {
                    processFileParallel(state, full_path);
                }
            } else {
                // Regular file, symlink, etc
                if (depth + 1 >= config.mindepth) {
                    processFileParallel(state, full_path);
                }
            }
        }
    }
}

fn processFileParallel(state: *ParallelState, path: []const u8) void {
    const config = state.config;

    // Create null-terminated path on stack
    var path_z: [1024]u8 = undefined;
    const path_len = @min(path.len, 1023);
    @memcpy(path_z[0..path_len], path[0..path_len]);
    path_z[path_len] = 0;

    // Get file info using direct syscall
    var statx_buf: linux.Statx = undefined;
    const flags: u32 = if (config.follow_symlinks) 0 else linux.AT.SYMLINK_NOFOLLOW;
    const result = linux.statx(
        linux.AT.FDCWD,
        @ptrCast(&path_z),
        flags,
        linux.STATX{ .TYPE = true, .MODE = true, .SIZE = true, .MTIME = true, .NLINK = true, .UID = true, .GID = true },
        &statx_buf,
    );

    if (@as(isize, @bitCast(result)) < 0) return;

    const name = std.fs.path.basename(path);
    const info = FileInfo{
        .path = path,
        .name = name,
        .mode = statx_buf.mode,
        .size = statx_buf.size,
        .mtime = statx_buf.mtime.sec,
        .nlink = statx_buf.nlink,
        .uid = statx_buf.uid,
        .gid = statx_buf.gid,
    };

    // Evaluate expressions
    var match = true;
    if (config.expressions.items.len > 0) {
        for (config.expressions.items) |expr| {
            if (!expr.evaluate(&info, state.now)) {
                match = false;
                break;
            }
        }
    }

    if (match) {
        // Execute actions
        for (config.actions.items) |action| {
            switch (action.action_type) {
                .print => {
                    // Direct output with newline
                    var buf: [1026]u8 = undefined;
                    const len = @min(path.len, 1024);
                    @memcpy(buf[0..len], path[0..len]);
                    buf[len] = '\n';
                    state.writeOutput(buf[0 .. len + 1]);
                },
                .print0 => {
                    var buf: [1025]u8 = undefined;
                    const len = @min(path.len, 1024);
                    @memcpy(buf[0..len], path[0..len]);
                    buf[len] = 0;
                    state.writeOutput(buf[0 .. len + 1]);
                },
                .delete => {
                    if (info.isDir()) {
                        _ = linux.rmdir(@ptrCast(&path_z));
                    } else {
                        _ = linux.unlink(@ptrCast(&path_z));
                    }
                },
                .exec => {
                    state.output_mutex.lock();
                    executeCommand(state.allocator, path, &action);
                    state.output_mutex.unlock();
                },
            }
        }
    }
}

fn walkDirectoryParallel(allocator: std.mem.Allocator, starting_points: []const []const u8, config: *const Config, now: i64) void {
    var state = ParallelState.init(allocator, config, now) catch return;
    defer state.deinit();

    // Add starting points to work queue
    for (starting_points) |start| {
        state.addWork(start, 0);
    }

    // Determine thread count (use available CPUs, max 16)
    const cpu_count = std.Thread.getCpuCount() catch 4;
    const thread_count = @min(cpu_count, 16);

    // Spawn worker threads
    var threads: [16]?std.Thread = [_]?std.Thread{null} ** 16;
    for (0..thread_count) |i| {
        threads[i] = std.Thread.spawn(.{}, workerThread, .{&state}) catch null;
    }

    // Main thread also does work
    workerThread(&state);

    // Signal shutdown
    state.shutdown.store(true, .seq_cst);

    // Wait for threads
    for (&threads) |*t| {
        if (t.*) |thread| {
            thread.join();
        }
    }
}

// Keep sequential version for -exec which needs ordering
fn walkDirectory(allocator: std.mem.Allocator, path: []const u8, config: *const Config, now: i64, depth: usize, writer: anytype) void {
    // Check depth limits
    if (config.maxdepth) |max| {
        if (depth > max) return;
    }

    // Process current file/directory if within mindepth
    if (depth >= config.mindepth) {
        processFile(allocator, path, config, now, writer);
    }

    // Check if we should descend
    if (config.maxdepth) |max| {
        if (depth >= max) return;
    }

    // Try to open as directory
    const path_z = allocator.dupeZ(u8, path) catch return;
    defer allocator.free(path_z);

    const dir = libc.opendir(path_z.ptr) orelse return;
    defer _ = libc.closedir(dir);

    while (true) {
        const entry = libc.readdir(dir) orelse break;

        const name_ptr: [*:0]const u8 = @ptrCast(&entry.name);
        const name = std.mem.span(name_ptr);

        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;

        const full_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ path, name }) catch continue;
        defer allocator.free(full_path);

        walkDirectory(allocator, full_path, config, now, depth + 1, writer);
    }
}

fn printHelp() void {
    const io_ctx = Io.Threaded.global_single_threaded.io();
    const stdout = Io.File.stdout();
    var buf: [2048]u8 = undefined;
    var writer = stdout.writer(io_ctx, &buf);
    writer.interface.writeAll(
        \\Usage: zfind [path...] [expression]
        \\
        \\Search for files in directory hierarchy.
        \\
        \\Options:
        \\  -L              follow symbolic links
        \\  -maxdepth N     descend at most N levels
        \\  -mindepth N     don't apply tests at levels less than N
        \\  -xdev           don't descend into other filesystems
        \\
        \\Tests:
        \\  -name PATTERN   filename matches shell glob PATTERN
        \\  -iname PATTERN  case-insensitive -name
        \\  -path PATTERN   full path matches glob PATTERN
        \\  -ipath PATTERN  case-insensitive -path
        \\  -regex PATTERN  filename matches regex PATTERN
        \\  -type TYPE      file type: f=file, d=dir, l=link, b,c,p,s
        \\  -size [+-]N[ckMG]  file size (+ greater, - less)
        \\  -mtime [+-]N    modification time in days
        \\  -newer FILE     newer than FILE
        \\  -empty          empty file or directory
        \\  -perm MODE      permission bits (octal)
        \\  -user NAME      owned by user NAME (name or numeric ID)
        \\  -group NAME     owned by group NAME (name or numeric ID)
        \\
        \\Operators:
        \\  -a, -and        AND (default)
        \\  -o, -or         OR
        \\  !, -not         NOT
        \\
        \\Actions:
        \\  -print          print pathname (default)
        \\  -print0         print null-terminated
        \\  -exec CMD {} ;  execute command
        \\  -delete         delete file
        \\
        \\      --help      display this help
        \\      --version   output version information
        \\
        \\zfind - High-performance file finder in Zig
        \\
    ) catch {};
    writer.interface.flush() catch {};
}

fn printVersion() void {
    const io_ctx = Io.Threaded.global_single_threaded.io();
    const stdout = Io.File.stdout();
    var buf: [64]u8 = undefined;
    var writer = stdout.writer(io_ctx, &buf);
    writer.interface.writeAll("zfind 0.1.0\n") catch {};
    writer.interface.flush() catch {};
}

pub fn main(init: std.process.Init) void {
    const allocator = init.gpa;

    var config = parseArgs(allocator, init.minimal.args) catch {
        std.process.exit(1);
    };
    defer config.deinit(allocator);

    // Get current time for -mtime comparisons
    var now_ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.REALTIME, &now_ts);
    const now = now_ts.sec;

    // Check if we need sequential processing (-exec requires it for ordering)
    var needs_sequential = false;
    for (config.actions.items) |action| {
        if (action.action_type == .exec) {
            needs_sequential = true;
            break;
        }
    }

    if (needs_sequential) {
        // Use sequential walker for -exec
        const io_ctx = Io.Threaded.global_single_threaded.io();
        const stdout = Io.File.stdout();
        var out_buf: [4096]u8 = undefined;
        var writer = stdout.writer(io_ctx, &out_buf);

        for (config.starting_points.items) |start| {
            walkDirectory(allocator, start, &config, now, 0, &writer);
        }

        writer.interface.flush() catch {};
    } else {
        // Use parallel walker for maximum performance
        walkDirectoryParallel(allocator, config.starting_points.items, &config, now);
    }
}
