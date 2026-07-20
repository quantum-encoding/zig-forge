//! Externally-anchored tests for zsed.
//!
//! Two kinds of anchor, neither of which is a roundtrip:
//!
//!  1. `zsedEq` — the expected output bytes are written literally in the test
//!     and come from the documented behavior of GNU sed 4.x / POSIX (the sed
//!     manual and `info sed`). These run with no external dependency.
//!
//!  2. `gsedDiff` — the same script/input is fed to zsed and to the real GNU
//!     `sed` binary (gsed) and the stdout + exit status are required to match.
//!     This is a true external anchor: the expected bytes are produced by an
//!     implementation zsed's author did not write. Skipped when gsed is absent.
//!
//! The zsed binary under test is located via the ZSED_BIN env var (set by
//! build.zig); gsed via GSED_BIN (default /opt/homebrew/bin/gsed).
//!
//! Everything is driven through `system` because this Zig's std.fs / child
//! process APIs are mid-refactor; the shell does the plumbing (temp files, pipes,
//! cmp) and its exit status is the assertion.

const std = @import("std");
const testing = std.testing;
const a = std.testing.allocator;

extern "c" fn system(command: [*:0]const u8) c_int;
extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;

fn envOr(name: [*:0]const u8, default: []const u8) []const u8 {
    if (getenv(name)) |v| return std.mem.span(v);
    return default;
}

fn zsedBin() []const u8 {
    return envOr("ZSED_BIN", "zig-out/bin/zsed");
}

fn gsedBin() []const u8 {
    return envOr("GSED_BIN", "/opt/homebrew/bin/gsed");
}

/// Single-quote a shell word, escaping any embedded single quotes, so arbitrary
/// bytes (including `$`, `\`, spaces, `;`) survive the shell unmangled.
fn shQuote(list: *std.ArrayListUnmanaged(u8), word: []const u8) !void {
    try list.append(a, '\'');
    for (word) |ch| {
        if (ch == '\'') {
            try list.appendSlice(a, "'\\''");
        } else {
            try list.append(a, ch);
        }
    }
    try list.append(a, '\'');
}

fn joinArgs(args: []const []const u8) !std.ArrayListUnmanaged(u8) {
    var out = std.ArrayListUnmanaged(u8).empty;
    errdefer out.deinit(a);
    for (args, 0..) |arg, i| {
        if (i != 0) try out.append(a, ' ');
        try shQuote(&out, arg);
    }
    return out;
}

fn systemZ(cmd: []const u8) !c_int {
    const cz = try a.dupeZ(u8, cmd);
    defer a.free(cz);
    return system(cz.ptr);
}

/// Assert that `zsed args` applied to `input` produces exactly `expected`.
fn zsedEq(args: []const []const u8, input: []const u8, expected: []const u8) !void {
    var argbuf = try joinArgs(args);
    defer argbuf.deinit(a);
    var inq = std.ArrayListUnmanaged(u8).empty;
    defer inq.deinit(a);
    try shQuote(&inq, input);
    var exq = std.ArrayListUnmanaged(u8).empty;
    defer exq.deinit(a);
    try shQuote(&exq, expected);

    const cmd = try std.fmt.allocPrint(a,
        \\D=$(mktemp -d) || exit 90
        \\printf '%s' {s} > "$D/in"
        \\{s} {s} "$D/in" > "$D/out" 2>/dev/null
        \\printf '%s' {s} > "$D/exp"
        \\cmp -s "$D/out" "$D/exp"; rc=$?
        \\rm -rf "$D"
        \\exit $rc
    , .{ inq.items, zsedBin(), argbuf.items, exq.items });
    defer a.free(cmd);

    const rc = try systemZ(cmd);
    if (rc != 0) {
        std.debug.print("\nzsedEq mismatch: args={s} input=\"{s}\" expected=\"{s}\" rc={d}\n", .{ argbuf.items, input, expected, rc });
        return error.DocumentedByteMismatch;
    }
}

