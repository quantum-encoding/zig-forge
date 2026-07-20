//! zfmt - simple text formatter (GNU `fmt` work-alike, coreutils 9.x).
//!
//! Reformats each paragraph in the FILE(s) (or stdin) to a goal width using
//! the same cost-based minimum-raggedness line-break algorithm as GNU fmt.
//! This is a faithful port of coreutils `src/fmt.c` (fmt_paragraph / base_cost
//! / line_cost / put_paragraph and the paragraph reader), so output is
//! byte-identical to GNU fmt for the supported options:
//!
//!   -c/--crown-margin, -s/--split-only, -t/--tagged-paragraph,
//!   -u/--uniform-spacing, -w/--width, -g/--goal, -p/--prefix, -WIDTH,
//!   --help, --version.
//!
//! Portability: all I/O goes through std.Io (works on macOS/BSD/Linux). The
//! previous implementation issued raw Linux syscall numbers and died with
//! SIGSYS on Darwin; it also had several stack-buffer overflows. This rewrite
//! removes all of that.

const std = @import("std");
const Io = std.Io;
const Dir = Io.Dir;

// ---- Cost constants (verbatim from coreutils fmt.c) ------------------------

const WIDTH: i32 = 75; // default max_width
const LEEWAY: i32 = 7; // goal is LEEWAY% below max
const DEF_INDENT: i32 = 3;

const COST = i64;
const MAXCOST: COST = std.math.maxInt(COST);

fn SQR(n: COST) COST {
    return n * n;
}
fn EQUIV(n: COST) COST {
    return SQR(n);
}
fn SHORT_COST(n: COST) COST {
    return EQUIV(n * 10);
}
fn RAGGED_COST(n: COST) COST {
    return @divTrunc(SHORT_COST(n), 2);
}
const LINE_COST: COST = 70 * 70;
fn WIDOW_COST(n: COST) COST {
    return @divTrunc(EQUIV(200), (n + 2));
}
fn ORPHAN_COST(n: COST) COST {
    return @divTrunc(EQUIV(150), (n + 2));
}
const SENTENCE_BONUS: COST = 50 * 50;
const NOBREAK_COST: COST = 600 * 600;
const PAREN_BONUS: COST = 40 * 40;
const PUNCT_BONUS: COST = 40 * 40;
const LINE_CREDIT: COST = 3 * 3;

const MAXWORDS: usize = 1000;
const MAXCHARS: usize = 5000;
const TABWIDTH: i32 = 8;

const EOF: i32 = -1;

fn isopen(c: u8) bool {
    return c == '(' or c == '[' or c == '\'' or c == '`' or c == '"';
}
fn isclose(c: u8) bool {
    return c == ')' or c == ']' or c == '\'' or c == '"';
}
fn isperiod(c: u8) bool {
    return c == '.' or c == '?' or c == '!';
}
/// C-locale ispunct: printable ASCII that is not alphanumeric and not space.
fn cIsPunct(c: u8) bool {
    return switch (c) {
        '!'...'/', ':'...'@', '['...'`', '{'...'~' => true,
        else => false,
    };
}
/// C-locale isspace.
fn cIsSpace(c: i32) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == 0x0b or c == 0x0c or c == '\r';
}

const Word = struct {
    text: usize = 0, // index into parabuf
    length: i32 = 0,
    space: i32 = 0,
    paren: bool = false,
    period: bool = false,
    punct: bool = false,
    final: bool = false,
    line_length: i32 = 0,
    best_cost: COST = 0,
    next_break: usize = 0, // index into word[]
};

