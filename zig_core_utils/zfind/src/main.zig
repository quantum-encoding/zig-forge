//! zfind - File finder compatible with a useful subset of GNU find.
//!
//! Portable implementation (macOS + Linux) built on libc via std.c.
//!
//! Predicates:
//! - -name / -iname PATTERN     : filename glob (supports *, ?, [..], \ escape)
//! - -path / -ipath PATTERN     : full-path glob
//! - -regex PATTERN             : full path, fully anchored (GNU semantics)
//! - -type f|d|l|b|c|p|s        : file type
//! - -size [+-]N[cwkMG]         : file size
//! - -mtime [+-]N               : modification time (days)
//! - -newer FILE                : newer than FILE
//! - -empty                     : empty file or directory
//! - -perm [-/]MODE             : permission bits (exact / all-of / any-of)
//! - -user / -group NAME|ID     : ownership
//! - -true / -false
//!
//! Operators (with GNU precedence: NOT > AND > OR):
//! - -a, -and (implicit) ; -o, -or ; !, -not ; ( )
//!
//! Actions: -print (default), -print0, -exec CMD {} \; , -delete
//!
//! Global options: -L, -maxdepth N, -mindepth N, -depth, -xdev / -mount

const std = @import("std");
const Io = std.Io;
const c = std.c;

// execvp is not surfaced by std.c on all targets; declare it directly.
extern "c" fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;

// S_IFMT type bits.
const S_IFMT: u32 = 0o170000;
const S_IFDIR: u32 = 0o040000;
const S_IFREG: u32 = 0o100000;
const S_IFLNK: u32 = 0o120000;
const S_IFBLK: u32 = 0o060000;
const S_IFCHR: u32 = 0o020000;
const S_IFIFO: u32 = 0o010000;
const S_IFSOCK: u32 = 0o140000;

// ---------------------------------------------------------------------------
// File metadata
// ---------------------------------------------------------------------------

const FileInfo = struct {
    path: []const u8,
    name: []const u8,
    mode: u32,
    size: u64,
    mtime: i64,
    nlink: u32,
    uid: u32,
    gid: u32,
    dev: i64,

    fn isDir(self: *const FileInfo) bool {
        return (self.mode & S_IFMT) == S_IFDIR;
    }
    fn isFile(self: *const FileInfo) bool {
        return (self.mode & S_IFMT) == S_IFREG;
    }
    fn isLink(self: *const FileInfo) bool {
        return (self.mode & S_IFMT) == S_IFLNK;
    }
    fn isBlockDev(self: *const FileInfo) bool {
        return (self.mode & S_IFMT) == S_IFBLK;
    }
    fn isCharDev(self: *const FileInfo) bool {
        return (self.mode & S_IFMT) == S_IFCHR;
    }
    fn isPipe(self: *const FileInfo) bool {
        return (self.mode & S_IFMT) == S_IFIFO;
    }
    fn isSocket(self: *const FileInfo) bool {
        return (self.mode & S_IFMT) == S_IFSOCK;
    }
};

fn infoFromStat(path: []const u8, name: []const u8, st: *const c.Stat) FileInfo {
    return .{
        .path = path,
        .name = name,
        .mode = @intCast(st.mode),
        .size = @intCast(@max(st.size, 0)),
        .mtime = st.mtime().sec,
        .nlink = @intCast(st.nlink),
        .uid = st.uid,
        .gid = st.gid,
        .dev = @intCast(st.dev),
    };
}

/// Portable fstatat wrapper. Returns null on error.
fn statPath(path_z: [*:0]const u8, follow: bool) ?c.Stat {
    var st: c.Stat = undefined;
    const flags: u32 = if (follow) 0 else c.AT.SYMLINK_NOFOLLOW;
    const r = c.fstatat(c.AT.FDCWD, path_z, &st, flags);
    if (r != 0) return null;
    return st;
}

// ---------------------------------------------------------------------------
// Predicates
// ---------------------------------------------------------------------------

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

const Comparison = enum { exact, greater, less };

const SizeComp = struct {
    value: i64,
    unit: u64,
    comparison: Comparison,
};

const TimeComp = struct {
    days: i64,
    comparison: Comparison,
};

const PermMatch = enum { exact, all_of, any_of };

const PermComp = struct {
    mode: u32,
    match: PermMatch,
};

const Predicate = struct {
    pred_type: PredicateType,
    pattern: []const u8 = "",
    size_comp: ?SizeComp = null,
    time_comp: ?TimeComp = null,
    perm_mode: u32 = 0,
    perm_match: PermMatch = .exact,
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
            // GNU -regex matches the ENTIRE path, fully anchored.
            .regex => regexFullMatch(info.path, self.pattern),
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
        if (info.isFile()) return info.size == 0;
        if (info.isDir()) return info.nlink <= 2; // . and .. only
        return false;
    }

    fn matchPerm(self: *const Predicate, info: *const FileInfo) bool {
        const file_perm = info.mode & 0o7777;
        return switch (self.perm_match) {
            // Exact permission bits.
            .exact => file_perm == self.perm_mode,
            // -MODE : all of the listed bits set.
            .all_of => (file_perm & self.perm_mode) == self.perm_mode,
            // /MODE : any of the listed bits set (0 mask never matches, per GNU).
            .any_of => self.perm_mode == 0 or (file_perm & self.perm_mode) != 0,
        };
    }
};

// ---------------------------------------------------------------------------
// Expression tree (NOT > AND > OR precedence)
// ---------------------------------------------------------------------------

