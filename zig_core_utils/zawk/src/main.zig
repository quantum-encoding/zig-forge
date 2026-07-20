//! zawk - High-performance AWK implementation
//!
//! Compatible with common AWK operations:
//! - Field splitting: $0, $1, $2, ... $NF
//! - Built-in variables: NF, NR, NR, FS, OFS, ORS, FILENAME
//! - Pattern-action rules: pattern { action }
//! - BEGIN/END blocks
//! - print statement
//! - Basic expressions and comparisons
//! - -F fs: set field separator
//! - -v var=val: set variable
//!
//! Implements a useful subset of AWK for common text processing tasks.

const std = @import("std");
const posix = std.posix;
const libc = std.c;

const MAX_FIELDS = 256;
const MAX_LINE = 65536;
const BUFFER_SIZE = 64 * 1024;

// Associative array type for AWK arrays
const AwkArray = struct {
    data: std.StringHashMapUnmanaged(Value),

    fn init() AwkArray {
        return .{ .data = .empty };
    }

    fn get(self: *const AwkArray, key: []const u8) Value {
        return self.data.get(key) orelse .uninitialized;
    }

    fn put(self: *AwkArray, allocator: std.mem.Allocator, key: []const u8, value: Value) !void {
        // Duplicate the key if it's not already in the map
        const owned_key = if (self.data.contains(key)) key else try allocator.dupe(u8, key);
        try self.data.put(allocator, owned_key, value);
    }

    fn delete(self: *AwkArray, key: []const u8) void {
        _ = self.data.remove(key);
    }

    fn contains(self: *const AwkArray, key: []const u8) bool {
        return self.data.contains(key);
    }

    fn count(self: *const AwkArray) usize {
        return self.data.count();
    }

    fn deinit(self: *AwkArray, allocator: std.mem.Allocator) void {
        self.data.deinit(allocator);
    }
};

const Value = union(enum) {
    string: []const u8,
    number: f64,
    array: *AwkArray,
    uninitialized,

    fn asString(self: Value, allocator: std.mem.Allocator) ![]const u8 {
        return switch (self) {
            .string => |s| s,
            .number => |n| {
                if (n == @trunc(n) and @abs(n) < 1e15) {
                    var buf: [32]u8 = undefined;
                    const len = formatInt(&buf, clampI64(n));
                    return try allocator.dupe(u8, buf[0..len]);
                } else {
                    // AWK default OFMT/CONVFMT is "%.6g".
                    var buf: [512]u8 = undefined;
                    const s = formatFloatC(&buf, 'g', n, 6);
                    return try allocator.dupe(u8, s);
                }
            },
            .array => "", // Arrays can't be converted to string
            .uninitialized => "",
        };
    }

    fn asNumber(self: Value) f64 {
        return switch (self) {
            .string => |s| parseNumber(s),
            .number => |n| n,
            .array => 0, // Arrays are 0 in numeric context
            .uninitialized => 0,
        };
    }

    fn asBool(self: Value) bool {
        return switch (self) {
            .string => |s| s.len > 0,
            .number => |n| n != 0,
            .array => |a| a.count() > 0,
            .uninitialized => false,
        };
    }
};

// AWK numeric-string conversion: parse the longest numeric prefix of `s`,
// including an optional exponent (e/E). Anchored to POSIX awk / std strtod
// semantics. Uses std.fmt.parseFloat on the scanned prefix so 1e30, .5e-2,
// etc. are honored instead of silently truncated.
fn isIdentChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_';
}

fn parseNumber(s: []const u8) f64 {
    if (s.len == 0) return 0;
    var i: usize = 0;

    // Skip leading whitespace
    while (i < s.len and (s[i] == ' ' or s[i] == '\t')) i += 1;
    const start = i;

    // Optional sign
    if (i < s.len and (s[i] == '-' or s[i] == '+')) i += 1;

    var saw_digit = false;
    // Integer part
    while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) saw_digit = true;
    // Decimal part
    if (i < s.len and s[i] == '.') {
        i += 1;
        while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) saw_digit = true;
    }
    if (!saw_digit) return 0;
    // Exponent part
    if (i < s.len and (s[i] == 'e' or s[i] == 'E')) {
        var j = i + 1;
        if (j < s.len and (s[j] == '+' or s[j] == '-')) j += 1;
        if (j < s.len and s[j] >= '0' and s[j] <= '9') {
            while (j < s.len and s[j] >= '0' and s[j] <= '9') j += 1;
            i = j;
        }
    }

    const token = s[start..i];
    return std.fmt.parseFloat(f64, token) catch 0;
}

// Clamp an f64 to the i64 range before @intFromFloat to avoid UB/panic on
// out-of-range or non-finite values.
fn clampI64(v: f64) i64 {
    if (std.math.isNan(v)) return 0;
    if (v >= 9.223372036854775e18) return std.math.maxInt(i64);
    if (v <= -9.223372036854775e18) return std.math.minInt(i64);
    return @intFromFloat(v);
}

fn clampU64(v: f64) u64 {
    if (std.math.isNan(v) or v <= 0) return 0;
    if (v >= 1.8446744073709552e19) return std.math.maxInt(u64);
    return @intFromFloat(v);
}

fn formatInt(buf: []u8, val: i64) usize {
    // Compute magnitude in u64 so i64_min negation cannot overflow.
    const negative = val < 0;
    var n: u64 = if (negative) @as(u64, @intCast(-(val + 1))) + 1 else @intCast(val);
    var i: usize = buf.len;

    if (n == 0) {
        // Callers slice buf[0..len]; write to buf[0], not buf[buf.len-1],
        // otherwise every integer 0 is rendered from an uninitialized byte.
        buf[0] = '0';
        return 1;
    }

    while (n > 0) {
        i -= 1;
        buf[i] = @intCast('0' + @as(u8, @intCast(n % 10)));
        n /= 10;
    }

    if (negative) {
        i -= 1;
        buf[i] = '-';
    }

    const len = buf.len - i;
    std.mem.copyForwards(u8, buf[0..len], buf[i..]);
    return len;
}

// Format a float with C printf semantics for %f, %e, %g. `buf` must be at
// least 512 bytes. Returns the formatted slice. Anchored to /usr/bin/awk
// (libc printf) behavior; verified in gnu_parity_test.zig.
fn formatFloatC(buf: []u8, spec: u8, val: f64, precision: usize) []const u8 {
    const float = std.fmt.float;
    if (std.math.isNan(val)) return if (spec == 'E' or spec == 'G' or spec == 'F') "NAN" else "nan";
    if (std.math.isInf(val)) {
        const neg = val < 0;
        const s: []const u8 = if (spec == 'E' or spec == 'G' or spec == 'F') "INF" else "inf";
        if (neg) {
            buf[0] = '-';
            @memcpy(buf[1 .. 1 + s.len], s);
            return buf[0 .. 1 + s.len];
        }
        return s;
    }

    switch (spec) {
        'f', 'F' => {
            return float.render(buf, val, .{ .mode = .decimal, .precision = precision }) catch buf[0..0];
        },
        'e', 'E' => {
            const raw = float.render(buf[256..], val, .{ .mode = .scientific, .precision = precision }) catch return buf[0..0];
            return fixupExponent(buf[0..256], raw, spec == 'E');
        },
        else => {
            // %g: precision is number of significant digits (0 -> 1).
            var p = precision;
            if (p == 0) p = 1;
            // Determine decimal exponent via a scientific rendering.
            var tmp: [64]u8 = undefined;
            const sci = float.render(&tmp, val, .{ .mode = .scientific, .precision = p - 1 }) catch return buf[0..0];
            const exp = parseSciExponent(sci);
            var out: []const u8 = undefined;
            if (exp < -4 or exp >= @as(i64, @intCast(p))) {
                // Use %e style with precision p-1, then trim trailing zeros.
                out = fixupExponent(buf[0..256], sci, spec == 'G');
                out = trimGZeros(buf[0..256], out, true);
            } else {
                // Use %f style with precision p-1-exp.
                const fprec: usize = @intCast(@max(0, @as(i64, @intCast(p)) - 1 - exp));
                const dec = float.render(buf[256..], val, .{ .mode = .decimal, .precision = fprec }) catch return buf[0..0];
                @memcpy(buf[0..dec.len], dec);
                out = trimGZeros(buf[0..256], buf[0..dec.len], false);
            }
            return out;
        },
    }
}

// Convert Zig scientific "1.235e4" / "1e-5" to C printf "1.235e+04".
fn fixupExponent(buf: []u8, raw: []const u8, upper: bool) []const u8 {
    const eidx = std.mem.indexOfScalar(u8, raw, 'e') orelse std.mem.indexOfScalar(u8, raw, 'E') orelse return raw;
    const mant = raw[0..eidx];
    var rest = raw[eidx + 1 ..];
    var sign: u8 = '+';
    if (rest.len > 0 and (rest[0] == '+' or rest[0] == '-')) {
        sign = rest[0];
        rest = rest[1..];
    }
    var w: usize = 0;
    @memcpy(buf[w .. w + mant.len], mant);
    w += mant.len;
    buf[w] = if (upper) 'E' else 'e';
    w += 1;
    buf[w] = sign;
    w += 1;
    // Exponent digits, minimum 2.
    if (rest.len < 2) {
        var pad: usize = 2 - rest.len;
        while (pad > 0) : (pad -= 1) {
            buf[w] = '0';
            w += 1;
        }
    }
    @memcpy(buf[w .. w + rest.len], rest);
    w += rest.len;
    return buf[0..w];
}

fn parseSciExponent(sci: []const u8) i64 {
    const eidx = std.mem.indexOfScalar(u8, sci, 'e') orelse std.mem.indexOfScalar(u8, sci, 'E') orelse return 0;
    const rest = sci[eidx + 1 ..];
    return std.fmt.parseInt(i64, rest, 10) catch 0;
}

// Trim trailing zeros for %g. If `is_exp` the mantissa is before 'e'/'E'.
// `scratch` must not alias `s`.
fn trimGZeros(scratch: []u8, s: []const u8, is_exp: bool) []const u8 {
    if (is_exp) {
        const eidx = std.mem.indexOfScalar(u8, s, 'e') orelse std.mem.indexOfScalar(u8, s, 'E') orelse return s;
        var mant = s[0..eidx];
        const exp = s[eidx..];
        if (std.mem.indexOfScalar(u8, mant, '.') != null) {
            while (mant.len > 0 and mant[mant.len - 1] == '0') mant = mant[0 .. mant.len - 1];
            if (mant.len > 0 and mant[mant.len - 1] == '.') mant = mant[0 .. mant.len - 1];
        }
        var w: usize = 0;
        std.mem.copyForwards(u8, scratch[w .. w + mant.len], mant);
        w += mant.len;
        std.mem.copyForwards(u8, scratch[w .. w + exp.len], exp);
        w += exp.len;
        return scratch[0..w];
    } else {
        var out = s;
        if (std.mem.indexOfScalar(u8, out, '.') != null) {
            while (out.len > 0 and out[out.len - 1] == '0') out = out[0 .. out.len - 1];
            if (out.len > 0 and out[out.len - 1] == '.') out = out[0 .. out.len - 1];
        }
        return out;
    }
}

const ExprType = enum {
    field,        // $N
    variable,     // identifier
    string_lit,   // "..."
    number_lit,   // 123
    regex,        // /pattern/
    binop,        // a + b, a ~ /re/
    unop,         // !a, -a
    concat,       // string concatenation
    call,         // function call
    array_access, // array[key]
    in_array,     // key in array
};

const BinOp = enum {
    add, sub, mul, div, mod,
    eq, ne, lt, le, gt, ge,
    match, not_match,
    and_op, or_op,
};

const Expr = struct {
    expr_type: ExprType,
    // For field: field_num for simple $N, or field_expr for computed $expr
    // For variable: name
    // For literals: value
    // For binop: left, right, op
    // For array_access: name (array name), left (index expression)
    // For in_array: left (key expr), name (array name)
    field_num: usize = 0, // Simple field like $1, $2 (0 means use field_expr)
    field_expr: ?*Expr = null, // For computed fields like $(NF-1)
    name: []const u8 = "",
    str_val: []const u8 = "",
    num_val: f64 = 0,
    left: ?*Expr = null,
    right: ?*Expr = null,
    op: BinOp = .add,
    args: []Expr = &[_]Expr{},
};

const ActionType = enum {
    print,
    print_expr,
    printf_stmt,
    assign,
    field_assign, // $N = value  (condition holds the field lvalue expr)
    array_assign, // array[key] = value
    delete_stmt,  // delete array[key]
    if_stmt,
    while_stmt,
    for_stmt,
    for_in_stmt,  // for (key in array)
    next,
    exit,
    expr_stmt,
};

const Action = struct {
    action_type: ActionType,
    exprs: []Expr = &[_]Expr{},
    var_name: []const u8 = "",
    body: []Action = &[_]Action{},
    else_body: []Action = &[_]Action{},
    condition: ?*Expr = null,
    init_action: ?*Action = null,
    incr_action: ?*Action = null,
};

const Rule = struct {
    pattern: ?*Expr = null, // null means match all
    is_begin: bool = false,
    is_end: bool = false,
    actions: []Action = &[_]Action{},
};

