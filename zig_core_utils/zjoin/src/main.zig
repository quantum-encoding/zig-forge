//! zjoin - join lines of two files on a common join field.
//!
//! GNU `join`-compatible: a merge join over two sorted inputs. This is a
//! faithful port of the coreutils join(1) algorithm (join.c) — same field
//! model (default separator collapses runs of blanks and skips leading
//! blanks; -t sets a single-char separator), same interleaved output order
//! for -a/-v unpairable lines, same -o / -o auto / -e formatting applied to
//! unpaired lines, and the same lazy --check-order sortedness diagnostics.
//!
//! Usage: zjoin [OPTION]... FILE1 FILE2

const std = @import("std");
const libc = std.c;

const VERSION = "1.1.0";

// ---------------------------------------------------------------------------
// Robust output (fixes: short-write / EINTR silently dropping data)
// ---------------------------------------------------------------------------

var out_buf: [64 * 1024]u8 = undefined;
var out_len: usize = 0;

fn writeAllFd(fd: c_int, bytes: []const u8) void {
    var off: usize = 0;
    while (off < bytes.len) {
        const n = libc.write(fd, bytes[off..].ptr, bytes.len - off);
        if (n < 0) {
            switch (std.posix.errno(n)) {
                .INTR => continue,
                else => {
                    if (fd == libc.STDOUT_FILENO) {
                        _ = libc.write(libc.STDERR_FILENO, "zjoin: write error\n", 19);
                        std.process.exit(1);
                    }
                    return;
                },
            }
        }
        if (n == 0) return; // avoid a spin on a pathological 0-byte write
        off += @intCast(n);
    }
}

fn outFlush() void {
    if (out_len == 0) return;
    writeAllFd(libc.STDOUT_FILENO, out_buf[0..out_len]);
    out_len = 0;
}

fn outWrite(bytes: []const u8) void {
    if (bytes.len == 0) return;
    if (out_len + bytes.len > out_buf.len) {
        outFlush();
        if (bytes.len >= out_buf.len) {
            writeAllFd(libc.STDOUT_FILENO, bytes);
            return;
        }
    }
    @memcpy(out_buf[out_len..][0..bytes.len], bytes);
    out_len += bytes.len;
}

fn outByte(c: u8) void {
    if (out_len == out_buf.len) outFlush();
    out_buf[out_len] = c;
    out_len += 1;
}

/// Flush pending stdout, then emit a diagnostic to stderr.
fn diagRaw(msg: []const u8) void {
    outFlush();
    writeAllFd(libc.STDERR_FILENO, msg);
}

fn diagf(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch blk: {
        // Truncated diagnostic is acceptable; keep the prefix.
        break :blk buf[0..];
    };
    diagRaw(s);
}

fn die(comptime fmt: []const u8, args: anytype) noreturn {
    diagf(fmt, args);
    std.process.exit(1);
}

// ---------------------------------------------------------------------------
// Config
// ---------------------------------------------------------------------------

const CheckOrder = enum { default, enabled, disabled };
const SepMode = enum { blank, char, whole };

const OutSpec = struct { file: u8, field: usize }; // file: 0=join, 1, 2 ; field 0-based

const Config = struct {
    join_field_1: usize = 0, // 0-based
    join_field_2: usize = 0,
    jf1_set: bool = false,
    jf2_set: bool = false,
    output_specs: std.ArrayListUnmanaged(OutSpec) = .empty,
    have_o: bool = false,
    autoformat: bool = false,
    sep_mode: SepMode = .blank,
    sep_char: u8 = ' ',
    output_sep: []const u8 = " ",
    empty_filler: ?[]const u8 = null,
    ignore_case: bool = false,
    print_unpairables_1: bool = false,
    print_unpairables_2: bool = false,
    print_pairables: bool = true,
    check_order: CheckOrder = .default,
    header: bool = false,
    eolchar: u8 = '\n',
    file1: ?[]const u8 = null,
    file2: ?[]const u8 = null,
};

// ---------------------------------------------------------------------------
// Lines and fields
// ---------------------------------------------------------------------------

const Field = struct { beg: usize, len: usize };

const Line = struct {
    raw: []const u8, // line contents, without the terminator
    fields: []const Field,
    nfields: usize,
};