const ExprType = enum { predicate, and_expr, or_expr, not_expr };

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
                if (self.right) |r| return r.evaluate(info, now);
                return true;
            },
            .or_expr => {
                if (self.left) |l| {
                    if (l.evaluate(info, now)) return true;
                }
                if (self.right) |r| return r.evaluate(info, now);
                return false;
            },
            .not_expr => {
                if (self.left) |l| return !l.evaluate(info, now);
                return true;
            },
        };
    }
};

// ---------------------------------------------------------------------------
// Actions
// ---------------------------------------------------------------------------

const ActionType = enum { print, print0, exec, delete };

const Action = struct {
    action_type: ActionType,
    exec_args: std.ArrayListUnmanaged([]const u8) = .empty,

    fn deinit(self: *Action, allocator: std.mem.Allocator) void {
        for (self.exec_args.items) |arg| allocator.free(arg);
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
    xdev: bool = false,
    depth_first: bool = false, // -depth, or implied by -delete

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

// ---------------------------------------------------------------------------
// Glob matching: *, ?, [..] (with ranges and ! / ^ negation), \ escape
// ---------------------------------------------------------------------------

fn toLower(ch: u8) u8 {
    return if (ch >= 'A' and ch <= 'Z') ch + 32 else ch;
}

fn chEq(a: u8, b: u8, ic: bool) bool {
    return if (ic) toLower(a) == toLower(b) else a == b;
}

fn chInRange(ch: u8, lo: u8, hi: u8, ic: bool) bool {
    if (ic) {
        const c2 = toLower(ch);
        return c2 >= toLower(lo) and c2 <= toLower(hi);
    }
    return ch >= lo and ch <= hi;
}

const BracketResult = struct { matched: bool, next: usize };

/// Match a single character `ch` against a bracket expression that begins at
/// pattern[0] == '['. Returns null if there is no closing ']' (caller treats
/// the '[' literally).
fn matchBracket(ch: u8, pattern: []const u8, ic: bool) ?BracketResult {
    var i: usize = 1;
    var negate = false;
    if (i < pattern.len and (pattern[i] == '!' or pattern[i] == '^')) {
        negate = true;
        i += 1;
    }
    var matched = false;
    var first = true;
    while (i < pattern.len) {
        if (pattern[i] == ']' and !first) {
            return .{ .matched = matched != negate, .next = i + 1 };
        }
        first = false;
        if (i + 2 < pattern.len and pattern[i + 1] == '-' and pattern[i + 2] != ']') {
            if (chInRange(ch, pattern[i], pattern[i + 2], ic)) matched = true;
            i += 3;
        } else {
            if (chEq(ch, pattern[i], ic)) matched = true;
            i += 1;
        }
    }
    return null; // unterminated class
}

fn globMatch(name: []const u8, pattern: []const u8, ic: bool) bool {
    if (pattern.len == 0) return name.len == 0;
    switch (pattern[0]) {
        '*' => {
            var k: usize = 0;
            while (true) {
                if (globMatch(name[k..], pattern[1..], ic)) return true;
                if (k >= name.len) return false;
                k += 1;
            }
        },
        '?' => {
            if (name.len == 0) return false;
            return globMatch(name[1..], pattern[1..], ic);
        },
        '[' => {
            if (name.len == 0) return false;
            if (matchBracket(name[0], pattern, ic)) |res| {
                if (!res.matched) return false;
                return globMatch(name[1..], pattern[res.next..], ic);
            }
            // No closing bracket: literal '['.
            if (chEq(name[0], '[', ic)) return globMatch(name[1..], pattern[1..], ic);
            return false;
        },
        '\\' => {
            if (pattern.len >= 2) {
                if (name.len == 0) return false;
                if (chEq(name[0], pattern[1], ic)) return globMatch(name[1..], pattern[2..], ic);
                return false;
            }
            if (name.len > 0 and name[0] == '\\') return globMatch(name[1..], pattern[1..], ic);
            return false;
        },
        else => {
            if (name.len == 0) return false;
            if (chEq(name[0], pattern[0], ic)) return globMatch(name[1..], pattern[1..], ic);
            return false;
        },
    }
}

// ---------------------------------------------------------------------------
// Minimal regex engine for -regex: ., *, +, ?, [..], \escape.
// Fully anchored to the whole text (GNU -regex semantics).
// ---------------------------------------------------------------------------

/// Length in bytes of one regex atom starting at pattern[0].
fn atomLen(pattern: []const u8) usize {
    if (pattern.len == 0) return 0;
    if (pattern[0] == '\\') return if (pattern.len >= 2) 2 else 1;
    if (pattern[0] == '[') {
        var i: usize = 1;
        if (i < pattern.len and pattern[i] == '^') i += 1;
        var first = true;
        while (i < pattern.len) {
            if (pattern[i] == ']' and !first) return i + 1;
            first = false;
            i += 1;
        }
        return 1; // unterminated -> literal '['
    }
    return 1;
}

/// Does character `ch` match the atom occupying pattern[0..atom_len]?
fn atomMatch(ch: u8, pattern: []const u8, atom_len: usize) bool {
    if (atom_len == 2 and pattern[0] == '\\') return ch == pattern[1];
    if (pattern[0] == '[' and atom_len > 1) {
        var i: usize = 1;
        var negate = false;
        if (i < pattern.len and pattern[i] == '^') {
            negate = true;
            i += 1;
        }
        var matched = false;
        var first = true;
        while (i < atom_len - 1) {
            if (pattern[i] == ']' and !first) break;
            first = false;
            if (i + 2 < atom_len - 1 and pattern[i + 1] == '-') {
                if (ch >= pattern[i] and ch <= pattern[i + 2]) matched = true;
                i += 3;
            } else {
                if (ch == pattern[i]) matched = true;
                i += 1;
            }
        }
        return matched != negate;
    }
    if (pattern[0] == '.') return true;
    return ch == pattern[0];
}

fn regexMatchHere(text: []const u8, pattern: []const u8, anchored_end: bool) bool {
    if (pattern.len == 0) return if (anchored_end) text.len == 0 else true;

    const alen = atomLen(pattern);
    const rest = pattern[alen..];
    const quant: u8 = if (rest.len > 0 and (rest[0] == '*' or rest[0] == '+' or rest[0] == '?')) rest[0] else 0;
    const after = if (quant != 0) rest[1..] else rest;

    switch (quant) {
        '*' => {
            var count: usize = 0;
            while (count < text.len and atomMatch(text[count], pattern, alen)) count += 1;
            var k = count;
            while (true) {
                if (regexMatchHere(text[k..], after, anchored_end)) return true;
                if (k == 0) break;
                k -= 1;
            }
            return false;
        },
        '+' => {
            var count: usize = 0;
            while (count < text.len and atomMatch(text[count], pattern, alen)) count += 1;
            if (count == 0) return false;
            var k = count;
            while (k >= 1) : (k -= 1) {
                if (regexMatchHere(text[k..], after, anchored_end)) return true;
            }
            return false;
        },
        '?' => {
            if (text.len > 0 and atomMatch(text[0], pattern, alen)) {
                if (regexMatchHere(text[1..], after, anchored_end)) return true;
            }
            return regexMatchHere(text, after, anchored_end);
        },
        else => {
            if (text.len == 0) return false;
            if (!atomMatch(text[0], pattern, alen)) return false;
            return regexMatchHere(text[1..], after, anchored_end);
        },
    }
}

fn regexFullMatch(text: []const u8, pattern: []const u8) bool {
    var pat = pattern;
    // Fully anchored already; drop redundant explicit anchors if present.
    if (pat.len > 0 and pat[0] == '^') pat = pat[1..];
    if (pat.len > 0 and pat[pat.len - 1] == '$') pat = pat[0 .. pat.len - 1];
    return regexMatchHere(text, pat, true);
}

// ---------------------------------------------------------------------------
// Argument value parsers (overflow-safe)
// ---------------------------------------------------------------------------

const ParseError = error{Invalid};

fn parseUserId(name: []const u8) ?u32 {
    if (std.fmt.parseInt(u32, name, 10)) |uid| return uid else |_| {}
    return lookupIdInFile("/etc/passwd", name);
}

fn parseGroupId(name: []const u8) ?u32 {
    if (std.fmt.parseInt(u32, name, 10)) |gid| return gid else |_| {}
    return lookupIdInFile("/etc/group", name);
}

/// Look up a name in a colon-separated database (passwd/group) and return the
/// numeric id in the 3rd field. Portable: uses std.fs.
fn lookupIdInFile(comptime file: [:0]const u8, name: []const u8) ?u32 {
    const fd = c.open(file.ptr, .{ .ACCMODE = .RDONLY });
    if (fd < 0) return null;
    defer _ = c.close(fd);
    var buf: [16384]u8 = undefined;
    var total: usize = 0;
    while (total < buf.len) {
        const r = c.read(fd, buf[total..].ptr, buf.len - total);
        if (r <= 0) break;
        total += @intCast(r);
    }
    var lines = std.mem.splitScalar(u8, buf[0..total], '\n');
    while (lines.next()) |line| {
        var fields = std.mem.splitScalar(u8, line, ':');
        const ent = fields.next() orelse continue;
        if (std.mem.eql(u8, ent, name)) {
            _ = fields.next(); // password
            const id_str = fields.next() orelse continue;
            return std.fmt.parseInt(u32, id_str, 10) catch continue;
        }
    }
    return null;
}

fn parseSize(s: []const u8) ParseError!SizeComp {
    if (s.len == 0) return error.Invalid;
    var idx: usize = 0;
    var comparison: Comparison = .exact;
    if (s[0] == '+') {
        comparison = .greater;
        idx = 1;
    } else if (s[0] == '-') {
        comparison = .less;
        idx = 1;
    }
    // Digits.
    var end = idx;
    while (end < s.len and s[end] >= '0' and s[end] <= '9') end += 1;
    if (end == idx) return error.Invalid;
    const value = std.fmt.parseInt(i64, s[idx..end], 10) catch return error.Invalid;

    var unit: u64 = 512; // default: 512-byte blocks
    if (end < s.len) {
        if (end + 1 != s.len) return error.Invalid; // trailing junk
        unit = switch (s[end]) {
            'b' => 512,
            'c' => 1,
            'w' => 2,
            'k' => 1024,
            'M' => 1024 * 1024,
            'G' => 1024 * 1024 * 1024,
            else => return error.Invalid,
        };
    }
    return .{ .value = value, .unit = unit, .comparison = comparison };
}

fn parseTime(s: []const u8) ParseError!TimeComp {
    if (s.len == 0) return error.Invalid;
    var idx: usize = 0;
    var comparison: Comparison = .exact;
    if (s[0] == '+') {
        comparison = .greater;
        idx = 1;
    } else if (s[0] == '-') {
        comparison = .less;
        idx = 1;
    }
    if (idx >= s.len) return error.Invalid;
    const value = std.fmt.parseInt(i64, s[idx..], 10) catch return error.Invalid;
    return .{ .days = value, .comparison = comparison };
}

fn parsePerm(s: []const u8) ParseError!PermComp {
    if (s.len == 0) return error.Invalid;
    var idx: usize = 0;
    var match: PermMatch = .exact;
    if (s[0] == '-') {
        match = .all_of;
        idx = 1;
    } else if (s[0] == '/') {
        match = .any_of;
        idx = 1;
    }
    if (idx >= s.len) return error.Invalid;
    const mode = std.fmt.parseInt(u32, s[idx..], 8) catch return error.Invalid;
    return .{ .mode = mode, .match = match };
}

fn getMtime(path: []const u8) ?i64 {
    var pbuf: [4096]u8 = undefined;
    if (path.len >= pbuf.len) return null;
    @memcpy(pbuf[0..path.len], path);
    pbuf[path.len] = 0;
    const st = statPath(@ptrCast(&pbuf), true) orelse return null;
    return st.mtime().sec;
}

// ---------------------------------------------------------------------------
// Argument parsing
// ---------------------------------------------------------------------------

fn fatalUsage(comptime fmt: []const u8, args: anytype) noreturn {
    var buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "zfind: " ++ fmt ++ "\n", args) catch "zfind: error\n";
    const stderr = Io.File.stderr();
    _ = c.write(stderr.handle, msg.ptr, msg.len);
    std.process.exit(2);
}

// Tokens for the expression grammar.
const TokKind = enum { pred, op_and, op_or, op_not, lparen, rparen };
const Tok = struct {
    kind: TokKind,
    pred: Predicate = undefined,
};

fn mkPred(p: Predicate) Tok {
    return .{ .kind = .pred, .pred = p };
}

// Recursive-descent parser producing a proper NOT>AND>OR tree.
const ExprParser = struct {
    allocator: std.mem.Allocator,
    toks: []const Tok,
    i: usize = 0,

    fn peek(self: *ExprParser) ?TokKind {
        if (self.i >= self.toks.len) return null;
        return self.toks[self.i].kind;
    }

    fn newNode(self: *ExprParser, node: Expression) !*Expression {
        const e = try self.allocator.create(Expression);
        e.* = node;
        return e;
    }

    fn parseOr(self: *ExprParser) anyerror!*Expression {
        var left = try self.parseAnd();
        while (self.peek()) |k| {
            if (k != .op_or) break;
            self.i += 1;
            const right = try self.parseAnd();
            left = try self.newNode(.{ .expr_type = .or_expr, .left = left, .right = right });
        }
        return left;
    }

    fn parseAnd(self: *ExprParser) anyerror!*Expression {
        var left = try self.parseNot();
        while (self.peek()) |k| {
            switch (k) {
                .op_and => {
                    self.i += 1;
                    const right = try self.parseNot();
                    left = try self.newNode(.{ .expr_type = .and_expr, .left = left, .right = right });
                },
                // implicit AND: another term starts here
                .pred, .lparen, .op_not => {
                    const right = try self.parseNot();
                    left = try self.newNode(.{ .expr_type = .and_expr, .left = left, .right = right });
                },
                else => break,
            }
        }
        return left;
    }

    fn parseNot(self: *ExprParser) anyerror!*Expression {
        if (self.peek()) |k| {
            if (k == .op_not) {
                self.i += 1;
                const operand = try self.parseNot();
                return self.newNode(.{ .expr_type = .not_expr, .left = operand });
            }
        }
        return self.parseTerm();
    }

    fn parseTerm(self: *ExprParser) anyerror!*Expression {
        const k = self.peek() orelse fatalUsage("expected expression", .{});
        switch (k) {
            .lparen => {
                self.i += 1;
                const inner = try self.parseOr();
                const closing = self.peek() orelse fatalUsage("expected `)'", .{});
                if (closing != .rparen) fatalUsage("expected `)'", .{});
                self.i += 1;
                return inner;
            },
            .pred => {
                const p = self.toks[self.i].pred;
                self.i += 1;
                return self.newNode(.{ .expr_type = .predicate, .predicate = p });
            },
            else => fatalUsage("invalid expression", .{}),
        }
    }
};

fn parseArgs(allocator: std.mem.Allocator, minimal_args: anytype) !Config {
    var args_list: std.ArrayListUnmanaged([]const u8) = .empty;
    defer args_list.deinit(allocator);
    var args_iter = std.process.Args.Iterator.init(minimal_args);
    while (args_iter.next()) |arg| try args_list.append(allocator, arg);
    const args = args_list.items;

    var config = Config{};
    errdefer config.deinit(allocator);

    var toks: std.ArrayListUnmanaged(Tok) = .empty;
    defer toks.deinit(allocator);

    var i: usize = 1;
    var in_predicates = false;

    // Requires an argument for `arg`; fatals if missing.
    const needArg = struct {
        fn get(a: []const []const u8, idx: *usize, name: []const u8) []const u8 {
            if (idx.* + 1 >= a.len) fatalUsage("missing argument to `{s}'", .{name});
            idx.* += 1;
            return a[idx.*];
        }
    }.get;

    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "--help")) {
            printHelp();
            std.process.exit(0);
        } else if (std.mem.eql(u8, arg, "--version")) {
            printVersion();
            std.process.exit(0);
        }

        // Global options (position-independent in practice).
        if (std.mem.eql(u8, arg, "-maxdepth")) {
            const v = needArg(args, &i, arg);
            config.maxdepth = std.fmt.parseInt(usize, v, 10) catch fatalUsage("invalid argument `{s}' to `-maxdepth'", .{v});
            continue;
        } else if (std.mem.eql(u8, arg, "-mindepth")) {
            const v = needArg(args, &i, arg);
            config.mindepth = std.fmt.parseInt(usize, v, 10) catch fatalUsage("invalid argument `{s}' to `-mindepth'", .{v});
            continue;
        } else if (std.mem.eql(u8, arg, "-L") or std.mem.eql(u8, arg, "-follow")) {
            config.follow_symlinks = true;
            continue;
        } else if (std.mem.eql(u8, arg, "-P")) {
            config.follow_symlinks = false;
            continue;
        } else if (std.mem.eql(u8, arg, "-depth")) {
            config.depth_first = true;
            continue;
        } else if (std.mem.eql(u8, arg, "-xdev") or std.mem.eql(u8, arg, "-mount")) {
            config.xdev = true;
            continue;
        }

        if (arg.len > 0 and arg[0] == '-' and !std.mem.eql(u8, arg, "-")) {
            in_predicates = true;

            if (std.mem.eql(u8, arg, "-name")) {
                const v = needArg(args, &i, arg);
                try toks.append(allocator, mkPred(.{ .pred_type = .name, .pattern = try allocator.dupe(u8, v) }));
            } else if (std.mem.eql(u8, arg, "-iname")) {
                const v = needArg(args, &i, arg);
                try toks.append(allocator, mkPred(.{ .pred_type = .iname, .pattern = try allocator.dupe(u8, v) }));
            } else if (std.mem.eql(u8, arg, "-path") or std.mem.eql(u8, arg, "-wholename")) {
                const v = needArg(args, &i, arg);
                try toks.append(allocator, mkPred(.{ .pred_type = .path_match, .pattern = try allocator.dupe(u8, v) }));
            } else if (std.mem.eql(u8, arg, "-ipath") or std.mem.eql(u8, arg, "-iwholename")) {
                const v = needArg(args, &i, arg);
                try toks.append(allocator, mkPred(.{ .pred_type = .ipath, .pattern = try allocator.dupe(u8, v) }));
            } else if (std.mem.eql(u8, arg, "-regex")) {
                const v = needArg(args, &i, arg);
                try toks.append(allocator, mkPred(.{ .pred_type = .regex, .pattern = try allocator.dupe(u8, v) }));
            } else if (std.mem.eql(u8, arg, "-type")) {
                const v = needArg(args, &i, arg);
                if (v.len != 1 or std.mem.indexOfScalar(u8, "fdlbcps", v[0]) == null)
                    fatalUsage("unknown argument to `-type': {s}", .{v});
                try toks.append(allocator, mkPred(.{ .pred_type = .file_type, .file_type_char = v[0] }));
            } else if (std.mem.eql(u8, arg, "-size")) {
                const v = needArg(args, &i, arg);
                const sc = parseSize(v) catch fatalUsage("invalid argument `{s}' to `-size'", .{v});
                try toks.append(allocator, mkPred(.{ .pred_type = .size, .size_comp = sc }));
            } else if (std.mem.eql(u8, arg, "-mtime")) {
                const v = needArg(args, &i, arg);
                const tc = parseTime(v) catch fatalUsage("invalid argument `{s}' to `-mtime'", .{v});
                try toks.append(allocator, mkPred(.{ .pred_type = .mtime, .time_comp = tc }));
            } else if (std.mem.eql(u8, arg, "-newer")) {
                const v = needArg(args, &i, arg);
                const mtime = getMtime(v) orelse fatalUsage("`{s}': No such file or directory", .{v});
                try toks.append(allocator, mkPred(.{ .pred_type = .newer, .newer_mtime = mtime }));
            } else if (std.mem.eql(u8, arg, "-empty")) {
                try toks.append(allocator, mkPred(.{ .pred_type = .empty }));
            } else if (std.mem.eql(u8, arg, "-perm")) {
                const v = needArg(args, &i, arg);
                const pc = parsePerm(v) catch fatalUsage("invalid mode `{s}'", .{v});
                try toks.append(allocator, mkPred(.{ .pred_type = .perm, .perm_mode = pc.mode, .perm_match = pc.match }));
            } else if (std.mem.eql(u8, arg, "-true")) {
                try toks.append(allocator, mkPred(.{ .pred_type = .true_pred }));
            } else if (std.mem.eql(u8, arg, "-false")) {
                try toks.append(allocator, mkPred(.{ .pred_type = .false_pred }));
            } else if (std.mem.eql(u8, arg, "-user")) {
                const v = needArg(args, &i, arg);
                const uid = parseUserId(v) orelse fatalUsage("`{s}' is not the name of a known user", .{v});
                try toks.append(allocator, mkPred(.{ .pred_type = .user, .user_id = uid }));
            } else if (std.mem.eql(u8, arg, "-group")) {
                const v = needArg(args, &i, arg);
                const gid = parseGroupId(v) orelse fatalUsage("`{s}' is not the name of a known group", .{v});
                try toks.append(allocator, mkPred(.{ .pred_type = .group, .group_id = gid }));
            }
            // Operators
            else if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "-or")) {
                try toks.append(allocator, .{ .kind = .op_or });
            } else if (std.mem.eql(u8, arg, "-a") or std.mem.eql(u8, arg, "-and")) {
                try toks.append(allocator, .{ .kind = .op_and });
            } else if (std.mem.eql(u8, arg, "-not")) {
                try toks.append(allocator, .{ .kind = .op_not });
            }
            // Actions
            else if (std.mem.eql(u8, arg, "-print")) {
                try config.actions.append(allocator, .{ .action_type = .print });
            } else if (std.mem.eql(u8, arg, "-print0")) {
                try config.actions.append(allocator, .{ .action_type = .print0 });
            } else if (std.mem.eql(u8, arg, "-delete")) {
                try config.actions.append(allocator, .{ .action_type = .delete });
                config.depth_first = true; // GNU: -delete implies -depth
            } else if (std.mem.eql(u8, arg, "-exec")) {
                var action = Action{ .action_type = .exec };
                var saw_terminator = false;
                i += 1;
                while (i < args.len) : (i += 1) {
                    if (std.mem.eql(u8, args[i], ";")) {
                        saw_terminator = true;
                        break;
                    }
                    if (std.mem.eql(u8, args[i], "+")) {
                        // '+' batching unsupported; treat as terminator + note.
                        saw_terminator = true;
                        break;
                    }
                    try action.exec_args.append(allocator, try allocator.dupe(u8, args[i]));
                }
                if (!saw_terminator) {
                    action.deinit(allocator);
                    fatalUsage("missing argument to `-exec'", .{});
                }
                try config.actions.append(allocator, action);
            } else {
                fatalUsage("unknown predicate `{s}'", .{arg});
            }
        } else if (std.mem.eql(u8, arg, "!")) {
            in_predicates = true;
            try toks.append(allocator, .{ .kind = .op_not });
        } else if (std.mem.eql(u8, arg, "(")) {
            in_predicates = true;
            try toks.append(allocator, .{ .kind = .lparen });
        } else if (std.mem.eql(u8, arg, ")")) {
            in_predicates = true;
            try toks.append(allocator, .{ .kind = .rparen });
        } else if (!in_predicates) {
            try config.starting_points.append(allocator, try allocator.dupe(u8, arg));
        } else {
            fatalUsage("paths must precede expression: `{s}'", .{arg});
        }
    }

    // Build the expression tree.
    if (toks.items.len > 0) {
        var parser = ExprParser{ .allocator = allocator, .toks = toks.items };
        const root = try parser.parseOr();
        if (parser.i != toks.items.len) fatalUsage("unexpected extra operator", .{});
        try config.expressions.append(allocator, root);
    }

    if (config.starting_points.items.len == 0) {
        try config.starting_points.append(allocator, try allocator.dupe(u8, "."));
    }
    if (config.actions.items.len == 0) {
        try config.actions.append(allocator, .{ .action_type = .print });
    }
    return config;
}