const AwkState = struct {
    allocator: std.mem.Allocator,
    variables: std.StringHashMapUnmanaged(Value),
    arrays: std.StringHashMapUnmanaged(*AwkArray),
    fields: [MAX_FIELDS][]const u8,
    nf: usize = 0,
    nr: usize = 0,
    fnr: usize = 0,
    fs: []const u8 = " ",
    ofs: []const u8 = " ",
    ors: []const u8 = "\n",
    filename: []const u8 = "",
    line: []const u8 = "",
    output: *OutputBuffer,
    should_next: bool = false,
    exit_code: u8 = 0,
    should_exit: bool = false,

    fn init(allocator: std.mem.Allocator, output: *OutputBuffer) AwkState {
        return .{
            .allocator = allocator,
            .variables = .empty,
            .arrays = .empty,
            .fields = undefined,
            .output = output,
        };
    }

    fn deinit(self: *AwkState) void {
        // Free all arrays
        var it = self.arrays.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.deinit(self.allocator);
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.arrays.deinit(self.allocator);
        self.variables.deinit(self.allocator);
    }

    fn getOrCreateArray(self: *AwkState, name: []const u8) !*AwkArray {
        if (self.arrays.get(name)) |arr| {
            return arr;
        }
        // Create new array
        const arr = try self.allocator.create(AwkArray);
        arr.* = AwkArray.init();
        const owned_name = try self.allocator.dupe(u8, name);
        try self.arrays.put(self.allocator, owned_name, arr);
        return arr;
    }

    fn getArrayElement(self: *AwkState, array_name: []const u8, key: []const u8) Value {
        if (self.arrays.get(array_name)) |arr| {
            return arr.get(key);
        }
        return .uninitialized;
    }

    fn setArrayElement(self: *AwkState, array_name: []const u8, key: []const u8, value: Value) !void {
        const arr = try self.getOrCreateArray(array_name);
        try arr.put(self.allocator, key, value);
    }

    fn deleteArrayElement(self: *AwkState, array_name: []const u8, key: []const u8) void {
        if (self.arrays.get(array_name)) |arr| {
            arr.delete(key);
        }
    }

    fn arrayContains(self: *AwkState, array_name: []const u8, key: []const u8) bool {
        if (self.arrays.get(array_name)) |arr| {
            return arr.contains(key);
        }
        return false;
    }

    fn setLine(self: *AwkState, line: []const u8) void {
        self.line = line;
        self.fields[0] = line;
        self.nf = 0;

        // Split fields
        if (self.fs.len == 1 and self.fs[0] == ' ') {
            // Default: split on runs of whitespace
            var i: usize = 0;
            while (i < line.len) {
                // Skip whitespace
                while (i < line.len and (line[i] == ' ' or line[i] == '\t')) i += 1;
                if (i >= line.len) break;

                const start = i;
                while (i < line.len and line[i] != ' ' and line[i] != '\t') i += 1;

                if (self.nf < MAX_FIELDS - 1) {
                    self.nf += 1;
                    self.fields[self.nf] = line[start..i];
                }
            }
        } else if (self.fs.len == 1) {
            // Single character separator
            const sep = self.fs[0];
            var start: usize = 0;
            var i: usize = 0;
            while (i <= line.len) {
                if (i == line.len or line[i] == sep) {
                    if (self.nf < MAX_FIELDS - 1) {
                        self.nf += 1;
                        self.fields[self.nf] = line[start..i];
                    }
                    start = i + 1;
                }
                i += 1;
            }
        } else {
            // Multi-char separator or regex (simplified: literal match)
            var start: usize = 0;
            var i: usize = 0;
            while (i + self.fs.len <= line.len) {
                if (std.mem.eql(u8, line[i..][0..self.fs.len], self.fs)) {
                    if (self.nf < MAX_FIELDS - 1) {
                        self.nf += 1;
                        self.fields[self.nf] = line[start..i];
                    }
                    start = i + self.fs.len;
                    i = start;
                } else {
                    i += 1;
                }
            }
            if (self.nf < MAX_FIELDS - 1) {
                self.nf += 1;
                self.fields[self.nf] = line[start..];
            }
        }
    }

    fn getField(self: *AwkState, n: usize) []const u8 {
        if (n == 0) return self.line;
        if (n > self.nf) return "";
        return self.fields[n];
    }

    // Assign field N (1-based). Copies `value`, extends NF with empty fields if
    // needed, then rebuilds $0 by joining fields with OFS (awk semantics). The
    // stored field/$0 strings are heap-owned; the arena is freed at process
    // exit like the rest of the interpreter's allocations.
    fn setField(self: *AwkState, n: usize, value: []const u8) void {
        if (n == 0) {
            const owned = self.allocator.dupe(u8, value) catch return;
            self.setLine(owned);
            return;
        }
        if (n >= MAX_FIELDS) return;
        // Snapshot existing field slices into owned copies so the rebuild does
        // not alias the old $0 buffer we are about to replace.
        var owned_fields: [MAX_FIELDS][]const u8 = undefined;
        const old_nf = self.nf;
        var k: usize = 1;
        while (k <= old_nf and k < MAX_FIELDS) : (k += 1) {
            owned_fields[k] = self.allocator.dupe(u8, self.fields[k]) catch "";
        }
        while (k < MAX_FIELDS) : (k += 1) owned_fields[k] = "";
        owned_fields[n] = self.allocator.dupe(u8, value) catch return;
        const new_nf = @max(old_nf, n);
        // Rebuild $0.
        var joined: std.ArrayListUnmanaged(u8) = .empty;
        var f: usize = 1;
        while (f <= new_nf) : (f += 1) {
            if (f > 1) joined.appendSlice(self.allocator, self.ofs) catch {};
            joined.appendSlice(self.allocator, owned_fields[f]) catch {};
        }
        self.line = joined.items;
        self.fields[0] = self.line;
        self.nf = new_nf;
        f = 1;
        while (f <= new_nf) : (f += 1) self.fields[f] = owned_fields[f];
    }

    fn getVariable(self: *AwkState, name: []const u8) Value {
        // Built-in variables
        if (std.mem.eql(u8, name, "NF")) return .{ .number = @floatFromInt(self.nf) };
        if (std.mem.eql(u8, name, "NR")) return .{ .number = @floatFromInt(self.nr) };
        if (std.mem.eql(u8, name, "FNR")) return .{ .number = @floatFromInt(self.fnr) };
        if (std.mem.eql(u8, name, "FS")) return .{ .string = self.fs };
        if (std.mem.eql(u8, name, "OFS")) return .{ .string = self.ofs };
        if (std.mem.eql(u8, name, "ORS")) return .{ .string = self.ors };
        if (std.mem.eql(u8, name, "FILENAME")) return .{ .string = self.filename };

        return self.variables.get(name) orelse .uninitialized;
    }

    fn setVariable(self: *AwkState, name: []const u8, value: Value) !void {
        // Handle special variables
        if (std.mem.eql(u8, name, "FS")) {
            if (value == .string) self.fs = value.string;
            return;
        }
        if (std.mem.eql(u8, name, "OFS")) {
            if (value == .string) self.ofs = value.string;
            return;
        }
        if (std.mem.eql(u8, name, "ORS")) {
            if (value == .string) self.ors = value.string;
            return;
        }

        try self.variables.put(self.allocator, name, value);
    }
};

const OutputBuffer = struct {
    buf: [65536]u8 = undefined,
    len: usize = 0,

    fn write(self: *OutputBuffer, data: []const u8) void {
        if (self.len + data.len > self.buf.len) {
            self.flush();
        }
        if (data.len > self.buf.len) {
            _ = libc.write(libc.STDOUT_FILENO, data.ptr, data.len);
            return;
        }
        @memcpy(self.buf[self.len..][0..data.len], data);
        self.len += data.len;
    }

    fn flush(self: *OutputBuffer) void {
        if (self.len > 0) {
            _ = libc.write(libc.STDOUT_FILENO, &self.buf, self.len);
            self.len = 0;
        }
    }
};

