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

    // Tokenizer data (slices point into mmap or allocated)
    tokens: [][]const u8,
    scores: []f32,
    token_types: []u32,
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
            .tokens = &.{},
            .scores = &.{},
            .token_types = &.{},
            .bos_id = 1,
            .eos_id = 2,
            .metadata = std.StringHashMap(MetadataValue).init(allocator),
            .tensors = std.StringHashMap(TensorInfo).init(allocator),
            .data_offset = 0,
            .tensor_count = 0,
        };

        try self.parse();
        return self;
    }

    pub fn close(self: *GGUFFile) void {
        if (self.tokens.len > 0) self.allocator.free(self.tokens);
        if (self.scores.len > 0) self.allocator.free(self.scores);
        if (self.token_types.len > 0) self.allocator.free(self.token_types);
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
        const magic = cursor.readBytes(4);
        if (!std.mem.eql(u8, magic, &GGUF_MAGIC)) return error.InvalidMagic;

        const version = cursor.readU32();
        if (version < 2 or version > 3) return error.UnsupportedVersion;

        self.tensor_count = cursor.readU64();
        const metadata_kv_count = cursor.readU64();

        // Parse metadata KV pairs
        for (0..metadata_kv_count) |_| {
            const key = cursor.readString();
            const value = try cursor.readMetadataValue();
            try self.metadata.put(key, value);
        }

        // Parse tensor infos
        for (0..self.tensor_count) |_| {
            const name = cursor.readString();
            const n_dims = cursor.readU32();
            var dims: [4]u64 = .{ 1, 1, 1, 1 };
            for (0..n_dims) |d| {
                dims[d] = cursor.readU64();
            }
            const dtype_raw = cursor.readU32();
            const dtype: GGMLType = @enumFromInt(dtype_raw);
            const offset = cursor.readU64();

            try self.tensors.put(name, TensorInfo{
                .name = name,
                .n_dims = n_dims,
                .dims = dims,
                .dtype = dtype,
                .offset = offset,
            });
        }

        // Data section starts at alignment boundary after all tensor infos
        const alignment = if (self.metadata.get("general.alignment")) |v|
            v.asU32() orelse GGUF_DEFAULT_ALIGNMENT
        else
            GGUF_DEFAULT_ALIGNMENT;

        self.data_offset = alignUp(cursor.pos, alignment);

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
                    const src: [*]const u32 = @alignCast(@ptrCast(arr.data_ptr));
                    @memcpy(types, src[0..count]);
                } else {
                    @memset(types, 0);
                }
                self.token_types = types;
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

const Reader = struct {
    data: []const u8,
    pos: usize,

    fn readU8(self: *Reader) u8 {
        const val = self.data[self.pos];
        self.pos += 1;
        return val;
    }

    fn readU32(self: *Reader) u32 {
        const val = std.mem.readInt(u32, self.data[self.pos..][0..4], .little);
        self.pos += 4;
        return val;
    }

    fn readI32(self: *Reader) i32 {
        const val = std.mem.readInt(i32, self.data[self.pos..][0..4], .little);
        self.pos += 4;
        return val;
    }

    fn readU64(self: *Reader) u64 {
        const val = std.mem.readInt(u64, self.data[self.pos..][0..8], .little);
        self.pos += 8;
        return val;
    }

    fn readI64(self: *Reader) i64 {
        const val = std.mem.readInt(i64, self.data[self.pos..][0..8], .little);
        self.pos += 8;
        return val;
    }

    fn readF32(self: *Reader) f32 {
        const bits = self.readU32();
        return @bitCast(bits);
    }

    fn readF64(self: *Reader) f64 {
        const bits = self.readU64();
        return @bitCast(bits);
    }

    fn readBytes(self: *Reader, n: usize) []const u8 {
        const slice = self.data[self.pos .. self.pos + n];
        self.pos += n;
        return slice;
    }

    fn readString(self: *Reader) []const u8 {
        const len: usize = @intCast(self.readU64());
        return self.readBytes(len);
    }

    fn readBool(self: *Reader) bool {
        return self.readU8() != 0;
    }

    fn readMetadataValue(self: *Reader) !MetadataValue {
        const vtype: MetadataValueType = @enumFromInt(self.readU32());
        return self.readValueOfType(vtype);
    }

    fn readValueOfType(self: *Reader, vtype: MetadataValueType) !MetadataValue {
        return switch (vtype) {
            .uint8 => .{ .uint8 = self.readU8() },
            .int8 => .{ .int8 = @bitCast(self.readU8()) },
            .uint16 => blk: {
                const val = std.mem.readInt(u16, self.data[self.pos..][0..2], .little);
                self.pos += 2;
                break :blk .{ .uint16 = val };
            },
            .int16 => blk: {
                const val = std.mem.readInt(i16, self.data[self.pos..][0..2], .little);
                self.pos += 2;
                break :blk .{ .int16 = val };
            },
            .uint32 => .{ .uint32 = self.readU32() },
            .int32 => .{ .int32 = self.readI32() },
            .float32 => .{ .float32 = self.readF32() },
            .bool_ => .{ .bool_ = self.readBool() },
            .string => .{ .string = self.readString() },
            .uint64 => .{ .uint64 = self.readU64() },
            .int64 => .{ .int64 = self.readI64() },
            .float64 => .{ .float64 = self.readF64() },
            .array => blk: {
                const elem_type: MetadataValueType = @enumFromInt(self.readU32());
                const len = self.readU64();
                const data_start = self.data.ptr + self.pos;
                // Skip past array data
                const count: usize = @intCast(len);
                for (0..count) |_| {
                    self.skipValueOfType(elem_type);
                }
                break :blk .{ .array = .{
                    .elem_type = elem_type,
                    .len = len,
                    .data_ptr = data_start,
                } };
            },
        };
    }

    fn skipValueOfType(self: *Reader, vtype: MetadataValueType) void {
        switch (vtype) {
            .uint8, .int8 => self.pos += 1,
            .uint16, .int16 => self.pos += 2,
            .uint32, .int32, .float32 => self.pos += 4,
            .uint64, .int64, .float64 => self.pos += 8,
            .bool_ => self.pos += 1,
            .string => {
                const len: usize = @intCast(self.readU64());
                self.pos += len;
            },
            .array => {
                const elem_type: MetadataValueType = @enumFromInt(self.readU32());
                const len = self.readU64();
                const count: usize = @intCast(len);
                for (0..count) |_| {
                    self.skipValueOfType(elem_type);
                }
            },
        }
    }
};

fn readU64FromPtr(ptr: [*]const u8) usize {
    const val = std.mem.readInt(u64, ptr[0..8], .little);
    return @intCast(val);
}

fn alignUp(pos: usize, alignment: usize) usize {
    return (pos + alignment - 1) & ~(alignment - 1);
}