/// Assert `zsed args` on `input` exits with `code`.
fn zsedExit(args: []const []const u8, input: []const u8, code: u8) !void {
    var argbuf = try joinArgs(args);
    defer argbuf.deinit(a);
    var inq = std.ArrayListUnmanaged(u8).empty;
    defer inq.deinit(a);
    try shQuote(&inq, input);
    const cmd = try std.fmt.allocPrint(a,
        \\printf '%s' {s} | {s} {s} >/dev/null 2>&1
        \\test $? -eq {d}
    , .{ inq.items, zsedBin(), argbuf.items, code });
    defer a.free(cmd);
    const rc = try systemZ(cmd);
    if (rc != 0) {
        std.debug.print("\nzsedExit: args={s} expected exit {d} (rc={d})\n", .{ argbuf.items, code, rc });
        return error.WrongExitStatus;
    }
}

fn gsedAvailable() bool {
    var buf: [512]u8 = undefined;
    const cmd = std.fmt.bufPrintZ(&buf, "test -x {s}", .{gsedBin()}) catch return false;
    return system(cmd.ptr) == 0;
}

/// External anchor: zsed and the real GNU sed must agree on stdout and exit
/// status for `args` on `input`.
fn gsedDiff(args: []const []const u8, input: []const u8) !void {
    if (!gsedAvailable()) return error.SkipZigTest;
    var argbuf = try joinArgs(args);
    defer argbuf.deinit(a);
    var inq = std.ArrayListUnmanaged(u8).empty;
    defer inq.deinit(a);
    try shQuote(&inq, input);

    const cmd = try std.fmt.allocPrint(a,
        \\D=$(mktemp -d) || exit 90
        \\printf '%s' {s} > "$D/in"
        \\{s} {s} "$D/in" > "$D/a" 2>/dev/null; ra=$?
        \\{s} {s} "$D/in" > "$D/b" 2>/dev/null; rb=$?
        \\rc=0
        \\cmp -s "$D/a" "$D/b" || rc=1
        \\[ "$ra" = "$rb" ] || rc=2
        \\rm -rf "$D"
        \\exit $rc
    , .{ inq.items, zsedBin(), argbuf.items, gsedBin(), argbuf.items });
    defer a.free(cmd);

    const rc = try systemZ(cmd);
    if (rc != 0) {
        std.debug.print("\ngsedDiff mismatch: args={s} input=\"{s}\" rc={d} (1=stdout,2=status)\n", .{ argbuf.items, input, rc });
        return error.DivergesFromGnuSed;
    }
}

// ---------------------------------------------------------------------------
// Documented-byte anchors (GNU sed manual / POSIX). Expected bytes are literal.
// ---------------------------------------------------------------------------

test "s: basic substitute first occurrence only" {
    try zsedEq(&.{"s/o/O/"}, "foo boo\n", "fOo boo\n");
}

test "s: global flag replaces all" {
    try zsedEq(&.{"s/o/O/g"}, "foo boo\n", "fOO bOO\n");
}

test "s: Nth occurrence only" {
    try zsedEq(&.{"s/o/O/2"}, "foo boo\n", "foO boo\n");
}

test "s: Ng replaces Nth and all after (finding: s///Ng)" {
    // GNU: `2g` replaces the 2nd match onward. src/main.zig previously let
    // `g` override `N` and replaced from the first.
    try zsedEq(&.{"s/a/X/2g"}, "a a a a\n", "a X X X\n");
}

test "ERE: plus quantifier (finding: -E ignored)" {
    try zsedEq(&.{ "-E", "s/a+/X/" }, "aaab\n", "Xb\n");
}

test "ERE: question quantifier" {
    try zsedEq(&.{ "-E", "s/colou?r/X/g" }, "color colour\n", "X X\n");
}

test "ERE: interval {n,m}" {
    try zsedEq(&.{ "-E", "s/a{2,3}/X/" }, "aaaa\n", "Xa\n");
}

test "BRE: interval backslash-brace" {
    try zsedEq(&.{"s/a\\{2\\}/X/"}, "aaa\n", "Xa\n");
}

test "ERE: alternation" {
    try zsedEq(&.{ "-E", "s/cat|dog/X/g" }, "cat and dog\n", "X and X\n");
}

