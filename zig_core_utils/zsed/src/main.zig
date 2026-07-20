//! zsed - High-performance stream editor
//!
//! Compatible with GNU sed for common operations:
//! - s/pattern/replacement/flags: substitute text
//! - y/source/dest/: transliterate characters
//! - d: delete pattern space
//! - p: print pattern space
//! - q: quit
//! - b/t/:: branch, branch-if-substitution, label
//! - N/P/D: multi-line commands
//! - { }: address-scoped command grouping
//! - Address types: line numbers, ranges, /regex/, $
//!
//! Not implemented (rejected as unknown commands): l, e, F, z, T, Q, r, R, w, W,
//! and the s/// w (write-file) and e (execute) flags.
//! - -n: suppress automatic printing
//! - -e: add script expression
//! - -f: read script from file
//! - -i[SUFFIX]: edit files in place
//! - -E/-r: use extended regular expressions
//!
//! Uses a simple but fast pattern matching engine.

const std = @import("std");
const libc = std.c;

// mkstemp: atomically create a uniquely-named temp file with O_EXCL semantics
// and mode 0600. Mutates the trailing "XXXXXX" of the template in place.
extern "c" fn mkstemp(template: [*:0]u8) c_int;

const BUFFER_SIZE = 64 * 1024;
const MAX_LINE = 8192;

// The most recently *used* regex, for GNU's empty-regex `//` reuse semantics.
var g_last_regex: ?*const Regex = null;

/// Resolve the regex to use for a command/address: its own compiled regex, or,
/// when the pattern was empty, the last regex used at runtime. Updates
/// `g_last_regex` on success so the next `//` reuses this one.
fn resolveRegex(compiled: ?*Regex, empty: bool) ?*const Regex {
    if (!empty) {
        if (compiled) |r| {
            g_last_regex = r;
            return r;
        }
        return null;
    }
    return g_last_regex;
}

const AddressType = enum {
    none,
    line_number,
    last_line,
    regex,
    step, // first~step
};

const Address = struct {
    addr_type: AddressType = .none,
    line_num: usize = 0,
    step: usize = 0,
    pattern: []const u8 = "",
    negated: bool = false,
    // Compiled address regex (null when the pattern is empty -> reuse last regex).
    regex: ?*Regex = null,
    regex_empty: bool = false,
};

const CommandType = enum {
    substitute,
    delete,
    print,
    quit,
    append,
    insert,
    change,
    print_line_num,
    next,
    hold,
    hold_append,
    get,
    get_append,
    exchange,
    transliterate,
    branch,
    branch_sub,
    label,
    append_next,
    print_first,
    delete_first,
    block_start,
    block_end,
    noop,
};

const SubstituteFlags = struct {
    global: bool = false,
    ignore_case: bool = false,
    print: bool = false,
    nth: usize = 0, // 0 means first occurrence (or all if global)
};

const Command = struct {
    addr1: Address = .{},
    addr2: Address = .{}, // For ranges
    has_range: bool = false,
    in_range: bool = false, // Track range state across lines
    cmd_type: CommandType = .noop,
    // For substitute
    pattern: []const u8 = "",
    replacement: []const u8 = "",
    sub_flags: SubstituteFlags = .{},
    // Compiled substitute regex (null when the pattern is empty -> reuse last regex).
    regex: ?*Regex = null,
    regex_empty: bool = false,
    // For a/i/c commands
    text: []const u8 = "",
    // For y command (transliterate)
    source_set: []const u8 = "",
    dest_set: []const u8 = "",
    // For b/t/: commands (label)
    label_name: []const u8 = "",
    // For block_start: index of the matching block_end command (resolved after parse).
    block_end: usize = 0,
};

const Config = struct {
    quiet: bool = false,
    in_place: bool = false,
    in_place_suffix: []const u8 = "",
    extended_regex: bool = false,
    expressions: std.ArrayListUnmanaged([]const u8) = .empty,
    script_files: std.ArrayListUnmanaged([]const u8) = .empty,
    files: std.ArrayListUnmanaged([]const u8) = .empty,

    fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        for (self.expressions.items) |item| {
            allocator.free(item);
        }
        self.expressions.deinit(allocator);
        for (self.script_files.items) |item| {
            allocator.free(item);
        }
        self.script_files.deinit(allocator);
        for (self.files.items) |item| {
            allocator.free(item);
        }
        self.files.deinit(allocator);
    }
};

// -----------------------------------------------------------------------------
// Regex engine
//
// A small backtracking regex engine supporting the subset of POSIX BRE / ERE
// that GNU sed uses in practice:
//   . ^ $ [..] [^..] [[:class:]]  literals and escapes
//   quantifiers  * + ? {n} {n,} {n,m}   (BRE spells + ? { } with a backslash)
//   groups ( )  \( \)   with capture tracking
//   alternation |  \|
//   backreferences \1..\9  in the pattern and in the replacement
//
// The matcher is a recursive backtracker driven by an explicit continuation
// linked-list (`Cont`) built on the Zig call stack, so it needs no heap during
// matching and it tracks submatches for backreferences.
// -----------------------------------------------------------------------------

const RegexError = error{ InvalidRegex, OutOfMemory };
const Q_MAX: usize = std.math.maxInt(usize);

const PosixClass = enum { alpha, digit, alnum, space, upper, lower, punct, xdigit, blank, cntrl, graph, print };

const ClassItem = union(enum) {
    ch: u8,
    range: struct { lo: u8, hi: u8 },
    posix: PosixClass,
};

const ClassSpec = struct {
    negated: bool = false,
    items: []const ClassItem = &.{},
};

const AtomKind = enum { lit, any, class, group, backref, bol, eol, word_boundary, not_word_boundary, word_start, word_end };

const Atom = struct {
    kind: AtomKind,
    ch: u8 = 0,
    cls: ClassSpec = .{},
    alts: []const Seq = &.{},
    gidx: usize = 0,
    ref: usize = 0,
};

const Piece = struct {
    atom: Atom,
    min: usize = 1,
    max: usize = 1,
};

const Seq = struct { pieces: []const Piece = &.{} };

const Regex = struct {
    arena: std.heap.ArenaAllocator,
    alts: []const Seq = &.{},
    ngroups: usize = 0,
    icase: bool = false,

    fn deinit(self: *Regex) void {
        self.arena.deinit();
    }
};

const Span = struct { start: usize = 0, end: usize = 0, set: bool = false };

const Match = struct {
    start: usize,
    end: usize,
    caps: [10]Span,
};

// ---- Parser ----------------------------------------------------------------

const QuantRange = struct { min: usize, max: usize };

