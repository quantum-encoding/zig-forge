const std = @import("std");
const Allocator = std.mem.Allocator;
const tensor_mod = @import("tensor.zig");
const TensorView = tensor_mod.TensorView;
const GGMLType = tensor_mod.GGMLType;

pub const GGUF_MAGIC: [4]u8 = .{ 'G', 'G', 'U', 'F' };
pub const GGUF_VERSION: u32 = 3;
pub const GGUF_DEFAULT_ALIGNMENT: usize = 32;

pub const MetadataValueType = enum(u32) {
    uint8 = 0,
    int8 = 1,
    uint16 = 2,
    int16 = 3,
    uint32 = 4,
    int32 = 5,
    float32 = 6,
    bool_ = 7,
    string = 8,
    array = 9,
    uint64 = 10,
    int64 = 11,
    float64 = 12,
};

pub const MetadataValue = union(MetadataValueType) {
    uint8: u8,
    int8: i8,
    uint16: u16,
    int16: i16,
    uint32: u32,
    int32: i32,
    float32: f32,
    bool_: bool,
    string: []const u8,
    array: ArrayValue,
    uint64: u64,
    int64: i64,
    float64: f64,

    pub fn asU32(self: MetadataValue) ?u32 {
        return switch (self) {
            .uint32 => |v| v,
            .int32 => |v| if (v >= 0) @intCast(v) else null,
            .uint64 => |v| if (v <= std.math.maxInt(u32)) @intCast(v) else null,
            .int64 => |v| if (v >= 0 and v <= std.math.maxInt(u32)) @intCast(v) else null,
            .uint16 => |v| @intCast(v),
            .uint8 => |v| @intCast(v),
            else => null,
        };
    }

    pub fn asF32(self: MetadataValue) ?f32 {
        return switch (self) {
            .float32 => |v| v,
            .float64 => |v| @floatCast(v),
            .uint32 => |v| @floatFromInt(v),
            .int32 => |v| @floatFromInt(v),
            else => null,
        };
    }

    pub fn asString(self: MetadataValue) ?[]const u8 {
        return switch (self) {
            .string => |v| v,
            else => null,
        };
    }
};

pub const ArrayValue = struct {
    elem_type: MetadataValueType,
    len: u64,
    /// Raw pointer into mmap'd region — elements are parsed on demand
    data_ptr: [*]const u8,
};

pub const TensorInfo = struct {
    name: []const u8,
    n_dims: u32,
    dims: [4]u64,
    dtype: GGMLType,
    offset: u64, // offset from start of tensor data section
};