test "groups + backreference swap (finding: \\1 unsupported)" {
    try zsedEq(&.{ "-E", "s/(a)(b)/\\2\\1/" }, "ab\n", "ba\n");
}

test "BRE groups + backreference" {
    try zsedEq(&.{"s/\\(a\\)\\(b\\)/\\2\\1/"}, "ab\n", "ba\n");
}

test "backreference in pattern" {
    try zsedEq(&.{ "-E", "s/(abc)\\1/X/" }, "abcabc\n", "X\n");
}

test "empty regex reuses last regex (finding: //)" {
    // GNU: `/foo/s//bar/` -> the empty s// reuses /foo/. Was "barfoo".
    try zsedEq(&.{"/foo/s//bar/"}, "foo\n", "bar\n");
}

test "dollar address matches last line (finding: is_last always false)" {
    try zsedEq(&.{ "-n", "$p" }, "1\n2\n3\n", "3\n");
}

test "c over a range prints once (finding: c per-line)" {
    // GNU prints the replacement once, when the range closes.
    try zsedEq(&.{"2,3c\\\nCH"}, "a\nb\nc\nd\n", "a\nCH\nd\n");
}

test "y transliterate decodes escapes (finding: y escapes)" {
    try zsedEq(&.{"y/\\t/_/"}, "a\tb\n", "a_b\n");
}

test "character class and POSIX class" {
    try zsedEq(&.{"s/[[:digit:]]/#/g"}, "a1b2\n", "a#b#\n");
}

test "anchors ^ and $" {
    try zsedEq(&.{"s/^/> /"}, "x\n", "> x\n");
    try zsedEq(&.{"s/$/!/"}, "x\n", "x!\n");
}

test "D sliding window does not overflow the stack (finding: D recursion)" {
    // The classic tail idiom recurses once per line in the old code; 200k lines
    // segfaulted. Here we just require it to run and emit the last line.
    const cmd = try std.fmt.allocPrint(a,
        \\seq 1 200000 | {s} '$!N;$!D' | tail -1
    , .{zsedBin()});
    defer a.free(cmd);
    const cz = try a.dupeZ(u8, cmd);
    defer a.free(cz);
    // Just assert it exits cleanly (0) rather than crashing (139).
    const wrapped = try std.fmt.allocPrint(a, "out=$({s}); test \"$out\" = 200000", .{cmd});
    defer a.free(wrapped);
    const rc = try systemZ(wrapped);
    try testing.expectEqual(@as(c_int, 0), rc);
}

test "in-place edit actually rewrites the file (finding: -i no-op)" {
    const cmd = try std.fmt.allocPrint(a,
        \\D=$(mktemp -d) || exit 90
        \\printf 'foo\nkeep\n' > "$D/f"
        \\{s} -i 's/foo/bar/' "$D/f"
        \\printf 'bar\nkeep\n' > "$D/exp"
        \\cmp -s "$D/f" "$D/exp"; rc=$?
        \\rm -rf "$D"
        \\exit $rc
    , .{zsedBin()});
    defer a.free(cmd);
    const rc = try systemZ(cmd);
    try testing.expectEqual(@as(c_int, 0), rc);
}

test "in-place with backup suffix keeps original" {
    const cmd = try std.fmt.allocPrint(a,
        \\D=$(mktemp -d) || exit 90
        \\printf 'foo\n' > "$D/f"
        \\{s} -i.bak 's/foo/bar/g' "$D/f"
        \\printf 'bar\n' > "$D/e1"; printf 'foo\n' > "$D/e2"
        \\rc=0
        \\cmp -s "$D/f" "$D/e1" || rc=1
        \\cmp -s "$D/f.bak" "$D/e2" || rc=1
        \\rm -rf "$D"
        \\exit $rc
    , .{zsedBin()});
    defer a.free(cmd);
    const rc = try systemZ(cmd);
    try testing.expectEqual(@as(c_int, 0), rc);
}

// ---------------------------------------------------------------------------
// Exit-status anchors (GNU: 4 = bad script, 2 = unreadable file).
// ---------------------------------------------------------------------------

test "unterminated s command errors (finding: malformed swallowed)" {
    try zsedExit(&.{"s"}, "x\n", 4);
}