const RegexParser = struct {
    pat: []const u8,
    pos: usize = 0,
    ere: bool,
    a: std.mem.Allocator,
    ngroups: usize = 0,

    fn atGroupClose(self: *RegexParser) bool {
        if (self.pos >= self.pat.len) return false;
        if (self.ere) return self.pat[self.pos] == ')';
        return self.pat[self.pos] == '\\' and self.pos + 1 < self.pat.len and self.pat[self.pos + 1] == ')';
    }

    fn atAlternation(self: *RegexParser) bool {
        if (self.pos >= self.pat.len) return false;
        if (self.ere) return self.pat[self.pos] == '|';
        return self.pat[self.pos] == '\\' and self.pos + 1 < self.pat.len and self.pat[self.pos + 1] == '|';
    }

    fn parseAlternation(self: *RegexParser) RegexError![]const Seq {
        var alts = std.ArrayListUnmanaged(Seq).empty;
        const first = try self.parseSeq();
        try alts.append(self.a, first);
        while (self.atAlternation()) {
            // consume the alternation operator
            self.pos += if (self.ere) 1 else 2;
            const s = try self.parseSeq();
            try alts.append(self.a, s);
        }
        return alts.items;
    }

    fn parseSeq(self: *RegexParser) RegexError!Seq {
        var pieces = std.ArrayListUnmanaged(Piece).empty;
        while (self.pos < self.pat.len) {
            if (self.atAlternation() or self.atGroupClose()) break;
            const atom = (try self.parseAtom(pieces.items.len == 0)) orelse break;
            const q = self.parseQuant();
            try pieces.append(self.a, .{ .atom = atom, .min = q.min, .max = q.max });
        }
        return .{ .pieces = pieces.items };
    }

    fn dollarIsAnchor(self: *RegexParser) bool {
        // In BRE, `$` is an anchor only at the end of the (sub)expression:
        // end of pattern, or right before \) or \| .
        const n = self.pos + 1;
        if (n >= self.pat.len) return true;
        if (self.pat[n] == '\\' and n + 1 < self.pat.len) {
            return self.pat[n + 1] == ')' or self.pat[n + 1] == '|';
        }
        return false;
    }

    fn parseAtom(self: *RegexParser, seq_start: bool) RegexError!?Atom {
        const c = self.pat[self.pos];

        if (c == '^' and (self.ere or seq_start)) {
            self.pos += 1;
            return Atom{ .kind = .bol };
        }
        if (c == '$') {
            if (self.ere or self.dollarIsAnchor()) {
                self.pos += 1;
                return Atom{ .kind = .eol };
            }
            self.pos += 1;
            return Atom{ .kind = .lit, .ch = '$' };
        }
        if (c == '.') {
            self.pos += 1;
            return Atom{ .kind = .any };
        }
        if (c == '[') {
            return try self.parseClass();
        }
        if (self.ere and c == '(') {
            self.pos += 1;
            return try self.parseGroup();
        }
        if (c == '\\' and self.pos + 1 < self.pat.len) {
            const nx = self.pat[self.pos + 1];
            if (!self.ere and nx == '(') {
                self.pos += 2;
                return try self.parseGroup();
            }
            if (nx >= '1' and nx <= '9') {
                self.pos += 2;
                return Atom{ .kind = .backref, .ref = nx - '0' };
            }
            // GNU word-boundary and char-class shorthands.
            switch (nx) {
                'b' => {
                    self.pos += 2;
                    return Atom{ .kind = .word_boundary };
                },
                'B' => {
                    self.pos += 2;
                    return Atom{ .kind = .not_word_boundary };
                },
                '<' => {
                    self.pos += 2;
                    return Atom{ .kind = .word_start };
                },
                '>' => {
                    self.pos += 2;
                    return Atom{ .kind = .word_end };
                },
                'w', 'W', 's', 'S' => {
                    self.pos += 2;
                    return try self.shorthandClass(nx);
                },
                else => {},
            }
            const lit: u8 = switch (nx) {
                'n' => '\n',
                't' => '\t',
                'r' => '\r',
                else => nx,
            };
            self.pos += 2;
            return Atom{ .kind = .lit, .ch = lit };
        }
        // Ordinary literal (including a lone metachar with nothing to repeat).
        self.pos += 1;
        return Atom{ .kind = .lit, .ch = c };
    }

    fn parseGroup(self: *RegexParser) RegexError!Atom {
        self.ngroups += 1;
        const gidx = self.ngroups;
        const alts = try self.parseAlternation();
        // consume close
        if (self.ere and self.pos < self.pat.len and self.pat[self.pos] == ')') {
            self.pos += 1;
        } else if (!self.ere and self.pos + 1 < self.pat.len and self.pat[self.pos] == '\\' and self.pat[self.pos + 1] == ')') {
            self.pos += 2;
        } else {
            return RegexError.InvalidRegex;
        }
        return Atom{ .kind = .group, .alts = alts, .gidx = gidx };
    }

    fn parseClass(self: *RegexParser) RegexError!Atom {
        // self.pat[self.pos] == '['
        var items = std.ArrayListUnmanaged(ClassItem).empty;
        var i = self.pos + 1;
        var negated = false;
        if (i < self.pat.len and self.pat[i] == '^') {
            negated = true;
            i += 1;
        }
        var first = true;
        while (i < self.pat.len) {
            if (self.pat[i] == ']' and !first) break;
            first = false;
            // POSIX class [:name:]
            if (self.pat[i] == '[' and i + 1 < self.pat.len and self.pat[i + 1] == ':') {
                const name_start = i + 2;
                var j = name_start;
                while (j + 1 < self.pat.len and !(self.pat[j] == ':' and self.pat[j + 1] == ']')) j += 1;
                if (j + 1 < self.pat.len) {
                    const name = self.pat[name_start..j];
                    if (posixClassFromName(name)) |pc| {
                        try items.append(self.a, .{ .posix = pc });
                    }
                    i = j + 2;
                    continue;
                }
            }
            // literal char, possibly a range
            var lo = self.pat[i];
            if (lo == '\\' and i + 1 < self.pat.len) {
                lo = switch (self.pat[i + 1]) {
                    'n' => '\n',
                    't' => '\t',
                    'r' => '\r',
                    else => self.pat[i + 1],
                };
                i += 2;
            } else {
                i += 1;
            }
            if (i + 1 < self.pat.len and self.pat[i] == '-' and self.pat[i + 1] != ']') {
                var hi = self.pat[i + 1];
                if (hi == '\\' and i + 2 < self.pat.len) {
                    hi = self.pat[i + 2];
                    i += 3;
                } else {
                    i += 2;
                }
                try items.append(self.a, .{ .range = .{ .lo = lo, .hi = hi } });
            } else {
                try items.append(self.a, .{ .ch = lo });
            }
        }
        if (i >= self.pat.len or self.pat[i] != ']') return RegexError.InvalidRegex;
        self.pos = i + 1;
        return Atom{ .kind = .class, .cls = .{ .negated = negated, .items = items.items } };
    }

    // Build a character-class atom for the GNU shorthands \w \W \s \S.
    //   \w == [[:alnum:]_], \W its negation; \s == [[:space:]], \S its negation.
    fn shorthandClass(self: *RegexParser, nx: u8) RegexError!Atom {
        var items = std.ArrayListUnmanaged(ClassItem).empty;
        switch (nx) {
            'w', 'W' => {
                try items.append(self.a, .{ .posix = .alnum });
                try items.append(self.a, .{ .ch = '_' });
            },
            's', 'S' => {
                try items.append(self.a, .{ .posix = .space });
            },
            else => unreachable,
        }
        const neg = (nx == 'W' or nx == 'S');
        return Atom{ .kind = .class, .cls = .{ .negated = neg, .items = items.items } };
    }

    fn parseQuant(self: *RegexParser) QuantRange {
        if (self.pos >= self.pat.len) return .{ .min = 1, .max = 1 };
        const c = self.pat[self.pos];
        if (self.ere) {
            switch (c) {
                '*' => {
                    self.pos += 1;
                    return .{ .min = 0, .max = Q_MAX };
                },
                '+' => {
                    self.pos += 1;
                    return .{ .min = 1, .max = Q_MAX };
                },
                '?' => {
                    self.pos += 1;
                    return .{ .min = 0, .max = 1 };
                },
                '{' => return self.parseInterval(false),
                else => return .{ .min = 1, .max = 1 },
            }
        } else {
            if (c == '*') {
                self.pos += 1;
                return .{ .min = 0, .max = Q_MAX };
            }
            if (c == '\\' and self.pos + 1 < self.pat.len) {
                const nx = self.pat[self.pos + 1];
                if (nx == '+') {
                    self.pos += 2;
                    return .{ .min = 1, .max = Q_MAX };
                }
                if (nx == '?') {
                    self.pos += 2;
                    return .{ .min = 0, .max = 1 };
                }
                if (nx == '{') return self.parseInterval(true);
            }
            return .{ .min = 1, .max = 1 };
        }
    }

    // Parse {n}, {n,}, {n,m}. `bre` means the braces are backslash-escaped and
    // the closing token is `\}`. On any malformation the `{` is treated as a
    // literal (return 1,1 without consuming), matching GNU's lenient behavior.
    fn parseInterval(self: *RegexParser, bre: bool) QuantRange {
        const save = self.pos;
        var i = self.pos + (if (bre) @as(usize, 2) else @as(usize, 1)); // skip { or \{
        var n: usize = 0;
        var have_n = false;
        while (i < self.pat.len and self.pat[i] >= '0' and self.pat[i] <= '9') {
            n = n *| 10 +| (self.pat[i] - '0');
            have_n = true;
            i += 1;
        }
        var m: usize = n;
        var have_comma = false;
        if (i < self.pat.len and self.pat[i] == ',') {
            have_comma = true;
            i += 1;
            var mm: usize = 0;
            var have_m = false;
            while (i < self.pat.len and self.pat[i] >= '0' and self.pat[i] <= '9') {
                mm = mm *| 10 +| (self.pat[i] - '0');
                have_m = true;
                i += 1;
            }
            m = if (have_m) mm else Q_MAX;
        }
        // closing
        const closed = if (bre)
            (i + 1 < self.pat.len and self.pat[i] == '\\' and self.pat[i + 1] == '}')
        else
            (i < self.pat.len and self.pat[i] == '}');
        if (!have_n or !closed) {
            self.pos = save; // treat { as literal
            return .{ .min = 1, .max = 1 };
        }
        self.pos = i + (if (bre) @as(usize, 2) else @as(usize, 1));
        return .{ .min = n, .max = if (have_comma) m else n };
    }
};

fn posixClassFromName(name: []const u8) ?PosixClass {
    const map = .{
        .{ "alpha", PosixClass.alpha },   .{ "digit", PosixClass.digit }, .{ "alnum", PosixClass.alnum },
        .{ "space", PosixClass.space },   .{ "upper", PosixClass.upper }, .{ "lower", PosixClass.lower },
        .{ "punct", PosixClass.punct },   .{ "xdigit", PosixClass.xdigit }, .{ "blank", PosixClass.blank },
        .{ "cntrl", PosixClass.cntrl },   .{ "graph", PosixClass.graph }, .{ "print", PosixClass.print },
    };
    inline for (map) |entry| {
        if (std.mem.eql(u8, name, entry[0])) return entry[1];
    }
    return null;
}

fn compileRegex(allocator: std.mem.Allocator, pattern: []const u8, ere: bool, icase: bool) RegexError!*Regex {
    const re = try allocator.create(Regex);
    errdefer allocator.destroy(re);
    re.* = .{ .arena = std.heap.ArenaAllocator.init(allocator), .icase = icase };
    errdefer re.arena.deinit();
    var parser = RegexParser{ .pat = pattern, .ere = ere, .a = re.arena.allocator() };
    const alts = try parser.parseAlternation();
    if (parser.pos != pattern.len) return RegexError.InvalidRegex; // trailing garbage e.g. unmatched )
    re.alts = alts;
    re.ngroups = parser.ngroups;
    return re;
}

// ---- Matcher ---------------------------------------------------------------

