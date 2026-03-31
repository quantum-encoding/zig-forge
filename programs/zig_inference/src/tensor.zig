const std = @import("std");

pub const GGMLType = enum(u32) {
    f32 = 0,
    f16 = 1,
    q4_0 = 2,
    q4_1 = 3,
    // 4, 5 unused
    q5_0 = 6,
    q5_1 = 7,
    q8_0 = 8,
    q8_1 = 9,
    q2_k = 10,
    q3_k = 11,
    q4_k = 12,
    q5_k = 13,
    q6_k = 14,
    q8_k = 15,
    iq2_xxs = 16,
    iq2_xs = 17,
    iq3_xxs = 18,
    iq1_s = 19,
    iq4_nl = 20,
    iq3_s = 21,
    iq2_s = 22,
    iq4_xs = 23,
    i8 = 24,
    i16 = 25,
    i32 = 26,
    i64 = 27,
    f64 = 28,
    iq1_m = 29,
    bf16 = 30,
    _,

    /// Block size (number of elements per quantization block)
    pub fn blockSize(self: GGMLType) u32 {
        return switch (self) {
            .f32 => 1,
            .f16 => 1,
            .q4_0 => 32,
            .q4_1 => 32,
            .q5_0 => 32,
            .q5_1 => 32,
            .q8_0 => 32,
            .q8_1 => 32,
            .q2_k => 256,
            .q3_k => 256,
            .q4_k => 256,
            .q5_k => 256,
            .q6_k => 256,
            .q8_k => 256,
            .bf16 => 1,
            .f64 => 1,
            .i8 => 1,
            .i16 => 1,
            .i32 => 1,
            .i64 => 1,
            else => 1,
        };
    }

    /// Bytes per block
    pub fn bytesPerBlock(self: GGMLType) u32 {
        return switch (self) {
            .f32 => 4,
            .f16 => 2,
            .q4_0 => 18, // 2 (f16 scale) + 16 (32 nibbles)
            .q4_1 => 20, // 2 (f16 scale) + 2 (f16 min) + 16
            .q5_0 => 22, // 2 + 4 + 16
            .q5_1 => 24, // 2 + 2 + 4 + 16
            .q8_0 => 34, // 2 (f16 scale) + 32 (32 × i8)
            .q8_1 => 36, // 2 + 2 + 32
            .q2_k => 84,
            .q3_k => 110,
            .q4_k => 144,
            .q5_k => 176,
            .q6_k => 210,
            .q8_k => 292,
            .bf16 => 2,
            .f64 => 8,
            .i8 => 1,
            .i16 => 2,
            .i32 => 4,
            .i64 => 8,
            else => 0,
        };
    }

    pub fn name(self: GGMLType) []const u8 {
        return switch (self) {
            .f32 => "F32",
            .f16 => "F16",
            .q4_0 => "Q4_0",
            .q4_1 => "Q4_1",
            .q5_0 => "Q5_0",
            .q5_1 => "Q5_1",
            .q8_0 => "Q8_0",
            .q8_1 => "Q8_1",
            .q2_k => "Q2_K",
            .q3_k => "Q3_K",
            .q4_k => "Q4_K",
            .q5_k => "Q5_K",
            .q6_k => "Q6_K",
            .q8_k => "Q8_K",
            .bf16 => "BF16",
            .f64 => "F64",
            else => "unknown",
        };
    }
};

pub const TensorView = struct {
    data: [*]const u8, // raw pointer into mmap'd region
    shape: [4]u64,
    n_dims: u32,
    dtype: GGMLType,

    /// Interpret data as f32 slice (only valid for F32 tensors)
    pub fn asF32Slice(self: TensorView) []const f32 {
        const total = self.elementCount();
        const ptr: [*]const f32 = @alignCast(@ptrCast(self.data));
        return ptr[0..total];
    }

    /// Interpret data as f16 values (raw u16 for bit manipulation)
    pub fn asF16Slice(self: TensorView) []const u16 {
        const total = self.elementCount();
        const ptr: [*]const u16 = @alignCast(@ptrCast(self.data));
        return ptr[0..total];
    }

    /// Number of elements in the tensor
    pub fn elementCount(self: TensorView) usize {
        var count: usize = 1;
        for (0..self.n_dims) |d| {
            count *= @intCast(self.shape[d]);
        }
        return count;
    }

    /// Number of rows (dim 1 for 2D, product of dims 1..n for nD)
    pub fn rows(self: TensorView) usize {
        if (self.n_dims < 2) return 1;
        var r: usize = 1;
        for (1..self.n_dims) |d| {
            r *= @intCast(self.shape[d]);
        }
        return r;
    }

    /// Number of columns (dim 0, innermost)
    pub fn cols(self: TensorView) usize {
        return @intCast(self.shape[0]);
    }

    /// Total bytes of raw data
    pub fn byteSize(self: TensorView) usize {
        const elems = self.elementCount();
        const bs = self.dtype.blockSize();
        const bpb = self.dtype.bytesPerBlock();
        return (elems / bs) * bpb;
    }

    /// Get a row of data as raw bytes (for quantized weight matrix)
    /// Row index is along dim 1 (each row has `cols()` elements)
    pub fn rowData(self: TensorView, row: usize) [*]const u8 {
        const cols_count = self.cols();
        const bs = self.dtype.blockSize();
        const bpb = self.dtype.bytesPerBlock();
        const blocks_per_row = cols_count / bs;
        const bytes_per_row = blocks_per_row * bpb;
        return self.data + row * bytes_per_row;
    }

    /// Get a row as an f32 slice (only valid for F32 tensors)
    pub fn rowF32(self: TensorView, row: usize) []const f32 {
        const cols_count = self.cols();
        const ptr: [*]const f32 = @alignCast(@ptrCast(self.data));
        return ptr[row * cols_count ..][0..cols_count];
    }
};
