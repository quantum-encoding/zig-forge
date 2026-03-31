const std = @import("std");
const variable_tester = @import("variable_tester");

/// Lossless Compression Test Function
/// Tests if a given compression formula can compress data without loss
pub fn testLosslessCompression(task: *const variable_tester.Task, allocator: std.mem.Allocator) !variable_tester.Result {
    // The task.data contains the compression formula as a string
    // For this initial implementation, we'll test simple run-length encoding

    const input_data = "AAAABBBCCDAA"; // Sample data to compress

    // Apply the formula (in this case, RLE)
    var compressed: std.ArrayListUnmanaged(u8) = .empty;
    defer compressed.deinit(allocator);

    try runLengthEncode(input_data, &compressed, allocator);

    // Decompress to verify losslessness
    var decompressed: std.ArrayListUnmanaged(u8) = .empty;
    defer decompressed.deinit(allocator);

    try runLengthDecode(compressed.items, &decompressed, allocator);

    // Check if decompression matches original
    const success = std.mem.eql(u8, input_data, decompressed.items);

    // Calculate compression ratio
    const original_size = input_data.len;
    const compressed_size = compressed.items.len;
    const ratio = @as(f64, @floatFromInt(compressed_size)) / @as(f64, @floatFromInt(original_size));

    // Only consider it a success if we achieved compression AND lossless
    const final_success = success and (compressed_size < original_size);

    return variable_tester.Result.init(
        task.id,
        final_success,
        try allocator.dupe(u8, compressed.items),
        ratio,
    );
}

/// Simple Run-Length Encoding implementation
fn runLengthEncode(input: []const u8, output: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator) !void {
    if (input.len == 0) return;

    var i: usize = 0;
    while (i < input.len) {
        const char = input[i];
        var count: u8 = 1;

        // Count consecutive identical characters
        while (i + count < input.len and input[i + count] == char and count < 255) {
            count += 1;
        }

        // Write count and character
        try output.append(allocator, count);
        try output.append(allocator, char);

        i += count;
    }
}

/// Run-Length Decoding
fn runLengthDecode(input: []const u8, output: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator) !void {
    var i: usize = 0;
    while (i + 1 < input.len) {
        const count = input[i];
        const char = input[i + 1];

        // Expand the run
        var j: u8 = 0;
        while (j < count) : (j += 1) {
            try output.append(allocator, char);
        }

        i += 2;
    }
}

/// Prime Number Test Function
/// Tests if a number is prime using trial division
pub fn testPrimeNumber(task: *const variable_tester.Task, allocator: std.mem.Allocator) !variable_tester.Result {
    _ = allocator;

    // Parse the number from task data
    const num_str = std.mem.trim(u8, task.data, &std.ascii.whitespace);
    const num = try std.fmt.parseInt(u64, num_str, 10);

    if (num < 2) {
        return variable_tester.Result.init(task.id, false, task.data, 0.0);
    }

    if (num == 2) {
        return variable_tester.Result.init(task.id, true, task.data, 1.0);
    }

    if (num % 2 == 0) {
        return variable_tester.Result.init(task.id, false, task.data, 0.0);
    }

    // Trial division
    var i: u64 = 3;
    const sqrt_num = @as(u64, @intFromFloat(@sqrt(@as(f64, @floatFromInt(num))))) + 1;

    while (i <= sqrt_num) : (i += 2) {
        if (num % i == 0) {
            return variable_tester.Result.init(task.id, false, task.data, 0.0);
        }
    }

    return variable_tester.Result.init(task.id, true, task.data, 1.0);
}

/// Hash Collision Test Function
/// Tests if a given input produces a specific hash prefix
pub fn testHashCollision(task: *const variable_tester.Task, allocator: std.mem.Allocator) !variable_tester.Result {
    _ = allocator;

    // Target: find input that produces hash starting with 0x0000
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(task.data, &hash, .{});

    // Check if first 2 bytes are zero
    const success = hash[0] == 0 and hash[1] == 0;

    // Score based on how many leading zero bits
    var score: f64 = 0.0;
    if (success) {
        // Count leading zero bits
        for (hash) |byte| {
            if (byte == 0) {
                score += 8.0;
            } else {
                score += @as(f64, @floatFromInt(@clz(byte)));
                break;
            }
        }
    }

    return variable_tester.Result.init(task.id, success, task.data, score);
}

/// Mathematical Formula Validator
/// Tests if a formula satisfies certain mathematical properties
pub fn testMathFormula(task: *const variable_tester.Task, allocator: std.mem.Allocator) !variable_tester.Result {
    _ = allocator;

    // Example: test if the formula "a^2 + b^2 = c^2" holds for given values
    // task.data format: "a,b,c" (e.g., "3,4,5")

    var iter = std.mem.splitScalar(u8, task.data, ',');

    const a_str = iter.next() orelse return error.InvalidFormat;
    const b_str = iter.next() orelse return error.InvalidFormat;
    const c_str = iter.next() orelse return error.InvalidFormat;

    const a = try std.fmt.parseInt(i64, std.mem.trim(u8, a_str, &std.ascii.whitespace), 10);
    const b = try std.fmt.parseInt(i64, std.mem.trim(u8, b_str, &std.ascii.whitespace), 10);
    const c = try std.fmt.parseInt(i64, std.mem.trim(u8, c_str, &std.ascii.whitespace), 10);

    const success = (a * a + b * b) == (c * c);
    const score: f64 = if (success) 1.0 else 0.0;

    return variable_tester.Result.init(task.id, success, task.data, score);
}

/// Numeric Match Test Function
/// Exhaustive search benchmark - finds a specific "secret" number
/// Used to verify swarm can search through millions of possibilities
pub const SECRET_NUMBER: u64 = 8_734_501;

pub fn testNumericMatch(task: *const variable_tester.Task, allocator: std.mem.Allocator) !variable_tester.Result {
    _ = allocator;

    // Parse the number from task data
    const num_str = std.mem.trim(u8, task.data, &std.ascii.whitespace);
    const num = std.fmt.parseInt(u64, num_str, 10) catch {
        return variable_tester.Result.init(task.id, false, task.data, 0.0);
    };

    // Check if this number matches the secret
    const success = (num == SECRET_NUMBER);
    const score: f64 = if (success) 1.0 else 0.0;

    return variable_tester.Result.init(task.id, success, task.data, score);
}