const Cont = struct {
    kind: enum { done, seq, close, quant },
    parent: ?*const Cont = null,
    seq: []const Piece = &.{},
    idx: usize = 0,
    gidx: usize = 0,
    atom: *const Atom = undefined,
    min: usize = 0,
    max: usize = 0,
    count: usize = 0,
    prev: usize = 0,
};

const MatchState = struct {
    re: *const Regex,
    text: []const u8,
    caps: [10]Span,

    fn cmatch(self: *MatchState, a: u8, b: u8) bool {
        if (self.re.icase) return std.ascii.toLower(a) == std.ascii.toLower(b);
        return a == b;
    }
};

fn isWordChar(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_';
}

fn atWordBoundary(text: []const u8, pos: usize) bool {
    const before = pos > 0 and isWordChar(text[pos - 1]);
    const after = pos < text.len and isWordChar(text[pos]);
    return before != after;
}

fn classMatches(spec: *const ClassSpec, ch: u8, icase: bool) bool {
    var found = false;
    for (spec.items) |it| {
        switch (it) {
            .ch => |c| {
                if (ch == c or (icase and std.ascii.toLower(ch) == std.ascii.toLower(c))) found = true;
            },
            .range => |r| {
                if (ch >= r.lo and ch <= r.hi) found = true;
                if (icase) {
                    const lc = std.ascii.toLower(ch);
                    if (lc >= std.ascii.toLower(r.lo) and lc <= std.ascii.toLower(r.hi)) found = true;
                    const uc = std.ascii.toUpper(ch);
                    if (uc >= r.lo and uc <= r.hi) found = true;
                }
            },
            .posix => |p| {
                const m = switch (p) {
                    .alpha => std.ascii.isAlphabetic(ch),
                    .digit => std.ascii.isDigit(ch),
                    .alnum => std.ascii.isAlphanumeric(ch),
                    .space => std.ascii.isWhitespace(ch),
                    .upper => std.ascii.isUpper(ch),
                    .lower => std.ascii.isLower(ch),
                    .punct => std.ascii.isPrint(ch) and !std.ascii.isAlphanumeric(ch) and !std.ascii.isWhitespace(ch) and ch != ' ',
                    .xdigit => std.ascii.isHex(ch),
                    .blank => ch == ' ' or ch == '\t',
                    .cntrl => std.ascii.isControl(ch),
                    .graph => std.ascii.isPrint(ch) and ch != ' ',
                    .print => std.ascii.isPrint(ch),
                };
                if (m) found = true;
            },
        }
        if (found) break;
    }
    return if (spec.negated) !found else found;
}

fn rApply(st: *MatchState, cont: ?*const Cont, pos: usize) ?usize {
    const c = cont orelse return pos;
    switch (c.kind) {
        .done => return pos,
        .seq => {
            if (c.idx >= c.seq.len) return rApply(st, c.parent, pos);
            const piece = &c.seq[c.idx];
            const after = Cont{ .kind = .seq, .seq = c.seq, .idx = c.idx + 1, .parent = c.parent };
            return rQuant(st, &piece.atom, piece.min, piece.max, 0, pos, pos, &after);
        },
        .quant => return rQuant(st, c.atom, c.min, c.max, c.count, pos, c.prev, c.parent),
        .close => {
            if (c.gidx != 0) {
                const saved_end = st.caps[c.gidx].end;
                const saved_set = st.caps[c.gidx].set;
                st.caps[c.gidx].end = pos;
                st.caps[c.gidx].set = true;
                if (rApply(st, c.parent, pos)) |e| return e;
                st.caps[c.gidx].end = saved_end;
                st.caps[c.gidx].set = saved_set;
                return null;
            }
            return rApply(st, c.parent, pos);
        },
    }
}

fn rQuant(st: *MatchState, atom: *const Atom, min: usize, max: usize, count: usize, pos: usize, prev: usize, after: ?*const Cont) ?usize {
    const zero_progress = count > 0 and pos == prev;
    if (count < max and !zero_progress) {
        const qc = Cont{ .kind = .quant, .atom = atom, .min = min, .max = max, .count = count + 1, .prev = pos, .parent = after };
        if (rAtom(st, atom, pos, &qc)) |e| return e;
    }
    if (count >= min) return rApply(st, after, pos);
    return null;
}

fn rAtom(st: *MatchState, atom: *const Atom, pos: usize, cont: *const Cont) ?usize {
    switch (atom.kind) {
        .lit => {
            if (pos < st.text.len and st.cmatch(atom.ch, st.text[pos])) return rApply(st, cont, pos + 1);
            return null;
        },
        .any => {
            if (pos < st.text.len) return rApply(st, cont, pos + 1);
            return null;
        },
        .class => {
            if (pos < st.text.len and classMatches(&atom.cls, st.text[pos], st.re.icase)) return rApply(st, cont, pos + 1);
            return null;
        },
        .bol => {
            if (pos == 0) return rApply(st, cont, pos);
            return null;
        },
        .eol => {
            if (pos == st.text.len) return rApply(st, cont, pos);
            return null;
        },
        .word_boundary => {
            if (atWordBoundary(st.text, pos)) return rApply(st, cont, pos);
            return null;
        },
        .not_word_boundary => {
            if (!atWordBoundary(st.text, pos)) return rApply(st, cont, pos);
            return null;
        },
        .word_start => {
            const before = pos > 0 and isWordChar(st.text[pos - 1]);
            const after = pos < st.text.len and isWordChar(st.text[pos]);
            if (!before and after) return rApply(st, cont, pos);
            return null;
        },
        .word_end => {
            const before = pos > 0 and isWordChar(st.text[pos - 1]);
            const after = pos < st.text.len and isWordChar(st.text[pos]);
            if (before and !after) return rApply(st, cont, pos);
            return null;
        },
        .backref => {
            const sp = st.caps[atom.ref];
            if (!sp.set) return rApply(st, cont, pos); // unmatched group matches empty
            const sub = st.text[sp.start..sp.end];
            if (pos + sub.len > st.text.len) return null;
            var k: usize = 0;
            while (k < sub.len) : (k += 1) {
                if (!st.cmatch(sub[k], st.text[pos + k])) return null;
            }
            return rApply(st, cont, pos + sub.len);
        },
        .group => {
            for (atom.alts) |alt| {
                const saved_start = st.caps[atom.gidx].start;
                const saved_end = st.caps[atom.gidx].end;
                const saved_set = st.caps[atom.gidx].set;
                if (atom.gidx != 0) st.caps[atom.gidx].start = pos;
                const closeC = Cont{ .kind = .close, .gidx = atom.gidx, .parent = cont };
                const innerC = Cont{ .kind = .seq, .seq = alt.pieces, .idx = 0, .parent = &closeC };
                if (rApply(st, &innerC, pos)) |e| return e;
                st.caps[atom.gidx].start = saved_start;
                st.caps[atom.gidx].end = saved_end;
                st.caps[atom.gidx].set = saved_set;
            }
            return null;
        },
    }
}

/// Search for the leftmost match of `re` in `text` at or after `from`.
fn regexSearch(re: *const Regex, text: []const u8, from: usize) ?Match {
    var pos = from;
    while (true) : (pos += 1) {
        var st = MatchState{ .re = re, .text = text, .caps = [_]Span{.{}} ** 10 };
        const doneC = Cont{ .kind = .done };
        for (re.alts) |alt| {
            st.caps = [_]Span{.{}} ** 10;
            const innerC = Cont{ .kind = .seq, .seq = alt.pieces, .idx = 0, .parent = &doneC };
            if (rApply(&st, &innerC, pos)) |end| {
                return .{ .start = pos, .end = end, .caps = st.caps };
            }
        }
        if (pos >= text.len) break;
    }
    return null;
}

fn regexMatches(re: *const Regex, text: []const u8) bool {
    return regexSearch(re, text, 0) != null;
}

const SubstituteError = error{ OutOfMemory, NoRegex };

fn substitute(allocator: std.mem.Allocator, line: []const u8, cmd: *const Command) SubstituteError![]u8 {
    const re = resolveRegex(cmd.regex, cmd.regex_empty) orelse return SubstituteError.NoRegex;

    var result = std.ArrayListUnmanaged(u8).empty;
    errdefer result.deinit(allocator);

    var pos: usize = 0;
    var occurrence: usize = 0;
    const nth = cmd.sub_flags.nth;
    const global = cmd.sub_flags.global;

    while (pos <= line.len) {
        const match = regexSearch(re, line, pos) orelse {
            try result.appendSlice(allocator, line[pos..]);
            break;
        };

        const abs_start = match.start;
        const abs_end = match.end;
        occurrence += 1;

        // GNU semantics: `N` alone -> only the Nth; `Ng` -> the Nth and every
        // occurrence after it; `g` alone -> all; bare -> the first.
        const should_replace = if (nth == 0)
            (global or occurrence == 1)
        else if (global)
            (occurrence >= nth)
        else
            (occurrence == nth);

        // Everything between the previous cursor and this match is copied verbatim.
        try result.appendSlice(allocator, line[pos..abs_start]);
        if (should_replace) {
            try appendReplacement(allocator, &result, cmd.replacement, line, &match);
        } else {
            try result.appendSlice(allocator, line[abs_start..abs_end]);
        }
        pos = abs_end;

        // Done after this single replacement when neither global nor an
        // open-ended Ng span keeps us going.
        if (should_replace and !global) {
            try result.appendSlice(allocator, line[pos..]);
            break;
        }

        // Advance past a zero-width match so we make progress.
        if (abs_start == abs_end) {
            if (pos < line.len) {
                try result.append(allocator, line[pos]);
                pos += 1;
            } else {
                break;
            }
        }
    }

    return result.toOwnedSlice(allocator);
}

