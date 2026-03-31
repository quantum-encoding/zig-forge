const std = @import("std");
const Allocator = std.mem.Allocator;
const tensor_mod = @import("tensor.zig");
const TensorView = tensor_mod.TensorView;
const GGMLType = tensor_mod.GGMLType;

/// Whisper ggml binary file loader (whisper.cpp format)
///
/// File format:
///   - Header: magic (0x67676d6c) + 11 i32 hyperparams
///   - Mel filterbank: n_mels × n_fft as f32
///   - Tokenizer: n_tokens × (len + bytes)
///   - Tensors: sequential (n_dims, name_len, ftype, dims[], name, raw_data)
///     No alignment — data immediately follows name bytes.

pub const WHISPER_MAGIC: u32 = 0x67676d6c; // "ggml"

pub const WhisperHParams = struct {
    n_vocab: u32,
    n_audio_ctx: u32,
    n_audio_state: u32,
    n_audio_head: u32,
    n_audio_layer: u32,
    n_text_ctx: u32,
    n_text_state: u32,
    n_text_head: u32,
    n_text_layer: u32,
    n_mels: u32,
    ftype: u32, // 0=f32, 1=f16 (global hint; per-tensor ftype overrides)
};

pub const WhisperTensorInfo = struct {
    name: []const u8,
    n_dims: u32,
    dims: [4]u32,
    ftype: u32, // 0=f32, 1=f16
    data_offset: usize,
    aligned_data: ?[*]const u8, // non-null if we allocated an aligned copy
};

