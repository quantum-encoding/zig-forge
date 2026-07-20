//! zfactor - Print prime factors
//!
//! High-performance prime factorization in Zig.
//!
//! Algorithm mirrors GNU factor: small trial division to strip tiny factors,
//! then a Miller-Rabin primality test plus Pollard's rho (Brent variant) for
//! the large cofactors, so large primes and semiprimes factor in milliseconds
//! instead of the O(sqrt(n)) trial-division blowup.

const std = @import("std");
const posix = std.posix;
const libc = std.c;

const VERSION = "1.0.0";

// Process-wide error flag: any invalid/too-large input makes the whole run
// exit non-zero, matching GNU factor's behaviour.
var any_error: bool = false;

fn writeStdout(data: []const u8) void {
    _ = libc.write(libc.STDOUT_FILENO, data.ptr, data.len);
}

fn writeStderr(data: []const u8) void {
    _ = libc.write(libc.STDERR_FILENO, data.ptr, data.len);
}

fn printUsage() void {
    const usage =
        \\Usage: zfactor [OPTION] [NUMBER]...
        \\Print the prime factors of each specified integer NUMBER.  If none
        \\are specified on the command line, read them from standard input.
        \\
        \\  -h, --exponents  print repeated factors in form p^e unless e is 1
        \\      --help       display this help and exit
        \\      --version    output version information and exit
        \\
    ;
    writeStdout(usage);
}

fn printVersion() void {
    writeStdout("zfactor " ++ VERSION ++ "\n");
}

// ---------------------------------------------------------------------------
// Modular arithmetic (u256 intermediates avoid u128 multiplication overflow)
// ---------------------------------------------------------------------------

fn mulmod(a: u128, b: u128, m: u128) u128 {
    const prod = (@as(u256, a) * @as(u256, b)) % @as(u256, m);
    return @intCast(prod);
}

fn powmod(base_in: u128, exp_in: u128, m: u128) u128 {
    var result: u128 = 1 % m;
    var base = base_in % m;
    var exp = exp_in;
    while (exp > 0) {
        if (exp & 1 == 1) result = mulmod(result, base, m);
        exp >>= 1;
        if (exp > 0) base = mulmod(base, base, m);
    }
    return result;
}

// Deterministic-enough Miller-Rabin. The first 12 primes are a proven
// deterministic witness set for all n < 3.317e24; we extend to the first
// primes below for extra safety on larger 128-bit cofactors.
const MR_BASES = [_]u128{ 2, 3, 5, 7, 11, 13, 17, 19, 23, 29, 31, 37, 41, 43, 47, 53, 59, 61, 67, 71 };

fn isPrime(n: u128) bool {
    if (n < 2) return false;
    for (MR_BASES) |p| {
        if (n == p) return true;
        if (n % p == 0) return false;
    }

    // n - 1 = d * 2^s
    var d = n - 1;
    var s: u32 = 0;
    while (d & 1 == 0) {
        d >>= 1;
        s += 1;
    }

    witness: for (MR_BASES) |a| {
        if (a % n == 0) continue;
        var x = powmod(a, d, n);
        if (x == 1 or x == n - 1) continue;
        var i: u32 = 1;
        while (i < s) : (i += 1) {
            x = mulmod(x, x, n);
            if (x == n - 1) continue :witness;
        }
        return false;
    }
    return true;
}

fn gcd(a_in: u128, b_in: u128) u128 {
    var a = a_in;
    var b = b_in;
    while (b != 0) {
        const t = a % b;
        a = b;
        b = t;
    }
    return a;
}

// Pollard's rho (Brent's variant). Precondition: n is composite and odd.
fn pollardRho(n: u128) u128 {
    if (n % 2 == 0) return 2;

    var c: u128 = 1;
    while (true) : (c += 1) {
        var x: u128 = 2;
        var y: u128 = 2;
        var d: u128 = 1;
        while (d == 1) {
            x = (mulmod(x, x, n) + c) % n;
            y = (mulmod(y, y, n) + c) % n;
            y = (mulmod(y, y, n) + c) % n;
            const diff = if (x > y) x - y else y - x;
            if (diff == 0) {
                d = n; // cycle without a factor; retry with next c
                break;
            }
            d = gcd(diff, n);
        }
        if (d != n) return d;
    }
}

// Recursively collect prime factors of an odd n >= 3 into `list`.
fn factorRec(n: u128, list: *std.ArrayList(u128), gpa: std.mem.Allocator) void {
    if (n == 1) return;
    if (isPrime(n)) {
        list.append(gpa, n) catch {};
        return;
    }
    const d = pollardRho(n);
    factorRec(d, list, gpa);
    factorRec(n / d, list, gpa);
}

// Fill `list` with the ascending prime factors (with multiplicity) of n.
fn collectFactors(n: u128, list: *std.ArrayList(u128), gpa: std.mem.Allocator) void {
    var num = n;
    while (num & 1 == 0) {
        list.append(gpa, 2) catch {};
        num >>= 1;
    }
    // Strip small odd factors cheaply and in order.
    var f: u128 = 3;
    while (f <= 1000 and f * f <= num) : (f += 2) {
        while (num % f == 0) {
            list.append(gpa, f) catch {};
            num /= f;
        }
    }
    if (num > 1) factorRec(num, list, gpa);
    std.mem.sort(u128, list.items, {}, std.sort.asc(u128));
}

// ---------------------------------------------------------------------------
// Output
// ---------------------------------------------------------------------------