const CaseMode = enum { none, upper, lower };

const CaseState = struct {
    mode: CaseMode = .none, // persistent \U / \L
    one: CaseMode = .none, // one-shot \u / \l (applies to next output char)

    fn byte(self: *CaseState, allocator: std.mem.Allocator, result: *std.ArrayListUnmanaged(u8), ch: u8) !void {
        var c = ch;
        if (self.one != .none) {
            c = if (self.one == .upper) std.ascii.toUpper(c) else std.ascii.toLower(c);
            self.one = .none;
        } else switch (self.mode) {
            .upper => c = std.ascii.toUpper(c),
            .lower => c = std.ascii.toLower(c),
            .none => {},
        }
        try result.append(allocator, c);
    }

    fn slice(self: *CaseState, allocator: std.mem.Allocator, result: *std.ArrayListUnmanaged(u8), s: []const u8) !void {
        for (s) |c| try self.byte(allocator, result, c);
    }
};

fn appendReplacement(allocator: std.mem.Allocator, result: *std.ArrayListUnmanaged(u8), replacement: []const u8, line: []const u8, match: *const Match) !void {
    const whole = line[match.start..match.end];
    var cs = CaseState{};
    var i: usize = 0;
    while (i < replacement.len) : (i += 1) {
        if (replacement[i] == '&') {
            try cs.slice(allocator, result, whole);
        } else if (replacement[i] == '\\' and i + 1 < replacement.len) {
            i += 1;
            switch (replacement[i]) {
                '0'...'9' => {
                    const g = replacement[i] - '0';
                    if (g == 0) {
                        try cs.slice(allocator, result, whole);
                    } else {
                        const sp = match.caps[g];
                        if (sp.set) try cs.slice(allocator, result, line[sp.start..sp.end]);
                    }
                },
                'n' => try cs.byte(allocator, result, '\n'),
                't' => try cs.byte(allocator, result, '\t'),
                'r' => try cs.byte(allocator, result, '\r'),
                '&' => try cs.byte(allocator, result, '&'),
                '\\' => try cs.byte(allocator, result, '\\'),
                // GNU case-conversion escapes: \U/\L set persistent mode,
                // \u/\l set a one-shot for the next char, \E resets.
                'U' => {
                    cs.mode = .upper;
                    cs.one = .none;
                },
                'L' => {
                    cs.mode = .lower;
                    cs.one = .none;
                },
                'E' => {
                    cs.mode = .none;
                    cs.one = .none;
                },
                'u' => cs.one = .upper,
                'l' => cs.one = .lower,
                else => try cs.byte(allocator, result, replacement[i]),
            }
        } else {
            try cs.byte(allocator, result, replacement[i]);
        }
    }
}

const ParseError = error{ OutOfMemory, ParseError };

/// Decode one `y///` set: read from script[pos..] up to the unescaped delimiter,
/// decoding `\n`, `\t`, `\r`, `\\` and an escaped delimiter to their literal
/// bytes. Advances `pos` past the closing delimiter. Errors if unterminated.
fn decodeYSet(allocator: std.mem.Allocator, script: []const u8, pos: *usize, delim: u8) error{ OutOfMemory, Unterminated }![]u8 {
    var out = std.ArrayListUnmanaged(u8).empty;
    errdefer out.deinit(allocator);
    var p = pos.*;
    while (p < script.len and script[p] != delim) {
        if (script[p] == '\\' and p + 1 < script.len) {
            const nx = script[p + 1];
            const decoded: u8 = switch (nx) {
                'n' => '\n',
                't' => '\t',
                'r' => '\r',
                '\\' => '\\',
                else => nx, // includes an escaped delimiter
            };
            try out.append(allocator, decoded);
            p += 2;
        } else {
            try out.append(allocator, script[p]);
            p += 1;
        }
    }
    if (p >= script.len) return error.Unterminated; // no closing delimiter
    p += 1; // skip closing delimiter
    pos.* = p;
    return out.toOwnedSlice(allocator);
}

fn reportParseError(pos: usize, reason: []const u8) void {
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "zsed: -e expression: char {d}: {s}\n", .{ pos, reason }) catch return;
    _ = libc.write(libc.STDERR_FILENO, msg.ptr, msg.len);
}

