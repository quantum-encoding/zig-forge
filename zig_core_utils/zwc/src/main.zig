//! zwc - High-performance word count utility in Zig
//!
//! Key advantages over GNU/Rust implementations:
//! - SIMD-accelerated line and byte counting using Zig's @Vector
//! - Comptime-specialized counting paths for different option combinations
//!
//! I/O model: each input is read fully into a heap buffer (c_allocator) via
//! posix.read, then counted in-memory. The -c (byte-only) path short-circuits
//! on the file's stat size and does not read the contents. There is no mmap.

const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;

// ============================================================================
// SIMD Configuration
// ============================================================================

const Vec32u8 = @Vector(32, u8);
const Vec64u8 = @Vector(64, u8);

// ============================================================================
// Word Count Result
// ============================================================================

const WordCount = struct {
    lines: u64 = 0,
    words: u64 = 0,
    chars: u64 = 0,
    bytes: u64 = 0,
    max_line_length: u64 = 0,

    pub fn add(self: *WordCount, other: WordCount) void {
        self.lines += other.lines;
        self.words += other.words;
        self.chars += other.chars;
        self.bytes += other.bytes;
        self.max_line_length = @max(self.max_line_length, other.max_line_length);
    }
};

// ============================================================================
// Configuration
// ============================================================================

const TotalMode = enum {
    auto, // Show total only with multiple files (default)
    always, // Always show total line
    only, // Only show total, not individual files
    never, // Never show total line
};

const Config = struct {
    show_lines: bool = false,
    show_words: bool = false,
    show_chars: bool = false,
    show_bytes: bool = false,
    show_max_line_length: bool = false,
    total_mode: TotalMode = .auto,
    files: std.ArrayListUnmanaged([]const u8) = .empty,

    fn needsWordCount(self: *const Config) bool {
        return self.show_words;
    }

    fn needsCharCount(self: *const Config) bool {
        return self.show_chars;
    }

    fn needsMaxLineLength(self: *const Config) bool {
        return self.show_max_line_length;
    }

    fn needsLineCount(self: *const Config) bool {
        return self.show_lines;
    }

    fn needsByteCount(self: *const Config) bool {
        return self.show_bytes;
    }

    fn shouldShowIndividual(self: *const Config) bool {
        return self.total_mode != .only;
    }

    fn shouldShowTotal(self: *const Config, file_count: usize) bool {
        return switch (self.total_mode) {
            .always => true,
            .only => true,
            .never => false,
            .auto => file_count > 1,
        };
    }

    fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        for (self.files.items) |item| {
            allocator.free(item);
        }
        self.files.deinit(allocator);
    }
};

// ============================================================================
// SIMD Counting Functions
// ============================================================================

/// Count newlines using SIMD - processes 32 bytes at a time
fn countNewlinesSimd(data: []const u8) u64 {
    var count: u64 = 0;
    var i: usize = 0;

    const newline_vec: Vec32u8 = @splat('\n');

    // Process 32 bytes at a time
    while (i + 32 <= data.len) : (i += 32) {
        const chunk: Vec32u8 = data[i..][0..32].*;
        const matches = chunk == newline_vec;
        // Count set bits in the comparison mask
        const mask: u32 = @bitCast(matches);
        count += @popCount(mask);
    }

    // Handle remainder
    while (i < data.len) : (i += 1) {
        if (data[i] == '\n') {
            count += 1;
        }
    }

    return count;
}

