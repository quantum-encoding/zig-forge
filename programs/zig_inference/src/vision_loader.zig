const std = @import("std");
const Allocator = std.mem.Allocator;

/// ZVIS (Zig Vision) weight file format loader.
///
/// v1 Header (20 bytes):
///   magic:      u32 = 0x5A564953 ("ZVIS")
///   version:    u32 = 1
///   n_tensors:  u32
///   model_type: u32 (0=u2netp, 1=modnet, ...)
///   reserved:   u32
///
/// v2 Header (20 + 28 bytes):
///   [same 20-byte header with version=2, model_type=2 (vits)]
///   TtsConfig (28 bytes):
///     n_vocab:      u32
///     d_model:      u32
///     n_enc_layers: u32
///     n_flow_layers:u32
///     n_ups:        u32
///     sample_rate:  u32
///     hop_length:   u32
///
/// Per tensor:
///   name_len: u32
///   name:     [name_len]u8
///   n_dims:   u32
///   dims:     [n_dims]u32  (NCHW order)
///   data:     [product(dims) * 4]u8  (always f32, BN pre-fused)

pub const ZVIS_MAGIC: u32 = 0x5A564953; // "ZVIS"

pub const TtsConfig = struct {
    n_vocab: u32,
    d_model: u32,
    n_enc_layers: u32,
    n_flow_layers: u32,
    n_ups: u32,
    sample_rate: u32,
    hop_length: u32,
};

pub const VisionTensorInfo = struct {
    name: []const u8,
    n_dims: u32,
    dims: [4]u32,
    data_offset: usize,
    data_size: usize,
    aligned_data: ?[*]const u8,
};

pub const VisionFile = struct {
    allocator: Allocator,
    mmap_ptr: [*]align(4096) const u8,
    mmap_len: usize,
    model_type: u32,
    n_tensors: u32,
    tensors: std.StringHashMap(VisionTensorInfo),
    aligned_bufs: std.ArrayListUnmanaged([]align(4) u8),
    tts_config: ?TtsConfig = null,

    pub fn open(allocator: Allocator, path: []const u8) !VisionFile {
        const c_path = try allocator.dupeZ(u8, path);
        defer allocator.free(c_path);

        const fd = std.c.open(c_path.ptr, .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
        if (fd < 0) return error.FileNotFound;
        defer _ = std.c.close(fd);

        const end_pos = std.c.lseek(fd, 0, std.c.SEEK.END);
        if (end_pos < 0) return error.StatFailed;
        _ = std.c.lseek(fd, 0, std.c.SEEK.SET);
        const file_size: usize = @intCast(end_pos);
        if (file_size < 20) return error.FileTooSmall;

        const mmap_result = std.c.mmap(null, file_size, .{ .READ = true }, .{ .TYPE = .PRIVATE }, fd, 0);
        if (mmap_result == std.c.MAP_FAILED) return error.MmapFailed;
        const mmap_ptr: [*]align(4096) const u8 = @alignCast(@ptrCast(mmap_result));

        var self = VisionFile{
            .allocator = allocator,
            .mmap_ptr = mmap_ptr,
            .mmap_len = file_size,
            .model_type = 0,
            .n_tensors = 0,
            .tensors = std.StringHashMap(VisionTensorInfo).init(allocator),
            .aligned_bufs = std.ArrayListUnmanaged([]align(4) u8).empty,
        };

        try self.parse();
        return self;
    }

    pub fn close(self: *VisionFile) void {
        for (self.aligned_bufs.items) |buf| {
            self.allocator.free(buf);
        }
        self.aligned_bufs.deinit(self.allocator);
        self.tensors.deinit();
        _ = std.c.munmap(@ptrCast(@constCast(@alignCast(self.mmap_ptr))), self.mmap_len);
    }

    /// Get a tensor's f32 data by name. Returns null if not found.
    pub fn getTensor(self: *const VisionFile, name: []const u8) ?[]const f32 {
        const info = self.tensors.get(name) orelse return null;
        const data_ptr = info.aligned_data orelse (self.mmap_ptr + info.data_offset);
        const n_elems = info.data_size / 4;
        const aligned: [*]const f32 = @alignCast(@ptrCast(data_ptr));
        return aligned[0..n_elems];
    }

    /// Get tensor shape. Returns null if not found.
    pub fn getShape(self: *const VisionFile, name: []const u8) ?[4]u32 {
        const info = self.tensors.get(name) orelse return null;
        return info.dims;
    }

    fn parse(self: *VisionFile) !void {
        var pos: usize = 0;
        const data = self.mmap_ptr[0..self.mmap_len];

        // Header
        const magic = readU32(data, pos);
        pos += 4;
        if (magic != ZVIS_MAGIC) return error.InvalidMagic;

        const version = readU32(data, pos);
        pos += 4;
        if (version != 1 and version != 2) return error.UnsupportedVersion;

        self.n_tensors = readU32(data, pos);
        pos += 4;

        self.model_type = readU32(data, pos);
        pos += 4;

        // reserved
        pos += 4;

        // v2: TtsConfig block (28 bytes) follows the 20-byte header
        if (version == 2) {
            if (pos + 28 > self.mmap_len) return error.FileTooSmall;
            self.tts_config = TtsConfig{
                .n_vocab = readU32(data, pos),
                .d_model = readU32(data, pos + 4),
                .n_enc_layers = readU32(data, pos + 8),
                .n_flow_layers = readU32(data, pos + 12),
                .n_ups = readU32(data, pos + 16),
                .sample_rate = readU32(data, pos + 20),
                .hop_length = readU32(data, pos + 24),
            };
            pos += 28;
        }

        // Parse tensors
        for (0..self.n_tensors) |_| {
            if (pos + 4 > self.mmap_len) break;

            const name_len = readU32(data, pos);
            pos += 4;

            if (pos + name_len > self.mmap_len) break;
            const name = data[pos..][0..name_len];
            pos += name_len;

            const n_dims = readU32(data, pos);
            pos += 4;

            var dims: [4]u32 = .{ 1, 1, 1, 1 };
            for (0..n_dims) |d| {
                dims[d] = readU32(data, pos);
                pos += 4;
            }

            // Compute data size (always f32)
            var n_elems: usize = 1;
            for (0..n_dims) |d| n_elems *= dims[d];
            const data_size = n_elems * 4;

            const data_offset = pos;
            pos += data_size;

            // For f32 tensors at unaligned offsets, create aligned copy
            var aligned_ptr: ?[*]const u8 = null;
            if (data_offset % 4 != 0) {
                const buf = try self.allocator.alignedAlloc(u8, .@"4", data_size);
                @memcpy(buf, data[data_offset..][0..data_size]);
                try self.aligned_bufs.append(self.allocator, buf);
                aligned_ptr = buf.ptr;
            }

            try self.tensors.put(name, VisionTensorInfo{
                .name = name,
                .n_dims = n_dims,
                .dims = dims,
                .data_offset = data_offset,
                .data_size = data_size,
                .aligned_data = aligned_ptr,
            });
        }
    }
};

fn readU32(data: []const u8, pos: usize) u32 {
    return std.mem.readInt(u32, data[pos..][0..4], .little);
}