// ---------------------------------------------------------------------------
// Traversal (single portable sequential walker, heap-allocated paths)
// ---------------------------------------------------------------------------

const AncestorId = struct { dev: i64, ino: u64 };

const WalkCtx = struct {
    allocator: std.mem.Allocator,
    config: *const Config,
    now: i64,
    writer: *Io.File.Writer,
    had_error: bool = false,
    root_dev: i64 = 0,
    ancestors: std.ArrayListUnmanaged(AncestorId) = .empty,

    fn deinit(self: *WalkCtx) void {
        self.ancestors.deinit(self.allocator);
    }
};

fn matches(config: *const Config, info: *const FileInfo, now: i64) bool {
    for (config.expressions.items) |expr| {
        if (!expr.evaluate(info, now)) return false;
    }
    return true;
}

fn runActions(ctx: *WalkCtx, info: *const FileInfo, path_z: [*:0]const u8) void {
    for (ctx.config.actions.items) |action| {
        switch (action.action_type) {
            .print => {
                ctx.writer.interface.writeAll(info.path) catch {};
                ctx.writer.interface.writeByte('\n') catch {};
            },
            .print0 => {
                ctx.writer.interface.writeAll(info.path) catch {};
                ctx.writer.interface.writeByte(0) catch {};
            },
            .delete => {
                const rc = if (info.isDir()) c.rmdir(path_z) else c.unlink(path_z);
                if (rc != 0) {
                    ctx.had_error = true;
                    reportError("cannot delete `{s}'", .{info.path});
                }
            },
            .exec => {
                ctx.writer.interface.flush() catch {};
                executeCommand(ctx.allocator, info.path, &action);
            },
        }
    }
}