/// Count bytes, chars, and lines in a single pass using SIMD
/// This counts UTF-8 characters by counting bytes that are NOT continuation bytes (0b10xxxxxx)
fn countBytesCharsLines(data: []const u8) struct { bytes: u64, chars: u64, lines: u64 } {
    var lines: u64 = 0;
    var chars: u64 = 0;
    var i: usize = 0;

    const newline_vec: Vec32u8 = @splat('\n');
    // UTF-8 continuation bytes start with 0b10xxxxxx (0x80-0xBF)
    // We count non-continuation bytes as character starts
    const cont_mask_low: Vec32u8 = @splat(0x80);
    const cont_mask_high: Vec32u8 = @splat(0xC0);

    // Process 32 bytes at a time
    while (i + 32 <= data.len) : (i += 32) {
        const chunk: Vec32u8 = data[i..][0..32].*;

        // Count newlines
        const nl_matches = chunk == newline_vec;
        const nl_mask: u32 = @bitCast(nl_matches);
        lines += @popCount(nl_mask);

        // Count character starts (non-continuation bytes)
        // A byte is a continuation byte if (byte & 0xC0) == 0x80
        const masked = chunk & cont_mask_high;
        const is_continuation = masked == cont_mask_low;
        const cont_mask: u32 = @bitCast(is_continuation);
        // Characters = total bytes - continuation bytes
        chars += 32 - @popCount(cont_mask);
    }

    // Handle remainder
    while (i < data.len) : (i += 1) {
        if (data[i] == '\n') {
            lines += 1;
        }
        // Count non-continuation bytes as characters
        if ((data[i] & 0xC0) != 0x80) {
            chars += 1;
        }
    }

    return .{ .bytes = data.len, .chars = chars, .lines = lines };
}

/// Count words - needs character-by-character scanning for whitespace transitions
fn countWords(data: []const u8) u64 {
    var words: u64 = 0;
    var in_word = false;

    for (data) |byte| {
        const is_whitespace = switch (byte) {
            ' ', '\t', '\n', '\r', 0x0B, 0x0C => true,
            else => false,
        };

        if (is_whitespace) {
            in_word = false;
        } else if (!in_word) {
            in_word = true;
            words += 1;
        }
    }

    return words;
}

/// Count max line length - needs character-by-character scanning
/// Returns the display width, handling tabs and Unicode
fn countMaxLineLength(data: []const u8) u64 {
    var max_len: u64 = 0;
    var current_len: u64 = 0;

    var i: usize = 0;
    while (i < data.len) {
        const byte = data[i];
        switch (byte) {
            '\n', '\r', 0x0C => {
                max_len = @max(max_len, current_len);
                current_len = 0;
                i += 1;
            },
            '\t' => {
                // Tab stops at every 8 columns
                current_len = (current_len / 8 + 1) * 8;
                i += 1;
            },
            else => {
                // Handle UTF-8 sequences. Advance the display column by the
                // code point's wcwidth (0 for combining marks, 2 for East-Asian
                // wide / emoji, 1 otherwise), matching GNU wc's wcwidth-based -L.
                const char_len = getUtf8CharLen(byte);
                if (char_len > 0 and i + char_len <= data.len) {
                    const cp = decodeUtf8(data[i..][0..char_len]);
                    if (cp) |c| {
                        current_len += wcwidth(c);
                    } else {
                        // Malformed continuation bytes: fall back to width 1.
                        current_len += 1;
                    }
                    i += char_len;
                } else {
                    // Invalid / truncated UTF-8, count as 1 byte.
                    current_len += 1;
                    i += 1;
                }
            },
        }
    }

    return @max(max_len, current_len);
}

fn getUtf8CharLen(first_byte: u8) usize {
    if (first_byte < 0x80) return 1;
    if (first_byte < 0xC0) return 0; // Continuation byte (invalid as first)
    if (first_byte < 0xE0) return 2;
    if (first_byte < 0xF0) return 3;
    if (first_byte < 0xF8) return 4;
    return 0; // Invalid
}