fn parseCommand(allocator: std.mem.Allocator, script: []const u8, ere: bool) ParseError!std.ArrayListUnmanaged(Command) {
    var commands = std.ArrayListUnmanaged(Command).empty;
    errdefer commands.deinit(allocator);

    var pos: usize = 0;
    while (pos < script.len) {
        // Skip whitespace and semicolons
        while (pos < script.len and (script[pos] == ' ' or script[pos] == '\t' or
            script[pos] == '\n' or script[pos] == ';'))
        {
            pos += 1;
        }
        if (pos >= script.len) break;

        var cmd = Command{};

        // Parse address(es)
        const addr_result = try parseAddress(allocator, script, pos, ere);
        cmd.addr1 = addr_result.addr;
        pos = addr_result.new_pos;

        // Skip whitespace
        while (pos < script.len and (script[pos] == ' ' or script[pos] == '\t')) {
            pos += 1;
        }

        // Check for comma (range)
        if (pos < script.len and script[pos] == ',') {
            pos += 1;
            while (pos < script.len and (script[pos] == ' ' or script[pos] == '\t')) {
                pos += 1;
            }
            const addr2_result = try parseAddress(allocator, script, pos, ere);
            cmd.addr2 = addr2_result.addr;
            pos = addr2_result.new_pos;
            cmd.has_range = true;
        }

        // Skip whitespace
        while (pos < script.len and (script[pos] == ' ' or script[pos] == '\t')) {
            pos += 1;
        }

        // Check for negation
        if (pos < script.len and script[pos] == '!') {
            cmd.addr1.negated = true;
            pos += 1;
        }

        if (pos >= script.len) break;

        // Parse command
        const c = script[pos];
        pos += 1;

        switch (c) {
            's' => {
                cmd.cmd_type = .substitute;
                if (pos >= script.len) {
                    reportParseError(pos, "unterminated `s' command");
                    return ParseError.ParseError;
                }
                const delim = script[pos];
                pos += 1;

                // Find pattern
                const pattern_start = pos;
                while (pos < script.len and script[pos] != delim) {
                    if (script[pos] == '\\' and pos + 1 < script.len) pos += 1;
                    pos += 1;
                }
                if (pos >= script.len) {
                    reportParseError(pos, "unterminated `s' command");
                    return ParseError.ParseError;
                }
                cmd.pattern = try allocator.dupe(u8, script[pattern_start..pos]);
                pos += 1; // Skip delimiter

                // Find replacement
                const repl_start = pos;
                while (pos < script.len and script[pos] != delim) {
                    if (script[pos] == '\\' and pos + 1 < script.len) pos += 1;
                    pos += 1;
                }
                if (pos >= script.len) {
                    reportParseError(pos, "unterminated `s' command");
                    return ParseError.ParseError;
                }
                cmd.replacement = try allocator.dupe(u8, script[repl_start..pos]);
                pos += 1; // Skip delimiter

                // Parse flags
                while (pos < script.len and script[pos] != ';' and script[pos] != '\n' and script[pos] != ' ' and script[pos] != '}') {
                    switch (script[pos]) {
                        'g' => cmd.sub_flags.global = true,
                        'i', 'I' => cmd.sub_flags.ignore_case = true,
                        'p' => cmd.sub_flags.print = true,
                        '1'...'9' => cmd.sub_flags.nth = script[pos] - '0',
                        else => {},
                    }
                    pos += 1;
                }

                // Compile the substitute regex now that we know the i flag.
                if (cmd.pattern.len == 0) {
                    cmd.regex_empty = true;
                } else {
                    cmd.regex = compileRegex(allocator, cmd.pattern, ere, cmd.sub_flags.ignore_case) catch {
                        reportParseError(pattern_start, "invalid regular expression");
                        return ParseError.ParseError;
                    };
                }
            },
            'y' => {
                cmd.cmd_type = .transliterate;
                if (pos >= script.len) {
                    reportParseError(pos, "unterminated `y' command");
                    return ParseError.ParseError;
                }
                const y_delim = script[pos];
                pos += 1;

                const src = decodeYSet(allocator, script, &pos, y_delim) catch |e| switch (e) {
                    error.Unterminated => {
                        reportParseError(pos, "unterminated `y' command");
                        return ParseError.ParseError;
                    },
                    error.OutOfMemory => return ParseError.OutOfMemory,
                };
                cmd.source_set = src;

                const dst = decodeYSet(allocator, script, &pos, y_delim) catch |e| switch (e) {
                    error.Unterminated => {
                        reportParseError(pos, "unterminated `y' command");
                        return ParseError.ParseError;
                    },
                    error.OutOfMemory => return ParseError.OutOfMemory,
                };
                cmd.dest_set = dst;

                if (cmd.source_set.len != cmd.dest_set.len) {
                    reportParseError(pos, "strings for `y' command are different lengths");
                    return ParseError.ParseError;
                }
            },
            'b' => {
                cmd.cmd_type = .branch;
                // Skip optional whitespace
                while (pos < script.len and (script[pos] == ' ' or script[pos] == '\t')) pos += 1;
                // Parse optional label name
                const lbl_start = pos;
                while (pos < script.len and script[pos] != ';' and script[pos] != '\n' and
                    script[pos] != ' ' and script[pos] != '\t' and script[pos] != '}')
                {
                    pos += 1;
                }
                cmd.label_name = try allocator.dupe(u8, script[lbl_start..pos]);
            },
            't' => {
                cmd.cmd_type = .branch_sub;
                // Skip optional whitespace
                while (pos < script.len and (script[pos] == ' ' or script[pos] == '\t')) pos += 1;
                // Parse optional label name
                const lbl_start = pos;
                while (pos < script.len and script[pos] != ';' and script[pos] != '\n' and
                    script[pos] != ' ' and script[pos] != '\t' and script[pos] != '}')
                {
                    pos += 1;
                }
                cmd.label_name = try allocator.dupe(u8, script[lbl_start..pos]);
            },
            ':' => {
                cmd.cmd_type = .label;
                // Skip optional whitespace
                while (pos < script.len and (script[pos] == ' ' or script[pos] == '\t')) pos += 1;
                // Parse label name
                const lbl_start = pos;
                while (pos < script.len and script[pos] != ';' and script[pos] != '\n' and
                    script[pos] != ' ' and script[pos] != '\t' and script[pos] != '}')
                {
                    pos += 1;
                }
                cmd.label_name = try allocator.dupe(u8, script[lbl_start..pos]);
            },
            'N' => cmd.cmd_type = .append_next,
            'P' => cmd.cmd_type = .print_first,
            'D' => cmd.cmd_type = .delete_first,
            'd' => cmd.cmd_type = .delete,
            'p' => cmd.cmd_type = .print,
            'q' => cmd.cmd_type = .quit,
            'n' => cmd.cmd_type = .next,
            '=' => cmd.cmd_type = .print_line_num,
            'h' => cmd.cmd_type = .hold,
            'H' => cmd.cmd_type = .hold_append,
            'g' => cmd.cmd_type = .get,
            'G' => cmd.cmd_type = .get_append,
            'x' => cmd.cmd_type = .exchange,
            'a' => {
                cmd.cmd_type = .append;
                // Skip optional backslash and whitespace
                if (pos < script.len and script[pos] == '\\') pos += 1;
                while (pos < script.len and (script[pos] == ' ' or script[pos] == '\t')) pos += 1;
                if (pos < script.len and script[pos] == '\n') pos += 1;

                // Parse text until end of line or unescaped semicolon
                const text_start = pos;
                while (pos < script.len and script[pos] != '\n') {
                    if (script[pos] == '\\' and pos + 1 < script.len) pos += 1;
                    pos += 1;
                }
                cmd.text = try allocator.dupe(u8, script[text_start..pos]);
            },
            'i' => {
                cmd.cmd_type = .insert;
                // Skip optional backslash and whitespace
                if (pos < script.len and script[pos] == '\\') pos += 1;
                while (pos < script.len and (script[pos] == ' ' or script[pos] == '\t')) pos += 1;
                if (pos < script.len and script[pos] == '\n') pos += 1;

                // Parse text
                const text_start = pos;
                while (pos < script.len and script[pos] != '\n') {
                    if (script[pos] == '\\' and pos + 1 < script.len) pos += 1;
                    pos += 1;
                }
                cmd.text = try allocator.dupe(u8, script[text_start..pos]);
            },
            'c' => {
                cmd.cmd_type = .change;
                // Skip optional backslash and whitespace
                if (pos < script.len and script[pos] == '\\') pos += 1;
                while (pos < script.len and (script[pos] == ' ' or script[pos] == '\t')) pos += 1;
                if (pos < script.len and script[pos] == '\n') pos += 1;

                // Parse text
                const text_start = pos;
                while (pos < script.len and script[pos] != '\n') {
                    if (script[pos] == '\\' and pos + 1 < script.len) pos += 1;
                    pos += 1;
                }
                cmd.text = try allocator.dupe(u8, script[text_start..pos]);
            },
            '#' => {
                // Comment - skip to end of line
                while (pos < script.len and script[pos] != '\n') pos += 1;
                continue;
            },
            '{' => cmd.cmd_type = .block_start,
            '}' => cmd.cmd_type = .block_end,
            else => {
                var buf: [64]u8 = undefined;
                const reason = std.fmt.bufPrint(&buf, "unknown command: `{c}'", .{c}) catch "unknown command";
                reportParseError(pos, reason);
                return ParseError.ParseError;
            },
        }

        try commands.append(allocator, cmd);
    }

    // Resolve command-grouping braces: pair each `{` with its matching `}` so the
    // executor can skip a whole block when the block's address does not match.
    {
        var stack = std.ArrayListUnmanaged(usize).empty;
        defer stack.deinit(allocator);
        for (commands.items, 0..) |*c, idx| {
            if (c.cmd_type == .block_start) {
                try stack.append(allocator, idx);
            } else if (c.cmd_type == .block_end) {
                if (stack.items.len == 0) {
                    reportParseError(idx, "unexpected `}'");
                    return ParseError.ParseError;
                }
                const open = stack.pop().?;
                commands.items[open].block_end = idx;
            }
        }
        if (stack.items.len != 0) {
            reportParseError(0, "unmatched `{'");
            return ParseError.ParseError;
        }
    }

    return commands;
}

fn parseAddress(allocator: std.mem.Allocator, script: []const u8, start: usize, ere: bool) ParseError!struct { addr: Address, new_pos: usize } {
    var addr = Address{};
    var pos = start;

    if (pos >= script.len) return .{ .addr = addr, .new_pos = pos };

    // Line number
    if (script[pos] >= '0' and script[pos] <= '9') {
        addr.addr_type = .line_number;
        var num: usize = 0;
        while (pos < script.len and script[pos] >= '0' and script[pos] <= '9') {
            num = num *| 10 +| (script[pos] - '0');
            pos += 1;
        }
        addr.line_num = num;

        // Check for step (first~step)
        if (pos < script.len and script[pos] == '~') {
            pos += 1;
            var step: usize = 0;
            while (pos < script.len and script[pos] >= '0' and script[pos] <= '9') {
                step = step *| 10 +| (script[pos] - '0');
                pos += 1;
            }
            addr.addr_type = .step;
            addr.step = step;
        }
    } else if (script[pos] == '$') {
        addr.addr_type = .last_line;
        pos += 1;
    } else if (script[pos] == '/') {
        addr.addr_type = .regex;
        pos += 1;
        const pattern_start = pos;
        while (pos < script.len and script[pos] != '/') {
            if (script[pos] == '\\' and pos + 1 < script.len) pos += 1;
            pos += 1;
        }
        if (pos >= script.len) {
            reportParseError(pos, "unterminated address regex");
            return ParseError.ParseError;
        }
        addr.pattern = script[pattern_start..pos];
        pos += 1; // Skip closing /

        // Optional address flags: I (case-insensitive), M (multiline; accepted
        // but treated as default here).
        var icase = false;
        while (pos < script.len and (script[pos] == 'I' or script[pos] == 'M')) {
            if (script[pos] == 'I') icase = true;
            pos += 1;
        }

        if (addr.pattern.len == 0) {
            addr.regex_empty = true;
        } else {
            addr.regex = compileRegex(allocator, addr.pattern, ere, icase) catch {
                reportParseError(pattern_start, "invalid regular expression");
                return ParseError.ParseError;
            };
        }
    }

    return .{ .addr = addr, .new_pos = pos };
}

fn addressMatches(addr: *const Address, line_num: usize, is_last: bool, line: []const u8) bool {
    const matches = switch (addr.addr_type) {
        .none => true,
        .line_number => line_num == addr.line_num,
        .last_line => is_last,
        .regex => blk: {
            const re = resolveRegex(addr.regex, addr.regex_empty) orelse break :blk false;
            break :blk regexMatches(re, line);
        },
        .step => if (addr.line_num == 0) false else (line_num >= addr.line_num and
            (addr.step == 0 or (line_num - addr.line_num) % addr.step == 0)),
    };
    return if (addr.negated) !matches else matches;
}

const OutputBuffer = struct {
    buf: [65536]u8 = undefined,
    len: usize = 0,
    fd: i32 = libc.STDOUT_FILENO,

    fn write(self: *OutputBuffer, data: []const u8) void {
        if (self.len + data.len > self.buf.len) {
            self.flush();
        }
        if (data.len > self.buf.len) {
            // Data too large, write directly
            _ = libc.write(self.fd, data.ptr, data.len);
            return;
        }
        @memcpy(self.buf[self.len..][0..data.len], data);
        self.len += data.len;
    }

    fn writeLine(self: *OutputBuffer, data: []const u8) void {
        self.write(data);
        self.write("\n");
    }

    /// Write a pattern-space line, appending a trailing newline only when the
    /// originating input line had one (preserves GNU's no-final-newline rule).
    fn writePS(self: *OutputBuffer, data: []const u8, nl: bool) void {
        self.write(data);
        if (nl) self.write("\n");
    }

    fn writeNum(self: *OutputBuffer, num: usize) void {
        var tmp: [20]u8 = undefined;
        var n = num;
        var i: usize = tmp.len;
        if (n == 0) {
            i -= 1;
            tmp[i] = '0';
        } else {
            while (n > 0) {
                i -= 1;
                tmp[i] = @intCast('0' + n % 10);
                n /= 10;
            }
        }
        self.write(tmp[i..]);
    }

    fn flush(self: *OutputBuffer) void {
        if (self.len > 0) {
            _ = libc.write(self.fd, &self.buf, self.len);
            self.len = 0;
        }
    }
};