fn reportError(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "zfind: " ++ fmt ++ "\n", args) catch return;
    const stderr = Io.File.stderr();
    _ = c.write(stderr.handle, msg.ptr, msg.len);
}

/// Recursively walk `path`. `depth` is 0 for a starting point.
fn walk(ctx: *WalkCtx, path: []const u8, depth: usize) void {
    const config = ctx.config;

    if (config.maxdepth) |max| {
        if (depth > max) return;
    }

    const path_z = ctx.allocator.dupeZ(u8, path) catch {
        ctx.had_error = true;
        return;
    };
    defer ctx.allocator.free(path_z);

    const st = statPath(path_z.ptr, config.follow_symlinks) orelse {
        ctx.had_error = true;
        reportError("`{s}': No such file or directory", .{path});
        return;
    };

    const name = std.fs.path.basename(path);
    const info = infoFromStat(path, name, &st);

    const within_depth = depth >= config.mindepth and
        (config.maxdepth == null or depth <= config.maxdepth.?);

    // Pre-order: test/act before descending (GNU default).
    if (!config.depth_first and within_depth) {
        if (matches(config, &info, ctx.now)) runActions(ctx, &info, path_z.ptr);
    }

    // Decide whether to descend.
    const can_descend = info.isDir() and
        (config.maxdepth == null or depth < config.maxdepth.?) and
        (!config.xdev or info.dev == ctx.root_dev);

    if (can_descend) {
        descend(ctx, path, depth, info.dev, @intCast(st.ino));
    }

    // Post-order: -depth / -delete process contents first, node last.
    if (config.depth_first and within_depth) {
        if (matches(config, &info, ctx.now)) runActions(ctx, &info, path_z.ptr);
    }
}