/// Decode a single UTF-8 code point from a `len`-byte slice, or null if the
/// continuation bytes are malformed.
fn decodeUtf8(bytes: []const u8) ?u21 {
    return switch (bytes.len) {
        1 => bytes[0],
        2 => blk: {
            if (bytes[1] & 0xC0 != 0x80) break :blk null;
            break :blk (@as(u21, bytes[0] & 0x1F) << 6) | (bytes[1] & 0x3F);
        },
        3 => blk: {
            if (bytes[1] & 0xC0 != 0x80 or bytes[2] & 0xC0 != 0x80) break :blk null;
            break :blk (@as(u21, bytes[0] & 0x0F) << 12) |
                (@as(u21, bytes[1] & 0x3F) << 6) | (bytes[2] & 0x3F);
        },
        4 => blk: {
            if (bytes[1] & 0xC0 != 0x80 or bytes[2] & 0xC0 != 0x80 or bytes[3] & 0xC0 != 0x80)
                break :blk null;
            break :blk (@as(u21, bytes[0] & 0x07) << 18) | (@as(u21, bytes[1] & 0x3F) << 12) |
                (@as(u21, bytes[2] & 0x3F) << 6) | (bytes[3] & 0x3F);
        },
        else => null,
    };
}

/// Display width of a Unicode code point, following the mk_wcwidth model
/// (Markus Kuhn) that glibc's wcwidth — and therefore GNU `wc -L` — tracks:
/// 0 for zero-width combining marks, 2 for East-Asian wide / fullwidth / emoji,
/// 1 otherwise. Control code points never reach here (handled by the caller).
fn wcwidth(cp: u21) u64 {
    if (cp == 0) return 0;
    if (isZeroWidth(cp)) return 0;
    if (isWide(cp)) return 2;
    return 1;
}

fn inRange(cp: u21, lo: u21, hi: u21) bool {
    return cp >= lo and cp <= hi;
}

fn isZeroWidth(cp: u21) bool {
    return inRange(cp, 0x0300, 0x036F) or // combining diacritical marks
        inRange(cp, 0x0483, 0x0489) or
        inRange(cp, 0x0591, 0x05BD) or
        inRange(cp, 0x0610, 0x061A) or
        inRange(cp, 0x064B, 0x065F) or
        cp == 0x0670 or
        inRange(cp, 0x06D6, 0x06DC) or
        inRange(cp, 0x06DF, 0x06E4) or
        inRange(cp, 0x0E31, 0x0E31) or
        inRange(cp, 0x0E34, 0x0E3A) or
        inRange(cp, 0x0EB1, 0x0EB1) or
        inRange(cp, 0x0EB4, 0x0EB9) or
        inRange(cp, 0x200B, 0x200F) or // zero-width space / joiners / marks
        inRange(cp, 0x202A, 0x202E) or
        inRange(cp, 0x2060, 0x2064) or
        inRange(cp, 0xFE00, 0xFE0F) or // variation selectors
        inRange(cp, 0xFE20, 0xFE2F) or
        cp == 0xFEFF or
        inRange(cp, 0x1AB0, 0x1AFF) or
        inRange(cp, 0x1DC0, 0x1DFF);
}

fn isWide(cp: u21) bool {
    return inRange(cp, 0x1100, 0x115F) or // Hangul Jamo
        cp == 0x2329 or cp == 0x232A or
        inRange(cp, 0x2E80, 0x303E) or // CJK radicals … symbols
        inRange(cp, 0x3041, 0x33FF) or // Hiragana … CJK compat
        inRange(cp, 0x3400, 0x4DBF) or // CJK Ext A
        inRange(cp, 0x4E00, 0x9FFF) or // CJK Unified Ideographs
        inRange(cp, 0xA000, 0xA4CF) or // Yi
        inRange(cp, 0xAC00, 0xD7A3) or // Hangul syllables
        inRange(cp, 0xF900, 0xFAFF) or // CJK compat ideographs
        inRange(cp, 0xFE10, 0xFE19) or
        inRange(cp, 0xFE30, 0xFE6F) or
        inRange(cp, 0xFF00, 0xFF60) or // fullwidth forms
        inRange(cp, 0xFFE0, 0xFFE6) or
        inRange(cp, 0x1F300, 0x1F64F) or // emoji: symbols & pictographs, emoticons
        inRange(cp, 0x1F900, 0x1F9FF) or // supplemental symbols & pictographs
        inRange(cp, 0x20000, 0x3FFFD); // CJK Ext B+ / supplementary ideographic
}