// Simple expression parser
const Parser = struct {
    allocator: std.mem.Allocator,
    src: []const u8,
    pos: usize = 0,
    rules: std.ArrayListUnmanaged(Rule),
    exprs: std.ArrayListUnmanaged(Expr),
    actions: std.ArrayListUnmanaged(Action),
    reserved_exprs: usize = 0,
    reserved_actions: usize = 0,
    had_error: bool = false,

    fn init(allocator: std.mem.Allocator, src: []const u8) Parser {
        // The AST stores raw *Expr pointers and []Expr / []Action slices into
        // these backing lists. If a list reallocated mid-parse every stored
        // pointer/slice would dangle (the original segfault). We reserve a
        // capacity that scales with the program size and is a proven upper
        // bound on the number of appends: every append in the parser is tied
        // to consuming at least one source byte (binary operators append at
        // most 2 nodes per operator character), so appends <= ~2*src.len. The
        // 8x/4x margins below guarantee no realloc for any real program, and
        // parseProgram asserts the capacity never grew as a safety net.
        const cap_e = src.len * 8 + 4096;
        const cap_a = src.len * 4 + 1024;
        var rules: std.ArrayListUnmanaged(Rule) = .empty;
        rules.ensureTotalCapacity(allocator, src.len + 64) catch {};
        var exprs: std.ArrayListUnmanaged(Expr) = .empty;
        exprs.ensureTotalCapacity(allocator, cap_e) catch {};
        var actions: std.ArrayListUnmanaged(Action) = .empty;
        actions.ensureTotalCapacity(allocator, cap_a) catch {};

        return .{
            .allocator = allocator,
            .src = src,
            .rules = rules,
            .exprs = exprs,
            .actions = actions,
            .reserved_exprs = exprs.capacity,
            .reserved_actions = actions.capacity,
        };
    }

    fn deinit(self: *Parser) void {
        self.rules.deinit(self.allocator);
        self.exprs.deinit(self.allocator);
        self.actions.deinit(self.allocator);
    }

    fn skipWhitespace(self: *Parser) void {
        while (self.pos < self.src.len) {
            if (self.src[self.pos] == ' ' or self.src[self.pos] == '\t' or self.src[self.pos] == '\n') {
                self.pos += 1;
            } else if (self.src[self.pos] == '#') {
                // Skip comment
                while (self.pos < self.src.len and self.src[self.pos] != '\n') self.pos += 1;
            } else {
                break;
            }
        }
    }

    fn peek(self: *Parser) ?u8 {
        self.skipWhitespace();
        if (self.pos >= self.src.len) return null;
        return self.src[self.pos];
    }

    fn parseProgram(self: *Parser) ![]Rule {
        while (self.peek() != null) {
            const before = self.pos;
            try self.parseRule();
            // Progress guard: if a rule consumed nothing we would spin forever
            // on malformed input. Flag an error and skip one byte to terminate.
            if (self.pos == before) {
                self.had_error = true;
                self.pos += 1;
            }
        }
        // Safety net: if any backing list grew past its reservation, a realloc
        // moved the buffer and every stored pointer/slice is now dangling.
        // Refuse to execute a corrupt AST.
        if (self.exprs.capacity != self.reserved_exprs or self.actions.capacity != self.reserved_actions) {
            return error.ProgramTooComplex;
        }
        return self.rules.items;
    }

    fn parseRule(self: *Parser) !void {
        self.skipWhitespace();
        if (self.pos >= self.src.len) return;

        var rule = Rule{};

        // Check for BEGIN/END
        if (self.matchKeyword("BEGIN")) {
            rule.is_begin = true;
        } else if (self.matchKeyword("END")) {
            rule.is_end = true;
        } else if (self.peek() != '{') {
            // Parse pattern
            const pattern = try self.parseExpr();
            try self.exprs.append(self.allocator, pattern);
            rule.pattern = &self.exprs.items[self.exprs.items.len - 1];
        }

        self.skipWhitespace();

        // Parse action block
        if (self.peek() == '{') {
            self.pos += 1;
            const actions_start = self.actions.items.len;

            while (self.peek() != '}' and self.peek() != null) {
                const before = self.pos;
                try self.parseAction();
                if (self.pos == before) {
                    self.had_error = true;
                    self.pos += 1;
                }
            }

            if (self.peek() == '}') self.pos += 1;
            rule.actions = self.actions.items[actions_start..];
        } else {
            // Default action: print $0
            try self.actions.append(self.allocator, .{ .action_type = .print });
            rule.actions = self.actions.items[self.actions.items.len - 1 ..];
        }

        try self.rules.append(self.allocator, rule);
    }

    fn matchKeyword(self: *Parser, keyword: []const u8) bool {
        self.skipWhitespace();
        if (self.pos + keyword.len > self.src.len) return false;
        if (!std.mem.eql(u8, self.src[self.pos..][0..keyword.len], keyword)) return false;
        if (self.pos + keyword.len < self.src.len) {
            const next = self.src[self.pos + keyword.len];
            if ((next >= 'a' and next <= 'z') or (next >= 'A' and next <= 'Z') or
                (next >= '0' and next <= '9') or next == '_')
            {
                return false;
            }
        }
        self.pos += keyword.len;
        return true;
    }

    fn parseAction(self: *Parser) !void {
        self.skipWhitespace();
        if (self.pos >= self.src.len) return;

        // Skip semicolons and newlines
        while (self.peek() == ';' or self.peek() == '\n') {
            self.pos += 1;
            self.skipWhitespace();
        }

        if (self.peek() == '}' or self.peek() == null) return;

        if (self.matchKeyword("printf")) {
            // printf format, args...
            var action = Action{ .action_type = .printf_stmt };
            self.skipWhitespace();
            action.exprs = try self.parseArgList('}');
            try self.actions.append(self.allocator, action);
        } else if (self.matchKeyword("print")) {
            var action = Action{ .action_type = .print_expr };
            self.skipWhitespace();
            if (self.peek() != ';' and self.peek() != '\n' and self.peek() != '}' and self.peek() != null) {
                action.exprs = try self.parseArgList('}');
            }
            if (action.exprs.len == 0) {
                action.action_type = .print;
            }
            try self.actions.append(self.allocator, action);
        } else if (self.matchKeyword("delete")) {
            // delete array[key]
            self.skipWhitespace();
            const expr = try self.parseExpr();
            // expr should be array_access type
            try self.exprs.append(self.allocator, expr);
            try self.actions.append(self.allocator, .{
                .action_type = .delete_stmt,
                .exprs = self.exprs.items[self.exprs.items.len - 1 ..],
            });
        } else if (self.matchKeyword("for")) {
            // for (key in array) or for (init; cond; incr)
            self.skipWhitespace();
            if (self.peek() == '(') {
                self.pos += 1;
                self.skipWhitespace();

                // Parse first part - could be "key in array" or an init expression
                const init_start = self.pos;
                var is_for_in = false;
                var key_var: []const u8 = "";

                // Try to parse identifier
                if (self.pos < self.src.len) {
                    const fc = self.src[self.pos];
                    if ((fc >= 'a' and fc <= 'z') or (fc >= 'A' and fc <= 'Z') or fc == '_') {
                        const kstart = self.pos;
                        while (self.pos < self.src.len) {
                            const kch = self.src[self.pos];
                            if ((kch >= 'a' and kch <= 'z') or (kch >= 'A' and kch <= 'Z') or
                                (kch >= '0' and kch <= '9') or kch == '_')
                            {
                                self.pos += 1;
                            } else break;
                        }
                        key_var = self.src[kstart..self.pos];
                        self.skipWhitespace();

                        if (self.matchKeyword("in")) {
                            is_for_in = true;
                        } else {
                            // Not for-in, reset position
                            self.pos = init_start;
                        }
                    }
                }

                if (is_for_in) {
                    // for (key in array) { body }
                    self.skipWhitespace();
                    // Parse array name
                    const arr_start = self.pos;
                    while (self.pos < self.src.len) {
                        const ach = self.src[self.pos];
                        if ((ach >= 'a' and ach <= 'z') or (ach >= 'A' and ach <= 'Z') or
                            (ach >= '0' and ach <= '9') or ach == '_')
                        {
                            self.pos += 1;
                        } else break;
                    }
                    const arr_name = self.src[arr_start..self.pos];
                    self.skipWhitespace();
                    if (self.peek() == ')') self.pos += 1;
                    self.skipWhitespace();

                    // Parse body
                    const body_start = self.actions.items.len;
                    if (self.peek() == '{') {
                        self.pos += 1;
                        while (self.peek() != '}' and self.peek() != null) {
                            const before = self.pos;
                            try self.parseAction();
                            if (self.pos == before) {
                                self.had_error = true;
                                self.pos += 1;
                            }
                        }
                        if (self.peek() == '}') self.pos += 1;
                    } else {
                        try self.parseAction();
                    }
                    const body_end = self.actions.items.len;

                    // Store array name expression
                    const arr_expr_start = self.exprs.items.len;
                    try self.exprs.append(self.allocator, .{ .expr_type = .variable, .name = arr_name });
                    const arr_expr_end = self.exprs.items.len;

                    // Ensure capacity before adding the for_in action to prevent reallocation
                    try self.actions.ensureTotalCapacity(self.allocator, self.actions.items.len + 1);

                    self.actions.appendAssumeCapacity(.{
                        .action_type = .for_in_stmt,
                        .var_name = key_var,
                        .body = self.actions.items[body_start..body_end],
                        .exprs = self.exprs.items[arr_expr_start..arr_expr_end],
                    });
                } else {
                    // Regular for loop - skip for now (complex)
                    // Just skip until closing )
                    var paren_depth: usize = 1;
                    while (paren_depth > 0 and self.pos < self.src.len) {
                        if (self.src[self.pos] == '(') paren_depth += 1;
                        if (self.src[self.pos] == ')') paren_depth -= 1;
                        self.pos += 1;
                    }
                    self.skipWhitespace();
                    // Skip body
                    if (self.peek() == '{') {
                        var brace_depth: usize = 1;
                        self.pos += 1;
                        while (brace_depth > 0 and self.pos < self.src.len) {
                            if (self.src[self.pos] == '{') brace_depth += 1;
                            if (self.src[self.pos] == '}') brace_depth -= 1;
                            self.pos += 1;
                        }
                    }
                }
            }
        } else if (self.matchKeyword("next")) {
            try self.actions.append(self.allocator, .{ .action_type = .next });
        } else if (self.matchKeyword("exit")) {
            // exit [expr] — capture the optional status expression.
            var action = Action{ .action_type = .exit };
            self.skipWhitespace();
            const p = self.peek();
            if (p != null and p.? != ';' and p.? != '}' and p.? != '\n') {
                const e = try self.parseExpr();
                try self.exprs.append(self.allocator, e);
                action.condition = &self.exprs.items[self.exprs.items.len - 1];
            }
            try self.actions.append(self.allocator, action);
        } else if (self.peek() == '$') {
            // Field assignment: $N = expr / $N op= expr / $N++ / $N--
            const stmt_start = self.pos;
            const lhs = try self.parsePrimary();
            try self.exprs.append(self.allocator, lhs);
            const lhs_ptr = &self.exprs.items[self.exprs.items.len - 1];
            self.skipWhitespace();

            var op: ?BinOp = null;
            var is_assign = false;
            var is_incr = false;
            var is_decr = false;
            if (self.pos + 1 < self.src.len and self.src[self.pos] == '+' and self.src[self.pos + 1] == '+') {
                is_incr = true;
            } else if (self.pos + 1 < self.src.len and self.src[self.pos] == '-' and self.src[self.pos + 1] == '-') {
                is_decr = true;
            } else if (self.pos + 1 < self.src.len and self.src[self.pos + 1] == '=' and
                (self.src[self.pos] == '+' or self.src[self.pos] == '-' or self.src[self.pos] == '*' or self.src[self.pos] == '/'))
            {
                op = switch (self.src[self.pos]) {
                    '+' => .add,
                    '-' => .sub,
                    '*' => .mul,
                    else => .div,
                };
            } else if (self.pos < self.src.len and self.src[self.pos] == '=' and
                (self.pos + 1 >= self.src.len or self.src[self.pos + 1] != '='))
            {
                is_assign = true;
            }

            if (is_assign) {
                self.pos += 1;
                const value_expr = try self.parseExpr();
                try self.exprs.append(self.allocator, value_expr);
                try self.actions.append(self.allocator, .{
                    .action_type = .field_assign,
                    .condition = lhs_ptr,
                    .exprs = self.exprs.items[self.exprs.items.len - 1 ..],
                });
            } else if (op != null or is_incr or is_decr) {
                if (is_incr or is_decr) self.pos += 2 else self.pos += 2;
                const rhs_expr = if (is_incr or is_decr) blk: {
                    break :blk Expr{ .expr_type = .number_lit, .num_val = 1 };
                } else try self.parseExpr();
                try self.exprs.append(self.allocator, rhs_expr);
                const combined = Expr{
                    .expr_type = .binop,
                    .op = if (is_decr) .sub else if (is_incr) .add else op.?,
                    .left = lhs_ptr,
                    .right = &self.exprs.items[self.exprs.items.len - 1],
                };
                try self.exprs.append(self.allocator, combined);
                try self.actions.append(self.allocator, .{
                    .action_type = .field_assign,
                    .condition = lhs_ptr,
                    .exprs = self.exprs.items[self.exprs.items.len - 1 ..],
                });
            } else {
                // Not an assignment — parse the whole thing as an expression.
                self.pos = stmt_start;
                const expr = try self.parseExpr();
                try self.exprs.append(self.allocator, expr);
                try self.actions.append(self.allocator, .{
                    .action_type = .expr_stmt,
                    .exprs = self.exprs.items[self.exprs.items.len - 1 ..],
                });
            }
        } else {
            // Check for identifier followed by assignment, array access, or compound assignment
            self.skipWhitespace();
            const start_pos = self.pos;

            // Try to parse simple identifier for potential assignment
            var var_name: []const u8 = "";
            var is_array_assign = false;
            var array_index_expr: ?Expr = null;

            if (self.pos < self.src.len) {
                const c = self.src[self.pos];
                if ((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_') {
                    const name_start = self.pos;
                    while (self.pos < self.src.len) {
                        const ch = self.src[self.pos];
                        if ((ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or
                            (ch >= '0' and ch <= '9') or ch == '_')
                        {
                            self.pos += 1;
                        } else {
                            break;
                        }
                    }
                    var_name = self.src[name_start..self.pos];

                    // Check for array subscript
                    self.skipWhitespace();
                    if (self.peek() == '[') {
                        self.pos += 1;
                        array_index_expr = try self.parseExpr();
                        self.skipWhitespace();
                        if (self.peek() == ']') self.pos += 1;
                        is_array_assign = true;
                    }
                }
            }

            self.skipWhitespace();

            // Check for ++, --, compound assignment (+=, -=, *=, /=) or simple assignment
            var compound_op: ?BinOp = null;
            var is_simple_assign = false;
            var is_increment = false;
            var is_decrement = false;

            if (var_name.len > 0 and self.pos < self.src.len) {
                // Check for ++ or --
                if (self.pos + 1 < self.src.len) {
                    if (self.src[self.pos] == '+' and self.src[self.pos + 1] == '+') {
                        is_increment = true;
                    } else if (self.src[self.pos] == '-' and self.src[self.pos + 1] == '-') {
                        is_decrement = true;
                    } else if (self.src[self.pos + 1] == '=') {
                        switch (self.src[self.pos]) {
                            '+' => compound_op = .add,
                            '-' => compound_op = .sub,
                            '*' => compound_op = .mul,
                            '/' => compound_op = .div,
                            else => {},
                        }
                    }
                }
                if (compound_op == null and !is_increment and !is_decrement and
                    self.src[self.pos] == '=' and
                    (self.pos + 1 >= self.src.len or self.src[self.pos + 1] != '='))
                {
                    is_simple_assign = true;
                }
            }

            // Handle array increment/decrement: arr[key]++ or arr[key]--
            if (is_array_assign and (is_increment or is_decrement)) {
                self.pos += 2; // Skip ++ or --
                // Store index expression
                try self.exprs.append(self.allocator, array_index_expr.?);
                // Create array access for current value
                const arr_access = Expr{
                    .expr_type = .array_access,
                    .name = var_name,
                    .left = &self.exprs.items[self.exprs.items.len - 1],
                };
                try self.exprs.append(self.allocator, arr_access);
                // Create the number 1
                const one_expr = Expr{ .expr_type = .number_lit, .num_val = 1 };
                try self.exprs.append(self.allocator, one_expr);
                // Create arr[key] + 1 or arr[key] - 1
                const combined = Expr{
                    .expr_type = .binop,
                    .op = if (is_increment) .add else .sub,
                    .left = &self.exprs.items[self.exprs.items.len - 2],
                    .right = &self.exprs.items[self.exprs.items.len - 1],
                };
                try self.exprs.append(self.allocator, combined);
                try self.actions.append(self.allocator, .{
                    .action_type = .array_assign,
                    .var_name = var_name,
                    .exprs = self.exprs.items[self.exprs.items.len - 4 ..], // index, arr_access, one, combined
                });
            } else if (is_array_assign and (is_simple_assign or compound_op != null)) {
                // Array assignment: array[key] = value or array[key] op= value
                if (compound_op) |op| {
                    self.pos += 2; // Skip op and =
                    const value_expr = try self.parseExpr();
                    // Store index expression
                    try self.exprs.append(self.allocator, array_index_expr.?);
                    // Create array access for current value
                    const arr_access = Expr{
                        .expr_type = .array_access,
                        .name = var_name,
                        .left = &self.exprs.items[self.exprs.items.len - 1],
                    };
                    try self.exprs.append(self.allocator, arr_access);
                    try self.exprs.append(self.allocator, value_expr);
                    const combined = Expr{
                        .expr_type = .binop,
                        .op = op,
                        .left = &self.exprs.items[self.exprs.items.len - 2],
                        .right = &self.exprs.items[self.exprs.items.len - 1],
                    };
                    try self.exprs.append(self.allocator, combined);
                    try self.actions.append(self.allocator, .{
                        .action_type = .array_assign,
                        .var_name = var_name,
                        .exprs = self.exprs.items[self.exprs.items.len - 4 ..], // index, arr_access, value, combined
                    });
                } else {
                    self.pos += 1; // Skip =
                    const value_expr = try self.parseExpr();
                    try self.exprs.append(self.allocator, array_index_expr.?);
                    try self.exprs.append(self.allocator, value_expr);
                    try self.actions.append(self.allocator, .{
                        .action_type = .array_assign,
                        .var_name = var_name,
                        .exprs = self.exprs.items[self.exprs.items.len - 2 ..], // index, value
                    });
                }
            } else if (!is_array_assign and (is_increment or is_decrement)) {
                // Simple variable increment/decrement: var++ or var--
                self.pos += 2; // Skip ++ or --
                const var_ref = Expr{ .expr_type = .variable, .name = var_name };
                try self.exprs.append(self.allocator, var_ref);
                const one_expr = Expr{ .expr_type = .number_lit, .num_val = 1 };
                try self.exprs.append(self.allocator, one_expr);
                const combined = Expr{
                    .expr_type = .binop,
                    .op = if (is_increment) .add else .sub,
                    .left = &self.exprs.items[self.exprs.items.len - 2],
                    .right = &self.exprs.items[self.exprs.items.len - 1],
                };
                try self.exprs.append(self.allocator, combined);
                try self.actions.append(self.allocator, .{
                    .action_type = .assign,
                    .var_name = var_name,
                    .exprs = self.exprs.items[self.exprs.items.len - 1 ..],
                });
            } else if (compound_op) |op| {
                // Compound assignment: var op= value
                self.pos += 2; // Skip op and =
                const value_expr = try self.parseExpr();
                // Create: var_ref op value_expr
                const var_ref = Expr{ .expr_type = .variable, .name = var_name };
                try self.exprs.append(self.allocator, var_ref);
                try self.exprs.append(self.allocator, value_expr);
                const combined = Expr{
                    .expr_type = .binop,
                    .op = op,
                    .left = &self.exprs.items[self.exprs.items.len - 2],
                    .right = &self.exprs.items[self.exprs.items.len - 1],
                };
                try self.exprs.append(self.allocator, combined);
                try self.actions.append(self.allocator, .{
                    .action_type = .assign,
                    .var_name = var_name,
                    .exprs = self.exprs.items[self.exprs.items.len - 1 ..],
                });
            } else if (is_simple_assign) {
                // Simple assignment: var = value
                self.pos += 1; // Skip =
                const value_expr = try self.parseExpr();
                try self.exprs.append(self.allocator, value_expr);
                try self.actions.append(self.allocator, .{
                    .action_type = .assign,
                    .var_name = var_name,
                    .exprs = self.exprs.items[self.exprs.items.len - 1 ..],
                });
            } else {
                // Not an assignment, parse as expression
                self.pos = start_pos; // Reset position
                const expr = try self.parseExpr();
                try self.exprs.append(self.allocator, expr);
                try self.actions.append(self.allocator, .{
                    .action_type = .expr_stmt,
                    .exprs = self.exprs.items[self.exprs.items.len - 1 ..],
                });
            }
        }

        // Skip optional semicolon
        self.skipWhitespace();
        if (self.peek() == ';') self.pos += 1;
    }

    fn parseExpr(self: *Parser) error{OutOfMemory}!Expr {
        return self.parseOr();
    }

    // Parse a comma-separated list of expressions into an independently-owned
    // slice holding ONLY the top-level expressions. This avoids the arg-list
    // pollution bug: parseExpr appends nested operand nodes into self.exprs, so
    // slicing self.exprs directly would interleave sub-expressions into the
    // argument vector (e.g. substr(s, i+1) would pass `i` instead of `i+1`).
    fn parseArgList(self: *Parser, terminator: u8) error{OutOfMemory}![]Expr {
        var list: std.ArrayListUnmanaged(Expr) = .empty;
        errdefer list.deinit(self.allocator);
        if (self.peek() != terminator and self.peek() != null) {
            try list.append(self.allocator, try self.parseExpr());
            while (self.peek() == ',') {
                self.pos += 1;
                try list.append(self.allocator, try self.parseExpr());
            }
        }
        return list.toOwnedSlice(self.allocator);
    }

    fn parseOr(self: *Parser) !Expr {
        var left = try self.parseAnd();

        while (self.peek() == '|' and self.pos + 1 < self.src.len and self.src[self.pos + 1] == '|') {
            self.pos += 2;
            const right = try self.parseAnd();
            try self.exprs.append(self.allocator, left);
            try self.exprs.append(self.allocator, right);
            left = .{
                .expr_type = .binop,
                .op = .or_op,
                .left = &self.exprs.items[self.exprs.items.len - 2],
                .right = &self.exprs.items[self.exprs.items.len - 1],
            };
        }

        return left;
    }

    fn parseAnd(self: *Parser) !Expr {
        var left = try self.parseComparison();

        while (self.peek() == '&' and self.pos + 1 < self.src.len and self.src[self.pos + 1] == '&') {
            self.pos += 2;
            const right = try self.parseComparison();
            try self.exprs.append(self.allocator, left);
            try self.exprs.append(self.allocator, right);
            left = .{
                .expr_type = .binop,
                .op = .and_op,
                .left = &self.exprs.items[self.exprs.items.len - 2],
                .right = &self.exprs.items[self.exprs.items.len - 1],
            };
        }

        return left;
    }

    // String concatenation by juxtaposition. Precedence sits below comparison
    // and above additive, matching POSIX awk. Conservative operand detection:
    // only start a concat when the next token unambiguously begins a new
    // operand ($, ", identifier, number) — never `(`, `/`, `+`, `-`, so
    // arithmetic and regex parsing are unaffected.
    fn parseConcat(self: *Parser) error{OutOfMemory}!Expr {
        var left = try self.parseAddSub();
        while (true) {
            self.skipWhitespace();
            if (self.pos >= self.src.len) break;
            const c = self.src[self.pos];
            const starts_operand = c == '$' or c == '"' or c == '_' or c == '.' or
                (c >= '0' and c <= '9') or (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z');
            if (!starts_operand) break;
            // Don't swallow the `in` membership keyword as a concat operand.
            if (c == 'i' and self.pos + 1 < self.src.len and self.src[self.pos + 1] == 'n' and
                (self.pos + 2 >= self.src.len or !isIdentChar(self.src[self.pos + 2]))) break;
            const right = try self.parseAddSub();
            try self.exprs.append(self.allocator, left);
            try self.exprs.append(self.allocator, right);
            left = .{
                .expr_type = .concat,
                .left = &self.exprs.items[self.exprs.items.len - 2],
                .right = &self.exprs.items[self.exprs.items.len - 1],
            };
        }
        return left;
    }

    fn parseComparison(self: *Parser) !Expr {
        const left = try self.parseConcat();

        self.skipWhitespace();
        if (self.pos >= self.src.len) return left;

        var op: ?BinOp = null;
        if (self.src[self.pos] == '=' and self.pos + 1 < self.src.len and self.src[self.pos + 1] == '=') {
            op = .eq;
            self.pos += 2;
        } else if (self.src[self.pos] == '!' and self.pos + 1 < self.src.len and self.src[self.pos + 1] == '=') {
            op = .ne;
            self.pos += 2;
        } else if (self.src[self.pos] == '<' and self.pos + 1 < self.src.len and self.src[self.pos + 1] == '=') {
            op = .le;
            self.pos += 2;
        } else if (self.src[self.pos] == '>' and self.pos + 1 < self.src.len and self.src[self.pos + 1] == '=') {
            op = .ge;
            self.pos += 2;
        } else if (self.src[self.pos] == '<') {
            op = .lt;
            self.pos += 1;
        } else if (self.src[self.pos] == '>') {
            op = .gt;
            self.pos += 1;
        } else if (self.src[self.pos] == '~') {
            op = .match;
            self.pos += 1;
        } else if (self.src[self.pos] == '!' and self.pos + 1 < self.src.len and self.src[self.pos + 1] == '~') {
            op = .not_match;
            self.pos += 2;
        }

        if (op) |o| {
            const right = try self.parseConcat();
            try self.exprs.append(self.allocator, left);
            try self.exprs.append(self.allocator, right);
            return .{
                .expr_type = .binop,
                .op = o,
                .left = &self.exprs.items[self.exprs.items.len - 2],
                .right = &self.exprs.items[self.exprs.items.len - 1],
            };
        }

        return left;
    }

    fn parseAddSub(self: *Parser) !Expr {
        var left = try self.parseMulDiv();

        while (true) {
            self.skipWhitespace();
            if (self.pos >= self.src.len) break;

            var op: ?BinOp = null;
            if (self.src[self.pos] == '+') {
                op = .add;
            } else if (self.src[self.pos] == '-') {
                op = .sub;
            } else {
                break;
            }

            self.pos += 1;
            const right = try self.parseMulDiv();
            try self.exprs.append(self.allocator, left);
            try self.exprs.append(self.allocator, right);
            left = .{
                .expr_type = .binop,
                .op = op.?,
                .left = &self.exprs.items[self.exprs.items.len - 2],
                .right = &self.exprs.items[self.exprs.items.len - 1],
            };
        }

        return left;
    }

    fn parseMulDiv(self: *Parser) !Expr {
        var left = try self.parseUnary();

        while (true) {
            self.skipWhitespace();
            if (self.pos >= self.src.len) break;

            var op: ?BinOp = null;
            if (self.src[self.pos] == '*') {
                op = .mul;
            } else if (self.src[self.pos] == '/') {
                op = .div;
            } else if (self.src[self.pos] == '%') {
                op = .mod;
            } else {
                break;
            }

            self.pos += 1;
            const right = try self.parseUnary();
            try self.exprs.append(self.allocator, left);
            try self.exprs.append(self.allocator, right);
            left = .{
                .expr_type = .binop,
                .op = op.?,
                .left = &self.exprs.items[self.exprs.items.len - 2],
                .right = &self.exprs.items[self.exprs.items.len - 1],
            };
        }

        return left;
    }

    fn parseUnary(self: *Parser) !Expr {
        self.skipWhitespace();
        if (self.pos >= self.src.len) return .{ .expr_type = .number_lit, .num_val = 0 };

        if (self.src[self.pos] == '-') {
            self.pos += 1;
            const operand = try self.parseUnary();
            // Negation is 0 - operand. Synthesize a real 0 literal on the left;
            // aliasing both sides to `operand` made -x evaluate to x-x == 0.
            try self.exprs.append(self.allocator, .{ .expr_type = .number_lit, .num_val = 0 });
            try self.exprs.append(self.allocator, operand);
            return .{
                .expr_type = .binop,
                .op = .sub,
                .left = &self.exprs.items[self.exprs.items.len - 2],
                .right = &self.exprs.items[self.exprs.items.len - 1],
            };
        }

        if (self.src[self.pos] == '+') {
            // Unary plus forces numeric conversion: 0 + operand.
            self.pos += 1;
            const operand = try self.parseUnary();
            try self.exprs.append(self.allocator, .{ .expr_type = .number_lit, .num_val = 0 });
            try self.exprs.append(self.allocator, operand);
            return .{
                .expr_type = .binop,
                .op = .add,
                .left = &self.exprs.items[self.exprs.items.len - 2],
                .right = &self.exprs.items[self.exprs.items.len - 1],
            };
        }

        return self.parsePrimary();
    }

    fn parsePrimary(self: *Parser) !Expr {
        self.skipWhitespace();
        if (self.pos >= self.src.len) return .{ .expr_type = .number_lit, .num_val = 0 };

        const c = self.src[self.pos];

        // Field reference $N
        if (c == '$') {
            self.pos += 1;
            self.skipWhitespace();

            // Check for simple numeric field like $1, $2
            if (self.pos < self.src.len and self.src[self.pos] >= '0' and self.src[self.pos] <= '9') {
                var num: usize = 0;
                while (self.pos < self.src.len and self.src[self.pos] >= '0' and self.src[self.pos] <= '9') {
                    num = num * 10 + (self.src[self.pos] - '0');
                    self.pos += 1;
                }
                return .{
                    .expr_type = .field,
                    .field_num = num,
                };
            }

            // Complex field expression like $(NF-1)
            const field_expr_val = try self.parsePrimary();
            try self.exprs.append(self.allocator, field_expr_val);
            return .{
                .expr_type = .field,
                .field_expr = &self.exprs.items[self.exprs.items.len - 1],
            };
        }

        // String literal
        if (c == '"') {
            self.pos += 1;
            const start = self.pos;
            while (self.pos < self.src.len and self.src[self.pos] != '"') {
                if (self.src[self.pos] == '\\' and self.pos + 1 < self.src.len) {
                    self.pos += 2;
                } else {
                    self.pos += 1;
                }
            }
            const str = self.src[start..self.pos];
            if (self.pos < self.src.len) self.pos += 1;
            return .{ .expr_type = .string_lit, .str_val = str };
        }

        // Regex literal
        if (c == '/') {
            self.pos += 1;
            const start = self.pos;
            while (self.pos < self.src.len and self.src[self.pos] != '/') {
                if (self.src[self.pos] == '\\' and self.pos + 1 < self.src.len) {
                    self.pos += 2;
                } else {
                    self.pos += 1;
                }
            }
            const pattern = self.src[start..self.pos];
            if (self.pos < self.src.len) self.pos += 1;
            return .{ .expr_type = .regex, .str_val = pattern };
        }

        // Number literal (with optional exponent, e.g. 1e30, 2.5E-3)
        if ((c >= '0' and c <= '9') or c == '.') {
            const start = self.pos;
            while (self.pos < self.src.len and
                ((self.src[self.pos] >= '0' and self.src[self.pos] <= '9') or self.src[self.pos] == '.'))
            {
                self.pos += 1;
            }
            // Exponent
            if (self.pos < self.src.len and (self.src[self.pos] == 'e' or self.src[self.pos] == 'E')) {
                var j = self.pos + 1;
                if (j < self.src.len and (self.src[j] == '+' or self.src[j] == '-')) j += 1;
                if (j < self.src.len and self.src[j] >= '0' and self.src[j] <= '9') {
                    while (j < self.src.len and self.src[j] >= '0' and self.src[j] <= '9') j += 1;
                    self.pos = j;
                }
            }
            return .{ .expr_type = .number_lit, .num_val = parseNumber(self.src[start..self.pos]) };
        }

        // Parenthesized expression
        if (c == '(') {
            self.pos += 1;
            const expr = try self.parseExpr();
            self.skipWhitespace();
            if (self.peek() == ')') self.pos += 1;
            return expr;
        }

        // Variable, function call, or array access
        if ((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_') {
            const start = self.pos;
            while (self.pos < self.src.len) {
                const ch = self.src[self.pos];
                if ((ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or
                    (ch >= '0' and ch <= '9') or ch == '_')
                {
                    self.pos += 1;
                } else {
                    break;
                }
            }
            const name = self.src[start..self.pos];

            // Check for function call
            self.skipWhitespace();
            if (self.peek() == '(') {
                self.pos += 1;
                const args = try self.parseArgList(')');
                if (self.peek() == ')') self.pos += 1;
                return .{
                    .expr_type = .call,
                    .name = name,
                    .args = args,
                };
            }

            // Check for array access: array[key]
            if (self.peek() == '[') {
                self.pos += 1;
                const index_expr = try self.parseExpr();
                self.skipWhitespace();
                if (self.peek() == ']') self.pos += 1;
                try self.exprs.append(self.allocator, index_expr);
                return .{
                    .expr_type = .array_access,
                    .name = name,
                    .left = &self.exprs.items[self.exprs.items.len - 1],
                };
            }

            return .{ .expr_type = .variable, .name = name };
        }

        // Unrecognized token. Advance past it so the caller's parse loops make
        // progress (never spin forever on malformed input) and record a syntax
        // error so we exit non-zero like GNU/POSIX awk instead of running a
        // half-parsed program.
        self.had_error = true;
        self.pos += 1;
        return .{ .expr_type = .number_lit, .num_val = 0 };
    }
};

fn evalExpr(state: *AwkState, expr: *const Expr) Value {
    switch (expr.expr_type) {
        .field => {
            // Simple numeric field $N
            if (expr.field_num > 0 or expr.field_expr == null) {
                return .{ .string = state.getField(expr.field_num) };
            }
            // Computed field $(expr)
            if (expr.field_expr) |fe| {
                const n = evalExpr(state, fe).asNumber();
                // Clamp before @intFromFloat: a huge/non-finite index otherwise
                // panics ("integer part out of bounds") and aborts the process.
                const fnum: usize = @intCast(@min(clampU64(n), @as(u64, MAX_FIELDS)));
                return .{ .string = state.getField(fnum) };
            }
            return .{ .string = state.line };
        },
        .variable => return state.getVariable(expr.name),
        .string_lit => return .{ .string = expr.str_val },
        .number_lit => return .{ .number = expr.num_val },
        .concat => {
            const l = if (expr.left) |x| evalExpr(state, x) else Value.uninitialized;
            const r = if (expr.right) |x| evalExpr(state, x) else Value.uninitialized;
            const ls = l.asString(state.allocator) catch "";
            const rs = r.asString(state.allocator) catch "";
            const buf = state.allocator.alloc(u8, ls.len + rs.len) catch return .{ .string = "" };
            @memcpy(buf[0..ls.len], ls);
            @memcpy(buf[ls.len..], rs);
            return .{ .string = buf };
        },
        .regex => {
            // Regex against $0
            if (matchSimplePattern(expr.str_val, state.line)) {
                return .{ .number = 1 };
            }
            return .{ .number = 0 };
        },
        .binop => {
            const left_val = if (expr.left) |l| evalExpr(state, l) else Value.uninitialized;
            const right_val = if (expr.right) |r| evalExpr(state, r) else Value.uninitialized;

            switch (expr.op) {
                .add => return .{ .number = left_val.asNumber() + right_val.asNumber() },
                .sub => return .{ .number = left_val.asNumber() - right_val.asNumber() },
                .mul => return .{ .number = left_val.asNumber() * right_val.asNumber() },
                .div => {
                    const r = right_val.asNumber();
                    if (r == 0) return .{ .number = 0 };
                    return .{ .number = left_val.asNumber() / r };
                },
                .mod => {
                    const r = right_val.asNumber();
                    if (r == 0) return .{ .number = 0 };
                    return .{ .number = @mod(left_val.asNumber(), r) };
                },
                .eq => {
                    if (left_val == .string or right_val == .string) {
                        const ls = left_val.asString(state.allocator) catch "";
                        const rs = right_val.asString(state.allocator) catch "";
                        return .{ .number = if (std.mem.eql(u8, ls, rs)) 1 else 0 };
                    }
                    return .{ .number = if (left_val.asNumber() == right_val.asNumber()) 1 else 0 };
                },
                .ne => {
                    if (left_val == .string or right_val == .string) {
                        const ls = left_val.asString(state.allocator) catch "";
                        const rs = right_val.asString(state.allocator) catch "";
                        return .{ .number = if (!std.mem.eql(u8, ls, rs)) 1 else 0 };
                    }
                    return .{ .number = if (left_val.asNumber() != right_val.asNumber()) 1 else 0 };
                },
                .lt => return .{ .number = if (left_val.asNumber() < right_val.asNumber()) 1 else 0 },
                .le => return .{ .number = if (left_val.asNumber() <= right_val.asNumber()) 1 else 0 },
                .gt => return .{ .number = if (left_val.asNumber() > right_val.asNumber()) 1 else 0 },
                .ge => return .{ .number = if (left_val.asNumber() >= right_val.asNumber()) 1 else 0 },
                .match => {
                    const text = left_val.asString(state.allocator) catch "";
                    const pattern = if (expr.right) |r| r.str_val else "";
                    return .{ .number = if (matchSimplePattern(pattern, text)) 1 else 0 };
                },
                .not_match => {
                    const text = left_val.asString(state.allocator) catch "";
                    const pattern = if (expr.right) |r| r.str_val else "";
                    return .{ .number = if (!matchSimplePattern(pattern, text)) 1 else 0 };
                },
                .and_op => return .{ .number = if (left_val.asBool() and right_val.asBool()) 1 else 0 },
                .or_op => return .{ .number = if (left_val.asBool() or right_val.asBool()) 1 else 0 },
            }
        },
        .call => return evalCall(state, expr.name, expr.args),
        .array_access => {
            // array[key] - get value from associative array
            if (expr.left) |key_expr| {
                const key = evalExpr(state, key_expr).asString(state.allocator) catch "";
                return state.getArrayElement(expr.name, key);
            }
            return .uninitialized;
        },
        .in_array => {
            // key in array - check if key exists in array
            if (expr.left) |key_expr| {
                const key = evalExpr(state, key_expr).asString(state.allocator) catch "";
                return .{ .number = if (state.arrayContains(expr.name, key)) 1 else 0 };
            }
            return .{ .number = 0 };
        },
        else => return .uninitialized,
    }
}

// For a regex-position argument, use the literal pattern if it's a /re/ token;
// otherwise evaluate it as a (dynamic) string pattern.
fn regexArg(state: *AwkState, expr: *const Expr) []const u8 {
    if (expr.expr_type == .regex) return expr.str_val;
    return evalExpr(state, expr).asString(state.allocator) catch "";
}

// Expand an awk sub/gsub replacement string: `&` -> matched text,
// `\&` -> literal '&', `\\` -> literal '\'.
fn expandReplacement(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), repl: []const u8, matched: []const u8) void {
    var i: usize = 0;
    while (i < repl.len) : (i += 1) {
        const c = repl[i];
        if (c == '\\' and i + 1 < repl.len) {
            const nxt = repl[i + 1];
            if (nxt == '&' or nxt == '\\') {
                out.append(allocator, nxt) catch {};
                i += 1;
                continue;
            }
            out.append(allocator, '\\') catch {};
        } else if (c == '&') {
            out.appendSlice(allocator, matched) catch {};
        } else {
            out.append(allocator, c) catch {};
        }
    }
}

// Write `value` back to an lvalue expression (used by sub/gsub target).
fn assignStringToLvalue(state: *AwkState, target: *const Expr, value: []const u8) void {
    switch (target.expr_type) {
        .field => {
            var n = target.field_num;
            if (n == 0 and target.field_expr != null) {
                const fv = evalExpr(state, target.field_expr.?).asNumber();
                n = @intCast(@min(clampU64(fv), @as(u64, MAX_FIELDS)));
            }
            state.setField(n, value);
        },
        .variable => {
            const owned = state.allocator.dupe(u8, value) catch return;
            state.setVariable(target.name, .{ .string = owned }) catch {};
        },
        .array_access => {
            if (target.left) |key_expr| {
                const key = evalExpr(state, key_expr).asString(state.allocator) catch "";
                const owned = state.allocator.dupe(u8, value) catch return;
                state.setArrayElement(target.name, key, .{ .string = owned }) catch {};
            }
        },
        else => {},
    }
}

fn evalCall(state: *AwkState, name: []const u8, args: []Expr) Value {
    if (std.mem.eql(u8, name, "length")) {
        if (args.len > 0) {
            const s = evalExpr(state, &args[0]).asString(state.allocator) catch "";
            return .{ .number = @floatFromInt(s.len) };
        }
        return .{ .number = @floatFromInt(state.line.len) };
    }
    if (std.mem.eql(u8, name, "substr")) {
        if (args.len >= 2) {
            const s = evalExpr(state, &args[0]).asString(state.allocator) catch "";
            const start_f = evalExpr(state, &args[1]).asNumber();
            // Saturate to 0..s.len before @intFromFloat: a huge/non-finite arg
            // otherwise panics and aborts. awk clamps such args to the string.
            const start: usize = if (start_f < 1) 0 else @intCast(@min(clampU64(start_f - 1), @as(u64, s.len)));
            if (start >= s.len) return .{ .string = "" };

            if (args.len >= 3) {
                const len_f = evalExpr(state, &args[2]).asNumber();
                const len: usize = @intCast(@min(clampU64(len_f), @as(u64, s.len)));
                const end = @min(start + len, s.len);
                return .{ .string = s[start..end] };
            }
            return .{ .string = s[start..] };
        }
        return .{ .string = "" };
    }
    if (std.mem.eql(u8, name, "index")) {
        if (args.len >= 2) {
            const s = evalExpr(state, &args[0]).asString(state.allocator) catch "";
            const needle = evalExpr(state, &args[1]).asString(state.allocator) catch "";
            if (std.mem.indexOf(u8, s, needle)) |idx| {
                return .{ .number = @floatFromInt(idx + 1) };
            }
            return .{ .number = 0 };
        }
        return .{ .number = 0 };
    }
    if (std.mem.eql(u8, name, "int")) {
        if (args.len > 0) {
            const n = evalExpr(state, &args[0]).asNumber();
            return .{ .number = @trunc(n) };
        }
        return .{ .number = 0 };
    }
    if (std.mem.eql(u8, name, "sqrt")) {
        if (args.len > 0) {
            const n = evalExpr(state, &args[0]).asNumber();
            return .{ .number = @sqrt(@max(0, n)) };
        }
        return .{ .number = 0 };
    }
    if (std.mem.eql(u8, name, "tolower") or std.mem.eql(u8, name, "toupper")) {
        if (args.len > 0) {
            const s = evalExpr(state, &args[0]).asString(state.allocator) catch "";
            var result = state.allocator.alloc(u8, s.len) catch return .{ .string = s };
            for (s, 0..) |c, i| {
                result[i] = if (std.mem.eql(u8, name, "tolower"))
                    std.ascii.toLower(c)
                else
                    std.ascii.toUpper(c);
            }
            return .{ .string = result };
        }
        return .{ .string = "" };
    }
    if (std.mem.eql(u8, name, "sprintf")) {
        // sprintf(fmt, args...) — honor the format string, same engine as printf.
        if (args.len == 0) return .{ .string = "" };
        const fmt = evalExpr(state, &args[0]).asString(state.allocator) catch "";
        return .{ .string = formatPrintf(state, fmt, args[1..]) };
    }
    if (std.mem.eql(u8, name, "split")) {
        // split(string, array, [sep])
        // Returns number of elements, fills array
        if (args.len >= 2) {
            const s = evalExpr(state, &args[0]).asString(state.allocator) catch "";
            const arr_name = args[1].name;
            const sep = if (args.len >= 3)
                evalExpr(state, &args[2]).asString(state.allocator) catch " "
            else
                state.fs;

            // Get or create the array
            const arr = state.getOrCreateArray(arr_name) catch return .{ .number = 0 };

            // Clear existing array
            arr.data.clearRetainingCapacity();

            var field_count: usize = 0;
            if (sep.len == 1 and sep[0] == ' ') {
                // Default: split on runs of whitespace
                var i: usize = 0;
                while (i < s.len) {
                    while (i < s.len and (s[i] == ' ' or s[i] == '\t')) i += 1;
                    if (i >= s.len) break;
                    const start = i;
                    while (i < s.len and s[i] != ' ' and s[i] != '\t') i += 1;

                    field_count += 1;
                    var idx_buf: [16]u8 = undefined;
                    const idx_len = formatInt(&idx_buf, @intCast(field_count));
                    arr.put(state.allocator, idx_buf[0..idx_len], .{ .string = s[start..i] }) catch {};
                }
            } else if (sep.len == 1) {
                const sep_char = sep[0];
                var start: usize = 0;
                var i: usize = 0;
                while (i <= s.len) {
                    if (i == s.len or s[i] == sep_char) {
                        field_count += 1;
                        var idx_buf: [16]u8 = undefined;
                        const idx_len = formatInt(&idx_buf, @intCast(field_count));
                        arr.put(state.allocator, idx_buf[0..idx_len], .{ .string = s[start..i] }) catch {};
                        start = i + 1;
                    }
                    i += 1;
                }
            } else if (sep.len > 0) {
                var start: usize = 0;
                var i: usize = 0;
                while (i + sep.len <= s.len) {
                    if (std.mem.eql(u8, s[i..][0..sep.len], sep)) {
                        field_count += 1;
                        var idx_buf: [16]u8 = undefined;
                        const idx_len = formatInt(&idx_buf, @intCast(field_count));
                        arr.put(state.allocator, idx_buf[0..idx_len], .{ .string = s[start..i] }) catch {};
                        start = i + sep.len;
                        i = start;
                    } else {
                        i += 1;
                    }
                }
                field_count += 1;
                var idx_buf: [16]u8 = undefined;
                const idx_len = formatInt(&idx_buf, @intCast(field_count));
                arr.put(state.allocator, idx_buf[0..idx_len], .{ .string = s[start..] }) catch {};
            }

            return .{ .number = @floatFromInt(field_count) };
        }
        return .{ .number = 0 };
    }
    if (std.mem.eql(u8, name, "sub") or std.mem.eql(u8, name, "gsub")) {
        // sub/gsub(regexp, replacement, [target]) — replace first / all ERE
        // matches, WRITE THE RESULT BACK to the target lvalue (default $0),
        // and return the replacement count.
        const global = name[0] == 'g';
        if (args.len < 2) return .{ .number = 0 };
        const pattern = regexArg(state, &args[0]);
        const repl = evalExpr(state, &args[1]).asString(state.allocator) catch "";
        const target = if (args.len >= 3) blk: {
            break :blk evalExpr(state, &args[2]).asString(state.allocator) catch "";
        } else state.line;
        // Own the target bytes: writeback replaces state.line and would
        // otherwise alias while we read from it.
        const src = state.allocator.dupe(u8, target) catch return .{ .number = 0 };

        var result: std.ArrayListUnmanaged(u8) = .empty;
        var count: f64 = 0;
        var i: usize = 0;
        while (i <= src.len) {
            const m = regexFind(state.allocator, pattern, src, i) orelse {
                result.appendSlice(state.allocator, src[i..]) catch {};
                break;
            };
            result.appendSlice(state.allocator, src[i..m.begin]) catch {};
            expandReplacement(state.allocator, &result, repl, src[m.begin..m.end]);
            count += 1;
            if (m.end == m.begin) {
                // Empty match: emit one char and advance to avoid looping.
                if (m.begin < src.len) result.append(state.allocator, src[m.begin]) catch {};
                i = m.begin + 1;
            } else {
                i = m.end;
            }
            if (!global) {
                result.appendSlice(state.allocator, src[i..]) catch {};
                break;
            }
        }

        if (count > 0) {
            if (args.len >= 3) {
                assignStringToLvalue(state, &args[2], result.items);
            } else {
                assignStringToLvalue(state, &.{ .expr_type = .field, .field_num = 0 }, result.items);
            }
        }
        return .{ .number = count };
    }
    if (std.mem.eql(u8, name, "match")) {
        // match(string, regexp) — leftmost-longest ERE match. Sets RSTART and
        // RLENGTH; returns the 1-based start position (0 if no match).
        if (args.len >= 2) {
            const s = evalExpr(state, &args[0]).asString(state.allocator) catch "";
            const pattern = regexArg(state, &args[1]);
            if (regexFind(state.allocator, pattern, s, 0)) |m| {
                state.setVariable("RSTART", .{ .number = @floatFromInt(m.begin + 1) }) catch {};
                state.setVariable("RLENGTH", .{ .number = @floatFromInt(m.end - m.begin) }) catch {};
                return .{ .number = @floatFromInt(m.begin + 1) };
            }
            state.setVariable("RSTART", .{ .number = 0 }) catch {};
            state.setVariable("RLENGTH", .{ .number = -1 }) catch {};
            return .{ .number = 0 };
        }
        return .{ .number = 0 };
    }
    if (std.mem.eql(u8, name, "sin")) {
        if (args.len > 0) {
            const n = evalExpr(state, &args[0]).asNumber();
            return .{ .number = @sin(n) };
        }
        return .{ .number = 0 };
    }
    if (std.mem.eql(u8, name, "cos")) {
        if (args.len > 0) {
            const n = evalExpr(state, &args[0]).asNumber();
            return .{ .number = @cos(n) };
        }
        return .{ .number = 0 };
    }
    if (std.mem.eql(u8, name, "exp")) {
        if (args.len > 0) {
            const n = evalExpr(state, &args[0]).asNumber();
            return .{ .number = @exp(n) };
        }
        return .{ .number = 0 };
    }
    if (std.mem.eql(u8, name, "log")) {
        if (args.len > 0) {
            const n = evalExpr(state, &args[0]).asNumber();
            if (n > 0) return .{ .number = @log(n) };
        }
        return .{ .number = 0 };
    }

    return .uninitialized;
}

// ---------------------------------------------------------------------------
// POSIX ERE engine (Thompson NFA). Linear-time simulation — no catastrophic
// backtracking, so untrusted patterns cannot wedge the process. Supports
// ^ $ . * + ? [ ] ( ) | and backslash escapes. Anchored to /usr/bin/awk's
// libc regex behavior (see gnu_parity_test.zig).
// ---------------------------------------------------------------------------
const RxKind = enum { consume, split, jmp, bol, eol, match };
const RxState = struct {
    kind: RxKind,
    set: std.StaticBitSet(256) = std.StaticBitSet(256).initEmpty(),
    out: u32 = 0,
    out2: u32 = 0,
};
const RxPatch = struct { state: u32, slot: u1 };

const Regex = struct {
    states: []RxState,
    start: u32,
    ok: bool,

    fn matches(self: *const Regex, text: []const u8) bool {
        return self.search(text, 0) != null;
    }

    // Leftmost-longest search at or after `from`. Returns {begin, end}.
    fn search(self: *const Regex, text: []const u8, from: usize) ?struct { begin: usize, end: usize } {
        if (!self.ok) return null;
        var begin = from;
        while (begin <= text.len) : (begin += 1) {
            if (self.runAt(text, begin)) |end| {
                return .{ .begin = begin, .end = end };
            }
        }
        return null;
    }

    // Anchored NFA simulation from `begin`; returns the longest end position
    // reachable in a match state, or null.
    fn runAt(self: *const Regex, text: []const u8, begin: usize) ?usize {
        var clist_buf: [1024]u32 = undefined;
        var nlist_buf: [1024]u32 = undefined;
        var seen = std.StaticBitSet(4096).initEmpty();
        var best: ?usize = null;

        const n = self.closureAppend(clist_buf[0..], 0, &seen, self.start, text, begin);
        var clist: []u32 = clist_buf[0..n];
        if (self.listHasMatch(clist)) best = begin;

        var pos = begin;
        while (pos < text.len and clist.len > 0) {
            const c = text[pos];
            var cnt: usize = 0;
            seen = std.StaticBitSet(4096).initEmpty();
            for (clist) |si| {
                const st = self.states[si];
                if (st.kind == .consume and st.set.isSet(c)) {
                    cnt = self.closureAppend(nlist_buf[0..], cnt, &seen, st.out, text, pos + 1);
                }
            }
            pos += 1;
            @memcpy(clist_buf[0..cnt], nlist_buf[0..cnt]);
            clist = clist_buf[0..cnt];
            if (self.listHasMatch(clist)) best = pos;
        }
        return best;
    }

    fn listHasMatch(self: *const Regex, list: []const u32) bool {
        for (list) |si| {
            if (self.states[si].kind == .match) return true;
        }
        return false;
    }

    fn closure(self: *const Regex, out_buf: []u32, seen: *std.StaticBitSet(4096), start_state: u32, text: []const u8, pos: usize) usize {
        return self.closureAppend(out_buf, 0, seen, start_state, text, pos);
    }

    // Epsilon-closure of `s` added to out_buf starting at index `count`.
    fn closureAppend(self: *const Regex, out_buf: []u32, count_in: usize, seen: *std.StaticBitSet(4096), s: u32, text: []const u8, pos: usize) usize {
        var count = count_in;
        if (s >= self.states.len or seen.isSet(s)) return count;
        seen.set(s);
        const st = self.states[s];
        switch (st.kind) {
            .split => {
                count = self.closureAppend(out_buf, count, seen, st.out, text, pos);
                count = self.closureAppend(out_buf, count, seen, st.out2, text, pos);
            },
            .jmp => {
                count = self.closureAppend(out_buf, count, seen, st.out, text, pos);
            },
            .bol => {
                if (pos == 0) count = self.closureAppend(out_buf, count, seen, st.out, text, pos);
            },
            .eol => {
                if (pos == text.len) count = self.closureAppend(out_buf, count, seen, st.out, text, pos);
            },
            .consume, .match => {
                if (count < out_buf.len) {
                    out_buf[count] = s;
                    count += 1;
                }
            },
        }
        return count;
    }
};

// Regex compiler: recursive descent building a Thompson NFA.
const RxCompiler = struct {
    pattern: []const u8,
    pos: usize = 0,
    states: std.ArrayListUnmanaged(RxState),
    allocator: std.mem.Allocator,
    failed: bool = false,

    const Frag = struct { start: u32, outs: std.ArrayListUnmanaged(RxPatch) };

    fn addState(self: *RxCompiler, st: RxState) u32 {
        const idx: u32 = @intCast(self.states.items.len);
        self.states.appendAssumeCapacity(st);
        return idx;
    }

    fn patch(self: *RxCompiler, outs: []const RxPatch, target: u32) void {
        for (outs) |p| {
            if (p.slot == 0) self.states.items[p.state].out = target else self.states.items[p.state].out2 = target;
        }
    }

    fn parseAlt(self: *RxCompiler) error{OutOfMemory}!Frag {
        var frag = try self.parseConcat();
        while (self.pos < self.pattern.len and self.pattern[self.pos] == '|') {
            self.pos += 1;
            const rhs = try self.parseConcat();
            const s = self.addState(.{ .kind = .split, .out = frag.start, .out2 = rhs.start });
            var outs: std.ArrayListUnmanaged(RxPatch) = .empty;
            try outs.appendSlice(self.allocator, frag.outs.items);
            try outs.appendSlice(self.allocator, rhs.outs.items);
            frag = .{ .start = s, .outs = outs };
        }
        return frag;
    }

    fn parseConcat(self: *RxCompiler) error{OutOfMemory}!Frag {
        var frag: ?Frag = null;
        while (self.pos < self.pattern.len and self.pattern[self.pos] != '|' and self.pattern[self.pos] != ')') {
            const r = try self.parseRepeat();
            if (frag) |*f| {
                self.patch(f.outs.items, r.start);
                f.outs.deinit(self.allocator);
                f.outs = r.outs;
            } else {
                frag = r;
            }
        }
        if (frag) |f| return f;
        // Empty: an epsilon jmp with a dangling out.
        const s = self.addState(.{ .kind = .jmp });
        var outs: std.ArrayListUnmanaged(RxPatch) = .empty;
        try outs.append(self.allocator, .{ .state = s, .slot = 0 });
        return .{ .start = s, .outs = outs };
    }

    fn parseRepeat(self: *RxCompiler) error{OutOfMemory}!Frag {
        var atom = try self.parseAtom();
        while (self.pos < self.pattern.len) {
            const c = self.pattern[self.pos];
            if (c == '*') {
                self.pos += 1;
                const s = self.addState(.{ .kind = .split, .out = atom.start });
                self.patch(atom.outs.items, s);
                atom.outs.deinit(self.allocator);
                var outs: std.ArrayListUnmanaged(RxPatch) = .empty;
                try outs.append(self.allocator, .{ .state = s, .slot = 1 });
                atom = .{ .start = s, .outs = outs };
            } else if (c == '+') {
                self.pos += 1;
                const s = self.addState(.{ .kind = .split, .out = atom.start });
                self.patch(atom.outs.items, s);
                atom.outs.deinit(self.allocator);
                var outs: std.ArrayListUnmanaged(RxPatch) = .empty;
                try outs.append(self.allocator, .{ .state = s, .slot = 1 });
                atom = .{ .start = atom.start, .outs = outs };
            } else if (c == '?') {
                self.pos += 1;
                const s = self.addState(.{ .kind = .split, .out = atom.start });
                var outs: std.ArrayListUnmanaged(RxPatch) = .empty;
                try outs.appendSlice(self.allocator, atom.outs.items);
                try outs.append(self.allocator, .{ .state = s, .slot = 1 });
                atom.outs.deinit(self.allocator);
                atom = .{ .start = s, .outs = outs };
            } else break;
        }
        return atom;
    }

    fn singleOut(self: *RxCompiler, st: RxState) error{OutOfMemory}!Frag {
        const idx = self.addState(st);
        var outs: std.ArrayListUnmanaged(RxPatch) = .empty;
        try outs.append(self.allocator, .{ .state = idx, .slot = 0 });
        return .{ .start = idx, .outs = outs };
    }

    fn parseAtom(self: *RxCompiler) error{OutOfMemory}!Frag {
        const c = self.pattern[self.pos];
        if (c == '(') {
            self.pos += 1;
            const inner = try self.parseAlt();
            if (self.pos < self.pattern.len and self.pattern[self.pos] == ')') self.pos += 1 else self.failed = true;
            return inner;
        }
        if (c == '[') {
            return self.parseClass();
        }
        if (c == '.') {
            self.pos += 1;
            var set = std.StaticBitSet(256).initEmpty();
            set = set.complement(); // any byte
            return self.singleOut(.{ .kind = .consume, .set = set });
        }
        if (c == '^') {
            self.pos += 1;
            return self.singleOut(.{ .kind = .bol });
        }
        if (c == '$') {
            self.pos += 1;
            return self.singleOut(.{ .kind = .eol });
        }
        var ch = c;
        if (c == '\\' and self.pos + 1 < self.pattern.len) {
            self.pos += 1;
            ch = switch (self.pattern[self.pos]) {
                't' => '\t',
                'n' => '\n',
                'r' => '\r',
                'f' => 12,
                'v' => 11,
                else => |x| x,
            };
        }
        self.pos += 1;
        var set = std.StaticBitSet(256).initEmpty();
        set.set(ch);
        return self.singleOut(.{ .kind = .consume, .set = set });
    }

    fn parseClass(self: *RxCompiler) error{OutOfMemory}!Frag {
        self.pos += 1; // consume '['
        var set = std.StaticBitSet(256).initEmpty();
        var negate = false;
        if (self.pos < self.pattern.len and self.pattern[self.pos] == '^') {
            negate = true;
            self.pos += 1;
        }
        // A leading ']' is a literal.
        var first = true;
        while (self.pos < self.pattern.len and (self.pattern[self.pos] != ']' or first)) {
            first = false;
            var lo = self.pattern[self.pos];
            if (lo == '\\' and self.pos + 1 < self.pattern.len) {
                self.pos += 1;
                lo = switch (self.pattern[self.pos]) {
                    't' => '\t',
                    'n' => '\n',
                    'r' => '\r',
                    else => |x| x,
                };
            }
            self.pos += 1;
            // Range a-z
            if (self.pos + 1 < self.pattern.len and self.pattern[self.pos] == '-' and self.pattern[self.pos + 1] != ']') {
                self.pos += 1;
                var hi = self.pattern[self.pos];
                if (hi == '\\' and self.pos + 1 < self.pattern.len) {
                    self.pos += 1;
                    hi = self.pattern[self.pos];
                }
                self.pos += 1;
                var x: usize = lo;
                while (x <= hi) : (x += 1) set.set(x);
            } else {
                set.set(lo);
            }
        }
        if (self.pos < self.pattern.len and self.pattern[self.pos] == ']') self.pos += 1 else self.failed = true;
        if (negate) set = set.complement();
        return self.singleOut(.{ .kind = .consume, .set = set });
    }
};

// Compile a pattern into a Regex owned by `allocator`. On failure returns a
// Regex with ok=false; callers fall back to literal substring matching.
fn compileRegex(allocator: std.mem.Allocator, pattern: []const u8) Regex {
    var states: std.ArrayListUnmanaged(RxState) = .empty;
    // Each atom adds at most ~2 states; reserve generously (plus 1 for the
    // final match state) so appends never realloc — state indices must stay
    // stable during compilation.
    states.ensureTotalCapacity(allocator, pattern.len * 4 + 16) catch {
        return .{ .states = &[_]RxState{}, .start = 0, .ok = false };
    };
    const reserved = states.capacity;
    var comp = RxCompiler{ .pattern = pattern, .states = states, .allocator = allocator };
    var frag = comp.parseAlt() catch {
        return .{ .states = comp.states.items, .start = 0, .ok = false };
    };
    if (comp.pos != pattern.len or comp.failed or comp.states.capacity != reserved or
        comp.states.items.len >= reserved)
    {
        frag.outs.deinit(allocator);
        return .{ .states = comp.states.items, .start = 0, .ok = false };
    }
    const match_state: u32 = @intCast(comp.states.items.len);
    comp.states.appendAssumeCapacity(.{ .kind = .match });
    comp.patch(frag.outs.items, match_state);
    frag.outs.deinit(allocator);
    return .{ .states = comp.states.items, .start = frag.start, .ok = true };
}

// Match `pattern` (ERE) anywhere in `text`. Falls back to literal substring
// search only if the pattern fails to compile.
fn matchSimplePattern(pattern: []const u8, text: []const u8) bool {
    if (pattern.len == 0) return true;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const re = compileRegex(arena.allocator(), pattern);
    if (re.ok) return re.matches(text);
    return std.mem.indexOf(u8, text, pattern) != null;
}

// Find the leftmost-longest ERE match of `pattern` in `text` at/after `from`.
fn regexFind(allocator: std.mem.Allocator, pattern: []const u8, text: []const u8, from: usize) ?struct { begin: usize, end: usize } {
    // Compile into a per-call arena freed on return; the result is just byte
    // indices, so nothing outlives the arena. sub/gsub/match run per record —
    // compiling into the long-lived gpa leaked the NFA on every call.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const re = compileRegex(arena.allocator(), pattern);
    if (re.ok) {
        if (re.search(text, from)) |m| return .{ .begin = m.begin, .end = m.end };
        return null;
    }
    // Literal fallback.
    if (std.mem.indexOfPos(u8, text, from, pattern)) |idx| {
        return .{ .begin = idx, .end = idx + pattern.len };
    }
    return null;
}

fn execAction(state: *AwkState, action: *const Action) void {
    switch (action.action_type) {
        .print => {
            state.output.write(state.line);
            state.output.write(state.ors);
        },
        .print_expr => {
            var first = true;
            for (action.exprs) |*expr| {
                if (!first) state.output.write(state.ofs);
                first = false;
                const val = evalExpr(state, expr);
                const s = val.asString(state.allocator) catch "";
                state.output.write(s);
            }
            state.output.write(state.ors);
        },
        .printf_stmt => {
            // printf format, args...
            if (action.exprs.len > 0) {
                const format_val = evalExpr(state, &action.exprs[0]);
                const format = format_val.asString(state.allocator) catch "";
                const result = formatPrintf(state, format, action.exprs[1..]);
                state.output.write(result);
            }
        },
        .assign => {
            if (action.exprs.len > 0) {
                const val = evalExpr(state, &action.exprs[0]);
                state.setVariable(action.var_name, val) catch {};
            }
        },
        .field_assign => {
            // $N = value — condition holds the field lvalue expr.
            if (action.exprs.len > 0 and action.condition != null) {
                const v = evalExpr(state, &action.exprs[0]);
                const s = v.asString(state.allocator) catch "";
                assignStringToLvalue(state, action.condition.?, s);
            }
        },
        .array_assign => {
            // array[key] = value
            // exprs[0] = key, exprs[1] = value (or exprs[3] = combined value for compound)
            if (action.exprs.len >= 2) {
                const key = evalExpr(state, &action.exprs[0]).asString(state.allocator) catch "";
                const val_idx: usize = if (action.exprs.len >= 4) 3 else 1;
                const val = evalExpr(state, &action.exprs[val_idx]);
                state.setArrayElement(action.var_name, key, val) catch {};
            }
        },
        .delete_stmt => {
            // delete array[key]
            if (action.exprs.len > 0) {
                const expr = &action.exprs[0];
                if (expr.expr_type == .array_access) {
                    if (expr.left) |key_expr| {
                        const key = evalExpr(state, key_expr).asString(state.allocator) catch "";
                        state.deleteArrayElement(expr.name, key);
                    }
                }
            }
        },
        .for_in_stmt => {
            // for (key in array) { body }
            // var_name = key variable, exprs[0] = array name expr
            if (action.exprs.len > 0) {
                const arr_name = action.exprs[0].name;
                if (state.arrays.get(arr_name)) |arr| {
                    var it = arr.data.iterator();
                    while (it.next()) |entry| {
                        if (state.should_next or state.should_exit) break;
                        // Set key variable
                        state.setVariable(action.var_name, .{ .string = entry.key_ptr.* }) catch {};
                        // Execute body
                        execActions(state, action.body);
                    }
                }
            }
        },
        .next => {
            state.should_next = true;
        },
        .exit => {
            if (action.condition) |code_expr| {
                const n = evalExpr(state, code_expr).asNumber();
                state.exit_code = @intCast(@mod(clampI64(n), 256));
            }
            state.should_exit = true;
        },
        .expr_stmt => {
            // Just evaluate for side effects
            if (action.exprs.len > 0) {
                _ = evalExpr(state, &action.exprs[0]);
            }
        },
        else => {},
    }
}

// Printf format string implementation
fn formatPrintf(state: *AwkState, format: []const u8, args: []const Expr) []const u8 {
    var result: std.ArrayListUnmanaged(u8) = .empty;
    var arg_idx: usize = 0;
    var i: usize = 0;

    while (i < format.len) {
        if (format[i] == '%' and i + 1 < format.len) {
            i += 1;

            // Handle %%
            if (format[i] == '%') {
                result.append(state.allocator, '%') catch {};
                i += 1;
                continue;
            }

            // Parse flags
            var left_align = false;
            var zero_pad = false;
            while (i < format.len) {
                if (format[i] == '-') {
                    left_align = true;
                    i += 1;
                } else if (format[i] == '0') {
                    zero_pad = true;
                    i += 1;
                } else if (format[i] == '+' or format[i] == ' ' or format[i] == '#') {
                    i += 1;
                } else {
                    break;
                }
            }

            // Parse width
            var width: usize = 0;
            while (i < format.len and format[i] >= '0' and format[i] <= '9') {
                width = width * 10 + (format[i] - '0');
                i += 1;
            }

            // Parse precision
            var precision: usize = 6;
            var has_precision = false;
            if (i < format.len and format[i] == '.') {
                i += 1;
                has_precision = true;
                precision = 0;
                while (i < format.len and format[i] >= '0' and format[i] <= '9') {
                    precision = precision * 10 + (format[i] - '0');
                    i += 1;
                }
            }

            // Parse specifier
            if (i < format.len) {
                const spec = format[i];
                i += 1;

                // Get argument value
                const val = if (arg_idx < args.len) evalExpr(state, &args[arg_idx]) else Value.uninitialized;
                arg_idx += 1;

                var buf: [512]u8 = undefined;
                var formatted: []const u8 = "";

                switch (spec) {
                    'd', 'i' => {
                        const n: i64 = clampI64(val.asNumber());
                        const len = formatInt(&buf, n);
                        formatted = buf[0..len];
                    },
                    'u' => {
                        const n: u64 = clampU64(val.asNumber());
                        var tmp_len: usize = buf.len;
                        if (n == 0) {
                            buf[0] = '0';
                            tmp_len = 1;
                        } else {
                            var m = n;
                            var tmp_i: usize = buf.len;
                            while (m > 0) {
                                tmp_i -= 1;
                                buf[tmp_i] = @intCast('0' + @as(u8, @intCast(m % 10)));
                                m /= 10;
                            }
                            tmp_len = buf.len - tmp_i;
                            std.mem.copyForwards(u8, buf[0..tmp_len], buf[tmp_i..]);
                        }
                        formatted = buf[0..tmp_len];
                    },
                    'x', 'X' => {
                        const n: u64 = clampU64(val.asNumber());
                        const hex_chars = if (spec == 'x') "0123456789abcdef" else "0123456789ABCDEF";
                        if (n == 0) {
                            buf[0] = '0';
                            formatted = buf[0..1];
                        } else {
                            var m = n;
                            var tmp_i: usize = buf.len;
                            while (m > 0) {
                                tmp_i -= 1;
                                buf[tmp_i] = hex_chars[@intCast(m & 0xf)];
                                m >>= 4;
                            }
                            const tmp_len = buf.len - tmp_i;
                            std.mem.copyForwards(u8, buf[0..tmp_len], buf[tmp_i..]);
                            formatted = buf[0..tmp_len];
                        }
                    },
                    'o' => {
                        const n: u64 = clampU64(val.asNumber());
                        if (n == 0) {
                            buf[0] = '0';
                            formatted = buf[0..1];
                        } else {
                            var m = n;
                            var tmp_i: usize = buf.len;
                            while (m > 0) {
                                tmp_i -= 1;
                                buf[tmp_i] = @intCast('0' + @as(u8, @intCast(m & 0x7)));
                                m >>= 3;
                            }
                            const tmp_len = buf.len - tmp_i;
                            std.mem.copyForwards(u8, buf[0..tmp_len], buf[tmp_i..]);
                            formatted = buf[0..tmp_len];
                        }
                    },
                    'f', 'F', 'e', 'E', 'g', 'G' => {
                        const n = val.asNumber();
                        const prec: usize = if (has_precision) precision else 6;
                        formatted = formatFloatC(&buf, spec, n, prec);
                    },
                    's' => {
                        formatted = val.asString(state.allocator) catch "";
                        if (has_precision and formatted.len > precision) {
                            formatted = formatted[0..precision];
                        }
                    },
                    'c' => {
                        // A numeric arg prints the character with that code;
                        // a string arg prints its first byte. (POSIX printf %c.)
                        switch (val) {
                            .number => |num| {
                                buf[0] = @intCast(@mod(clampI64(num), 256));
                                formatted = buf[0..1];
                            },
                            else => {
                                const s = val.asString(state.allocator) catch "";
                                if (s.len > 0) {
                                    buf[0] = s[0];
                                    formatted = buf[0..1];
                                } else {
                                    formatted = buf[0..0];
                                }
                            },
                        }
                    },
                    else => {},
                }

                // Apply width and padding
                if (width > 0 and formatted.len < width) {
                    const pad_char: u8 = if (zero_pad and !left_align) '0' else ' ';
                    const pad_len = width - formatted.len;
                    if (left_align) {
                        result.appendSlice(state.allocator, formatted) catch {};
                        var p: usize = 0;
                        while (p < pad_len) : (p += 1) {
                            result.append(state.allocator, ' ') catch {};
                        }
                    } else {
                        var p: usize = 0;
                        while (p < pad_len) : (p += 1) {
                            result.append(state.allocator, pad_char) catch {};
                        }
                        result.appendSlice(state.allocator, formatted) catch {};
                    }
                } else {
                    result.appendSlice(state.allocator, formatted) catch {};
                }
            }
        } else if (format[i] == '\\' and i + 1 < format.len) {
            // Handle escape sequences
            i += 1;
            switch (format[i]) {
                'n' => result.append(state.allocator, '\n') catch {},
                't' => result.append(state.allocator, '\t') catch {},
                'r' => result.append(state.allocator, '\r') catch {},
                '\\' => result.append(state.allocator, '\\') catch {},
                else => {
                    result.append(state.allocator, '\\') catch {};
                    result.append(state.allocator, format[i]) catch {};
                },
            }
            i += 1;
        } else {
            result.append(state.allocator, format[i]) catch {};
            i += 1;
        }
    }

    return result.items;
}

fn execActions(state: *AwkState, actions: []const Action) void {
    for (actions) |*action| {
        if (state.should_next or state.should_exit) break;
        execAction(state, action);
    }
}

fn patternMatches(state: *AwkState, pattern: ?*const Expr) bool {
    if (pattern == null) return true;
    return evalExpr(state, pattern.?).asBool();
}

const Config = struct {
    fs: []const u8 = " ",
    program: []const u8 = "",
    variables: std.ArrayListUnmanaged(struct { name: []const u8, value: []const u8 }) = .empty,
    files: std.ArrayListUnmanaged([]const u8) = .empty,

    fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        if (self.program.len > 0) allocator.free(self.program);
        self.variables.deinit(allocator);
        for (self.files.items) |item| {
            allocator.free(item);
        }
        self.files.deinit(allocator);
    }
};

fn readProgramFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    const fd = libc.open(path_z.ptr, .{ .ACCMODE = .RDONLY }, @as(libc.mode_t, 0));
    if (fd < 0) return error.OpenError;
    defer _ = libc.close(fd);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    var chunk: [64 * 1024]u8 = undefined;
    while (true) {
        const n = libc.read(fd, &chunk, chunk.len);
        if (n < 0) return error.ReadError;
        if (n == 0) break;
        try buf.appendSlice(allocator, chunk[0..@intCast(n)]);
    }
    return buf.toOwnedSlice(allocator);
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
    var positional_seen = false; // a positional program string was consumed
    var program_from_file = false;
    var no_more_flags = false;

    while (i < args.len) : (i += 1) {
        const arg = args[i];

        // Option parsing continues until a positional program string is seen.
        // With -f the program comes from files, so options keep parsing.
        if (!no_more_flags and arg.len > 1 and arg[0] == '-' and !positional_seen) {
            if (std.mem.eql(u8, arg, "--")) {
                no_more_flags = true;
            } else if (std.mem.eql(u8, arg, "--help")) {
                printHelp();
                std.process.exit(0);
            } else if (std.mem.eql(u8, arg, "--version")) {
                printVersion();
                std.process.exit(0);
            } else if (arg[1] == 'F') {
                if (arg.len > 2) {
                    config.fs = arg[2..];
                } else {
                    i += 1;
                    if (i < args.len) config.fs = args[i];
                }
            } else if (arg[1] == 'v') {
                var var_arg: []const u8 = "";
                if (arg.len > 2) {
                    var_arg = arg[2..];
                } else {
                    i += 1;
                    if (i < args.len) var_arg = args[i];
                }
                if (std.mem.indexOf(u8, var_arg, "=")) |eq_pos| {
                    try config.variables.append(allocator, .{
                        .name = var_arg[0..eq_pos],
                        .value = var_arg[eq_pos + 1 ..],
                    });
                }
            } else if (arg[1] == 'f') {
                // -f progfile: read the program from a file. Repeated -f files
                // are concatenated with newlines. Positional args become data.
                var path: []const u8 = "";
                if (arg.len > 2) {
                    path = arg[2..];
                } else {
                    i += 1;
                    if (i < args.len) path = args[i] else {
                        std.debug.print("zawk: -f requires an argument\n", .{});
                        std.process.exit(2);
                    }
                }
                const contents = readProgramFile(allocator, path) catch {
                    std.debug.print("zawk: can't open program file {s}\n", .{path});
                    std.process.exit(2);
                };
                if (config.program.len == 0) {
                    config.program = contents;
                } else {
                    const merged = try std.mem.concat(allocator, u8, &.{ config.program, "\n", contents });
                    allocator.free(config.program);
                    allocator.free(contents);
                    config.program = merged;
                }
                program_from_file = true;
            } else {
                std.debug.print("zawk: unknown option {s}\n", .{arg});
                std.process.exit(2);
            }
        } else if (!positional_seen and !program_from_file) {
            config.program = try allocator.dupe(u8, arg);
            positional_seen = true;
        } else {
            try config.files.append(allocator, try allocator.dupe(u8, arg));
        }
    }

    if (config.files.items.len == 0) {
        try config.files.append(allocator, try allocator.dupe(u8, "-"));
    }

    return config;
}

fn processFile(
    allocator: std.mem.Allocator,
    path: []const u8,
    is_stdin: bool,
    rules: []Rule,
    state: *AwkState,
) !void {
    state.filename = path;
    state.fnr = 0;

    var line_buffer: [MAX_LINE]u8 = undefined;
    var line_len: usize = 0;

    if (is_stdin) {
        const stdin_fd: c_int = 0;
        var read_buf: [BUFFER_SIZE]u8 = undefined;

        while (true) {
            const bytes_ret = libc.read(stdin_fd, &read_buf, read_buf.len);
            if (bytes_ret <= 0) break;
            const bytes_read: usize = @intCast(bytes_ret);

            for (read_buf[0..bytes_read]) |byte| {
                if (byte == '\n') {
                    state.nr += 1;
                    state.fnr += 1;
                    state.setLine(line_buffer[0..line_len]);
                    state.should_next = false;

                    for (rules) |*rule| {
                        if (rule.is_begin or rule.is_end) continue;
                        if (state.should_next or state.should_exit) break;
                        if (patternMatches(state, rule.pattern)) {
                            execActions(state, rule.actions);
                        }
                    }

                    line_len = 0;
                    if (state.should_exit) return;
                } else if (line_len < line_buffer.len) {
                    line_buffer[line_len] = byte;
                    line_len += 1;
                }
            }
        }

        if (line_len > 0) {
            state.nr += 1;
            state.fnr += 1;
            state.setLine(line_buffer[0..line_len]);
            state.should_next = false;

            for (rules) |*rule| {
                if (rule.is_begin or rule.is_end) continue;
                if (state.should_next or state.should_exit) break;
                if (patternMatches(state, rule.pattern)) {
                    execActions(state, rule.actions);
                }
            }
        }
    } else {
        const path_z = try allocator.dupeZ(u8, path);
        defer allocator.free(path_z);

        const fd_ret = libc.open(path_z.ptr, .{ .ACCMODE = .RDONLY }, @as(libc.mode_t, 0));
        if (fd_ret < 0) {
            std.debug.print("zawk: {s}: cannot open\n", .{path});
            return error.OpenError;
        }
        const fd = fd_ret;
        defer _ = libc.close(fd);

        var read_buf: [BUFFER_SIZE]u8 = undefined;

        while (true) {
            const bytes_ret = libc.read(fd, &read_buf, read_buf.len);
            if (bytes_ret <= 0) break;
            const bytes_read: usize = @intCast(bytes_ret);

            for (read_buf[0..bytes_read]) |byte| {
                if (byte == '\n') {
                    state.nr += 1;
                    state.fnr += 1;
                    state.setLine(line_buffer[0..line_len]);
                    state.should_next = false;

                    for (rules) |*rule| {
                        if (rule.is_begin or rule.is_end) continue;
                        if (state.should_next or state.should_exit) break;
                        if (patternMatches(state, rule.pattern)) {
                            execActions(state, rule.actions);
                        }
                    }

                    line_len = 0;
                    if (state.should_exit) return;
                } else if (line_len < line_buffer.len) {
                    line_buffer[line_len] = byte;
                    line_len += 1;
                }
            }
        }

        if (line_len > 0) {
            state.nr += 1;
            state.fnr += 1;
            state.setLine(line_buffer[0..line_len]);
            state.should_next = false;

            for (rules) |*rule| {
                if (rule.is_begin or rule.is_end) continue;
                if (state.should_next or state.should_exit) break;
                if (patternMatches(state, rule.pattern)) {
                    execActions(state, rule.actions);
                }
            }
        }
    }
}

fn printHelp() void {
    const help =
        \\Usage: zawk [OPTIONS] 'program' [file ...]
        \\       zawk [OPTIONS] -f progfile [file ...]
        \\
        \\Options:
        \\  -F fs        Set field separator (default: whitespace)
        \\  -v var=val   Set variable before execution
        \\  --help       Display this help
        \\  --version    Display version
        \\
        \\Program Structure:
        \\  pattern { action }
        \\  BEGIN { action }     Execute before processing
        \\  END { action }       Execute after processing
        \\
        \\Built-in Variables:
        \\  $0           Entire line
        \\  $1, $2, ...  Fields
        \\  NF           Number of fields
        \\  NR           Record number (total)
        \\  FNR          Record number (per file)
        \\  FS           Field separator
        \\  OFS          Output field separator
        \\  ORS          Output record separator
        \\  FILENAME     Current filename
        \\
        \\String Functions:
        \\  length(s)         String length
        \\  substr(s,p,n)     Substring
        \\  index(s,t)        Find t in s
        \\  split(s,a,sep)    Split s into array a
        \\  sub(re,r,t)       Replace first match
        \\  gsub(re,r,t)      Replace all matches
        \\  match(s,re)       Find pattern position
        \\  tolower(s)        Convert to lowercase
        \\  toupper(s)        Convert to uppercase
        \\  sprintf(fmt,...)  Format string
        \\
        \\Math Functions:
        \\  int(n)       Integer part
        \\  sqrt(n)      Square root
        \\  sin(n)       Sine
        \\  cos(n)       Cosine
        \\  exp(n)       Exponential
        \\  log(n)       Natural logarithm
        \\
        \\Arrays:
        \\  arr[key]          Access element
        \\  arr[key] = val    Set element
        \\  delete arr[key]   Delete element
        \\  for (k in arr)    Iterate keys
        \\  (k in arr)        Test membership
        \\
        \\Output:
        \\  print             Print $0
        \\  print expr,...    Print expressions
        \\  printf fmt,...    Formatted print
        \\
        \\Examples:
        \\  zawk '{print $1}'              Print first field
        \\  zawk -F: '{print $1}' /etc/passwd
        \\  zawk 'NR==1'                   Print first line
        \\  zawk '/pattern/'               Print matching lines
        \\  zawk '{sum+=$1} END{print sum}' Sum first column
        \\  zawk '{a[$1]++} END{for(k in a) print k,a[k]}'
        \\  zawk '{printf "%s: %d\n", $1, NR}'
        \\
        \\zawk - High-performance AWK in Zig
        \\
    ;
    _ = libc.write(libc.STDOUT_FILENO, help.ptr, help.len);
}

fn printVersion() void {
    _ = libc.write(libc.STDOUT_FILENO, "zawk 0.1.0\n", 11);
}

pub fn main(init: std.process.Init) void {
    const allocator = init.gpa;

    var config = parseArgs(allocator, init.minimal.args) catch {
        std.process.exit(1);
    };
    defer config.deinit(allocator);

    if (config.program.len == 0) {
        std.debug.print("zawk: no program specified\n", .{});
        std.process.exit(1);
    }

    // Parse program
    var parser = Parser.init(allocator, config.program);
    defer parser.deinit();

    const rules = parser.parseProgram() catch {
        std.debug.print("zawk: syntax error\n", .{});
        std.process.exit(2);
    };
    if (parser.had_error) {
        std.debug.print("zawk: syntax error in program\n", .{});
        std.process.exit(2);
    }

    // Initialize state
    var output = OutputBuffer{};
    var state = AwkState.init(allocator, &output);
    defer state.deinit();

    state.fs = config.fs;

    // Set -v variables
    for (config.variables.items) |v| {
        state.setVariable(v.name, .{ .string = v.value }) catch {};
    }

    // Execute BEGIN blocks
    for (rules) |*rule| {
        if (rule.is_begin) {
            execActions(&state, rule.actions);
        }
    }

    // Process files
    if (!state.should_exit) {
        for (config.files.items) |file| {
            const is_stdin = std.mem.eql(u8, file, "-");
            processFile(allocator, file, is_stdin, rules, &state) catch {};
            if (state.should_exit) break;
        }
    }

    // Execute END blocks
    for (rules) |*rule| {
        if (rule.is_end) {
            execActions(&state, rule.actions);
        }
    }

    output.flush();
    std.process.exit(state.exit_code);
}