fn appendNum(buf: []u8, idx: *usize, n: u128) void {
    const s = std.fmt.bufPrint(buf[idx.*..], "{d}", .{n}) catch return;
    idx.* += s.len;
}

fn appendStr(buf: []u8, idx: *usize, s: []const u8) void {
    if (idx.* + s.len > buf.len) return;
    @memcpy(buf[idx.*..][0..s.len], s);
    idx.* += s.len;
}

fn factorize(n: u128, exponents: bool, gpa: std.mem.Allocator) void {
    var list: std.ArrayList(u128) = .empty;
    defer list.deinit(gpa);

    if (n >= 2) collectFactors(n, &list, gpa);

    var buf: [4096]u8 = undefined;
    var idx: usize = 0;
    appendNum(&buf, &idx, n);
    appendStr(&buf, &idx, ":");

    if (exponents) {
        var i: usize = 0;
        while (i < list.items.len) {
            const p = list.items[i];
            var e: usize = 1;
            while (i + e < list.items.len and list.items[i + e] == p) e += 1;
            appendStr(&buf, &idx, " ");
            appendNum(&buf, &idx, p);
            if (e > 1) {
                appendStr(&buf, &idx, "^");
                appendNum(&buf, &idx, @intCast(e));
            }
            i += e;
        }
    } else {
        for (list.items) |p| {
            appendStr(&buf, &idx, " ");
            appendNum(&buf, &idx, p);
        }
    }

    appendStr(&buf, &idx, "\n");
    writeStdout(buf[0..idx]);
}

// ---------------------------------------------------------------------------
// Parsing
// ---------------------------------------------------------------------------

const ParseError = error{ Invalid, TooLarge };

/// Parse a strictly-formed non-negative decimal integer. Accepts an optional
/// leading '+' (GNU factor does). Rejects empty input, embedded whitespace,
/// and any non-digit. Overflow past u128 yields error.TooLarge.
fn parseNumber(s: []const u8) ParseError!u128 {
    if (s.len == 0) return error.Invalid;
    var digits = s;
    if (digits[0] == '+') digits = digits[1..];
    if (digits.len == 0) return error.Invalid;

    var result: u128 = 0;
    for (digits) |c| {
        if (c < '0' or c > '9') return error.Invalid;
        result = std.math.mul(u128, result, 10) catch return error.TooLarge;
        result = std.math.add(u128, result, c - '0') catch return error.TooLarge;
    }
    return result;
}

fn reportInvalid(token: []const u8) void {
    var buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "zfactor: \u{2018}{s}\u{2019} is not a valid positive integer\n", .{token}) catch "zfactor: invalid input\n";
    writeStderr(msg);
    any_error = true;
}

fn reportTooLarge(token: []const u8) void {
    var buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "zfactor: \u{2018}{s}\u{2019} is too large\n", .{token}) catch "zfactor: number too large\n";
    writeStderr(msg);
    any_error = true;
}

fn handleToken(token: []const u8, exponents: bool, gpa: std.mem.Allocator) void {
    if (parseNumber(token)) |n| {
        factorize(n, exponents, gpa);
    } else |err| switch (err) {
        error.Invalid => reportInvalid(token),
        error.TooLarge => reportTooLarge(token),
    }
}

// ---------------------------------------------------------------------------
// stdin (whitespace-tokenised, like GNU)
// ---------------------------------------------------------------------------

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0b or c == 0x0c;
}

fn processLine(line: []const u8, exponents: bool, gpa: std.mem.Allocator) void {
    var i: usize = 0;
    while (i < line.len) {
        while (i < line.len and isSpace(line[i])) i += 1;
        const start = i;
        while (i < line.len and !isSpace(line[i])) i += 1;
        if (i > start) handleToken(line[start..i], exponents, gpa);
    }
}

fn readStdin(exponents: bool, gpa: std.mem.Allocator) void {
    var buf: [65536]u8 = undefined;
    var line_buf: [4096]u8 = undefined;
    var line_len: usize = 0;

    while (true) {
        const n = posix.read(0, &buf) catch break;
        if (n == 0) {
            if (line_len > 0) processLine(line_buf[0..line_len], exponents, gpa);
            break;
        }

        for (buf[0..n]) |c| {
            if (c == '\n') {
                processLine(line_buf[0..line_len], exponents, gpa);
                line_len = 0;
            } else if (line_len < line_buf.len) {
                line_buf[line_len] = c;
                line_len += 1;
            }
        }
    }
}

fn invalidOption(arg: []const u8) void {
    var buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "zfactor: invalid option \u{2018}{s}\u{2019}\nTry 'zfactor --help' for more information.\n", .{arg}) catch "zfactor: invalid option\n";
    writeStderr(msg);
}

pub fn main(init: std.process.Init) !void {
    const gpa = std.heap.c_allocator;

    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    _ = args_iter.next(); // skip program name

    var numbers_found = false;
    var exponents = false;

    while (args_iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help")) {
            printUsage();
            return;
        } else if (std.mem.eql(u8, arg, "--version")) {
            printVersion();
            return;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--exponents")) {
            exponents = true;
        } else if (arg.len > 1 and arg[0] == '-') {
            // A leading dash that is not a recognised option is an option
            // error; GNU's getopt does the same (even for "-5") and exits 1.
            invalidOption(arg);
            std.process.exit(1);
        } else {
            numbers_found = true;
            handleToken(arg, exponents, gpa);
        }
    }

    if (!numbers_found) {
        readStdin(exponents, gpa);
    }

    if (any_error) std.process.exit(1);
}