pub const WhisperFile = struct {
    allocator: Allocator,

    // mmap'd file
    mmap_ptr: [*]align(4096) const u8,
    mmap_len: usize,

    // Hyperparameters
    hparams: WhisperHParams,

    // Mel filterbank from the file [n_mels × n_fft_bins]
    mel_filters: []const f32,
    mel_n_mels: u32,
    mel_n_fft: u32,

    // Tokenizer
    tokens: [][]const u8,
    n_tokens: u32,

    // Tensor registry
    tensors: std.StringHashMap(WhisperTensorInfo),

    // Aligned copies of f32 tensors with unaligned data offsets
    aligned_bufs: std.ArrayListUnmanaged([]align(4) u8),

    pub fn open(allocator: Allocator, path: []const u8) !WhisperFile {
        const c_path = try allocator.dupeZ(u8, path);
        defer allocator.free(c_path);

        const fd = std.c.open(c_path.ptr, .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
        if (fd < 0) return error.FileNotFound;
        defer _ = std.c.close(fd);

        const end_pos = std.c.lseek(fd, 0, std.c.SEEK.END);
        if (end_pos < 0) return error.StatFailed;
        _ = std.c.lseek(fd, 0, std.c.SEEK.SET);
        const file_size: usize = @intCast(end_pos);
        if (file_size < 48) return error.FileTooSmall;

        const mmap_result = std.c.mmap(null, file_size, .{ .READ = true }, .{ .TYPE = .PRIVATE }, fd, 0);
        if (mmap_result == std.c.MAP_FAILED) return error.MmapFailed;
        const mmap_ptr: [*]align(4096) const u8 = @alignCast(@ptrCast(mmap_result));

        var self = WhisperFile{
            .allocator = allocator,
            .mmap_ptr = mmap_ptr,
            .mmap_len = file_size,
            .hparams = undefined,
            .mel_filters = &.{},
            .mel_n_mels = 0,
            .mel_n_fft = 0,
            .tokens = &.{},
            .n_tokens = 0,
            .tensors = std.StringHashMap(WhisperTensorInfo).init(allocator),
            .aligned_bufs = std.ArrayListUnmanaged([]align(4) u8).empty,
        };

        try self.parse();
        return self;
    }

    pub fn close(self: *WhisperFile) void {
        // Free aligned copies
        for (self.aligned_bufs.items) |buf| {
            self.allocator.free(buf);
        }
        self.aligned_bufs.deinit(self.allocator);
        if (self.tokens.len > 0) self.allocator.free(self.tokens);
        self.tensors.deinit();
        _ = std.c.munmap(@ptrCast(@constCast(@alignCast(self.mmap_ptr))), self.mmap_len);
    }

    pub fn getTensor(self: *const WhisperFile, name: []const u8) ?TensorView {
        const info = self.tensors.get(name) orelse return null;
        const data_ptr = info.aligned_data orelse (self.mmap_ptr + info.data_offset);
        // Convert dims u32 → u64 and map ftype to GGMLType
        var shape: [4]u64 = .{ 1, 1, 1, 1 };
        for (0..info.n_dims) |d| {
            shape[d] = info.dims[d];
        }
        const dtype: GGMLType = if (info.ftype == 1) .f16 else .f32;
        return TensorView{
            .data = data_ptr,
            .shape = shape,
            .n_dims = info.n_dims,
            .dtype = dtype,
        };
    }

    fn parse(self: *WhisperFile) !void {
        var pos: usize = 0;
        const data = self.mmap_ptr[0..self.mmap_len];

        // Magic
        const magic = readU32(data, pos);
        pos += 4;
        if (magic != WHISPER_MAGIC) return error.InvalidMagic;

        // Hyperparameters (11 × i32)
        self.hparams = WhisperHParams{
            .n_vocab = readU32(data, pos),
            .n_audio_ctx = readU32(data, pos + 4),
            .n_audio_state = readU32(data, pos + 8),
            .n_audio_head = readU32(data, pos + 12),
            .n_audio_layer = readU32(data, pos + 16),
            .n_text_ctx = readU32(data, pos + 20),
            .n_text_state = readU32(data, pos + 24),
            .n_text_head = readU32(data, pos + 28),
            .n_text_layer = readU32(data, pos + 32),
            .n_mels = readU32(data, pos + 36),
            .ftype = readU32(data, pos + 40),
        };
        pos += 44;

        // Mel filterbank
        self.mel_n_mels = readU32(data, pos);
        pos += 4;
        self.mel_n_fft = readU32(data, pos);
        pos += 4;
        const mel_count: usize = @as(usize, self.mel_n_mels) * self.mel_n_fft;
        const mel_ptr: [*]const f32 = @alignCast(@ptrCast(data.ptr + pos));
        self.mel_filters = mel_ptr[0..mel_count];
        pos += mel_count * 4;

        // Tokenizer
        self.n_tokens = readU32(data, pos);
        pos += 4;
        const tokens = try self.allocator.alloc([]const u8, self.n_tokens);
        for (0..self.n_tokens) |i| {
            const tlen = readU32(data, pos);
            pos += 4;
            tokens[i] = data[pos..][0..tlen];
            pos += tlen;
        }
        self.tokens = tokens;

        // Tensors
        while (pos + 12 <= self.mmap_len) {
            const n_dims = readU32(data, pos);
            const name_len = readU32(data, pos + 4);
            const ftype = readU32(data, pos + 8);
            pos += 12;

            if (n_dims < 1 or n_dims > 4 or name_len < 1 or name_len > 256) break;

            var dims: [4]u32 = .{ 1, 1, 1, 1 };
            for (0..n_dims) |d| {
                dims[d] = readU32(data, pos);
                pos += 4;
            }

            const name = data[pos..][0..name_len];
            pos += name_len;

            const data_offset = pos;

            // Compute data size
            var n_elems: usize = 1;
            for (0..n_dims) |d| n_elems *= dims[d];
            const bytes_per_elem: usize = if (ftype == 1) 2 else 4;
            const data_size = n_elems * bytes_per_elem;
            pos += data_size;

            // For f32 tensors at unaligned offsets, allocate an aligned copy
            var aligned_ptr: ?[*]const u8 = null;
            if (ftype == 0 and data_offset % 4 != 0) {
                const buf = try self.allocator.alignedAlloc(u8, .@"4", data_size);
                @memcpy(buf, data[data_offset..][0..data_size]);
                try self.aligned_bufs.append(self.allocator, buf);
                aligned_ptr = buf.ptr;
            }

            try self.tensors.put(name, WhisperTensorInfo{
                .name = name,
                .n_dims = n_dims,
                .dims = dims,
                .ftype = ftype,
                .data_offset = data_offset,
                .aligned_data = aligned_ptr,
            });
        }
    }
};

fn readU32(data: []const u8, pos: usize) u32 {
    return std.mem.readInt(u32, data[pos..][0..4], .little);
}