test "unknown command errors" {
    try zsedExit(&.{"Z"}, "x\n", 4);
}

test "unreadable file exits 2" {
    // GNU exits 2 when a named input file cannot be opened.
    var argbuf = try joinArgs(&.{ "s/a/b/", "/no/such/file/zsed_missing" });
    defer argbuf.deinit(a);
    const cmd = try std.fmt.allocPrint(a, "{s} {s} >/dev/null 2>&1; test $? -eq 2", .{ zsedBin(), argbuf.items });
    defer a.free(cmd);
    const rc = try systemZ(cmd);
    try testing.expectEqual(@as(c_int, 0), rc);
}

// ---------------------------------------------------------------------------
// Differential anchors against the real GNU sed binary.
// ---------------------------------------------------------------------------

test "gsed diff: substitution family" {
    try gsedDiff(&.{"s/o/O/"}, "hello world\nfoo\n");
    try gsedDiff(&.{"s/o/O/g"}, "hello world\nfoo\n");
    try gsedDiff(&.{"s/l/L/2g"}, "hello\n");
    try gsedDiff(&.{"s/b/[&]/"}, "abc\n");
    try gsedDiff(&.{ "-E", "s/(a)(b)/\\2\\1/" }, "ab\n");
    try gsedDiff(&.{ "-E", "s/a+/X/g" }, "aaa bbb aa\n");
    try gsedDiff(&.{ "-E", "s/(cat|dog)/[\\1]/g" }, "cat dog fox\n");
    try gsedDiff(&.{"s/x*/-/g"}, "aaa\n");
}

test "gsed diff: addresses and ranges" {
    try gsedDiff(&.{"2,3d"}, "1\n2\n3\n4\n");
    try gsedDiff(&.{"$d"}, "1\n2\n3\n");
    try gsedDiff(&.{"/foo/d"}, "foo\nbar\nfoo baz\n");
    try gsedDiff(&.{ "-n", "1~2p" }, "1\n2\n3\n4\n5\n");
    try gsedDiff(&.{ "-n", "2!p" }, "1\n2\n3\n");
    try gsedDiff(&.{"2,3c\\\nCH"}, "a\nb\nc\nd\n");
}

test "gsed diff: multiline N/P/D and hold space" {
    try gsedDiff(&.{ "$!N", "s/\\n/ /" }, "a\nb\nc\nd\n");
    try gsedDiff(&.{ "-n", "1!G;h;$p" }, "1\n2\n3\n"); // tac
    try gsedDiff(&.{"N;P;D"}, "a\nb\nc\n");
    try gsedDiff(&.{"$!N;$!D"}, "1\n2\n3\n4\n5\n"); // print last line
}

test "gsed diff: append/insert/change and flags" {
    try gsedDiff(&.{"1a\\\nAPP"}, "x\ny\n");
    try gsedDiff(&.{"1i\\\nINS"}, "x\ny\n");
    try gsedDiff(&.{ "-n", "s/foo/bar/p" }, "foo\nnope\n");
    try gsedDiff(&.{ "-e", "s/f/F/", "-e", "s/o/O/g" }, "foo\n");
    try gsedDiff(&.{":x;s/a/b/;tx"}, "aaa\n");
    try gsedDiff(&.{"y/abc/xyz/"}, "cabbage\n");
}

test "gsed diff: no trailing newline preserved" {
    try gsedDiff(&.{"s/./#/"}, "abc\ndef");
    try gsedDiff(&.{"s/o/0/g"}, "no_newline");
}

// ---------------------------------------------------------------------------
// Command-grouping braces { } (CRITICAL finding: addressed block ran inner
// commands UNCONDITIONALLY on every line -> silent data loss under -i).
// Anchored both to literal documented bytes and differentially to gsed.
// ---------------------------------------------------------------------------

test "block: addressed {d} deletes ONLY matching lines (finding: brace no-op)" {
    // Pre-fix zsed emitted nothing here (deleted every line). GNU keeps the
    // non-matching lines. Documented bytes.
    try zsedEq(&.{"/DELETE/{d}"}, "keep1\nDELETE\nkeep2\n", "keep1\nkeep2\n");
}