// ============================================================================
// File Processing
// ============================================================================

/// A counted input plus the metadata GNU wc uses to compute column width:
/// `size` is the byte length (file st_size / bytes read), and `statable` is
/// true only for regular files whose size bounds the counts in advance.
const CountResult = struct {
    count: WordCount,
    size: u64,
    statable: bool,
};

fn countFile(path: []const u8, config: *const Config) !CountResult {
    const Io = std.Io;
    const io = Io.Threaded.global_single_threaded.io();
    const Dir = Io.Dir;

    // Open file
    const file = Dir.openFile(Dir.cwd(), io, path, .{}) catch |err| {
        return err;
    };
    defer file.close(io);

    // Get file size for byte count optimization
    const stat = file.stat(io) catch |err| {
        return err;
    };

    // GNU wc rejects directories with "Is a directory" (exit 1) rather than
    // reading them. Surface it here for every mode, including the -c fast path
    // (which otherwise would print the directory's stat size and exit 0).
    if (stat.kind == .directory) {
        return error.IsDir;
    }

    const statable = stat.kind == .file;

    // For byte-only counting, just return the file size
    if (config.show_bytes and !config.show_lines and !config.show_words and
        !config.show_chars and !config.show_max_line_length)
    {
        return .{ .count = WordCount{ .bytes = stat.size }, .size = stat.size, .statable = statable };
    }

    // Read file into buffer
    const allocator = std.heap.c_allocator;

    const data = try allocator.alloc(u8, stat.size);
    defer allocator.free(data);

    // Use posix read directly for simplicity
    var total_read: usize = 0;
    while (total_read < stat.size) {
        const n = posix.read(file.handle, data[total_read..]) catch |err| {
            return err;
        };
        if (n == 0) break;
        total_read += n;
    }

    const actual_data = data[0..total_read];
    return .{ .count = countData(actual_data, config), .size = total_read, .statable = statable };
}

fn countStdin(config: *const Config) !CountResult {
    const allocator = std.heap.c_allocator;

    // stdin is statable (its size bounds the counts) only when it is a regular
    // file, e.g. `zwc < file`. A pipe/tty falls back to GNU's minimum width.
    const Io = std.Io;
    const io = Io.Threaded.global_single_threaded.io();
    const statable = blk: {
        const st = Io.File.stdin().stat(io) catch break :blk false;
        break :blk st.kind == .file;
    };

    // Read all of stdin into memory
    var list: std.ArrayListUnmanaged(u8) = .empty;
    defer list.deinit(allocator);

    var buf: [8192]u8 = undefined;
    while (true) {
        const n = try posix.read(posix.STDIN_FILENO, &buf);
        if (n == 0) break;
        try list.appendSlice(allocator, buf[0..n]);
    }

    return .{ .count = countData(list.items, config), .size = list.items.len, .statable = statable };
}

fn countData(data: []const u8, config: *const Config) WordCount {
    var result = WordCount{};

    // Byte count is always just the length
    if (config.needsByteCount()) {
        result.bytes = data.len;
    }

    // Fast path: only need lines and/or bytes and/or chars
    if (!config.needsWordCount() and !config.needsMaxLineLength()) {
        if (config.needsLineCount() or config.needsCharCount()) {
            const counts = countBytesCharsLines(data);
            result.lines = counts.lines;
            result.chars = counts.chars;
            result.bytes = counts.bytes;
        }
        return result;
    }

    // Need word count or max line length - do full scan
    if (config.needsLineCount()) {
        result.lines = countNewlinesSimd(data);
    }

    if (config.needsCharCount()) {
        // Count non-continuation UTF-8 bytes
        const counts = countBytesCharsLines(data);
        result.chars = counts.chars;
    }

    if (config.needsWordCount()) {
        result.words = countWords(data);
    }

    if (config.needsMaxLineLength()) {
        result.max_line_length = countMaxLineLength(data);
    }

    return result;
}