const Fmt = struct {
    // options
    crown: bool = false,
    tagged: bool = false,
    split: bool = false,
    uniform: bool = false,

    prefix: []const u8 = "", // trimmed
    prefix_full_length: i32 = 0,
    prefix_lead_space: i32 = 0,
    prefix_length: i32 = 0,

    max_width: i32 = WIDTH,
    goal_width: i32 = 0,

    // per-run state
    in_column: i32 = 0,
    out_column: i32 = 0,
    tabs: bool = false,
    prefix_indent: i32 = 0,
    first_indent: i32 = 0,
    other_indent: i32 = 0,
    next_char: i32 = 0,
    next_prefix_indent: i32 = 0,
    last_line_length: i32 = 0,

    parabuf: [MAXCHARS]u8 = undefined,
    wptr: usize = 0,
    words: [MAXWORDS]Word = undefined,
    word_limit: usize = 0,

    // input
    input: []const u8 = "",
    ipos: usize = 0,

    // output
    out: *Io.File.Writer,
    write_failed: bool = false,

    fn getc(self: *Fmt) i32 {
        if (self.ipos >= self.input.len) return EOF;
        const c = self.input[self.ipos];
        self.ipos += 1;
        return c;
    }

    fn putchar(self: *Fmt, c: u8) void {
        if (self.write_failed) return;
        self.out.interface.writeByte(c) catch {
            self.write_failed = true;
        };
    }

    fn puts(self: *Fmt, s: []const u8) void {
        if (self.write_failed) return;
        self.out.interface.writeAll(s) catch {
            self.write_failed = true;
        };
    }

    // ---- input scanning ---------------------------------------------------

    fn getSpace(self: *Fmt, c_in: i32) i32 {
        var c = c_in;
        while (true) {
            if (c == ' ') {
                self.in_column += 1;
            } else if (c == '\t') {
                self.tabs = true;
                self.in_column = @divTrunc(self.in_column, TABWIDTH) * TABWIDTH + TABWIDTH;
            } else {
                return c;
            }
            c = self.getc();
        }
    }

    fn getPrefix(self: *Fmt) i32 {
        self.in_column = 0;
        var c = self.getSpace(self.getc());
        if (self.prefix_length == 0) {
            self.next_prefix_indent = if (self.prefix_lead_space < self.in_column)
                self.prefix_lead_space
            else
                self.in_column;
        } else {
            self.next_prefix_indent = self.in_column;
            for (self.prefix) |pc| {
                if (c != @as(i32, pc)) return c;
                self.in_column += 1;
                c = self.getc();
            }
            c = self.getSpace(c);
        }
        return c;
    }

    fn checkPunctuation(self: *Fmt, w: usize) void {
        const start = self.words[w].text;
        var finish = start + @as(usize, @intCast(self.words[w].length - 1));
        const fin = self.parabuf[finish];
        self.words[w].paren = isopen(self.parabuf[start]);
        self.words[w].punct = cIsPunct(fin);
        while (start < finish and isclose(self.parabuf[finish])) finish -= 1;
        self.words[w].period = isperiod(self.parabuf[finish]);
    }

    fn setOtherIndent(self: *Fmt, same_paragraph: bool) void {
        if (self.split) {
            self.other_indent = self.first_indent;
        } else if (self.crown) {
            self.other_indent = if (same_paragraph) self.in_column else self.first_indent;
        } else if (self.tagged) {
            if (same_paragraph and self.in_column != self.first_indent) {
                self.other_indent = self.in_column;
            } else if (self.other_indent == self.first_indent) {
                self.other_indent = if (self.first_indent == 0) DEF_INDENT else 0;
            }
        } else {
            self.other_indent = self.first_indent;
        }
    }

    /// Read a line, breaking it into words. Returns first non-blank char of
    /// next line.
    fn getLine(self: *Fmt, c_in: i32) i32 {
        var c = c_in;
        const end_of_parabuf = MAXCHARS;
        const end_of_word = MAXWORDS - 2;

        while (true) { // for each word in a line
            // Scan word.
            self.words[self.word_limit].text = self.wptr;
            while (true) {
                if (self.wptr == end_of_parabuf) {
                    self.setOtherIndent(true);
                    self.flushParagraph();
                }
                self.parabuf[self.wptr] = @intCast(c);
                self.wptr += 1;
                c = self.getc();
                if (c == EOF or cIsSpace(c)) break;
            }
            self.words[self.word_limit].length =
                @intCast(self.wptr - self.words[self.word_limit].text);
            self.in_column += self.words[self.word_limit].length;
            self.checkPunctuation(self.word_limit);

            // Scan inter-word space.
            const start = self.in_column;
            c = self.getSpace(c);
            self.words[self.word_limit].space = self.in_column - start;
            self.words[self.word_limit].final = (c == EOF or
                (self.words[self.word_limit].period and
                    (c == '\n' or self.words[self.word_limit].space > 1)));
            if (c == '\n' or c == EOF or self.uniform) {
                self.words[self.word_limit].space = if (self.words[self.word_limit].final) 2 else 1;
            }
            if (self.word_limit == end_of_word) {
                self.setOtherIndent(true);
                self.flushParagraph();
            }
            self.word_limit += 1;

            if (c == '\n' or c == EOF) break;
        }
        return self.getPrefix();
    }

    // ---- paragraph handling ----------------------------------------------

    fn flushParagraph(self: *Fmt) void {
        // Special case: it's all one word — just flush it.
        if (self.word_limit == 0) {
            self.puts(self.parabuf[0..self.wptr]);
            self.wptr = 0;
            return;
        }

        self.fmtParagraph();

        // Choose a good split point.
        var split_point = self.word_limit;
        var best_break: COST = MAXCOST;
        var w = self.words[0].next_break;
        while (w != self.word_limit) : (w = self.words[w].next_break) {
            if (self.words[w].best_cost - self.words[self.words[w].next_break].best_cost < best_break) {
                split_point = w;
                best_break = self.words[w].best_cost - self.words[self.words[w].next_break].best_cost;
            }
            if (best_break <= MAXCOST - LINE_CREDIT) best_break += LINE_CREDIT;
        }
        self.putParagraph(split_point);

        // Shift text of remaining words down to start of parabuf.
        const sp_text = self.words[split_point].text;
        std.mem.copyForwards(u8, self.parabuf[0 .. self.wptr - sp_text], self.parabuf[sp_text..self.wptr]);
        const shift = sp_text;
        self.wptr -= shift;

        var i = split_point;
        while (i <= self.word_limit) : (i += 1) self.words[i].text -= shift;

        // Copy words from split_point down to word[0].
        const count = self.word_limit - split_point + 1;
        std.mem.copyForwards(Word, self.words[0..count], self.words[split_point .. split_point + count]);
        self.word_limit -= split_point;
    }

    /// Compute optimal formatting for the whole paragraph.
    fn fmtParagraph(self: *Fmt) void {
        self.words[self.word_limit].best_cost = 0;
        const saved_length = self.words[self.word_limit].length;
        self.words[self.word_limit].length = self.max_width; // sentinel

        var start_idx: isize = @as(isize, @intCast(self.word_limit)) - 1;
        while (start_idx >= 0) : (start_idx -= 1) {
            const start: usize = @intCast(start_idx);
            var best: COST = MAXCOST;
            var len: i32 = if (start == 0) self.first_indent else self.other_indent;

            var w = start;
            len += self.words[w].length;
            while (true) {
                w += 1;

                // Consider breaking before w.
                var wcost = self.lineCost(w, len) + self.words[w].best_cost;
                if (start == 0 and self.last_line_length > 0) {
                    wcost += RAGGED_COST(len - self.last_line_length);
                }
                if (wcost < best) {
                    best = wcost;
                    self.words[start].next_break = w;
                    self.words[start].line_length = len;
                }

                if (w == self.word_limit) break;

                len += self.words[w - 1].space + self.words[w].length;
                if (len > self.max_width) break;
            }
            self.words[start].best_cost = best + self.baseCost(start);
        }

        self.words[self.word_limit].length = saved_length;
    }

    fn baseCost(self: *Fmt, this: usize) COST {
        var cost: COST = LINE_COST;

        if (this > 0) {
            if (self.words[this - 1].period) {
                if (self.words[this - 1].final) {
                    cost -= SENTENCE_BONUS;
                } else {
                    cost += NOBREAK_COST;
                }
            } else if (self.words[this - 1].punct) {
                cost -= PUNCT_BONUS;
            } else if (this > 1 and self.words[this - 2].final) {
                cost += WIDOW_COST(self.words[this - 1].length);
            }
        }

        if (self.words[this].paren) {
            cost -= PAREN_BONUS;
        } else if (self.words[this].final) {
            cost += ORPHAN_COST(self.words[this].length);
        }

        return cost;
    }

    fn lineCost(self: *Fmt, next: usize, len: i32) COST {
        if (next == self.word_limit) return 0;
        var n = self.goal_width - len;
        var cost = SHORT_COST(n);
        if (self.words[next].next_break != self.word_limit) {
            n = len - self.words[next].line_length;
            cost += RAGGED_COST(n);
        }
        return cost;
    }

    fn putParagraph(self: *Fmt, finish: usize) void {
        self.putLine(0, self.first_indent);
        var w = self.words[0].next_break;
        while (w != finish) : (w = self.words[w].next_break) {
            self.putLine(w, self.other_indent);
        }
    }

    fn putLine(self: *Fmt, w_start: usize, indent: i32) void {
        self.out_column = 0;
        self.putSpace(self.prefix_indent);
        self.puts(self.prefix);
        self.out_column += self.prefix_length;
        self.putSpace(indent - self.out_column);

        const endline = self.words[w_start].next_break - 1;
        var w = w_start;
        while (w != endline) : (w += 1) {
            self.putWord(w);
            self.putSpace(self.words[w].space);
        }
        self.putWord(w);
        self.last_line_length = self.out_column;
        self.putchar('\n');
    }

    fn putWord(self: *Fmt, w: usize) void {
        const s = self.words[w].text;
        const len: usize = @intCast(self.words[w].length);
        self.puts(self.parabuf[s .. s + len]);
        self.out_column += self.words[w].length;
    }

    fn putSpace(self: *Fmt, space: i32) void {
        const space_target = self.out_column + space;
        if (self.tabs) {
            const tab_target = @divTrunc(space_target, TABWIDTH) * TABWIDTH;
            if (self.out_column + 1 < tab_target) {
                while (self.out_column < tab_target) {
                    self.putchar('\t');
                    self.out_column = @divTrunc(self.out_column, TABWIDTH) * TABWIDTH + TABWIDTH;
                }
            }
        }
        while (self.out_column < space_target) {
            self.putchar(' ');
            self.out_column += 1;
        }
    }

    fn copyRest(self: *Fmt, c_in: i32) i32 {
        var c = c_in;
        self.out_column = 0;
        if (self.in_column > self.next_prefix_indent or (c != '\n' and c != EOF)) {
            self.putSpace(self.next_prefix_indent);
            var i: usize = 0;
            while (self.out_column != self.in_column and i < self.prefix.len) : (i += 1) {
                self.putchar(self.prefix[i]);
                self.out_column += 1;
            }
            if (c != EOF and c != '\n') self.putSpace(self.in_column - self.out_column);
            if (c == EOF and self.in_column >= self.next_prefix_indent + self.prefix_length)
                self.putchar('\n');
        }
        while (c != '\n' and c != EOF) {
            self.putchar(@intCast(c));
            c = self.getc();
        }
        return c;
    }

    fn samePara(self: *Fmt, c: i32) bool {
        return self.next_prefix_indent == self.prefix_indent and
            self.in_column >= self.next_prefix_indent + self.prefix_full_length and
            c != '\n' and c != EOF;
    }

    /// Returns false at end of input.
    fn getParagraph(self: *Fmt) bool {
        self.last_line_length = 0;
        var c = self.next_char;

        // Scan (and copy) blank lines, and lines not introduced by the prefix.
        while (c == '\n' or c == EOF or
            self.next_prefix_indent < self.prefix_lead_space or
            self.in_column < self.next_prefix_indent + self.prefix_full_length)
        {
            c = self.copyRest(c);
            if (c == EOF) {
                self.next_char = EOF;
                return false;
            }
            self.putchar('\n');
            c = self.getPrefix();
        }

        // Got a suitable first line for a paragraph.
        self.prefix_indent = self.next_prefix_indent;
        self.first_indent = self.in_column;
        self.wptr = 0;
        self.word_limit = 0;
        c = self.getLine(c);
        self.setOtherIndent(self.samePara(c));

        if (self.split) {
            // one line only
        } else if (self.crown) {
            if (self.samePara(c)) {
                while (true) {
                    c = self.getLine(c);
                    if (!(self.samePara(c) and self.in_column == self.other_indent)) break;
                }
            }
        } else if (self.tagged) {
            if (self.samePara(c) and self.in_column != self.first_indent) {
                while (true) {
                    c = self.getLine(c);
                    if (!(self.samePara(c) and self.in_column == self.other_indent)) break;
                }
            }
        } else {
            while (self.samePara(c) and self.in_column == self.other_indent) {
                c = self.getLine(c);
            }
        }

        self.words[self.word_limit - 1].period = true;
        self.words[self.word_limit - 1].final = true;
        self.next_char = c;
        return true;
    }

    /// Format one input source to stdout.
    fn run(self: *Fmt, input: []const u8) void {
        self.input = input;
        self.ipos = 0;
        self.tabs = false;
        self.other_indent = 0;
        self.next_char = self.getPrefix();
        while (self.getParagraph()) {
            self.fmtParagraph();
            self.putParagraph(self.word_limit);
        }
    }
};