fn descend(ctx: *WalkCtx, path: []const u8, depth: usize, dev: i64, ino: u64) void {
    // Symlink-loop / hardlink-cycle guard.
    for (ctx.ancestors.items) |a| {
        if (a.dev == dev and a.ino == ino) return;
    }
    ctx.ancestors.append(ctx.allocator, .{ .dev = dev, .ino = ino }) catch {};
    defer _ = ctx.ancestors.pop();

    const path_z = ctx.allocator.dupeZ(u8, path) catch {
        ctx.had_error = true;
        return;
    };
    defer ctx.allocator.free(path_z);

    const dir = c.opendir(path_z.ptr) orelse {
        ctx.had_error = true;
        reportError("`{s}': cannot open directory", .{path});
        return;
    };
    defer _ = c.closedir(dir);

    while (c.readdir(dir)) |entry| {
        const name = std.mem.sliceTo(&entry.name, 0);
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;

        const full = std.fmt.allocPrint(ctx.allocator, "{s}/{s}", .{ path, name }) catch {
            ctx.had_error = true;
            continue;
        };
        defer ctx.allocator.free(full);
        walk(ctx, full, depth + 1);
    }
}

fn executeCommand(allocator: std.mem.Allocator, path: []const u8, action: *const Action) void {
    if (action.exec_args.items.len == 0) return;

    var argv = std.ArrayListUnmanaged(?[*:0]const u8).empty;
    defer {
        for (argv.items) |arg| {
            if (arg) |a| allocator.free(std.mem.span(a));
        }
        argv.deinit(allocator);
    }

    for (action.exec_args.items) |arg| {
        if (std.mem.eql(u8, arg, "{}")) {
            const p = allocator.dupeZ(u8, path) catch return;
            argv.append(allocator, p.ptr) catch return;
        } else {
            const a = allocator.dupeZ(u8, arg) catch return;
            argv.append(allocator, a.ptr) catch return;
        }
    }
    argv.append(allocator, null) catch return;

    const pid = c.fork();
    if (pid == 0) {
        _ = execvp(argv.items[0].?, @ptrCast(argv.items.ptr));
        c._exit(127);
    } else if (pid > 0) {
        _ = c.waitpid(pid, null, 0);
    }
}