// ============================================================================
// Argument Parsing
// ============================================================================

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

    var i: usize = 1; // Skip program name
    var explicit_options = false;

    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (arg.len > 0 and arg[0] == '-' and arg.len > 1 and arg[1] != '-') {
            // Short options (can be combined: -lwc)
            for (arg[1..]) |c| {
                switch (c) {
                    'l' => {
                        config.show_lines = true;
                        explicit_options = true;
                    },
                    'w' => {
                        config.show_words = true;
                        explicit_options = true;
                    },
                    'c' => {
                        config.show_bytes = true;
                        explicit_options = true;
                    },
                    'm' => {
                        config.show_chars = true;
                        explicit_options = true;
                    },
                    'L' => {
                        config.show_max_line_length = true;
                        explicit_options = true;
                    },
                    else => {
                        printErrorFmt("invalid option -- '{c}'", .{c});
                        std.process.exit(1);
                    },
                }
            }
        } else if (std.mem.eql(u8, arg, "--help")) {
            printHelp();
            std.process.exit(0);
        } else if (std.mem.eql(u8, arg, "--version")) {
            printVersion();
            std.process.exit(0);
        } else if (std.mem.eql(u8, arg, "--lines")) {
            config.show_lines = true;
            explicit_options = true;
        } else if (std.mem.eql(u8, arg, "--words")) {
            config.show_words = true;
            explicit_options = true;
        } else if (std.mem.eql(u8, arg, "--bytes")) {
            config.show_bytes = true;
            explicit_options = true;
        } else if (std.mem.eql(u8, arg, "--chars")) {
            config.show_chars = true;
            explicit_options = true;
        } else if (std.mem.eql(u8, arg, "--max-line-length")) {
            config.show_max_line_length = true;
            explicit_options = true;
        } else if (std.mem.eql(u8, arg, "--total") or std.mem.eql(u8, arg, "--total=always")) {
            config.total_mode = .always;
        } else if (std.mem.eql(u8, arg, "--total=auto")) {
            config.total_mode = .auto;
        } else if (std.mem.eql(u8, arg, "--total=only")) {
            config.total_mode = .only;
        } else if (std.mem.eql(u8, arg, "--total=never")) {
            config.total_mode = .never;
        } else if (std.mem.startsWith(u8, arg, "--total=")) {
            printErrorFmt("invalid argument '{s}' for '--total'", .{arg[8..]});
            std.process.exit(1);
        } else if (std.mem.eql(u8, arg, "--")) {
            // End of options, rest are files
            i += 1;
            while (i < args.len) : (i += 1) {
                try config.files.append(allocator, try allocator.dupe(u8, args[i]));
            }
            break;
        } else if (arg.len > 0 and arg[0] == '-' and arg.len == 1) {
            // "-" means stdin
            try config.files.append(allocator, try allocator.dupe(u8, "-"));
        } else {
            // File argument
            try config.files.append(allocator, try allocator.dupe(u8, arg));
        }
    }

    // Default: show lines, words, bytes (like GNU wc)
    if (!explicit_options) {
        config.show_lines = true;
        config.show_words = true;
        config.show_bytes = true;
    }

    return config;
}

// ============================================================================
// Output
// ============================================================================