fn setPrefix(f: *Fmt, p: []const u8) void {
    var lead: i32 = 0;
    var s = p;
    while (s.len > 0 and s[0] == ' ') {
        lead += 1;
        s = s[1..];
    }
    f.prefix_lead_space = lead;
    f.prefix_full_length = @intCast(s.len);
    var end = s.len;
    while (end > 0 and s[end - 1] == ' ') end -= 1;
    f.prefix = s[0..end];
    f.prefix_length = @intCast(end);
}

// ---- I/O helpers -----------------------------------------------------------

fn errMsg(err: anyerror) []const u8 {
    return switch (err) {
        error.FileNotFound => "No such file or directory",
        error.AccessDenied, error.PermissionDenied => "Permission denied",
        error.IsDir => "Is a directory",
        else => "Input/output error",
    };
}

fn readAll(io: Io, file: Io.File, allocator: std.mem.Allocator) ![]u8 {
    var list: std.ArrayListUnmanaged(u8) = .empty;
    errdefer list.deinit(allocator);
    var buf: [65536]u8 = undefined;
    while (true) {
        const n = file.readStreaming(io, &.{&buf}) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        if (n == 0) continue;
        try list.appendSlice(allocator, buf[0..n]);
    }
    return list.toOwnedSlice(allocator);
}