fn findLabelIndex(commands: []Command, label_name: []const u8) ?usize {
    for (commands, 0..) |*cmd, idx| {
        if (cmd.cmd_type == .label and std.mem.eql(u8, cmd.label_name, label_name)) {
            return idx;
        }
    }
    return null;
}

fn transliterate(allocator: std.mem.Allocator, text: []const u8, source: []const u8, dest: []const u8) ![]u8 {
    var result = try allocator.alloc(u8, text.len);
    for (text, 0..) |ch, idx| {
        var replaced = false;
        for (source, 0..) |sc, si| {
            if (ch == sc) {
                result[idx] = if (si < dest.len) dest[si] else ch;
                replaced = true;
                break;
            }
        }
        if (!replaced) {
            result[idx] = ch;
        }
    }
    return result;
}

/// LineReader reads from an fd (or stdin) and produces lines one at a time.
/// This is needed so that N command can pull in the next line from within
/// the command processing loop.
const LineReader = struct {
    read_buf: [BUFFER_SIZE]u8 = undefined,
    read_len: usize = 0,
    read_pos: usize = 0,
    fd: i32,
    eof: bool = false,
    // Whether the most recently returned line ended with a newline in the input.
    had_newline: bool = true,

    fn init(fd: i32) LineReader {
        return .{ .fd = fd };
    }

    /// Return true if there is at least one more byte of input available,
    /// reading ahead into the buffer without consuming it. Used to detect the
    /// last line (`$` address, ranged `c`). Treats read errors as EOF.
    fn hasMore(self: *LineReader) bool {
        if (self.read_pos < self.read_len) return true;
        if (self.eof) return false;
        const n = libc.read(self.fd, &self.read_buf, self.read_buf.len);
        if (n <= 0) {
            self.eof = true;
            return false;
        }
        self.read_len = @intCast(n);
        self.read_pos = 0;
        return true;
    }

    /// Read the next line. Returns null at EOF.
    /// The returned slice is allocated and owned by the caller.
    fn nextLine(self: *LineReader, allocator: std.mem.Allocator) !?[]u8 {
        var line_buf = std.ArrayListUnmanaged(u8).empty;
        errdefer line_buf.deinit(allocator);

        while (true) {
            // Scan remaining buffer for newline
            while (self.read_pos < self.read_len) {
                const byte = self.read_buf[self.read_pos];
                self.read_pos += 1;
                if (byte == '\n') {
                    self.had_newline = true;
                    return try line_buf.toOwnedSlice(allocator);
                }
                try line_buf.append(allocator, byte);
            }
            // Need more data
            if (self.eof) {
                // Return remaining data as last line (no trailing newline)
                if (line_buf.items.len > 0) {
                    self.had_newline = false;
                    return try line_buf.toOwnedSlice(allocator);
                }
                line_buf.deinit(allocator);
                return null;
            }
            const n = libc.read(self.fd, &self.read_buf, self.read_buf.len);
            if (n <= 0) {
                self.eof = true;
                // Return remaining data as last line
                if (line_buf.items.len > 0) {
                    self.had_newline = false;
                    return try line_buf.toOwnedSlice(allocator);
                }
                line_buf.deinit(allocator);
                return null;
            }
            self.read_len = @intCast(n);
            self.read_pos = 0;
        }
    }
};

fn processEscText(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var text_buf = std.ArrayListUnmanaged(u8).empty;
    errdefer text_buf.deinit(allocator);
    var ti: usize = 0;
    while (ti < text.len) {
        if (text[ti] == '\\' and ti + 1 < text.len) {
            ti += 1;
            switch (text[ti]) {
                'n' => try text_buf.append(allocator, '\n'),
                't' => try text_buf.append(allocator, '\t'),
                else => try text_buf.append(allocator, text[ti]),
            }
        } else {
            try text_buf.append(allocator, text[ti]);
        }
        ti += 1;
    }
    return text_buf.toOwnedSlice(allocator);
}

fn dirOf(path: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| {
        return path[0 .. i + 1];
    }
    return "";
}

fn renameZ(allocator: std.mem.Allocator, old: []const u8, new: []const u8) !void {
    const old_z = try allocator.dupeZ(u8, old);
    defer allocator.free(old_z);
    const new_z = try allocator.dupeZ(u8, new);
    defer allocator.free(new_z);
    if (libc.rename(old_z.ptr, new_z.ptr) != 0) return error.RenameFailed;
}

/// Finalize an in-place edit: optionally back up the original, then atomically
/// rename the temp file over it. Returns an error on any filesystem failure.
fn finalizeInPlace(allocator: std.mem.Allocator, orig: []const u8, tmp: []const u8, suffix: []const u8) !void {
    if (suffix.len > 0) {
        // Build the backup name. A `*` in the suffix is replaced by the
        // original filename (GNU convention); otherwise it is appended.
        var backup = std.ArrayListUnmanaged(u8).empty;
        defer backup.deinit(allocator);
        if (std.mem.indexOfScalar(u8, suffix, '*')) |_| {
            for (suffix) |ch| {
                if (ch == '*') try backup.appendSlice(allocator, orig) else try backup.append(allocator, ch);
            }
        } else {
            try backup.appendSlice(allocator, orig);
            try backup.appendSlice(allocator, suffix);
        }
        try renameZ(allocator, orig, backup.items);
    }
    try renameZ(allocator, tmp, orig);
}

fn processFile(
    allocator: std.mem.Allocator,
    path: []const u8,
    is_stdin: bool,
    commands: []Command,
    config: *const Config,
) !bool {
    var out = OutputBuffer{};

    var hold_space = std.ArrayListUnmanaged(u8).empty;
    defer hold_space.deinit(allocator);

    var fd: i32 = undefined;
    if (is_stdin) {
        fd = libc.STDIN_FILENO;
    } else {
        const path_z = try allocator.dupeZ(u8, path);
        defer allocator.free(path_z);
        fd = libc.open(path_z.ptr, .{ .ACCMODE = .RDONLY }, @as(libc.mode_t, 0));
        if (fd < 0) {
            var buf: [1024]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "zsed: can't read {s}: No such file or directory\n", .{path}) catch "zsed: cannot open file\n";
            _ = libc.write(libc.STDERR_FILENO, msg.ptr, msg.len);
            return error.OpenError;
        }
    }
    defer if (!is_stdin) {
        _ = libc.close(fd);
    };

    // In-place setup: redirect output to a temp file in the same directory.
    var tmp_path: ?[]u8 = null;
    var tmp_fd: i32 = -1;
    const do_in_place = config.in_place and !is_stdin;
    defer if (tmp_path) |tp| allocator.free(tp);
    if (do_in_place) {
        const dir = dirOf(path);
        // Unpredictable temp name created atomically via mkstemp (O_CREAT|O_EXCL,
        // mode 0600) so a predictable name can't be pre-created as a symlink and
        // clobbered (TOCTOU). mkstemp rewrites the trailing XXXXXX in place.
        const template_str = try std.fmt.allocPrint(allocator, "{s}.zsed_tmpXXXXXX", .{dir});
        defer allocator.free(template_str);
        const template = try allocator.dupeZ(u8, template_str);
        defer allocator.free(template);
        tmp_fd = mkstemp(template.ptr);
        if (tmp_fd < 0) {
            _ = libc.write(libc.STDERR_FILENO, "zsed: couldn't open temporary file\n", 35);
            return error.OpenError;
        }
        tmp_path = try allocator.dupe(u8, std.mem.sliceTo(template, 0));
        // Preserve the original file's permission bits on the replacement, but
        // never copy the setuid/setgid/sticky bits onto a fresh file we own.
        var st: libc.Stat = undefined;
        if (libc.fstat(fd, &st) == 0) {
            _ = libc.fchmod(tmp_fd, @intCast(st.mode & 0o0777));
        }
        out.fd = tmp_fd;
    }

    var reader = LineReader.init(fd);
    var line_num: usize = 0;

    var pattern_space = std.ArrayListUnmanaged(u8).empty;
    defer pattern_space.deinit(allocator);

    var quit_program = false;

    // Main cycle: read a line, process commands, print if needed
    while (true) {
        const maybe_line = try reader.nextLine(allocator);
        if (maybe_line == null) break;
        const line = maybe_line.?;
        defer allocator.free(line);

        pattern_space.clearRetainingCapacity();
        try pattern_space.appendSlice(allocator, line);
        line_num += 1;

        var sub_happened = false; // Track substitutions for 't' command
        processCommands(allocator, commands, &pattern_space, &hold_space, &reader, &line_num, &sub_happened, config, &out) catch |e| {
            if (e == error.Quit) {
                quit_program = true;
                break;
            }
            return e;
        };
    }

    out.flush();

    if (do_in_place) {
        _ = libc.close(tmp_fd);
        finalizeInPlace(allocator, path, tmp_path.?, config.in_place_suffix) catch {
            _ = libc.write(libc.STDERR_FILENO, "zsed: failed to finalize in-place edit\n", 39);
            return error.OpenError;
        };
    }

    return quit_program;
}