/// Writes one count line. `writer` is created ONCE by the caller and reused so
/// its positional offset advances across lines; creating a fresh stdout writer
/// per line would re-emit every line at file offset 0 (each pwrite at pos 0),
/// silently clobbering all but the last line when stdout is a regular file.
fn printStats(writer: anytype, result: *const WordCount, config: *const Config, title: ?[]const u8, width: usize) void {
    var first = true;

    if (config.show_lines) {
        if (!first) writer.interface.writeAll(" ") catch {};
        printNumber(writer, result.lines, width);
        first = false;
    }

    if (config.show_words) {
        if (!first) writer.interface.writeAll(" ") catch {};
        printNumber(writer, result.words, width);
        first = false;
    }

    if (config.show_chars) {
        if (!first) writer.interface.writeAll(" ") catch {};
        printNumber(writer, result.chars, width);
        first = false;
    }

    if (config.show_bytes) {
        if (!first) writer.interface.writeAll(" ") catch {};
        printNumber(writer, result.bytes, width);
        first = false;
    }

    if (config.show_max_line_length) {
        if (!first) writer.interface.writeAll(" ") catch {};
        printNumber(writer, result.max_line_length, width);
        first = false;
    }

    if (title) |t| {
        writer.interface.writeAll(" ") catch {};
        writer.interface.writeAll(t) catch {};
    }

    writer.interface.writeAll("\n") catch {};
}

fn printNumber(writer: anytype, num: u64, width: usize) void {
    var num_buf: [20]u8 = undefined;
    const num_str = std.fmt.bufPrint(&num_buf, "{d}", .{num}) catch return;

    // Right-align with spaces
    if (num_str.len < width) {
        var spaces: usize = width - num_str.len;
        while (spaces > 0) : (spaces -= 1) {
            writer.interface.writeAll(" ") catch {};
        }
    }
    writer.interface.writeAll(num_str) catch {};
}

fn computeWidth(total: *const WordCount, config: *const Config) usize {
    var max: u64 = 0;
    if (config.show_lines) max = @max(max, total.lines);
    if (config.show_words) max = @max(max, total.words);
    if (config.show_chars) max = @max(max, total.chars);
    if (config.show_bytes) max = @max(max, total.bytes);
    if (config.show_max_line_length) max = @max(max, total.max_line_length);

    return numDigits(max);
}

fn numDigits(value: u64) usize {
    if (value == 0) return 1;
    var digits: usize = 0;
    var n = value;
    while (n > 0) : (n /= 10) {
        digits += 1;
    }
    return digits;
}

fn countColumns(config: *const Config) usize {
    var n: usize = 0;
    if (config.show_lines) n += 1;
    if (config.show_words) n += 1;
    if (config.show_chars) n += 1;
    if (config.show_bytes) n += 1;
    if (config.show_max_line_length) n += 1;
    return n;
}

/// Field width matching GNU wc (coreutils 9.x). Verified against the real GNU
/// binary across regular files, pipes, multi-file totals, and single-count
/// shortcuts (see gnu_parity_test.zig):
///   * --total=only               -> width 1
///   * one column, one input, no total -> width 1 (no padding)
///   * all inputs are regular files -> digits(sum of file sizes) (the sizes
///     bound every count, so this is computable without reading)
///   * otherwise (pipe/tty input) -> max(7, digits(largest printed count))
fn computeGnuWidth(
    config: *const Config,
    total: *const WordCount,
    n_inputs: usize,
    print_total: bool,
    all_statable: bool,
    total_size: u64,
) usize {
    if (config.total_mode == .only) return 1;
    if (countColumns(config) == 1 and n_inputs <= 1 and !print_total) return 1;
    if (all_statable) return @max(@as(usize, 1), numDigits(total_size));
    return @max(@as(usize, 7), computeWidth(total, config));
}

/// Map a caught Zig error to the GNU/POSIX strerror-style message GNU wc emits,
/// so `zwc missing` says "No such file or directory" not "error.FileNotFound".
fn gnuErrorString(err: anyerror) []const u8 {
    return switch (err) {
        error.FileNotFound => "No such file or directory",
        error.IsDir => "Is a directory",
        error.AccessDenied, error.PermissionDenied => "Permission denied",
        error.NotDir => "Not a directory",
        error.NameTooLong => "File name too long",
        error.SymLinkLoop => "Too many levels of symbolic links",
        error.FileTooBig => "File too large",
        error.SystemResources => "Cannot allocate memory",
        error.DeviceBusy => "Device or resource busy",
        error.InputOutput => "Input/output error",
        error.BrokenPipe => "Broken pipe",
        error.ConnectionResetByPeer => "Connection reset by peer",
        error.ProcessFdQuotaExceeded, error.SystemFdQuotaExceeded => "Too many open files",
        else => @errorName(err),
    };
}