/// GNU join's uni_blank: the stand-in for "the other file's line" when
/// printing an unpaired line. Zero fields.
const uni_blank = Line{ .raw = "", .fields = &[_]Field{}, .nfields = 0 };

fn isBlank(c: u8) bool {
    return c == ' ' or c == '\t';
}

/// Split `raw` into fields per the coreutils xfields() rules.
fn splitFields(arena: std.mem.Allocator, raw: []const u8, cfg: *const Config) ![]const Field {
    var list: std.ArrayListUnmanaged(Field) = .empty;
    switch (cfg.sep_mode) {
        .whole => {
            // -t '' : the whole line is a single field (empty line -> 0 fields).
            if (raw.len != 0) try list.append(arena, .{ .beg = 0, .len = raw.len });
        },
        .char => {
            // Single-char separator: adjacent separators yield empty fields.
            // An empty line yields zero fields (xfields returns early).
            if (raw.len != 0) {
                var start: usize = 0;
                var i: usize = 0;
                while (i < raw.len) : (i += 1) {
                    if (raw[i] == cfg.sep_char) {
                        try list.append(arena, .{ .beg = start, .len = i - start });
                        start = i + 1;
                    }
                }
                try list.append(arena, .{ .beg = start, .len = raw.len - start });
            }
        },
        .blank => {
            // Default: skip leading blanks; each field is a maximal run of
            // non-blank bytes; runs of blanks separate fields.
            var i: usize = 0;
            while (i < raw.len) {
                while (i < raw.len and isBlank(raw[i])) : (i += 1) {}
                if (i >= raw.len) break;
                const start = i;
                while (i < raw.len and !isBlank(raw[i])) : (i += 1) {}
                try list.append(arena, .{ .beg = start, .len = i - start });
            }
        },
    }
    return list.items;
}

fn parseAllLines(arena: std.mem.Allocator, data: []const u8, cfg: *const Config) ![]const Line {
    var lines: std.ArrayListUnmanaged(Line) = .empty;
    const term = cfg.eolchar;
    var start: usize = 0;
    var i: usize = 0;
    while (i < data.len) : (i += 1) {
        if (data[i] == term) {
            const raw = data[start..i];
            const fields = try splitFields(arena, raw, cfg);
            try lines.append(arena, .{ .raw = raw, .fields = fields, .nfields = fields.len });
            start = i + 1;
        }
    }
    if (start < data.len) {
        const raw = data[start..];
        const fields = try splitFields(arena, raw, cfg);
        try lines.append(arena, .{ .raw = raw, .fields = fields, .nfields = fields.len });
    }
    return lines.items;
}

fn keyOf(line: *const Line, jf: usize) []const u8 {
    if (jf < line.nfields) {
        const f = line.fields[jf];
        return line.raw[f.beg..][0..f.len];
    }
    return "";
}

fn keycmp(l1: *const Line, jf1: usize, l2: *const Line, jf2: usize, ignore_case: bool) std.math.Order {
    const k1 = keyOf(l1, jf1);
    const k2 = keyOf(l2, jf2);
    // Absent / empty join fields sort before any non-empty one.
    if (k1.len == 0) return if (k2.len == 0) .eq else .lt;
    if (k2.len == 0) return .gt;

    const n = @min(k1.len, k2.len);
    if (ignore_case) {
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const ca = std.ascii.toLower(k1[i]);
            const cb = std.ascii.toLower(k2[i]);
            if (ca < cb) return .lt;
            if (ca > cb) return .gt;
        }
    } else {
        const c = std.mem.order(u8, k1[0..n], k2[0..n]);
        if (c != .eq) return c;
    }
    return std.math.order(k1.len, k2.len);
}

// ---------------------------------------------------------------------------
// Merge-join engine (port of coreutils join())
// ---------------------------------------------------------------------------

const Cursor = struct {
    lines: []const Line,
    pos: usize = 0,
    line_no: usize = 0, // 1-based number of the most recently read line
    prev: ?*const Line = null,
};

const State = struct {
    arena: std.mem.Allocator,
    cfg: *const Config,
    seen_unpairable: bool = false,
    issued: [2]bool = .{ false, false },
    autocount_1: usize = 0,
    autocount_2: usize = 0,
};