fn printErr(comptime fmt: []const u8, args: anytype) void {
    std.debug.print("zfmt: " ++ fmt ++ "\n", args);
}

fn parseWidth(s: []const u8, max: u64) ?i32 {
    const v = std.fmt.parseInt(u64, s, 10) catch return null;
    if (v > max) return null;
    return @intCast(v);
}

fn printHelp(io: Io) void {
    var buf: [2048]u8 = undefined;
    var w = Io.File.stdout().writer(io, &buf);
    w.interface.writeAll(
        \\Usage: zfmt [-WIDTH] [OPTION]... [FILE]...
        \\Reformat each paragraph in the FILE(s), writing to standard output.
        \\The option -WIDTH is an abbreviated form of --width=DIGITS.
        \\
        \\With no FILE, or when FILE is -, read standard input.
        \\
        \\  -c, --crown-margin        preserve indentation of first two lines
        \\  -p, --prefix=STRING       reformat only lines beginning with STRING,
        \\                              reattaching the prefix to reformatted lines
        \\  -s, --split-only          split long lines, but do not refill
        \\  -t, --tagged-paragraph    indentation of first line different from second
        \\  -u, --uniform-spacing     one space between words, two after sentences
        \\  -w, --width=WIDTH         maximum line width (default of 75 columns)
        \\  -g, --goal=WIDTH          goal width (default of 93% of width)
        \\      --help                display this help and exit
        \\      --version             output version information and exit
        \\
    ) catch {};
    w.interface.flush() catch {};
}