fn printError(msg: []const u8) void {
    std.debug.print("zwc: {s}\n", .{msg});
}

fn printErrorFmt(comptime fmt: []const u8, args: anytype) void {
    std.debug.print("zwc: " ++ fmt ++ "\n", args);
}

fn printHelp() void {
    const Io = std.Io;
    const io = Io.Threaded.global_single_threaded.io();
    var buf: [4096]u8 = undefined;
    const stdout_file = Io.File.stdout();
    var writer = stdout_file.writer(io, &buf);
    writer.interface.writeAll(
        \\Usage: zwc [OPTION]... [FILE]...
        \\Print newline, word, and byte counts for each FILE, and a total line if
        \\more than one FILE is specified.  A word is a non-zero-length sequence of
        \\printable characters delimited by white space.
        \\
        \\With no FILE, or when FILE is -, read standard input.
        \\
        \\  -c, --bytes            print the byte counts
        \\  -m, --chars            print the character counts
        \\  -l, --lines            print the newline counts
        \\  -L, --max-line-length  print the maximum display width
        \\  -w, --words            print the word counts
        \\      --total=WHEN       when to print total: auto, always, only, never
        \\      --help             display this help and exit
        \\      --version          output version information and exit
        \\
        \\zwc - High-performance word count utility in Zig
        \\
    ) catch {};
    writer.interface.flush() catch {};
}

fn printVersion() void {
    const Io = std.Io;
    const io = Io.Threaded.global_single_threaded.io();
    var buf: [256]u8 = undefined;
    const stdout_file = Io.File.stdout();
    var writer = stdout_file.writer(io, &buf);
    writer.interface.writeAll("zwc 0.1.0\n") catch {};
    writer.interface.flush() catch {};
}

// ============================================================================
// Entry Point
// ============================================================================

pub fn main(init: std.process.Init) void {
    const allocator = init.gpa;

    var config = parseArgs(allocator, init.minimal.args) catch {
        printError("failed to parse arguments");
        std.process.exit(1);
    };
    defer config.deinit(allocator);

    // Create ONE stdout writer for the whole run. Its positional offset must
    // advance across every printed line — a per-line writer would pwrite each
    // line at offset 0, clobbering all but the last when stdout is a file.
    const Io = std.Io;
    const io = Io.Threaded.global_single_threaded.io();
    var out_buf: [4096]u8 = undefined;
    const stdout_file = Io.File.stdout();
    var writer = stdout_file.writer(io, &out_buf);

    var total = WordCount{};
    var total_size: u64 = 0;
    var all_statable = true;
    var error_occurred = false;
    var files_processed: usize = 0;

    if (config.files.items.len == 0) {
        // Read from stdin
        const result = countStdin(&config) catch |err| {
            printErrorFmt("-: {s}", .{gnuErrorString(err)});
            std.process.exit(1);
        };
        total.add(result.count);
        total_size += result.size;
        all_statable = all_statable and result.statable;
        files_processed = 1;

        const width = computeGnuWidth(&config, &total, 1, false, all_statable, total_size);
        printStats(&writer, &result.count, &config, null, width);
    } else {
        const ResultItem = struct { count: WordCount, name: []const u8 };
        // First pass: count every input, accumulating totals for width.
        var results: std.ArrayListUnmanaged(ResultItem) = .empty;
        defer results.deinit(allocator);

        for (config.files.items) |file_path| {
            const result = if (std.mem.eql(u8, file_path, "-"))
                countStdin(&config) catch |err| {
                    printErrorFmt("-: {s}", .{gnuErrorString(err)});
                    error_occurred = true;
                    continue;
                }
            else
                countFile(file_path, &config) catch |err| {
                    printErrorFmt("{s}: {s}", .{ file_path, gnuErrorString(err) });
                    error_occurred = true;
                    // GNU still emits a zero-count line for a directory (it
                    // opens it, reads 0 bytes, then errors), and the directory —
                    // being non-regular — forces the fallback column width.
                    if (err == error.IsDir) {
                        all_statable = false;
                        results.append(allocator, .{ .count = .{}, .name = file_path }) catch {};
                        files_processed += 1;
                    }
                    continue;
                };
            total.add(result.count);
            total_size += result.size;
            all_statable = all_statable and result.statable;
            const name = if (std.mem.eql(u8, file_path, "-")) "-" else file_path;
            results.append(allocator, .{ .count = result.count, .name = name }) catch continue;
            files_processed += 1;
        }

        // Second pass: print with the consistent GNU-derived width.
        const print_total = config.shouldShowTotal(files_processed);
        const width = computeGnuWidth(&config, &total, files_processed, print_total, all_statable, total_size);

        // Print individual file stats (unless --total=only)
        if (config.shouldShowIndividual()) {
            for (results.items) |item| {
                printStats(&writer, &item.count, &config, item.name, width);
            }
        }

        // Print total based on total_mode. GNU omits the "total" label under
        // --total=only (the total line is the only output).
        if (print_total) {
            const total_title: ?[]const u8 = if (config.total_mode == .only) null else "total";
            printStats(&writer, &total, &config, total_title, width);
        }
    }

    writer.interface.flush() catch {};

    if (error_occurred) {
        std.process.exit(1);
    }
}