fn flushAppends(allocator: std.mem.Allocator, out: *OutputBuffer, queue: *std.ArrayListUnmanaged([]u8)) void {
    for (queue.items) |t| {
        out.writeLine(t);
        allocator.free(t);
    }
    queue.clearRetainingCapacity();
}

fn processCommands(
    allocator: std.mem.Allocator,
    commands: []Command,
    pattern_space: *std.ArrayListUnmanaged(u8),
    hold_space: *std.ArrayListUnmanaged(u8),
    reader: *LineReader,
    line_num: *usize,
    sub_happened: *bool,
    config: *const Config,
    out: *OutputBuffer,
) error{ OutOfMemory, Quit }!void {
    // Reset sub_happened at start of new input line
    sub_happened.* = false;
    return processCommandsInner(allocator, commands, pattern_space, hold_space, reader, line_num, sub_happened, config, out);
}

fn processCommandsInner(
    allocator: std.mem.Allocator,
    commands: []Command,
    pattern_space: *std.ArrayListUnmanaged(u8),
    hold_space: *std.ArrayListUnmanaged(u8),
    reader: *LineReader,
    line_num: *usize,
    sub_happened: *bool,
    config: *const Config,
    out: *OutputBuffer,
) error{ OutOfMemory, Quit }!void {
    const print_line = !config.quiet;

    // Text queued by `a` (append), flushed at the end of the cycle and on
    // cycle-boundary events (n/N/d/c/q), matching GNU's ordering.
    var append_queue = std.ArrayListUnmanaged([]u8).empty;
    defer {
        for (append_queue.items) |t| allocator.free(t);
        append_queue.deinit(allocator);
    }

    // Outer loop supports the `D` command restarting the script on the
    // remaining pattern space WITHOUT recursion (avoids stack overflow).
    restart: while (true) {
        var cmd_idx: usize = 0;
        while (cmd_idx < commands.len) {
            const cmd = &commands[cmd_idx];
            const is_last = !reader.hasMore();

            var matches: bool = false;
            var range_end = false;
            if (cmd.has_range) {
                if (!cmd.in_range) {
                    if (addressMatches(&cmd.addr1, line_num.*, is_last, pattern_space.items)) {
                        cmd.in_range = true;
                        matches = true;
                        // A range that closes on the same line it opened.
                        if (addressMatches(&cmd.addr2, line_num.*, is_last, pattern_space.items) and
                            cmd.addr2.addr_type == .line_number and cmd.addr2.line_num <= line_num.*)
                        {
                            cmd.in_range = false;
                            range_end = true;
                        }
                    }
                } else {
                    matches = true;
                    if (addressMatches(&cmd.addr2, line_num.*, is_last, pattern_space.items)) {
                        cmd.in_range = false;
                        range_end = true;
                    }
                }
                if (cmd.addr1.negated) {
                    matches = !matches;
                    range_end = false;
                }
            } else {
                matches = addressMatches(&cmd.addr1, line_num.*, is_last, pattern_space.items);
            }

            // Command-grouping block: on match, fall through into the block; on
            // no-match, jump past the matching `}` so the inner commands are
            // scoped by the block's address (they must NOT run unconditionally).
            if (cmd.cmd_type == .block_start) {
                cmd_idx = if (matches) cmd_idx + 1 else cmd.block_end + 1;
                continue;
            }

            if (!matches) {
                cmd_idx += 1;
                continue;
            }

            switch (cmd.cmd_type) {
                .substitute => {
                    const new_line = substitute(allocator, pattern_space.items, cmd) catch |e| switch (e) {
                        error.OutOfMemory => return error.OutOfMemory,
                        error.NoRegex => {
                            const m = "zsed: no previous regular expression\n";
                            _ = libc.write(libc.STDERR_FILENO, m.ptr, m.len);
                            std.process.exit(1);
                        },
                    };
                    const changed = !std.mem.eql(u8, new_line, pattern_space.items);
                    pattern_space.clearRetainingCapacity();
                    try pattern_space.appendSlice(allocator, new_line);
                    allocator.free(new_line);
                    if (changed) {
                        sub_happened.* = true;
                        if (cmd.sub_flags.print) {
                            out.writePS(pattern_space.items, reader.had_newline);
                        }
                    }
                },
                .delete => {
                    flushAppends(allocator, out, &append_queue);
                    return; // Don't print, start next cycle
                },
                .print => {
                    out.writePS(pattern_space.items, reader.had_newline);
                },
                .quit => {
                    if (print_line) {
                        out.writePS(pattern_space.items, reader.had_newline);
                    }
                    flushAppends(allocator, out, &append_queue);
                    return error.Quit;
                },
                .print_line_num => {
                    out.writeNum(line_num.*);
                    out.write("\n");
                },
                .next => {
                    if (print_line) {
                        out.writePS(pattern_space.items, reader.had_newline);
                    }
                    flushAppends(allocator, out, &append_queue);
                    const maybe_line = try reader.nextLine(allocator);
                    if (maybe_line == null) {
                        // No next line: n branches to end and quits.
                        return error.Quit;
                    }
                    const next_line = maybe_line.?;
                    defer allocator.free(next_line);
                    pattern_space.clearRetainingCapacity();
                    try pattern_space.appendSlice(allocator, next_line);
                    line_num.* += 1;
                },
                .hold => {
                    hold_space.clearRetainingCapacity();
                    try hold_space.appendSlice(allocator, pattern_space.items);
                },
                .hold_append => {
                    try hold_space.append(allocator, '\n');
                    try hold_space.appendSlice(allocator, pattern_space.items);
                },
                .get => {
                    pattern_space.clearRetainingCapacity();
                    try pattern_space.appendSlice(allocator, hold_space.items);
                },
                .get_append => {
                    try pattern_space.append(allocator, '\n');
                    try pattern_space.appendSlice(allocator, hold_space.items);
                },
                .exchange => {
                    const temp = try allocator.dupe(u8, pattern_space.items);
                    defer allocator.free(temp);
                    pattern_space.clearRetainingCapacity();
                    try pattern_space.appendSlice(allocator, hold_space.items);
                    hold_space.clearRetainingCapacity();
                    try hold_space.appendSlice(allocator, temp);
                },
                .append => {
                    // Queue the text; it is emitted after this cycle's autoprint.
                    const text_processed = try processEscText(allocator, cmd.text);
                    try append_queue.append(allocator, text_processed);
                },
                .insert => {
                    const text_processed = try processEscText(allocator, cmd.text);
                    defer allocator.free(text_processed);
                    out.writeLine(text_processed);
                },
                .change => {
                    // For a ranged c, emit the text only once, when the range
                    // closes (or on the last line if the range runs off the end).
                    const emit = if (cmd.has_range) (range_end or is_last) else true;
                    if (emit) {
                        const text_processed = try processEscText(allocator, cmd.text);
                        defer allocator.free(text_processed);
                        out.writeLine(text_processed);
                    }
                    flushAppends(allocator, out, &append_queue);
                    return; // delete pattern space, start next cycle
                },
                .transliterate => {
                    const new_text = try transliterate(allocator, pattern_space.items, cmd.source_set, cmd.dest_set);
                    pattern_space.clearRetainingCapacity();
                    try pattern_space.appendSlice(allocator, new_text);
                    allocator.free(new_text);
                },
                .label => {},
                .branch => {
                    if (cmd.label_name.len == 0) {
                        break;
                    } else {
                        if (findLabelIndex(commands, cmd.label_name)) |target| {
                            cmd_idx = target;
                            continue;
                        }
                        break;
                    }
                },
                .branch_sub => {
                    if (sub_happened.*) {
                        sub_happened.* = false;
                        if (cmd.label_name.len == 0) {
                            break;
                        } else {
                            if (findLabelIndex(commands, cmd.label_name)) |target| {
                                cmd_idx = target;
                                continue;
                            }
                            break;
                        }
                    }
                },
                .append_next => {
                    flushAppends(allocator, out, &append_queue);
                    const maybe_line = try reader.nextLine(allocator);
                    if (maybe_line == null) {
                        // GNU default: print pattern space (unless -n) and quit.
                        if (print_line) {
                            out.writePS(pattern_space.items, reader.had_newline);
                        }
                        return error.Quit;
                    }
                    const next_line = maybe_line.?;
                    defer allocator.free(next_line);
                    try pattern_space.append(allocator, '\n');
                    try pattern_space.appendSlice(allocator, next_line);
                    line_num.* += 1;
                },
                .print_first => {
                    const ps = pattern_space.items;
                    if (std.mem.indexOfScalar(u8, ps, '\n')) |nl_pos| {
                        out.writeLine(ps[0..nl_pos]);
                    } else {
                        out.writePS(ps, reader.had_newline);
                    }
                },
                .delete_first => {
                    const ps = pattern_space.items;
                    if (std.mem.indexOfScalar(u8, ps, '\n')) |nl_pos| {
                        // Remove up to and including the first newline, then
                        // restart the script on the remainder (loop, no recursion).
                        const remaining = try allocator.dupe(u8, ps[nl_pos + 1 ..]);
                        defer allocator.free(remaining);
                        pattern_space.clearRetainingCapacity();
                        try pattern_space.appendSlice(allocator, remaining);
                        continue :restart;
                    } else {
                        // No newline: behaves like `d`.
                        flushAppends(allocator, out, &append_queue);
                        return;
                    }
                },
                .block_start => {}, // handled above the switch
                .block_end => {}, // closing brace is a no-op marker
                .noop => {},
            }

            cmd_idx += 1;
        }

        // End of command list - print pattern space if auto-print, then appends.
        if (print_line) {
            out.writePS(pattern_space.items, reader.had_newline);
        }
        flushAppends(allocator, out, &append_queue);
        return;
    }
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
    var found_script = false;

    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (arg.len > 0 and arg[0] == '-' and arg.len > 1 and arg[1] != '-') {
            var j: usize = 1;
            while (j < arg.len) : (j += 1) {
                switch (arg[j]) {
                    'n' => config.quiet = true,
                    'e' => {
                        if (j + 1 < arg.len) {
                            try config.expressions.append(allocator, try allocator.dupe(u8, arg[j + 1 ..]));
                            found_script = true;
                            break;
                        } else {
                            i += 1;
                            if (i < args.len) {
                                try config.expressions.append(allocator, try allocator.dupe(u8, args[i]));
                                found_script = true;
                            }
                        }
                    },
                    'f' => {
                        if (j + 1 < arg.len) {
                            try config.script_files.append(allocator, try allocator.dupe(u8, arg[j + 1 ..]));
                            found_script = true;
                            break;
                        } else {
                            i += 1;
                            if (i < args.len) {
                                try config.script_files.append(allocator, try allocator.dupe(u8, args[i]));
                                found_script = true;
                            }
                        }
                    },
                    'E', 'r' => config.extended_regex = true,
                    'i' => {
                        config.in_place = true;
                        if (j + 1 < arg.len) {
                            config.in_place_suffix = arg[j + 1 ..];
                            break;
                        }
                    },
                    else => {},
                }
            }
        } else if (arg.len > 1 and arg[0] == '-' and arg[1] == '-') {
            if (std.mem.eql(u8, arg, "--help")) {
                printHelp();
                std.process.exit(0);
            } else if (std.mem.eql(u8, arg, "--version")) {
                printVersion();
                std.process.exit(0);
            } else if (std.mem.eql(u8, arg, "--quiet") or std.mem.eql(u8, arg, "--silent")) {
                config.quiet = true;
            } else if (std.mem.eql(u8, arg, "--regexp-extended")) {
                config.extended_regex = true;
            } else if (std.mem.startsWith(u8, arg, "--expression=")) {
                try config.expressions.append(allocator, try allocator.dupe(u8, arg[13..]));
                found_script = true;
            } else if (std.mem.startsWith(u8, arg, "--file=")) {
                try config.script_files.append(allocator, try allocator.dupe(u8, arg[7..]));
                found_script = true;
            } else if (std.mem.startsWith(u8, arg, "--in-place")) {
                config.in_place = true;
                if (arg.len > 10 and arg[10] == '=') {
                    config.in_place_suffix = arg[11..];
                }
            }
        } else {
            // First non-option is script if no -e or -f was given
            if (!found_script and config.expressions.items.len == 0 and config.script_files.items.len == 0) {
                try config.expressions.append(allocator, try allocator.dupe(u8, arg));
                found_script = true;
            } else {
                try config.files.append(allocator, try allocator.dupe(u8, arg));
            }
        }
    }

    if (config.files.items.len == 0) {
        try config.files.append(allocator, try allocator.dupe(u8, "-"));
    }

    return config;
}