fn checkOrder(prev: *const Line, cur: *const Line, which: u8, st: *State) void {
    const cfg = st.cfg;
    if (cfg.check_order == .disabled) return;
    if (cfg.check_order != .enabled and !st.seen_unpairable) return;
    if (st.issued[which - 1]) return;

    const jf = if (which == 1) cfg.join_field_1 else cfg.join_field_2;
    if (keycmp(prev, jf, cur, jf, cfg.ignore_case) == .gt) {
        const name = if (which == 1) cfg.file1.? else cfg.file2.?;
        // Build with the arena so long lines aren't truncated.
        const msg = std.fmt.allocPrint(st.arena, "zjoin: {s}:{d}: is not sorted: {s}\n", .{
            name, cur_line_no, cur.raw,
        }) catch "zjoin: input is not in sorted order\n";
        diagRaw(msg);
        if (cfg.check_order == .enabled) std.process.exit(1);
        st.issued[which - 1] = true;
    }
}

// The line number of the line most recently returned by getLine, made visible
// to checkOrder (which runs inside getLine, against the current line).
var cur_line_no: usize = 0;

fn getLine(cur: *Cursor, which: u8, st: *State) ?*const Line {
    if (cur.pos >= cur.lines.len) return null;
    const line = &cur.lines[cur.pos];
    cur.pos += 1;
    cur.line_no += 1;
    cur_line_no = cur.line_no;
    if (cur.prev) |p| checkOrder(p, line, which, st);
    cur.prev = line;
    return line;
}

fn prfield(n: usize, line: *const Line, cfg: *const Config) void {
    if (n < line.nfields) {
        const f = line.fields[n];
        if (f.len != 0) {
            outWrite(line.raw[f.beg..][0..f.len]);
        } else if (cfg.empty_filler) |e| {
            outWrite(e);
        }
    } else if (cfg.empty_filler) |e| {
        outWrite(e);
    }
}

fn prfields(line: *const Line, join_field: usize, autocount: usize, cfg: *const Config) void {
    const nfields = if (cfg.autoformat) autocount else line.nfields;
    var i: usize = 0;
    while (i < join_field and i < nfields) : (i += 1) {
        outWrite(cfg.output_sep);
        prfield(i, line, cfg);
    }
    i = join_field + 1;
    while (i < nfields) : (i += 1) {
        outWrite(cfg.output_sep);
        prfield(i, line, cfg);
    }
}

fn prjoin(line1: *const Line, line2: *const Line, cfg: *const Config, st: *State) void {
    if (cfg.have_o) {
        for (cfg.output_specs.items, 0..) |o, idx| {
            if (idx != 0) outWrite(cfg.output_sep);
            var line: *const Line = undefined;
            var field: usize = undefined;
            if (o.file == 0) {
                if (line1 == &uni_blank) {
                    line = line2;
                    field = cfg.join_field_2;
                } else {
                    line = line1;
                    field = cfg.join_field_1;
                }
            } else {
                line = if (o.file == 1) line1 else line2;
                field = o.field;
            }
            prfield(field, line, cfg);
        }
        outByte(cfg.eolchar);
    } else {
        var line: *const Line = undefined;
        var field: usize = undefined;
        if (line1 == &uni_blank) {
            line = line2;
            field = cfg.join_field_2;
        } else {
            line = line1;
            field = cfg.join_field_1;
        }
        prfield(field, line, cfg);
        prfields(line1, cfg.join_field_1, st.autocount_1, cfg);
        prfields(line2, cfg.join_field_2, st.autocount_2, cfg);
        outByte(cfg.eolchar);
    }
}