// ============================================================================
// Tests
// ============================================================================

test "SIMD newline counting" {
    const testing = std.testing;

    // Empty
    try testing.expectEqual(@as(u64, 0), countNewlinesSimd(""));

    // No newlines
    try testing.expectEqual(@as(u64, 0), countNewlinesSimd("hello world"));

    // Single newline
    try testing.expectEqual(@as(u64, 1), countNewlinesSimd("hello\nworld"));

    // Multiple newlines
    try testing.expectEqual(@as(u64, 3), countNewlinesSimd("line1\nline2\nline3\n"));

    // Large input (tests SIMD path)
    var large: [1000]u8 = undefined;
    @memset(&large, '\n');
    try testing.expectEqual(@as(u64, 1000), countNewlinesSimd(&large));
}

test "word counting" {
    const testing = std.testing;

    try testing.expectEqual(@as(u64, 0), countWords(""));
    try testing.expectEqual(@as(u64, 2), countWords("hello world"));
    try testing.expectEqual(@as(u64, 3), countWords("one two three"));
    try testing.expectEqual(@as(u64, 3), countWords("  one  two  three  "));
    try testing.expectEqual(@as(u64, 3), countWords("one\ntwo\tthree"));
}

test "UTF-8 character counting" {
    const testing = std.testing;

    // ASCII only
    const ascii_counts = countBytesCharsLines("hello");
    try testing.expectEqual(@as(u64, 5), ascii_counts.chars);
    try testing.expectEqual(@as(u64, 5), ascii_counts.bytes);

    // UTF-8 (2-byte: é, 3-byte: 中, 4-byte: 😀)
    const utf8_counts = countBytesCharsLines("héllo");
    try testing.expectEqual(@as(u64, 5), utf8_counts.chars); // h, é, l, l, o
    try testing.expectEqual(@as(u64, 6), utf8_counts.bytes); // é is 2 bytes
}

test "max line length" {
    const testing = std.testing;

    try testing.expectEqual(@as(u64, 5), countMaxLineLength("hello"));
    try testing.expectEqual(@as(u64, 5), countMaxLineLength("hello\nhi"));
    try testing.expectEqual(@as(u64, 8), countMaxLineLength("\t")); // Tab at pos 0 goes to 8
}