test "block: unaddressed inner command must NOT leak past address" {
    // The whole point: `2{s/./X/}` may only touch line 2.
    try zsedEq(&.{"2{s/./X/}"}, "aa\nbb\ncc\n", "aa\nXb\ncc\n");
}

test "gsed diff: command-grouping blocks" {
    try gsedDiff(&.{"/b/{d}"}, "a\nb\nc\nb2\n");
    try gsedDiff(&.{"/a/{s/a/A/;s/b/B/}"}, "ab\nxy\nba\n");
    try gsedDiff(&.{"2,3{s/./#/}"}, "aa\nbb\ncc\ndd\n");
    try gsedDiff(&.{"/x/!{d}"}, "x1\ny2\nx3\n");
    try gsedDiff(&.{"/a/{/b/{s/./Z/}}"}, "ab\nac\nxb\n"); // nested
    try gsedDiff(&.{ "-n", "2{p}" }, "a\nb\nc\n");
}

test "block: unmatched brace is a parse error (exit 4)" {
    try zsedExit(&.{"/a/{d"}, "a\n", 4);
    try zsedExit(&.{"d}"}, "a\n", 4);
}

// ---------------------------------------------------------------------------
// Replacement case conversion \U \L \u \l \E (finding: emitted literally).
// ---------------------------------------------------------------------------

test "case: \\U uppercases the rest (documented bytes)" {
    try zsedEq(&.{"s/.*/\\U&/"}, "hello\n", "HELLO\n");
}

test "case: \\L lowercases the rest (documented bytes)" {
    try zsedEq(&.{"s/.*/\\L&/"}, "HeLLo\n", "hello\n");
}

test "case: \\u one-shot uppercases only next char" {
    try zsedEq(&.{"s/.*/\\u&/"}, "hello world\n", "Hello world\n");
}

test "gsed diff: case-conversion escapes" {
    try gsedDiff(&.{"s/.*/\\U&/"}, "Hello World\n");
    try gsedDiff(&.{"s/.*/\\L&/"}, "Hello World\n");
    try gsedDiff(&.{"s/\\w\\+/\\u&/g"}, "the quick brown fox\n"); // title-case each word
    try gsedDiff(&.{ "-E", "s/(.)(.*)/\\U\\1\\E\\2/" }, "hello\n"); // capitalize first
    try gsedDiff(&.{"s/.*/\\l&/"}, "HELLO\n");
}

// ---------------------------------------------------------------------------
// Regex shorthands \b \< \> \w \W \s \S (finding: matched literally).
// ---------------------------------------------------------------------------

test "regex: \\b word boundary (documented bytes)" {
    try zsedEq(&.{"s/\\bbar\\b/X/"}, "foo bar baz\n", "foo X baz\n");
}

test "regex: \\w matches word chars (documented bytes)" {
    // a,1,_ and b are word chars; space and ! are not. -> "### #!"
    try zsedEq(&.{"s/\\w/#/g"}, "a1_ b!\n", "### #!\n");
}

test "gsed diff: regex shorthands" {
    try gsedDiff(&.{"s/\\bbar\\b/X/g"}, "bar embargo bar\n");
    try gsedDiff(&.{"s/\\w/#/g"}, "a1_ b!.\n");
    try gsedDiff(&.{"s/\\W/#/g"}, "a1_ b!.\n");
    try gsedDiff(&.{"s/\\s/_/g"}, "a b\tc\n");
    try gsedDiff(&.{"s/\\S/./g"}, "a b\tc\n");
    try gsedDiff(&.{"s/\\<foo/X/g"}, "foo afoo foo\n");
    try gsedDiff(&.{"s/foo\\>/X/g"}, "foo foobar foo\n");
    try gsedDiff(&.{ "-E", "s/\\w+/[&]/g" }, "one two three\n");
}

// ---------------------------------------------------------------------------
// Large numeric literals must NOT panic (finding: integer overflow crash).
// We can't diff the exact bytes (gsed rejects some), but zsed must exit
// cleanly (0 or a diagnostic), never abort (134/SIGABRT).
// ---------------------------------------------------------------------------