pub const GGUFFile = struct {
    allocator: Allocator,

    // mmap'd file
    mmap_ptr: [*]align(4096) const u8,
    mmap_len: usize,

    // Model architecture params
    architecture: []const u8,
    block_count: u32,
    embedding_length: u32,
    head_count: u32,
    head_count_kv: u32,
    feed_forward_length: u32,
    context_length: u32,
    vocab_size: u32,
    rope_freq_base: f32,
    rms_norm_eps: f32,
    head_dim: u32, // Qwen3: attention.key_length, NOT embedding_length/head_count
    pooling_type: u32, // 0=none 1=mean 2=cls 3=last (embedding models)

    // Tokenizer data (slices point into mmap or allocated)
    tokens: [][]const u8,
    scores: []f32,
    token_types: []u32,
    merges: [][]const u8, // GPT-2 BPE merge rules ("a b"), rank = index
    tokenizer_model: []const u8, // "llama" (SentencePiece) | "gpt2" (byte-level BPE)
    add_bos: bool,
    add_eos: bool,
    bos_id: u32,
    eos_id: u32,

    // All metadata for generic access
    metadata: std.StringHashMap(MetadataValue),

    // Tensor registry
    tensors: std.StringHashMap(TensorInfo),
    data_offset: usize, // byte offset in file where tensor data starts
    tensor_count: u64,

    pub fn open(allocator: Allocator, path: []const u8) !GGUFFile {
        // Open via C for cross-platform compat (Zig 0.16 file API limitations)
        const c_path = try allocator.dupeZ(u8, path);
        defer allocator.free(c_path);

        const fd = std.c.open(c_path.ptr, .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
        if (fd < 0) return error.FileNotFound;
        defer _ = std.c.close(fd);

        // Get file size via lseek to avoid fstat (std.c.fstat is void on linux in Zig 0.16)
        const end_pos = std.c.lseek(fd, 0, std.c.SEEK.END);
        if (end_pos < 0) return error.StatFailed;
        _ = std.c.lseek(fd, 0, std.c.SEEK.SET);
        const file_size: usize = @intCast(end_pos);
        if (file_size < 24) return error.FileTooSmall;

        // mmap the entire file
        const mmap_result = std.c.mmap(null, file_size, .{ .READ = true }, .{ .TYPE = .PRIVATE }, fd, 0);
        if (mmap_result == std.c.MAP_FAILED) return error.MmapFailed;
        const mmap_ptr: [*]align(4096) const u8 = @alignCast(@ptrCast(mmap_result));

        var self = GGUFFile{
            .allocator = allocator,
            .mmap_ptr = mmap_ptr,
            .mmap_len = file_size,
            .architecture = "",
            .block_count = 0,
            .embedding_length = 0,
            .head_count = 0,
            .head_count_kv = 0,
            .feed_forward_length = 0,
            .context_length = 0,
            .vocab_size = 0,
            .rope_freq_base = 10000.0,
            .rms_norm_eps = 1e-5,
            .head_dim = 0,
            .pooling_type = 0,
            .tokens = &.{},
            .scores = &.{},
            .token_types = &.{},
            .merges = &.{},
            .tokenizer_model = "",
            .add_bos = true,
            .add_eos = false,
            .bos_id = 1,
            .eos_id = 2,
            .metadata = std.StringHashMap(MetadataValue).init(allocator),
            .tensors = std.StringHashMap(TensorInfo).init(allocator),
            .data_offset = 0,
            .tensor_count = 0,
        };

        // On a malformed/truncated file `parse` returns an error; release the
        // mmap and any partially-built maps/allocations instead of leaking them.
        errdefer self.close();
        try self.parse();
        return self;
    }

    pub fn close(self: *GGUFFile) void {
        if (self.tokens.len > 0) self.allocator.free(self.tokens);
        if (self.scores.len > 0) self.allocator.free(self.scores);
        if (self.token_types.len > 0) self.allocator.free(self.token_types);
        if (self.merges.len > 0) self.allocator.free(self.merges);
        self.metadata.deinit();
        self.tensors.deinit();
        _ = std.c.munmap(@ptrCast(@constCast(@alignCast(self.mmap_ptr))), self.mmap_len);
    }

    /// Get a tensor view by name — zero-copy pointer into mmap'd data
    pub fn getTensor(self: *const GGUFFile, name: []const u8) ?TensorView {
        const info = self.tensors.get(name) orelse return null;
        const data_ptr = self.mmap_ptr + self.data_offset + info.offset;
        return TensorView{
            .data = data_ptr,
            .shape = info.dims,
            .n_dims = info.n_dims,
            .dtype = info.dtype,
        };
    }

    // ── Internal parsing ──

    fn parse(self: *GGUFFile) !void {
        var cursor = Reader{ .data = self.mmap_ptr[0..self.mmap_len], .pos = 0 };

        // Header
        const magic = try cursor.readBytes(4);
        if (!std.mem.eql(u8, magic, &GGUF_MAGIC)) return error.InvalidMagic;

        const version = try cursor.readU32();
        if (version < 2 or version > 3) return error.UnsupportedVersion;

        self.tensor_count = try cursor.readU64();
        const metadata_kv_count = try cursor.readU64();

        // Each KV pair / tensor info consumes several header bytes, so the file
        // cannot contain more of them than it has bytes. Cap the loop counts
        // against the mapped length to reject absurd counts up front (and to
        // keep the loop bound sane) rather than iterating billions of times.
        if (metadata_kv_count > self.mmap_len or self.tensor_count > self.mmap_len) {
            return error.CorruptHeader;
        }

        // Parse metadata KV pairs
        for (0..metadata_kv_count) |_| {
            const key = try cursor.readString();
            const value = try cursor.readMetadataValue();
            try self.metadata.put(key, value);
        }

        // Parse tensor infos
        for (0..self.tensor_count) |_| {
            const name = try cursor.readString();
            const n_dims = try cursor.readU32();
            // GGUF tensors have at most 4 dimensions; a larger value would write
            // past the fixed `dims` array (an OOB stack write with safety off).
            if (n_dims > 4) return error.InvalidTensorDims;
            var dims: [4]u64 = .{ 1, 1, 1, 1 };
            for (0..n_dims) |d| {
                dims[d] = try cursor.readU64();
            }
            const dtype_raw = try cursor.readU32();
            const dtype: GGMLType = @enumFromInt(dtype_raw); // non-exhaustive enum: any u32 is valid
            const offset = try cursor.readU64();

            try self.tensors.put(name, TensorInfo{
                .name = name,
                .n_dims = n_dims,
                .dims = dims,
                .dtype = dtype,
                .offset = offset,
            });
        }

        // Data section starts at alignment boundary after all tensor infos.
        // The alignment comes from attacker-controlled metadata: reject zero or
        // non-power-of-two values, which would make `alignUp` underflow or emit
        // a wrong data offset.
        const alignment = if (self.metadata.get("general.alignment")) |v|
            v.asU32() orelse GGUF_DEFAULT_ALIGNMENT
        else
            GGUF_DEFAULT_ALIGNMENT;
        if (alignment == 0 or (alignment & (alignment - 1)) != 0) {
            return error.InvalidAlignment;
        }

        self.data_offset = alignUp(cursor.pos, alignment);
        // The tensor-data section must begin inside the mapping.
        if (self.data_offset > self.mmap_len) return error.Truncated;

        // Extract model parameters from metadata
        try self.extractModelParams();
        try self.extractTokenizer();
    }

    fn extractModelParams(self: *GGUFFile) !void {
        self.architecture = if (self.metadata.get("general.architecture")) |v| v.asString() orelse "llama" else "llama";
        const arch = self.architecture;

        // Helper to look up arch-prefixed keys
        var key_buf: [256]u8 = undefined;

        self.block_count = self.getArchU32(arch, "block_count", &key_buf) orelse 0;
        self.embedding_length = self.getArchU32(arch, "embedding_length", &key_buf) orelse 0;
        self.head_count = self.getArchU32(arch, "attention.head_count", &key_buf) orelse 0;
        self.head_count_kv = self.getArchU32(arch, "attention.head_count_kv", &key_buf) orelse self.head_count;
        self.feed_forward_length = self.getArchU32(arch, "feed_forward_length", &key_buf) orelse 0;
        self.context_length = self.getArchU32(arch, "context_length", &key_buf) orelse 2048;
        self.vocab_size = self.getArchU32(arch, "vocab_size", &key_buf) orelse 0;

        self.rope_freq_base = self.getArchF32(arch, "rope.freq_base", &key_buf) orelse 10000.0;
        self.rms_norm_eps = self.getArchF32(arch, "attention.layer_norm_rms_epsilon", &key_buf) orelse 1e-5;

        // Qwen3 (and other models) set head_dim explicitly via key_length; it is
        // NOT always embedding_length/head_count (Qwen3-4B: 128 vs 2560/32=80).
        self.head_dim = self.getArchU32(arch, "attention.key_length", &key_buf) orelse
            (if (self.head_count > 0) self.embedding_length / self.head_count else 0);
        self.pooling_type = self.getArchU32(arch, "pooling_type", &key_buf) orelse 0;
    }

    pub fn getArchU32(self: *const GGUFFile, arch: []const u8, suffix: []const u8, buf: *[256]u8) ?u32 {
        const key = std.fmt.bufPrint(buf, "{s}.{s}", .{ arch, suffix }) catch return null;
        const val = self.metadata.get(key) orelse return null;
        return val.asU32();
    }

    pub fn getArchF32(self: *const GGUFFile, arch: []const u8, suffix: []const u8, buf: *[256]u8) ?f32 {
        const key = std.fmt.bufPrint(buf, "{s}.{s}", .{ arch, suffix }) catch return null;
        const val = self.metadata.get(key) orelse return null;
        return val.asF32();
    }

    fn extractTokenizer(self: *GGUFFile) !void {
        // Tokens array
        if (self.metadata.get("tokenizer.ggml.tokens")) |val| {
            if (val == .array) {
                const arr = val.array;
                if (arr.elem_type == .string) {
                    const count: usize = @intCast(arr.len);
                    var tokens = try self.allocator.alloc([]const u8, count);
                    var ptr = arr.data_ptr;
                    for (0..count) |i| {
                        const slen = readU64FromPtr(ptr);
                        ptr += 8;
                        tokens[i] = ptr[0..slen];
                        ptr += slen;
                    }
                    self.tokens = tokens;
                    if (self.vocab_size == 0) self.vocab_size = @intCast(count);
                }
            }
        }

        // Scores array (read byte-by-byte — data may not be 4-byte aligned)
        if (self.metadata.get("tokenizer.ggml.scores")) |val| {
            if (val == .array) {
                const arr = val.array;
                if (arr.elem_type == .float32) {
                    const count: usize = @intCast(arr.len);
                    const scores = try self.allocator.alloc(f32, count);
                    const raw = arr.data_ptr;
                    for (0..count) |si| {
                        const offset = si * 4;
                        scores[si] = @bitCast(std.mem.readInt(u32, raw[offset..][0..4], .little));
                    }
                    self.scores = scores;
                }
            }
        }

        // Token types
        if (self.metadata.get("tokenizer.ggml.token_type")) |val| {
            if (val == .array) {
                const arr = val.array;
                const count: usize = @intCast(arr.len);
                const types = try self.allocator.alloc(u32, count);
                if (arr.elem_type == .int32 or arr.elem_type == .uint32) {
                    // Array data may not be 4-byte aligned in the mmap — read byte-by-byte.
                    const raw = arr.data_ptr;
                    for (0..count) |ti| {
                        types[ti] = std.mem.readInt(u32, raw[ti * 4 ..][0..4], .little);
                    }
                } else {
                    @memset(types, 0);
                }
                self.token_types = types;
            }
        }

        // Tokenizer family: "llama" (SentencePiece) vs "gpt2" (byte-level BPE, Qwen3)
        if (self.metadata.get("tokenizer.ggml.model")) |v| {
            self.tokenizer_model = v.asString() orelse "";
        }
        if (self.metadata.get("tokenizer.ggml.add_bos_token")) |v| {
            if (v == .bool_) self.add_bos = v.bool_;
        }
        if (self.metadata.get("tokenizer.ggml.add_eos_token")) |v| {
            if (v == .bool_) self.add_eos = v.bool_;
        }

        // Merges (string array "a b") — present for GPT-2 BPE; rank == array index
        if (self.metadata.get("tokenizer.ggml.merges")) |val| {
            if (val == .array and val.array.elem_type == .string) {
                const arr = val.array;
                const count: usize = @intCast(arr.len);
                const merges = try self.allocator.alloc([]const u8, count);
                var ptr = arr.data_ptr;
                for (0..count) |i| {
                    const slen = readU64FromPtr(ptr);
                    ptr += 8;
                    merges[i] = ptr[0..slen];
                    ptr += slen;
                }
                self.merges = merges;
            }
        }

        // Special token IDs
        if (self.metadata.get("tokenizer.ggml.bos_token_id")) |v| {
            self.bos_id = v.asU32() orelse 1;
        }
        if (self.metadata.get("tokenizer.ggml.eos_token_id")) |v| {
            self.eos_id = v.asU32() orelse 2;
        }
    }

    /// Count parameters (sum of all tensor element counts)
    pub fn parameterCount(self: *const GGUFFile) u64 {
        var total: u64 = 0;
        var it = self.tensors.valueIterator();
        while (it.next()) |info| {
            var elems: u64 = 1;
            for (0..info.n_dims) |d| {
                elems *= info.dims[d];
            }
            total += elems;
        }
        return total;
    }

    /// Get the dominant quantization type
    pub fn dominantQuantType(self: *const GGUFFile) GGMLType {
        var counts = [_]u32{0} ** 32;
        var it = self.tensors.valueIterator();
        while (it.next()) |info| {
            const idx = @intFromEnum(info.dtype);
            if (idx < 32) counts[idx] += 1;
        }
        var best: u32 = 0;
        var best_count: u32 = 0;
        for (counts, 0..) |c, i| {
            if (c > best_count) {
                best_count = c;
                best = @intCast(i);
            }
        }
        return @enumFromInt(best);
    }
};

// ── Reader utility for sequential parsing of mmap'd buffer ──

/// Errors raised while parsing a malformed or truncated GGUF file.
pub const GgufError = error{
    /// A read would run past the end of the mmap'd buffer.
    Truncated,
    /// A metadata value-type tag did not name a known type.
    InvalidType,
    /// Nested arrays are not permitted by the GGUF spec.
    NestedArray,
};

const Reader = struct {
    data: []const u8,
    pos: usize,

    /// Reject any read that would overrun the buffer. `data.len - pos` never
    /// underflows because every successful read keeps `pos <= data.len`.
    inline fn ensure(self: *const Reader, n: usize) GgufError!void {
        if (n > self.data.len - self.pos) return error.Truncated;
    }

    fn readU8(self: *Reader) GgufError!u8 {
        try self.ensure(1);
        const val = self.data[self.pos];
        self.pos += 1;
        return val;
    }

    fn readU16(self: *Reader) GgufError!u16 {
        try self.ensure(2);
        const val = std.mem.readInt(u16, self.data[self.pos..][0..2], .little);
        self.pos += 2;
        return val;
    }

    fn readI16(self: *Reader) GgufError!i16 {
        try self.ensure(2);
        const val = std.mem.readInt(i16, self.data[self.pos..][0..2], .little);
        self.pos += 2;
        return val;
    }

    fn readU32(self: *Reader) GgufError!u32 {
        try self.ensure(4);
        const val = std.mem.readInt(u32, self.data[self.pos..][0..4], .little);
        self.pos += 4;
        return val;
    }

    fn readI32(self: *Reader) GgufError!i32 {
        try self.ensure(4);
        const val = std.mem.readInt(i32, self.data[self.pos..][0..4], .little);
        self.pos += 4;
        return val;
    }

    fn readU64(self: *Reader) GgufError!u64 {
        try self.ensure(8);
        const val = std.mem.readInt(u64, self.data[self.pos..][0..8], .little);
        self.pos += 8;
        return val;
    }

    fn readI64(self: *Reader) GgufError!i64 {
        try self.ensure(8);
        const val = std.mem.readInt(i64, self.data[self.pos..][0..8], .little);
        self.pos += 8;
        return val;
    }

    fn readF32(self: *Reader) GgufError!f32 {
        const bits = try self.readU32();
        return @bitCast(bits);
    }

    fn readF64(self: *Reader) GgufError!f64 {
        const bits = try self.readU64();
        return @bitCast(bits);
    }

    fn readBytes(self: *Reader, n: usize) GgufError![]const u8 {
        try self.ensure(n);
        const slice = self.data[self.pos .. self.pos + n];
        self.pos += n;
        return slice;
    }

    fn readString(self: *Reader) GgufError![]const u8 {
        const len: usize = @intCast(try self.readU64());
        return self.readBytes(len);
    }

    fn readBool(self: *Reader) GgufError!bool {
        return (try self.readU8()) != 0;
    }

    /// Read a value-type tag and reject any value outside the defined enum range,
    /// since `@enumFromInt` on an out-of-range value is illegal behavior in
    /// ReleaseFast (the FFI libraries are built with safety off).
    fn readValueType(self: *Reader) GgufError!MetadataValueType {
        const raw = try self.readU32();
        if (raw > @intFromEnum(MetadataValueType.float64)) return error.InvalidType;
        return @enumFromInt(raw);
    }

    fn readMetadataValue(self: *Reader) GgufError!MetadataValue {
        const vtype = try self.readValueType();
        return self.readValueOfType(vtype, false);
    }

    /// `in_array` guards against nested arrays (disallowed by the spec) so a
    /// hostile file cannot drive unbounded recursion here.
    fn readValueOfType(self: *Reader, vtype: MetadataValueType, in_array: bool) GgufError!MetadataValue {
        return switch (vtype) {
            .uint8 => .{ .uint8 = try self.readU8() },
            .int8 => .{ .int8 = @bitCast(try self.readU8()) },
            .uint16 => .{ .uint16 = try self.readU16() },
            .int16 => .{ .int16 = try self.readI16() },
            .uint32 => .{ .uint32 = try self.readU32() },
            .int32 => .{ .int32 = try self.readI32() },
            .float32 => .{ .float32 = try self.readF32() },
            .bool_ => .{ .bool_ = try self.readBool() },
            .string => .{ .string = try self.readString() },
            .uint64 => .{ .uint64 = try self.readU64() },
            .int64 => .{ .int64 = try self.readI64() },
            .float64 => .{ .float64 = try self.readF64() },
            .array => blk: {
                if (in_array) return error.NestedArray;
                const elem_type = try self.readValueType();
                const len = try self.readU64();
                const data_start = self.data.ptr + self.pos;
                // Skip past array data, bounds-checking every element. This
                // validates the whole array region up front, so later readers
                // that walk `data_ptr` with `len` stay inside the mmap.
                const count: usize = @intCast(len);
                for (0..count) |_| {
                    try self.skipValueOfType(elem_type);
                }
                break :blk .{ .array = .{
                    .elem_type = elem_type,
                    .len = len,
                    .data_ptr = data_start,
                } };
            },
        };
    }

    fn skipValueOfType(self: *Reader, vtype: MetadataValueType) GgufError!void {
        const width: usize = switch (vtype) {
            .uint8, .int8, .bool_ => 1,
            .uint16, .int16 => 2,
            .uint32, .int32, .float32 => 4,
            .uint64, .int64, .float64 => 8,
            .string => {
                const len: usize = @intCast(try self.readU64());
                try self.ensure(len);
                self.pos += len;
                return;
            },
            .array => return error.NestedArray,
        };
        try self.ensure(width);
        self.pos += width;
    }
};

fn readU64FromPtr(ptr: [*]const u8) usize {
    const val = std.mem.readInt(u64, ptr[0..8], .little);
    return @intCast(val);
}

fn alignUp(pos: usize, alignment: usize) usize {
    return (pos + alignment - 1) & ~(alignment - 1);
}