fn join(arena: std.mem.Allocator, cfg: *const Config, lines1: []const Line, lines2: []const Line) !void {
    var cur1 = Cursor{ .lines = lines1 };
    var cur2 = Cursor{ .lines = lines2 };
    var st = State{ .arena = arena, .cfg = cfg };

    var seq1: std.ArrayListUnmanaged(*const Line) = .empty;
    var seq2: std.ArrayListUnmanaged(*const Line) = .empty;

    // Read the first line of each file.
    if (getLine(&cur1, 1, &st)) |l| try seq1.append(arena, l);
    if (getLine(&cur2, 2, &st)) |l| try seq2.append(arena, l);

    if (cfg.autoformat) {
        st.autocount_1 = if (seq1.items.len > 0) seq1.items[0].nfields else 0;
        st.autocount_2 = if (seq2.items.len > 0) seq2.items[0].nfields else 0;
    }

    if (cfg.header and (seq1.items.len > 0 or seq2.items.len > 0)) {
        const h1: *const Line = if (seq1.items.len > 0) seq1.items[0] else &uni_blank;
        const h2: *const Line = if (seq2.items.len > 0) seq2.items[0] else &uni_blank;
        prjoin(h1, h2, cfg, &st);
        cur1.prev = null;
        cur2.prev = null;
        if (seq1.items.len > 0) {
            seq1.clearRetainingCapacity();
            if (getLine(&cur1, 1, &st)) |l| try seq1.append(arena, l);
        }
        if (seq2.items.len > 0) {
            seq2.clearRetainingCapacity();
            if (getLine(&cur2, 2, &st)) |l| try seq2.append(arena, l);
        }
    }

    while (seq1.items.len > 0 and seq2.items.len > 0) {
        const diff = keycmp(seq1.items[0], cfg.join_field_1, seq2.items[0], cfg.join_field_2, cfg.ignore_case);

        if (diff == .lt) {
            if (cfg.print_unpairables_1) prjoin(seq1.items[0], &uni_blank, cfg, &st);
            seq1.clearRetainingCapacity();
            if (getLine(&cur1, 1, &st)) |l| try seq1.append(arena, l);
            st.seen_unpairable = true;
            continue;
        }
        if (diff == .gt) {
            if (cfg.print_unpairables_2) prjoin(&uni_blank, seq2.items[0], cfg, &st);
            seq2.clearRetainingCapacity();
            if (getLine(&cur2, 2, &st)) |l| try seq2.append(arena, l);
            st.seen_unpairable = true;
            continue;
        }

        // Keys are equal: gather the rest of both groups, then output the
        // cartesian product.
        var sentinel1: ?*const Line = null;
        while (true) {
            const l = getLine(&cur1, 1, &st) orelse break;
            if (keycmp(l, cfg.join_field_1, seq2.items[0], cfg.join_field_2, cfg.ignore_case) != .eq) {
                sentinel1 = l;
                break;
            }
            try seq1.append(arena, l);
        }
        var sentinel2: ?*const Line = null;
        while (true) {
            const l = getLine(&cur2, 2, &st) orelse break;
            if (keycmp(seq1.items[0], cfg.join_field_1, l, cfg.join_field_2, cfg.ignore_case) != .eq) {
                sentinel2 = l;
                break;
            }
            try seq2.append(arena, l);
        }

        if (cfg.print_pairables) {
            for (seq1.items) |a| {
                for (seq2.items) |b| {
                    prjoin(a, b, cfg, &st);
                }
            }
        }

        seq1.clearRetainingCapacity();
        if (sentinel1) |s| try seq1.append(arena, s);
        seq2.clearRetainingCapacity();
        if (sentinel2) |s| try seq2.append(arena, s);
    }

    // Read the tail ends of both inputs to (a) print remaining unpairables and
    // (b) verify sort order, exactly like coreutils.
    var checktail = false;
    if (cfg.check_order != .disabled and !(st.issued[0] and st.issued[1])) checktail = true;

    if ((cfg.print_unpairables_1 or checktail) and seq1.items.len > 0) {
        if (cfg.print_unpairables_1) prjoin(seq1.items[0], &uni_blank, cfg, &st);
        if (seq2.items.len > 0) st.seen_unpairable = true;
        while (getLine(&cur1, 1, &st)) |line| {
            if (cfg.print_unpairables_1) prjoin(line, &uni_blank, cfg, &st);
            if (st.issued[0] and !cfg.print_unpairables_1) break;
        }
    }

    if ((cfg.print_unpairables_2 or checktail) and seq2.items.len > 0) {
        if (cfg.print_unpairables_2) prjoin(&uni_blank, seq2.items[0], cfg, &st);
        if (seq1.items.len > 0) st.seen_unpairable = true;
        while (getLine(&cur2, 2, &st)) |line| {
            if (cfg.print_unpairables_2) prjoin(&uni_blank, line, cfg, &st);
            if (st.issued[1] and !cfg.print_unpairables_2) break;
        }
    }

    outFlush();
    if (st.issued[0] or st.issued[1]) {
        diagRaw("zjoin: input is not in sorted order\n");
        std.process.exit(1);
    }
}

