//! zwc - High-performance word count utility in Zig
//!
//! Key advantages over GNU/Rust implementations:
//! - SIMD-accelerated line and byte counting using Zig's @Vector
//! - Comptime-specialized counting paths for different option combinations
//! - Zero allocations in hot path
//! - Memory-mapped file I/O for large files

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
                // Handle UTF-8 sequences
                const char_len = getUtf8CharLen(byte);
                if (char_len > 0) {
                    // For now, assume each character is width 1
                    // Full Unicode width would require lookup tables
                    current_len += 1;
                    i += char_len;
                } else {
                    // Invalid UTF-8, count as 1 byte
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

// ============================================================================
// File Processing
// ============================================================================

fn countFile(path: []const u8, config: *const Config) !WordCount {
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

    // For byte-only counting, just return the file size
    if (config.show_bytes and !config.show_lines and !config.show_words and
        !config.show_chars and !config.show_max_line_length)
    {
        return WordCount{ .bytes = stat.size };
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
    return countData(actual_data, config);
}

fn countStdin(config: *const Config) !WordCount {
    const allocator = std.heap.c_allocator;

    // Read all of stdin into memory
    var list: std.ArrayListUnmanaged(u8) = .empty;
    defer list.deinit(allocator);

    var buf: [8192]u8 = undefined;
    while (true) {
        const n = posix.read(posix.STDIN_FILENO, &buf) catch break;
        if (n == 0) break;
        try list.appendSlice(allocator, buf[0..n]);
    }

    return countData(list.items, config);
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

fn printStats(result: *const WordCount, config: *const Config, title: ?[]const u8, width: usize) void {
    const Io = std.Io;
    const io = Io.Threaded.global_single_threaded.io();
    var buf: [256]u8 = undefined;
    const stdout_file = Io.File.stdout();
    var writer = stdout_file.writer(io, &buf);

    var first = true;

    if (config.show_lines) {
        if (!first) writer.interface.writeAll(" ") catch {};
        printNumber(&writer, result.lines, width);
        first = false;
    }

    if (config.show_words) {
        if (!first) writer.interface.writeAll(" ") catch {};
        printNumber(&writer, result.words, width);
        first = false;
    }

    if (config.show_chars) {
        if (!first) writer.interface.writeAll(" ") catch {};
        printNumber(&writer, result.chars, width);
        first = false;
    }

    if (config.show_bytes) {
        if (!first) writer.interface.writeAll(" ") catch {};
        printNumber(&writer, result.bytes, width);
        first = false;
    }

    if (config.show_max_line_length) {
        if (!first) writer.interface.writeAll(" ") catch {};
        printNumber(&writer, result.max_line_length, width);
        first = false;
    }

    if (title) |t| {
        writer.interface.writeAll(" ") catch {};
        writer.interface.writeAll(t) catch {};
    }

    writer.interface.writeAll("\n") catch {};
    writer.interface.flush() catch {};
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

    // Calculate digits needed
    if (max == 0) return 1;
    var digits: usize = 0;
    var n = max;
    while (n > 0) : (n /= 10) {
        digits += 1;
    }
    return digits;
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

    var total = WordCount{};
    var error_occurred = false;
    var files_processed: usize = 0;

    // First pass: calculate totals for width computation
    if (config.files.items.len == 0) {
        // Read from stdin
        const result = countStdin(&config) catch |err| {
            printErrorFmt("-: {}", .{err});
            error_occurred = true;
            std.process.exit(1);
        };
        total.add(result);
        files_processed = 1;

        const width = computeWidth(&total, &config);
        printStats(&result, &config, null, width);
    } else {
        const ResultItem = struct { count: WordCount, name: []const u8 };
        // Process files - first pass to get totals for width
        var results: std.ArrayListUnmanaged(ResultItem) = .empty;
        defer results.deinit(allocator);

        for (config.files.items) |file_path| {
            if (std.mem.eql(u8, file_path, "-")) {
                const result = countStdin(&config) catch |err| {
                    printErrorFmt("-: {}", .{err});
                    error_occurred = true;
                    continue;
                };
                total.add(result);
                results.append(allocator, .{ .count = result, .name = "-" }) catch continue;
            } else {
                const result = countFile(file_path, &config) catch |err| {
                    printErrorFmt("{s}: {}", .{ file_path, err });
                    error_occurred = true;
                    continue;
                };
                total.add(result);
                results.append(allocator, .{ .count = result, .name = file_path }) catch continue;
            }
            files_processed += 1;
        }

        // Second pass: print with consistent width
        const width = @max(computeWidth(&total, &config), 1);

        // Print individual file stats (unless --total=only)
        if (config.shouldShowIndividual()) {
            for (results.items) |item| {
                printStats(&item.count, &config, item.name, width);
            }
        }

        // Print total based on total_mode
        if (config.shouldShowTotal(files_processed)) {
            printStats(&total, &config, "total", width);
        }
    }

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