// ---------------------------------------------------------------------------
// Help / version
// ---------------------------------------------------------------------------

fn printHelp() void {
    const io_ctx = Io.Threaded.global_single_threaded.io();
    const stdout = Io.File.stdout();
    var buf: [2048]u8 = undefined;
    var writer = stdout.writer(io_ctx, &buf);
    writer.interface.writeAll(
        \\Usage: zfind [path...] [expression]
        \\
        \\Search for files in a directory hierarchy.
        \\
        \\Options:
        \\  -L              follow symbolic links
        \\  -maxdepth N     descend at most N levels
        \\  -mindepth N     don't apply tests at levels less than N
        \\  -depth          process directory contents before the directory
        \\  -xdev           don't descend into other filesystems
        \\
        \\Tests:
        \\  -name PATTERN   filename matches shell glob PATTERN
        \\  -iname PATTERN  case-insensitive -name
        \\  -path PATTERN   full path matches glob PATTERN
        \\  -ipath PATTERN  case-insensitive -path
        \\  -regex PATTERN  whole path matches regex PATTERN (anchored)
        \\  -type TYPE      file type: f=file, d=dir, l=link, b,c,p,s
        \\  -size [+-]N[cwkMG]  file size (+ greater, - less)
        \\  -mtime [+-]N    modification time in days
        \\  -newer FILE     newer than FILE
        \\  -empty          empty file or directory
        \\  -perm MODE      permission bits (MODE / -MODE all / /MODE any)
        \\  -user NAME      owned by user NAME (name or numeric ID)
        \\  -group NAME     owned by group NAME (name or numeric ID)
        \\
        \\Operators:
        \\  -a, -and        AND (default)
        \\  -o, -or         OR
        \\  !, -not         NOT
        \\  ( )             grouping
        \\
        \\Actions:
        \\  -print          print pathname (default)
        \\  -print0         print null-terminated
        \\  -exec CMD {} ;  execute command
        \\  -delete         delete file (implies -depth)
        \\
        \\      --help      display this help
        \\      --version   output version information
        \\
    ) catch {};
    writer.interface.flush() catch {};
}