// ---------------------------------------------------------------------------
// Argument parsing (getopt-ish, with GNU-compatible validation)
// ---------------------------------------------------------------------------

/// Convert a 1-based join-field string to a 0-based index. Errors like GNU's
/// string_to_join_field: a diagnostic + exit 1 on non-numeric or <= 0.
fn parseFieldNum(s: []const u8) usize {
    const v = std.fmt.parseInt(usize, s, 10) catch |e| switch (e) {
        // Too-large values are clamped (GNU clamps to PTRDIFF_MAX); such a
        // field simply never exists, matching GNU's effective behavior.
        error.Overflow => return std.math.maxInt(usize),
        error.InvalidCharacter => die("zjoin: invalid field number: '{s}'\n", .{s}),
    };
    if (v == 0) die("zjoin: invalid field number: '{s}'\n", .{s});
    return v - 1;
}

fn parseFileNum(s: []const u8) u8 {
    const v = std.fmt.parseInt(u32, s, 10) catch {
        die("zjoin: invalid file number: '{s}'\n", .{s});
    };
    if (v != 1 and v != 2) die("zjoin: invalid file number: '{s}'\n", .{s});
    return @intCast(v);
}

fn setJoinField1(cfg: *Config, val: usize) void {
    if (cfg.jf1_set and cfg.join_field_1 != val)
        die("zjoin: incompatible join fields {d}, {d}\n", .{ cfg.join_field_1 + 1, val + 1 });
    cfg.join_field_1 = val;
    cfg.jf1_set = true;
}

fn setJoinField2(cfg: *Config, val: usize) void {
    if (cfg.jf2_set and cfg.join_field_2 != val)
        die("zjoin: incompatible join fields {d}, {d}\n", .{ cfg.join_field_2 + 1, val + 1 });
    cfg.join_field_2 = val;
    cfg.jf2_set = true;
}

fn setTab(cfg: *Config, val: []const u8) void {
    if (val.len == 0) {
        cfg.sep_mode = .whole;
        return;
    }
    if (std.mem.eql(u8, val, "\\0")) {
        cfg.sep_mode = .char;
        cfg.sep_char = 0;
        cfg.output_sep = "\x00";
        return;
    }
    if (val.len != 1) die("zjoin: multi-character tab '{s}'\n", .{val});
    if (cfg.sep_mode == .char and cfg.sep_char != val[0]) die("zjoin: incompatible tabs\n", .{});
    cfg.sep_mode = .char;
    cfg.sep_char = val[0];
    cfg.output_sep = val;
}

fn addFieldList(arena: std.mem.Allocator, cfg: *Config, str: []const u8) !void {
    cfg.have_o = true;
    var it = std.mem.tokenizeAny(u8, str, ", \t");
    while (it.next()) |spec| {
        try decodeFieldSpec(arena, cfg, spec);
    }
}

fn decodeFieldSpec(arena: std.mem.Allocator, cfg: *Config, s: []const u8) !void {
    if (s.len == 0) return;
    switch (s[0]) {
        '0' => {
            if (s.len != 1) die("zjoin: invalid field specifier: '{s}'\n", .{s});
            try cfg.output_specs.append(arena, .{ .file = 0, .field = 0 });
        },
        '1', '2' => {
            if (s.len < 2 or s[1] != '.') die("zjoin: invalid field specifier: '{s}'\n", .{s});
            const field = parseFieldNum(s[2..]);
            try cfg.output_specs.append(arena, .{ .file = s[0] - '0', .field = field });
        },
        else => die("zjoin: invalid file number in field spec: '{s}'\n", .{s}),
    }
}

fn usageError(cfg: *const Config) noreturn {
    if (cfg.file1) |f1| {
        diagf("zjoin: missing operand after '{s}'\nTry 'zjoin --help' for more information.\n", .{f1});
    } else {
        diagRaw("zjoin: missing operand\nTry 'zjoin --help' for more information.\n");
    }
    std.process.exit(1);
}