test "overflow: huge line-number address does not crash" {
    const cmd = try std.fmt.allocPrint(a,
        \\printf 'x\n' | {s} '99999999999999999999999p' >/dev/null 2>&1
        \\rc=$?; test $rc -ne 134 -a $rc -ne 139
    , .{zsedBin()});
    defer a.free(cmd);
    try testing.expectEqual(@as(c_int, 0), try systemZ(cmd));
}

test "overflow: huge interval quantifier does not crash" {
    const cmd = try std.fmt.allocPrint(a,
        \\printf 'aaa\n' | {s} -E 's/a{{99999999999999999999}}/X/' >/dev/null 2>&1
        \\rc=$?; test $rc -ne 134 -a $rc -ne 139
    , .{zsedBin()});
    defer a.free(cmd);
    try testing.expectEqual(@as(c_int, 0), try systemZ(cmd));
}

test "overflow: huge step address does not crash" {
    const cmd = try std.fmt.allocPrint(a,
        \\printf '1\n2\n' | {s} -n '1~99999999999999999999p' >/dev/null 2>&1
        \\rc=$?; test $rc -ne 134 -a $rc -ne 139
    , .{zsedBin()});
    defer a.free(cmd);
    try testing.expectEqual(@as(c_int, 0), try systemZ(cmd));
}

// ---------------------------------------------------------------------------
// In-place temp-file safety (finding: predictable name, no O_EXCL/O_NOFOLLOW).
// We assert the observable contract: the edit succeeds, leaves NO temp file
// behind, and (the security property) refuses to write THROUGH a pre-planted
// symlink of the guessable old name into an outside victim file.
// ---------------------------------------------------------------------------

test "in-place: no predictable temp file is left behind" {
    const cmd = try std.fmt.allocPrint(a,
        \\D=$(mktemp -d) || exit 90
        \\printf 'foo\n' > "$D/f"
        \\printf 'bar\n' > "$D/exp"
        \\{s} -i 's/foo/bar/' "$D/f"
        \\rc=0
        \\cmp -s "$D/f" "$D/exp" || rc=1
        \\ls -a "$D" | grep -q zsed_tmp && rc=2
        \\rm -rf "$D"
        \\exit $rc
    , .{zsedBin()});
    defer a.free(cmd);
    try testing.expectEqual(@as(c_int, 0), try systemZ(cmd));
}

test "in-place: does not clobber a pre-planted predictable-name symlink" {
    // The old code opened <dir>/.zsed_tmp_<pid> with O_CREAT|O_TRUNC and no
    // O_EXCL. An attacker who guessed the name and planted a symlink to a
    // victim file would have it truncated+overwritten. With mkstemp the name
    // is unpredictable AND created with O_EXCL, so the victim stays intact.
    // We can't guess the new random name, so we assert the property that a
    // file named like the OLD scheme is never followed/written.
    const cmd = try std.fmt.allocPrint(a,
        \\D=$(mktemp -d) || exit 90
        \\printf 'SECRET\n' > "$D/victim"
        \\printf 'SECRET\n' > "$D/victim_exp"
        \\printf 'foo\n' > "$D/f"
        \\printf 'bar\n' > "$D/f_exp"
        \\# Best-effort: plant old-scheme (pid-based) symlink names to the victim
        \\# near the shell's pid, where the zsed child's pid is likely to land.
        \\p=$$; end=$((p+2500)); while [ "$p" -le "$end" ]; do ln -s "$D/victim" "$D/.zsed_tmp_$p" 2>/dev/null; p=$((p+1)); done
        \\{s} -i 's/foo/bar/' "$D/f" >/dev/null 2>&1
        \\rc=0
        \\# Victim must be untouched.
        \\cmp -s "$D/victim" "$D/victim_exp" || rc=1
        \\# Edit must still have applied to the real target.
        \\cmp -s "$D/f" "$D/f_exp" || rc=2
        \\rm -rf "$D"
        \\exit $rc
    , .{zsedBin()});
    defer a.free(cmd);
    try testing.expectEqual(@as(c_int, 0), try systemZ(cmd));
}