fn printHelp() void {
    const help =
        \\Usage: zsed [OPTION]... {script-only-if-no-other-script} [input-file]...
        \\
        \\  -n, --quiet, --silent    suppress automatic printing of pattern space
        \\  -e script, --expression=script
        \\                           add the script to the commands to be executed
        \\  -f script-file, --file=script-file
        \\                           add contents of script-file to commands
        \\  -i[SUFFIX], --in-place[=SUFFIX]
        \\                           edit files in place (makes backup if SUFFIX supplied)
        \\  -E, -r, --regexp-extended
        \\                           use extended regular expressions
        \\      --help               display this help and exit
        \\      --version            output version information and exit
        \\
        \\Commands:
        \\  s/regexp/replacement/flags  substitute matching text
        \\    flags: g (global), i (ignore case), p (print), N (Nth occurrence)
        \\  y/source/dest/              transliterate characters
        \\  d                           delete pattern space
        \\  D                           delete first line of pattern space
        \\  p                           print pattern space
        \\  P                           print first line of pattern space
        \\  q                           quit
        \\  n                           read next line into pattern space
        \\  N                           append next line to pattern space
        \\  a\\ text                     append text after current line
        \\  i\\ text                     insert text before current line
        \\  c\\ text                     change (replace) current line with text
        \\  =                           print line number
        \\  h/H                         copy/append pattern space to hold space
        \\  g/G                         copy/append hold space to pattern space
        \\  x                           exchange pattern and hold spaces
        \\  :label                      define label for b and t commands
        \\  b label                     branch to label (or end of script)
        \\  t label                     branch if substitution was made
        \\
        \\Addresses:
        \\  N                           line number
        \\  $                           last line
        \\  /regexp/                    lines matching regexp
        \\  N,M                         range from line N to M
        \\  N~S                         every S lines starting at N
        \\
        \\zsed - High-performance stream editor in Zig
        \\
    ;
    _ = libc.write(libc.STDOUT_FILENO, help.ptr, help.len);
}

fn printVersion() void {
    _ = libc.write(libc.STDOUT_FILENO, "zsed 0.1.0\n", 11);
}

pub fn main(init: std.process.Init) void {
    const allocator = init.gpa;

    var config = parseArgs(allocator, init.minimal.args) catch {
        std.process.exit(1);
    };
    defer config.deinit(allocator);

    // Read script files (-f) and add their contents as expressions
    for (config.script_files.items) |script_path| {
        const script_path_z = allocator.dupeZ(u8, script_path) catch {
            std.debug.print("zsed: out of memory\n", .{});
            std.process.exit(1);
        };
        defer allocator.free(script_path_z);

        const sfd = libc.open(script_path_z.ptr, .{ .ACCMODE = .RDONLY }, @as(libc.mode_t, 0));
        if (sfd < 0) {
            std.debug.print("zsed: cannot open script file: {s}\n", .{script_path});
            std.process.exit(1);
        }
        defer _ = libc.close(sfd);

        // Read entire script file
        var script_buf = std.ArrayListUnmanaged(u8).empty;
        defer script_buf.deinit(allocator);
        var tmp_buf: [4096]u8 = undefined;
        while (true) {
            const n = libc.read(sfd, &tmp_buf, tmp_buf.len);
            if (n <= 0) break;
            const bytes: usize = @intCast(n);
            script_buf.appendSlice(allocator, tmp_buf[0..bytes]) catch {
                std.debug.print("zsed: out of memory\n", .{});
                std.process.exit(1);
            };
        }
        const duped = allocator.dupe(u8, script_buf.items) catch {
            std.debug.print("zsed: out of memory\n", .{});
            std.process.exit(1);
        };
        config.expressions.append(allocator, duped) catch {
            std.debug.print("zsed: out of memory\n", .{});
            std.process.exit(1);
        };
    }

    if (config.expressions.items.len == 0) {
        std.debug.print("zsed: no script specified\n", .{});
        std.process.exit(1);
    }

    // Parse all expressions into commands
    var all_commands = std.ArrayListUnmanaged(Command).empty;
    defer {
        // Free allocated strings and compiled regexes in commands
        for (all_commands.items) |cmd| {
            if (cmd.pattern.len > 0) allocator.free(cmd.pattern);
            if (cmd.replacement.len > 0) allocator.free(cmd.replacement);
            if (cmd.text.len > 0) allocator.free(cmd.text);
            if (cmd.source_set.len > 0) allocator.free(cmd.source_set);
            if (cmd.dest_set.len > 0) allocator.free(cmd.dest_set);
            if (cmd.label_name.len > 0) allocator.free(cmd.label_name);
            if (cmd.regex) |r| {
                r.deinit();
                allocator.destroy(r);
            }
            if (cmd.addr1.regex) |r| {
                r.deinit();
                allocator.destroy(r);
            }
            if (cmd.addr2.regex) |r| {
                r.deinit();
                allocator.destroy(r);
            }
        }
        all_commands.deinit(allocator);
    }

    for (config.expressions.items) |expr| {
        var cmds = parseCommand(allocator, expr, config.extended_regex) catch |e| {
            // parseCommand already printed a specific diagnostic for ParseError.
            if (e == error.OutOfMemory) std.debug.print("zsed: out of memory\n", .{});
            std.process.exit(4); // GNU sed exit status for a bad script
        };
        for (cmds.items) |cmd| {
            all_commands.append(allocator, cmd) catch {};
        }
        cmds.deinit(allocator);
    }

    // GNU: a file that can't be opened is a warning (exit status 2), and the
    // remaining files are still processed. `q` stops the whole program.
    var exit_status: u8 = 0;
    for (config.files.items) |file| {
        const is_stdin = std.mem.eql(u8, file, "-");
        const quit = processFile(allocator, file, is_stdin, all_commands.items, &config) catch |e| {
            if (e == error.OpenError) {
                exit_status = 2;
                continue;
            }
            std.process.exit(1);
        };
        if (quit) break;
    }
    std.process.exit(exit_status);
}