fn printHelp() void {
    const help =
        \\Usage: zjoin [OPTION]... FILE1 FILE2
        \\For each pair of input lines with identical join fields, write a line to
        \\standard output.  The default join field is the first, delimited by blanks.
        \\
        \\  -a FILENUM        also print unpairable lines from file FILENUM, where
        \\                      FILENUM is 1 or 2, corresponding to FILE1 or FILE2
        \\  -e STRING         replace missing (empty) input fields with STRING;
        \\                      i.e., missing fields specified with '-12jo' options
        \\  -i, --ignore-case ignore differences in case when comparing fields
        \\  -j FIELD          equivalent to '-1 FIELD -2 FIELD'
        \\  -o FORMAT         obey FORMAT while constructing output line
        \\  -t CHAR           use CHAR as input and output field separator
        \\  -v FILENUM        like -a FILENUM, but suppress joined output lines
        \\  -1 FIELD          join on this FIELD of file 1
        \\  -2 FIELD          join on this FIELD of file 2
        \\  --check-order     check that the input is correctly sorted, even
        \\                      if all input lines are pairable
        \\  --nocheck-order   do not check that the input is correctly sorted
        \\  --header          treat the first line in each file as field headers,
        \\                      print them without trying to pair them
        \\  -z, --zero-terminated     line delimiter is NUL, not newline
        \\      --help        display this help and exit
        \\      --version     output version information and exit
        \\
        \\Unless -t CHAR is given, leading blanks separate fields and are ignored,
        \\else fields are separated by CHAR.  Any FIELD is a field number counted
        \\from 1.  FORMAT is one or more comma or blank separated specifications,
        \\each being 'FILENUM.FIELD' or '0'.  Default FORMAT outputs the join field,
        \\the remaining fields from FILE1, the remaining fields from FILE2, all
        \\separated by CHAR.  If FORMAT is the keyword 'auto', then the first line
        \\of each file determines the number of fields output for each line.
        \\
        \\Important: FILE1 and FILE2 must be sorted on the join fields.
        \\
    ;
    outWrite(help);
    outFlush();
}

fn printVersion() void {
    outWrite("zjoin " ++ VERSION ++ "\n");
    outFlush();
}

fn parseArgs(arena: std.mem.Allocator, args: []const []const u8, cfg: *Config) !void {
    var seen_dashdash = false;
    var jopt: ?usize = null; // -j value stashed until both set

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (seen_dashdash or arg.len == 0 or arg[0] != '-' or arg.len == 1) {
            // operand (includes "-" = stdin)
            if (cfg.file1 == null) {
                cfg.file1 = arg;
            } else if (cfg.file2 == null) {
                cfg.file2 = arg;
            } else {
                die("zjoin: extra operand '{s}'\n", .{arg});
            }
            continue;
        }

        if (arg[1] == '-') {
            // long option
            const opt = arg[2..];
            if (opt.len == 0) {
                seen_dashdash = true;
            } else if (std.mem.eql(u8, opt, "help")) {
                printHelp();
                std.process.exit(0);
            } else if (std.mem.eql(u8, opt, "version")) {
                printVersion();
                std.process.exit(0);
            } else if (std.mem.eql(u8, opt, "ignore-case")) {
                cfg.ignore_case = true;
            } else if (std.mem.eql(u8, opt, "zero-terminated")) {
                cfg.eolchar = 0;
            } else if (std.mem.eql(u8, opt, "header")) {
                cfg.header = true;
            } else if (std.mem.eql(u8, opt, "check-order")) {
                cfg.check_order = .enabled;
            } else if (std.mem.eql(u8, opt, "nocheck-order")) {
                cfg.check_order = .disabled;
            } else {
                die("zjoin: unrecognized option '{s}'\nTry 'zjoin --help' for more information.\n", .{arg});
            }
            continue;
        }

        // short option cluster
        var j: usize = 1;
        cluster: while (j < arg.len) {
            const c = arg[j];
            switch (c) {
                'i' => {
                    cfg.ignore_case = true;
                    j += 1;
                },
                'z' => {
                    cfg.eolchar = 0;
                    j += 1;
                },
                '1', '2', 'j', 'a', 'v', 't', 'e', 'o' => {
                    // option takes an argument: rest of this cluster, or next argv
                    var val: []const u8 = undefined;
                    if (j + 1 < arg.len) {
                        val = arg[j + 1 ..];
                    } else {
                        i += 1;
                        if (i >= args.len)
                            die("zjoin: option requires an argument -- '{c}'\n", .{c});
                        val = args[i];
                    }
                    switch (c) {
                        '1' => setJoinField1(cfg, parseFieldNum(val)),
                        '2' => setJoinField2(cfg, parseFieldNum(val)),
                        'j' => {
                            const f = parseFieldNum(val);
                            if (jopt != null and jopt.? != f)
                                die("zjoin: incompatible join fields {d}, {d}\n", .{ jopt.? + 1, f + 1 });
                            jopt = f;
                            setJoinField1(cfg, f);
                            setJoinField2(cfg, f);
                        },
                        'a' => {
                            const fn_ = parseFileNum(val);
                            if (fn_ == 1) cfg.print_unpairables_1 = true else cfg.print_unpairables_2 = true;
                        },
                        'v' => {
                            cfg.print_pairables = false;
                            const fn_ = parseFileNum(val);
                            if (fn_ == 1) cfg.print_unpairables_1 = true else cfg.print_unpairables_2 = true;
                        },
                        't' => setTab(cfg, val),
                        'e' => {
                            if (cfg.empty_filler) |e| {
                                if (!std.mem.eql(u8, e, val))
                                    die("zjoin: conflicting empty-field replacement strings\n", .{});
                            }
                            cfg.empty_filler = val;
                        },
                        'o' => {
                            if (std.mem.eql(u8, val, "auto")) {
                                cfg.autoformat = true;
                            } else {
                                try addFieldList(arena, cfg, val);
                            }
                        },
                        else => unreachable,
                    }
                    break :cluster; // rest of cluster consumed as the arg
                },
                else => {
                    die("zjoin: invalid option -- '{c}'\nTry 'zjoin --help' for more information.\n", .{c});
                },
            }
        }
    }
}