fn printVersion(io: Io) void {
    var buf: [64]u8 = undefined;
    var w = Io.File.stdout().writer(io, &buf);
    w.interface.writeAll("zfmt (zig-forge coreutils)\n") catch {};
    w.interface.flush() catch {};
}

const Options = struct {
    fmt: Fmt,
    files: std.ArrayListUnmanaged([]const u8) = .empty,
};

/// Parse argv. Exits the process on --help/--version/parse error, matching
/// GNU fmt's exit codes.
fn parseArgs(
    io: Io,
    allocator: std.mem.Allocator,
    args: [][]const u8,
    out: *Io.File.Writer,
) Options {
    var opts = Options{ .fmt = Fmt{ .out = out } };

    var max_width_opt: ?[]const u8 = null;
    var goal_width_opt: ?[]const u8 = null;

    var idx: usize = 0; // index into args (already excludes argv[0])

    // Old option syntax: leading -DIGITS as the very first argument.
    if (args.len > 0 and args[0].len >= 2 and args[0][0] == '-' and
        args[0][1] >= '0' and args[0][1] <= '9')
    {
        max_width_opt = args[0][1..];
        idx = 1;
    }

    var only_files = false;
    while (idx < args.len) : (idx += 1) {
        const arg = args[idx];
        if (only_files or arg.len == 0 or arg[0] != '-' or std.mem.eql(u8, arg, "-")) {
            opts.files.append(allocator, arg) catch @panic("OOM");
            continue;
        }

        if (arg[1] == '-') {
            // long option
            const body = arg[2..];
            if (body.len == 0) {
                only_files = true;
            } else if (std.mem.eql(u8, body, "help")) {
                printHelp(io);
                std.process.exit(0);
            } else if (std.mem.eql(u8, body, "version")) {
                printVersion(io);
                std.process.exit(0);
            } else if (std.mem.eql(u8, body, "crown-margin")) {
                opts.fmt.crown = true;
            } else if (std.mem.eql(u8, body, "split-only")) {
                opts.fmt.split = true;
            } else if (std.mem.eql(u8, body, "tagged-paragraph")) {
                opts.fmt.tagged = true;
            } else if (std.mem.eql(u8, body, "uniform-spacing")) {
                opts.fmt.uniform = true;
            } else if (longVal(body, "width")) |v| {
                max_width_opt = takeVal(args, &idx, v);
            } else if (longVal(body, "goal")) |v| {
                goal_width_opt = takeVal(args, &idx, v);
            } else if (longVal(body, "prefix")) |v| {
                setPrefix(&opts.fmt, takeVal(args, &idx, v));
            } else {
                printErr("unrecognized option '{s}'", .{arg});
                printErr("Try 'zfmt --help' for more information.", .{});
                std.process.exit(1);
            }
        } else {
            // short option cluster
            var ci: usize = 1;
            cluster: while (ci < arg.len) : (ci += 1) {
                switch (arg[ci]) {
                    'c' => opts.fmt.crown = true,
                    's' => opts.fmt.split = true,
                    't' => opts.fmt.tagged = true,
                    'u' => opts.fmt.uniform = true,
                    'w', 'g', 'p' => |oc| {
                        const rest = arg[ci + 1 ..];
                        const v = if (rest.len > 0) rest else nextArg(args, &idx);
                        switch (oc) {
                            'w' => max_width_opt = v,
                            'g' => goal_width_opt = v,
                            'p' => setPrefix(&opts.fmt, v),
                            else => unreachable,
                        }
                        break :cluster;
                    },
                    '0'...'9' => {
                        printErr("invalid option -- {c}; -WIDTH is recognized only when it is the first option; use -w N instead", .{arg[ci]});
                        std.process.exit(1);
                    },
                    else => {
                        printErr("invalid option -- '{c}'", .{arg[ci]});
                        printErr("Try 'zfmt --help' for more information.", .{});
                        std.process.exit(1);
                    },
                }
            }
        }
    }

    if (max_width_opt) |s| {
        opts.fmt.max_width = parseWidth(s, MAXCHARS / 2) orelse {
            printErr("invalid width: '{s}'", .{s});
            std.process.exit(1);
        };
    }

    if (goal_width_opt) |s| {
        const gmax: u64 = @intCast(opts.fmt.max_width);
        opts.fmt.goal_width = parseWidth(s, gmax) orelse {
            printErr("invalid width: '{s}'", .{s});
            std.process.exit(1);
        };
        if (max_width_opt == null) opts.fmt.max_width = opts.fmt.goal_width + 10;
    } else {
        opts.fmt.goal_width = @intCast(@divTrunc(@as(i64, opts.fmt.max_width) * (2 * (100 - LEEWAY) + 1), 200));
    }

    return opts;
}