fn printVersion() void {
    const io_ctx = Io.Threaded.global_single_threaded.io();
    const stdout = Io.File.stdout();
    var buf: [64]u8 = undefined;
    var writer = stdout.writer(io_ctx, &buf);
    writer.interface.writeAll("zfind 0.2.0\n") catch {};
    writer.interface.flush() catch {};
}

pub fn main(init: std.process.Init) void {
    const allocator = init.gpa;

    var config = parseArgs(allocator, init.minimal.args) catch {
        std.process.exit(1);
    };
    defer config.deinit(allocator);

    // Wall-clock seconds for -mtime/-newer math. Not a security check.
    var now_ts: c.timespec = undefined;
    _ = c.clock_gettime(c.CLOCK.REALTIME, &now_ts);
    const now: i64 = @intCast(now_ts.sec);

    const io_ctx = Io.Threaded.global_single_threaded.io();
    const stdout = Io.File.stdout();
    var out_buf: [16384]u8 = undefined;
    var writer = stdout.writer(io_ctx, &out_buf);

    var ctx = WalkCtx{
        .allocator = allocator,
        .config = &config,
        .now = now,
        .writer = &writer,
    };
    defer ctx.deinit();

    for (config.starting_points.items) |start| {
        // Record this starting point's device for -xdev.
        const sz = allocator.dupeZ(u8, start) catch continue;
        defer allocator.free(sz);
        if (statPath(sz.ptr, config.follow_symlinks)) |st| {
            ctx.root_dev = @intCast(st.dev);
        }
        ctx.ancestors.clearRetainingCapacity();
        walk(&ctx, start, 0);
    }

    writer.interface.flush() catch {};

    if (ctx.had_error) std.process.exit(1);
}