// ---------------------------------------------------------------------------
// File reading
// ---------------------------------------------------------------------------

extern fn strerror(errnum: c_int) [*:0]const u8;
fn c_strerror(errnum: c_int) [*:0]const u8 {
    return strerror(errnum);
}

fn readWholeFile(arena: std.mem.Allocator, name: []const u8) ![]u8 {
    const is_stdin = std.mem.eql(u8, name, "-");
    var fd: c_int = 0;
    if (!is_stdin) {
        var path_buf: [4096]u8 = undefined;
        const path_z = std.fmt.bufPrintZ(&path_buf, "{s}", .{name}) catch {
            die("zjoin: {s}: file name too long\n", .{name});
        };
        const fd_ret = libc.open(path_z.ptr, .{ .ACCMODE = .RDONLY }, @as(libc.mode_t, 0));
        if (fd_ret < 0) {
            const es = c_strerror(@intFromEnum(std.posix.errno(fd_ret)));
            die("zjoin: {s}: {s}\n", .{ name, std.mem.span(es) });
        }
        fd = fd_ret;
    }
    defer {
        if (!is_stdin) _ = libc.close(fd);
    }

    var data: std.ArrayListUnmanaged(u8) = .empty;
    var read_buf: [65536]u8 = undefined;
    while (true) {
        const n = libc.read(fd, &read_buf, read_buf.len);
        if (n < 0) {
            switch (std.posix.errno(n)) {
                .INTR => continue,
                else => die("zjoin: {s}: read error\n", .{name}),
            }
        }
        if (n == 0) break;
        try data.appendSlice(arena, read_buf[0..@intCast(n)]);
    }
    return data.items;
}

pub fn main(init: std.process.Init) !void {
    var arena_state = std.heap.ArenaAllocator.init(init.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var args_list: std.ArrayListUnmanaged([]const u8) = .empty;
    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    while (args_iter.next()) |arg| {
        try args_list.append(arena, arg);
    }
    const argv = args_list.items;

    var cfg = Config{};
    try parseArgs(arena, if (argv.len > 0) argv[1..] else argv, &cfg);

    if (cfg.file1 == null or cfg.file2 == null) {
        usageError(&cfg);
    }

    const data1 = try readWholeFile(arena, cfg.file1.?);
    const data2 = try readWholeFile(arena, cfg.file2.?);

    const lines1 = try parseAllLines(arena, data1, &cfg);
    const lines2 = try parseAllLines(arena, data2, &cfg);

    try join(arena, &cfg, lines1, lines2);
}