fn longVal(body: []const u8, name: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, body, name)) {
        const rest = body[name.len..];
        if (rest.len == 0) return "";
        if (rest[0] == '=') return rest[1..];
    }
    return null;
}

/// For a long option value: if inline ("=x") non-empty, use it; else next arg.
fn takeVal(args: [][]const u8, idx: *usize, inline_val: []const u8) []const u8 {
    if (inline_val.len > 0) return inline_val;
    return nextArg(args, idx);
}

fn nextArg(args: [][]const u8, idx: *usize) []const u8 {
    if (idx.* + 1 < args.len) {
        idx.* += 1;
        return args[idx.*];
    }
    printErr("option requires an argument", .{});
    std.process.exit(1);
}

pub fn main(init: std.process.Init) void {
    const allocator = init.gpa;
    const io = Io.Threaded.global_single_threaded.io();

    // Materialize args into a slice.
    var args_list: std.ArrayListUnmanaged([]const u8) = .empty;
    defer args_list.deinit(allocator);
    var it = std.process.Args.Iterator.init(init.minimal.args);
    _ = it.skip(); // argv[0]
    while (it.next()) |a| args_list.append(allocator, a) catch @panic("OOM");

    var write_buf: [65536]u8 = undefined;
    var stdout_writer = Io.File.stdout().writerStreaming(io, &write_buf);

    var opts = parseArgs(io, allocator, args_list.items, &stdout_writer);
    defer opts.files.deinit(allocator);

    var ok = true;

    if (opts.files.items.len == 0) {
        const content = readAll(io, Io.File.stdin(), allocator) catch {
            printErr("read error", .{});
            std.process.exit(1);
        };
        defer allocator.free(content);
        opts.fmt.run(content);
    } else {
        for (opts.files.items) |path| {
            if (std.mem.eql(u8, path, "-")) {
                const content = readAll(io, Io.File.stdin(), allocator) catch {
                    printErr("read error", .{});
                    ok = false;
                    continue;
                };
                defer allocator.free(content);
                opts.fmt.run(content);
            } else {
                const file = Dir.openFile(Dir.cwd(), io, path, .{}) catch |err| {
                    printErr("cannot open '{s}' for reading: {s}", .{ path, errMsg(err) });
                    ok = false;
                    continue;
                };
                defer file.close(io);
                if (file.stat(io)) |st| {
                    if (st.kind == .directory) {
                        printErr("cannot open '{s}' for reading: Is a directory", .{path});
                        ok = false;
                        continue;
                    }
                } else |_| {}
                const content = readAll(io, file, allocator) catch {
                    printErr("error reading '{s}'", .{path});
                    ok = false;
                    continue;
                };
                defer allocator.free(content);
                opts.fmt.run(content);
            }
        }
    }

    stdout_writer.interface.flush() catch {
        opts.fmt.write_failed = true;
    };

    if (opts.fmt.write_failed) {
        printErr("write error", .{});
        std.process.exit(1);
    }
    if (!ok) std.process.exit(1);
}