// ---------------------------------------------------------------------------
// Unit tests: pure predicate/parse logic vs documented GNU/POSIX behaviour.
// (Integration tests that diff against /usr/bin/find live in gnu_parity_test.)
// ---------------------------------------------------------------------------

test {
    _ = @import("gnu_parity_test.zig");
}

const testing = std.testing;

test "globMatch: bracket classes, ranges, negation, escape" {
    // POSIX glob semantics (also what BSD/GNU find -name implement).
    try testing.expect(globMatch("a.txt", "[ab].txt", false));
    try testing.expect(globMatch("b.txt", "[ab].txt", false));
    try testing.expect(!globMatch("c.txt", "[ab].txt", false));
    try testing.expect(globMatch("m", "[a-z]", false));
    try testing.expect(!globMatch("M", "[a-z]", false));
    try testing.expect(globMatch("x", "[!a-c]", false)); // negation
    try testing.expect(!globMatch("b", "[!a-c]", false));
    try testing.expect(globMatch("a*b", "a\\*b", false)); // escaped star = literal
    try testing.expect(!globMatch("axb", "a\\*b", false));
    // Unterminated bracket is a literal '['.
    try testing.expect(globMatch("[x", "[x", false));
    // Star / question.
    try testing.expect(globMatch("readme.md", "*.md", false));
    try testing.expect(globMatch("ab", "a?", false));
    try testing.expect(globMatch("A.TXT", "*.txt", true)); // ignore case
}

test "regexFullMatch: anchored whole-string, classes and quantifiers" {
    // GNU find -regex is fully anchored against the ENTIRE path.
    try testing.expect(regexFullMatch("/a/sub/b", ".*/sub/.*"));
    try testing.expect(!regexFullMatch("/a/other/b", ".*/sub/.*"));
    try testing.expect(regexFullMatch("abc123", "[a-z]+[0-9]+"));
    try testing.expect(!regexFullMatch("abc123x", "[a-z]+[0-9]+")); // must consume all
    try testing.expect(regexFullMatch("file.txt", "file\\.txt"));
    try testing.expect(!regexFullMatch("fileXtxt", "file\\.txt")); // '.' escaped -> literal dot
    try testing.expect(regexFullMatch("aaa", "a*"));
    try testing.expect(regexFullMatch("", "a*"));
    try testing.expect(!regexFullMatch("sub", ".*/sub/.*")); // basename would falsely match pre-fix
}

test "matchPerm: exact vs all-of (-) vs any-of (/)" {
    // GNU: MODE exact, -MODE all bits, /MODE any bit.
    var info = FileInfo{
        .path = "x",
        .name = "x",
        .mode = 0o100644, // regular file, 0644
        .size = 0,
        .mtime = 0,
        .nlink = 1,
        .uid = 0,
        .gid = 0,
        .dev = 0,
    };
    const exact = Predicate{ .pred_type = .perm, .perm_mode = 0o644, .perm_match = .exact };
    try testing.expect(exact.matchPerm(&info));
    const exact_wrong = Predicate{ .pred_type = .perm, .perm_mode = 0o755, .perm_match = .exact };
    try testing.expect(!exact_wrong.matchPerm(&info));

    // 0644 has no exec bits.
    const any_exec = Predicate{ .pred_type = .perm, .perm_mode = 0o111, .perm_match = .any_of };
    try testing.expect(!any_exec.matchPerm(&info));
    const all_exec = Predicate{ .pred_type = .perm, .perm_mode = 0o111, .perm_match = .all_of };
    try testing.expect(!all_exec.matchPerm(&info));

    info.mode = 0o100755; // 0755 now
    try testing.expect(any_exec.matchPerm(&info)); // any exec bit set
    try testing.expect(all_exec.matchPerm(&info)); // all exec bits set

    // any-of write for 0755 (owner write only): /222 matches because u+w set.
    const any_write = Predicate{ .pred_type = .perm, .perm_mode = 0o222, .perm_match = .any_of };
    try testing.expect(any_write.matchPerm(&info));
    // all-of write for 0755: requires g+w and o+w too -> fails.
    const all_write = Predicate{ .pred_type = .perm, .perm_mode = 0o222, .perm_match = .all_of };
    try testing.expect(!all_write.matchPerm(&info));
}

test "parseSize/parseTime/parsePerm reject overflow and junk (no wrap, no panic)" {
    try testing.expectError(error.Invalid, parseSize("99999999999999999999"));
    try testing.expectError(error.Invalid, parseSize("+"));
    try testing.expectError(error.Invalid, parseSize("10X"));
    try testing.expectError(error.Invalid, parseTime("99999999999999999999"));
    try testing.expectError(error.Invalid, parsePerm("99999999999"));
    // Valid ones still parse.
    const s = try parseSize("+10M");
    try testing.expectEqual(@as(i64, 10), s.value);
    try testing.expectEqual(@as(u64, 1024 * 1024), s.unit);
    try testing.expectEqual(Comparison.greater, s.comparison);
    const p = try parsePerm("/222");
    try testing.expectEqual(PermMatch.any_of, p.match);
    try testing.expectEqual(@as(u32, 0o222), p.mode);
}

test "parsePerm distinguishes '-' (all) from '/' (any) from exact" {
    try testing.expectEqual(PermMatch.exact, (try parsePerm("644")).match);
    try testing.expectEqual(PermMatch.all_of, (try parsePerm("-644")).match);
    try testing.expectEqual(PermMatch.any_of, (try parsePerm("/644")).match);
}
