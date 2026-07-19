//! ═══════════════════════════════════════════════════════════════════════════
//! WASM BINARY PARSER - WebAssembly Module Decoder
//! ═══════════════════════════════════════════════════════════════════════════
//!
//! Parses binary WASM format as defined in:
//! https://webassembly.github.io/spec/core/binary/index.html

const std = @import("std");
const types = @import("types.zig");
const opcodes = @import("opcodes.zig");

const ValType = types.ValType;
const FuncType = types.FuncType;
const Limits = types.Limits;
const MemType = types.MemType;
const TableType = types.TableType;
const GlobalType = types.GlobalType;
const Import = types.Import;
const Export = types.Export;
const ExternKind = types.ExternKind;
const BlockType = types.BlockType;

/// WASM magic number: \0asm
pub const MAGIC: [4]u8 = .{ 0x00, 0x61, 0x73, 0x6D };
/// WASM version 1
pub const VERSION: [4]u8 = .{ 0x01, 0x00, 0x00, 0x00 };

/// Spec cap on memory size: 2^16 pages == 4 GiB
/// https://webassembly.github.io/spec/core/syntax/types.html#memory-types
pub const MAX_MEMORY_PAGES: u32 = 65536;

/// Runtime resource bound on table size (NOT a spec limit — the spec allows
/// up to 2^32-1 elements). A declared table is allocated eagerly at
/// instantiation, so an unbounded count is a trivial memory-exhaustion vector
/// from an untrusted module.
pub const MAX_TABLE_ELEMS: u32 = 10_000_000;

/// Runtime resource bound on the number of locals a single function may
/// declare. Locals are allocated per call frame; unbounded counts multiply by
/// the call depth.
pub const MAX_FUNC_LOCALS: u32 = 100_000;

/// Section IDs
pub const SectionId = enum(u8) {
    custom = 0,
    type = 1,
    import = 2,
    function = 3,
    table = 4,
    memory = 5,
    global = 6,
    @"export" = 7,
    start = 8,
    element = 9,
    code = 10,
    data = 11,
    data_count = 12,
    _,
};

/// Parsed WASM module
pub const Module = struct {
    allocator: std.mem.Allocator,

    // Type section
    types: []FuncType = &.{},

    // Import section
    imports: []Import = &.{},
    import_func_count: u32 = 0,
    import_table_count: u32 = 0,
    import_mem_count: u32 = 0,
    import_global_count: u32 = 0,

    // Function section (type indices)
    func_types: []u32 = &.{},

    // Table section
    tables: []TableType = &.{},

    // Memory section
    memories: []MemType = &.{},

    // Global section
    globals: []Global = &.{},

    // Export section
    exports: []Export = &.{},

    // Start function index
    start: ?u32 = null,

    // Element section
    elements: []types.Elem = &.{},

    // Code section (function bodies)
    codes: []Code = &.{},

    // Data section
    datas: []types.Data = &.{},

    // Custom sections
    custom_sections: []CustomSection = &.{},

    pub const Global = struct {
        type: GlobalType,
        init: []const u8,
    };

    pub const Code = struct {
        locals: []LocalDecl,
        body: []const u8,
    };

    pub const LocalDecl = struct {
        count: u32,
        val_type: ValType,
    };

    pub const CustomSection = struct {
        name: []const u8,
        data: []const u8,
    };

    pub fn deinit(self: *Module) void {
        // Free type params/results
        for (self.types) |t| {
            self.allocator.free(t.params);
            self.allocator.free(t.results);
        }
        self.allocator.free(self.types);

        // Free imports
        for (self.imports) |imp| {
            self.allocator.free(imp.module);
            self.allocator.free(imp.name);
        }
        self.allocator.free(self.imports);

        self.allocator.free(self.func_types);
        self.allocator.free(self.tables);
        self.allocator.free(self.memories);

        // Free globals
        for (self.globals) |g| {
            self.allocator.free(g.init);
        }
        self.allocator.free(self.globals);

        // Free exports
        for (self.exports) |e| {
            self.allocator.free(e.name);
        }
        self.allocator.free(self.exports);

        // Free codes
        for (self.codes) |c| {
            self.allocator.free(c.locals);
        }
        self.allocator.free(self.codes);

        // Free custom sections
        for (self.custom_sections) |cs| {
            self.allocator.free(cs.name);
        }
        self.allocator.free(self.custom_sections);

        // Free data sections
        for (self.datas) |d| {
            self.allocator.free(d.init);
            switch (d.mode) {
                .active => |active| self.allocator.free(active.offset.instrs),
                .passive => {},
            }
        }
        self.allocator.free(self.datas);

        // Free element segments
        for (self.elements) |e| {
            if (e.owns_init_bytes) {
                for (e.init) |ie| self.allocator.free(ie.instrs);
            }
            self.allocator.free(e.init);
        }
        self.allocator.free(self.elements);
    }

    /// Get function count (imports + defined)
    pub fn funcCount(self: *const Module) u32 {
        return self.import_func_count + @as(u32, @intCast(self.func_types.len));
    }

    /// Get function type by function index
    pub fn getFuncType(self: *const Module, func_idx: u32) ?FuncType {
        if (func_idx < self.import_func_count) {
            // Import function
            var idx: u32 = 0;
            for (self.imports) |imp| {
                switch (imp.desc) {
                    .func => |type_idx| {
                        if (idx == func_idx) {
                            if (type_idx < self.types.len) {
                                return self.types[type_idx];
                            }
                        }
                        idx += 1;
                    },
                    else => {},
                }
            }
        } else {
            // Defined function
            const local_idx = func_idx - self.import_func_count;
            if (local_idx < self.func_types.len) {
                const type_idx = self.func_types[local_idx];
                if (type_idx < self.types.len) {
                    return self.types[type_idx];
                }
            }
        }
        return null;
    }

    /// Find export by name
    pub fn findExport(self: *const Module, name: []const u8) ?Export {
        for (self.exports) |e| {
            if (std.mem.eql(u8, e.name, name)) {
                return e;
            }
        }
        return null;
    }

    /// Get import by function index (for imported functions)
    pub fn getImport(self: *const Module, func_idx: u32) ?Import {
        if (func_idx >= self.import_func_count) return null;

        var idx: u32 = 0;
        for (self.imports) |imp| {
            switch (imp.desc) {
                .func => {
                    if (idx == func_idx) {
                        return imp;
                    }
                    idx += 1;
                },
                else => {},
            }
        }
        return null;
    }
};

/// Binary reader with LEB128 support
pub const Reader = struct {
    data: []const u8,
    pos: usize = 0,

    pub fn init(data: []const u8) Reader {
        return .{ .data = data };
    }

    pub fn remaining(self: *const Reader) usize {
        return if (self.pos < self.data.len) self.data.len - self.pos else 0;
    }

    pub fn isEof(self: *const Reader) bool {
        return self.pos >= self.data.len;
    }

    pub fn readByte(self: *Reader) !u8 {
        if (self.pos >= self.data.len) return error.UnexpectedEof;
        const b = self.data[self.pos];
        self.pos += 1;
        return b;
    }

    pub fn readBytes(self: *Reader, len: usize) ![]const u8 {
        // Overflow-safe: `len` is decoded from the module (attacker-controlled),
        // so `pos + len` must not wrap before the comparison.
        const end = std.math.add(usize, self.pos, len) catch return error.UnexpectedEof;
        if (end > self.data.len) return error.UnexpectedEof;
        const bytes = self.data[self.pos..][0..len];
        self.pos = end;
        return bytes;
    }

    pub fn peekByte(self: *const Reader) !u8 {
        if (self.pos >= self.data.len) return error.UnexpectedEof;
        return self.data[self.pos];
    }

    /// Read unsigned LEB128 (u32).
    ///
    /// Spec: https://webassembly.github.io/spec/core/binary/values.html#integers
    /// A `u32` is encoded in at most `ceil(32/7) == 5` bytes, and the final
    /// byte must not set bits above the 32-bit value range. Both are enforced:
    /// an over-long encoding or a 5th byte wider than 4 value bits is
    /// malformed and rejected rather than silently truncated.
    ///
    /// `shift` is a `usize` (not `u5`) so the loop bookkeeping can exceed the
    /// shift-operand width without overflow-panicking on untrusted input.
    pub fn readU32(self: *Reader) !u32 {
        var result: u32 = 0;
        var shift: usize = 0;

        while (true) {
            const byte = try self.readByte();
            const payload: u32 = byte & 0x7F;

            if (shift >= 32) return error.InvalidLeb128; // over-long
            // On the final (5th) byte only 32-28 == 4 value bits may be set.
            const room: usize = 32 - shift;
            if (room < 7 and payload >= (@as(u32, 1) << @intCast(room))) return error.InvalidLeb128;

            result |= payload << @intCast(shift);

            if (byte & 0x80 == 0) break;
            shift += 7;
        }

        return result;
    }

    /// Read signed LEB128 (i32).
    ///
    /// At most 5 bytes; the final byte must be a valid sign extension of the
    /// remaining value bits (spec `sN` well-formedness), so `0xFF 0xFF 0xFF
    /// 0xFF 0x7F`-style over-wide encodings are rejected.
    pub fn readI32(self: *Reader) !i32 {
        return @truncate(try self.readSigned(32));
    }

    /// Read signed LEB128 (i64).
    pub fn readI64(self: *Reader) !i64 {
        return try self.readSigned(64);
    }

    /// Shared signed-LEB128 decoder for `bits` in {32, 64}.
    fn readSigned(self: *Reader, comptime bits: u7) !i64 {
        var result: i64 = 0;
        var shift: usize = 0;

        while (true) {
            const byte = try self.readByte();
            const payload: i64 = byte & 0x7F;

            if (shift >= bits) return error.InvalidLeb128; // over-long

            const room: u7 = bits - @as(u7, @intCast(shift));
            if (room < 7) {
                // Final byte: the value bits that survive must be a proper
                // sign extension — all the bits above `room` must equal the
                // sign bit of the truncated value.
                if (byte & 0x80 != 0) return error.InvalidLeb128;
                const sign_bit: u8 = @as(u8, 1) << @intCast(room - 1);
                const high_mask: u8 = @truncate(~((@as(u16, 1) << @intCast(room)) - 1) & 0x7F);
                const high = (byte & 0x7F) & high_mask;
                if (byte & sign_bit != 0) {
                    if (high != high_mask) return error.InvalidLeb128;
                } else {
                    if (high != 0) return error.InvalidLeb128;
                }
            }

            result |= payload << @intCast(shift);
            shift += 7;

            if (byte & 0x80 == 0) {
                if (shift < 64 and (byte & 0x40) != 0) {
                    result |= @as(i64, -1) << @intCast(shift);
                }
                break;
            }
        }

        return result;
    }

    pub fn readF32(self: *Reader) !f32 {
        const bytes = try self.readBytes(4);
        return @bitCast(std.mem.readInt(u32, bytes[0..4], .little));
    }

    pub fn readF64(self: *Reader) !f64 {
        const bytes = try self.readBytes(8);
        return @bitCast(std.mem.readInt(u64, bytes[0..8], .little));
    }

    pub fn readName(self: *Reader, allocator: std.mem.Allocator) ![]u8 {
        const len = try self.readU32();
        if (self.pos + len > self.data.len) return error.UnexpectedEof;
        const name = try allocator.dupe(u8, self.data[self.pos..][0..len]);
        self.pos += len;
        return name;
    }

    pub fn readValType(self: *Reader) !ValType {
        const byte = try self.readByte();
        return std.enums.fromInt(ValType, byte) orelse error.InvalidValType;
    }

    pub fn readBlockType(self: *Reader) !BlockType {
        const byte = try self.peekByte();

        if (byte == 0x40) {
            _ = try self.readByte();
            return .{ .empty = {} };
        }

        // Try as value type
        if (std.enums.fromInt(ValType, byte)) |vt| {
            _ = try self.readByte();
            return .{ .val_type = vt };
        }

        // Otherwise it's a type index (signed LEB128)
        const idx = try self.readI32();
        if (idx < 0) return error.InvalidBlockType;
        return .{ .type_idx = @intCast(idx) };
    }

    /// Spec: limits are `0x00 n` or `0x01 n m`, and `n <= m` must hold.
    /// Any other flag byte is malformed; an inverted range is malformed.
    /// Rejecting both here keeps every downstream allocation sane.
    pub fn readLimits(self: *Reader) !Limits {
        const flags = try self.readByte();
        if (flags != 0x00 and flags != 0x01) return error.InvalidLimits;

        const min = try self.readU32();

        if (flags == 0x01) {
            const max = try self.readU32();
            if (max < min) return error.InvalidLimits;
            return .{ .min = min, .max = max };
        }

        return .{ .min = min };
    }

    /// Memory limits are additionally capped at 2^16 pages (4 GiB) by the
    /// spec. Without this a module declaring `min = 0xFFFFFFFF` pages would
    /// have `Memory.init` attempt a 256 TiB allocation.
    pub fn readMemType(self: *Reader) !MemType {
        const limits = try self.readLimits();
        if (limits.min > MAX_MEMORY_PAGES) return error.InvalidLimits;
        if (limits.max) |max| {
            if (max > MAX_MEMORY_PAGES) return error.InvalidLimits;
        }
        return .{ .limits = limits };
    }

    pub fn readTableType(self: *Reader) !TableType {
        const elem_type = try self.readValType();
        const limits = try self.readLimits();
        if (limits.min > MAX_TABLE_ELEMS) return error.InvalidLimits;
        return .{ .elem_type = elem_type, .limits = limits };
    }

    /// Reject a declared item count that cannot possibly be backed by the
    /// bytes that remain. Every vector element costs at least one byte on the
    /// wire, so `count > remaining()` is malformed by construction. Without
    /// this a 5-byte module claiming `0xFFFFFFFF` entries drives a
    /// multi-gigabyte up-front allocation before the first read fails.
    pub fn readCount(self: *Reader) !u32 {
        const count = try self.readU32();
        if (count > self.remaining()) return error.CountExceedsSection;
        return count;
    }

    pub fn readGlobalType(self: *Reader) !GlobalType {
        const val_type = try self.readValType();
        const mut_byte = try self.readByte();
        return .{
            .val_type = val_type,
            .mutable = mut_byte == 0x01,
        };
    }
};

pub const ParseError = error{
    InvalidMagic,
    InvalidVersion,
    InvalidSection,
    InvalidValType,
    InvalidBlockType,
    InvalidLeb128,
    UnexpectedEof,
    InvalidFuncType,
    InvalidImport,
    InvalidExport,
    OutOfMemory,
    InvalidCode,
    InvalidGlobal,
    InvalidData,
    InvalidElement,
    InvalidLimits,
    CountExceedsSection,
    TooManyLocals,
};

/// Parse a WASM binary module
pub fn parse(allocator: std.mem.Allocator, data: []const u8) ParseError!Module {
    var reader = Reader.init(data);

    // Check magic
    const magic = reader.readBytes(4) catch return error.InvalidMagic;
    if (!std.mem.eql(u8, magic, &MAGIC)) {
        return error.InvalidMagic;
    }

    // Check version
    const version = reader.readBytes(4) catch return error.InvalidVersion;
    if (!std.mem.eql(u8, version, &VERSION)) {
        return error.InvalidVersion;
    }

    var module = Module{ .allocator = allocator };
    errdefer module.deinit();

    // Temporary lists for building
    var types_list = std.ArrayList(FuncType).empty;
    defer types_list.deinit(allocator);
    var imports_list = std.ArrayList(Import).empty;
    defer imports_list.deinit(allocator);
    var func_types_list = std.ArrayList(u32).empty;
    defer func_types_list.deinit(allocator);
    var tables_list = std.ArrayList(TableType).empty;
    defer tables_list.deinit(allocator);
    var memories_list = std.ArrayList(MemType).empty;
    defer memories_list.deinit(allocator);
    var globals_list = std.ArrayList(Module.Global).empty;
    defer globals_list.deinit(allocator);
    var exports_list = std.ArrayList(Export).empty;
    defer exports_list.deinit(allocator);
    var codes_list = std.ArrayList(Module.Code).empty;
    defer codes_list.deinit(allocator);
    var custom_list = std.ArrayList(Module.CustomSection).empty;
    defer custom_list.deinit(allocator);
    var datas_list = std.ArrayList(types.Data).empty;
    defer datas_list.deinit(allocator);
    var elements_list = std.ArrayList(types.Elem).empty;
    defer elements_list.deinit(allocator);

    // The `defer …deinit(allocator)` above each list frees only the list's own
    // backing array — NOT the allocations the parsed elements own (type
    // param/result slices, import and export names, global/data init bytes,
    // per-function local declarations). Ownership does not move into `module`
    // until the toOwnedSlice block at the very bottom, so a parse error in any
    // later section left everything parsed so far unreachable and unfreed.
    // Feeding a stream of malformed modules leaked memory without bound.
    errdefer {
        for (types_list.items) |t| {
            allocator.free(t.params);
            allocator.free(t.results);
        }
        for (imports_list.items) |imp| {
            allocator.free(imp.module);
            allocator.free(imp.name);
        }
        for (globals_list.items) |g| allocator.free(g.init);
        for (exports_list.items) |e| allocator.free(e.name);
        for (codes_list.items) |c| allocator.free(c.locals);
        for (custom_list.items) |cs| allocator.free(cs.name);
        for (datas_list.items) |d| {
            allocator.free(d.init);
            switch (d.mode) {
                .active => |active| allocator.free(active.offset.instrs),
                .passive => {},
            }
        }
        for (elements_list.items) |e| {
            if (e.owns_init_bytes) {
                for (e.init) |ie| allocator.free(ie.instrs);
            }
            allocator.free(e.init);
        }
    }

    // Binary Format §5.5.2: the non-custom sections must appear at most once
    // and in increasing order of section id (custom sections may appear
    // anywhere). Accepting a repeated or out-of-order section means two
    // decoders can disagree about which of two conflicting sections wins —
    // exactly the ambiguity a validator exists to remove.
    var last_section_id: u8 = 0;

    // Parse sections
    while (!reader.isEof()) {
        const section_id_byte = reader.readByte() catch break;
        const section_id: SectionId = @enumFromInt(section_id_byte);
        if (section_id != .custom) {
            if (section_id_byte <= last_section_id) return error.InvalidSection;
            last_section_id = section_id_byte;
        }
        const section_size = reader.readU32() catch return error.InvalidSection;

        if (reader.pos + section_size > reader.data.len) {
            return error.UnexpectedEof;
        }

        const section_end = reader.pos + section_size;
        var section_reader = Reader.init(reader.data[reader.pos..section_end]);

        switch (section_id) {
            .custom => {
                const name = section_reader.readName(allocator) catch continue;
                const remaining_data = section_reader.data[section_reader.pos..];
                custom_list.append(allocator, .{
                    .name = name,
                    .data = remaining_data,
                }) catch return error.OutOfMemory;
            },

            .type => {
                const count = section_reader.readCount() catch return error.InvalidSection;
                var i: u32 = 0;
                while (i < count) : (i += 1) {
                    const ft = parseType(allocator, &section_reader) catch return error.InvalidFuncType;
                    types_list.append(allocator, ft) catch return error.OutOfMemory;
                }
            },

            .import => {
                const count = section_reader.readCount() catch return error.InvalidSection;
                var i: u32 = 0;
                while (i < count) : (i += 1) {
                    const imp = parseImport(allocator, &section_reader) catch return error.InvalidImport;
                    imports_list.append(allocator, imp) catch return error.OutOfMemory;

                    // Count imports by kind
                    switch (imp.desc) {
                        .func => module.import_func_count += 1,
                        .table => module.import_table_count += 1,
                        .mem => module.import_mem_count += 1,
                        .global => module.import_global_count += 1,
                    }
                }
            },

            .function => {
                const count = section_reader.readCount() catch return error.InvalidSection;
                var i: u32 = 0;
                while (i < count) : (i += 1) {
                    const type_idx = section_reader.readU32() catch return error.InvalidSection;
                    func_types_list.append(allocator, type_idx) catch return error.OutOfMemory;
                }
            },

            .table => {
                const count = section_reader.readCount() catch return error.InvalidSection;
                var i: u32 = 0;
                while (i < count) : (i += 1) {
                    const tt = section_reader.readTableType() catch return error.InvalidSection;
                    tables_list.append(allocator, tt) catch return error.OutOfMemory;
                }
            },

            .memory => {
                const count = section_reader.readCount() catch return error.InvalidSection;
                var i: u32 = 0;
                while (i < count) : (i += 1) {
                    const mt = section_reader.readMemType() catch return error.InvalidSection;
                    memories_list.append(allocator, mt) catch return error.OutOfMemory;
                }
            },

            .global => {
                const count = section_reader.readCount() catch return error.InvalidSection;
                var i: u32 = 0;
                while (i < count) : (i += 1) {
                    const g = parseGlobal(allocator, &section_reader) catch return error.InvalidGlobal;
                    globals_list.append(allocator, g) catch return error.OutOfMemory;
                }
            },

            .@"export" => {
                const count = section_reader.readCount() catch return error.InvalidSection;
                var i: u32 = 0;
                while (i < count) : (i += 1) {
                    const exp = parseExport(allocator, &section_reader) catch return error.InvalidExport;
                    exports_list.append(allocator, exp) catch return error.OutOfMemory;
                }
            },

            .start => {
                module.start = section_reader.readU32() catch return error.InvalidSection;
            },

            .element => {
                const count = section_reader.readCount() catch return error.InvalidSection;
                var i: u32 = 0;
                while (i < count) : (i += 1) {
                    const elem = parseElement(allocator, &section_reader) catch return error.InvalidElement;
                    elements_list.append(allocator, elem) catch return error.OutOfMemory;
                }
            },

            .code => {
                const count = section_reader.readCount() catch return error.InvalidSection;
                var i: u32 = 0;
                while (i < count) : (i += 1) {
                    const code = parseCode(allocator, &section_reader) catch return error.InvalidCode;
                    codes_list.append(allocator, code) catch return error.OutOfMemory;
                }
            },

            .data => {
                const count = section_reader.readCount() catch return error.InvalidSection;
                var i: u32 = 0;
                while (i < count) : (i += 1) {
                    const data_entry = parseDataEntry(allocator, &section_reader) catch return error.InvalidData;
                    datas_list.append(allocator, data_entry) catch return error.OutOfMemory;
                }
            },

            .data_count => {
                // Skip - just a count for validation
            },

            _ => {
                // Unknown section - skip
            },
        }

        reader.pos = section_end;
    }

    // Transfer ownership
    module.types = types_list.toOwnedSlice(allocator) catch return error.OutOfMemory;
    module.imports = imports_list.toOwnedSlice(allocator) catch return error.OutOfMemory;
    module.func_types = func_types_list.toOwnedSlice(allocator) catch return error.OutOfMemory;
    module.tables = tables_list.toOwnedSlice(allocator) catch return error.OutOfMemory;
    module.memories = memories_list.toOwnedSlice(allocator) catch return error.OutOfMemory;
    module.globals = globals_list.toOwnedSlice(allocator) catch return error.OutOfMemory;
    module.exports = exports_list.toOwnedSlice(allocator) catch return error.OutOfMemory;
    module.codes = codes_list.toOwnedSlice(allocator) catch return error.OutOfMemory;
    module.custom_sections = custom_list.toOwnedSlice(allocator) catch return error.OutOfMemory;
    module.datas = datas_list.toOwnedSlice(allocator) catch return error.OutOfMemory;
    module.elements = elements_list.toOwnedSlice(allocator) catch return error.OutOfMemory;

    return module;
}

fn parseType(allocator: std.mem.Allocator, reader: *Reader) !FuncType {
    const form = try reader.readByte();
    if (form != 0x60) return error.InvalidFuncType;

    // Params. `readCount` bounds the declared length by the bytes that remain,
    // so a forged count cannot drive a huge up-front allocation.
    const param_count = try reader.readCount();
    const params = try allocator.alloc(ValType, param_count);
    errdefer allocator.free(params);
    for (params) |*p| {
        p.* = try reader.readValType();
    }

    // Results
    const result_count = try reader.readCount();
    const results = try allocator.alloc(ValType, result_count);
    errdefer allocator.free(results);
    for (results) |*r| {
        r.* = try reader.readValType();
    }

    return .{ .params = params, .results = results };
}

fn parseImport(allocator: std.mem.Allocator, reader: *Reader) !Import {
    const module_name = try reader.readName(allocator);
    errdefer allocator.free(module_name);

    const name = try reader.readName(allocator);
    errdefer allocator.free(name);

    const kind_byte = try reader.readByte();
    // `@enumFromInt` on an out-of-range value is illegal behavior — it panics
    // in safe builds. The kind byte comes straight off the wire, so an invalid
    // one must be an error, not a host crash.
    const kind: ExternKind = std.enums.fromInt(ExternKind, kind_byte) orelse
        return error.InvalidImport;

    const desc: Import.ImportDesc = switch (kind) {
        .func => .{ .func = try reader.readU32() },
        .table => .{ .table = try reader.readTableType() },
        .mem => .{ .mem = try reader.readMemType() },
        .global => .{ .global = try reader.readGlobalType() },
    };

    return .{
        .module = module_name,
        .name = name,
        .desc = desc,
    };
}

fn parseExport(allocator: std.mem.Allocator, reader: *Reader) !Export {
    const name = try reader.readName(allocator);
    errdefer allocator.free(name);

    const kind_byte = try reader.readByte();
    const kind: ExternKind = std.enums.fromInt(ExternKind, kind_byte) orelse
        return error.InvalidExport;
    const idx = try reader.readU32();

    return .{
        .name = name,
        .desc = .{
            .kind = kind,
            .idx = idx,
        },
    };
}

fn parseGlobal(allocator: std.mem.Allocator, reader: *Reader) !Module.Global {
    const gt = try reader.readGlobalType();

    const init = try allocator.dupe(u8, try readConstExpr(reader));

    return .{
        .type = gt,
        .init = init,
    };
}

fn parseCode(allocator: std.mem.Allocator, reader: *Reader) !Module.Code {
    // Binary Format §5.5.13: `code := size:u32 code:func`, where `size` is the
    // byte length of the function that follows. It was previously discarded on
    // the grounds that position tracking makes it redundant — but that means a
    // module whose declared size disagrees with its actual body is ACCEPTED,
    // and the two decoders (ours and any other) then disagree about where the
    // next function begins. Validate it against what we actually consume.
    const declared_size = try reader.readU32();
    if (declared_size > reader.remaining()) return error.InvalidCode;
    const func_start = reader.pos;

    // Parse locals
    const local_count = try reader.readCount();
    const locals = try allocator.alloc(Module.LocalDecl, local_count);
    errdefer allocator.free(locals);

    // Each declaration carries a repeat count; the SUM is what gets allocated
    // per call frame. Sum with overflow checking and bound it, otherwise a
    // handful of declarations each claiming 2^32-1 locals either wraps or
    // demands a terabyte-scale frame.
    var total_locals: u64 = 0;
    for (locals) |*l| {
        l.count = try reader.readU32();
        l.val_type = try reader.readValType();
        total_locals += l.count;
        if (total_locals > MAX_FUNC_LOCALS) return error.TooManyLocals;
    }

    // Body is remaining bytes (including end opcode)
    const body_start = reader.pos;

    // Skip to find end of function.
    //
    // Every opcode with immediates must consume them here, or an immediate
    // byte gets mistaken for an opcode and the body boundary lands in the
    // wrong place — which silently reinterprets the rest of the code section.
    var depth: u32 = 1;
    while (depth > 0) {
        const byte = try reader.readByte();
        switch (byte) {
            0x02, 0x03, 0x04 => {
                depth = try std.math.add(u32, depth, 1); // block, loop, if
                _ = try reader.readBlockType();
            },
            0x0B => depth -= 1, // end
            0x41 => _ = try reader.readI32(),
            0x42 => _ = try reader.readI64(),
            0x43 => _ = try reader.readBytes(4),
            0x44 => _ = try reader.readBytes(8),
            // br, br_if, call, local.*, global.*, table.get, table.set
            0x0C, 0x0D, 0x10, 0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26 => _ = try reader.readU32(),
            0x0E => {
                // br_table: a vector of `count` labels plus the default label.
                const count = try reader.readCount();
                var i: u32 = 0;
                while (i <= count) : (i += 1) _ = try reader.readU32();
            },
            0x1C => {
                // select_t: a vector of result value types
                const count = try reader.readCount();
                var i: u32 = 0;
                while (i < count) : (i += 1) _ = try reader.readByte();
            },
            0x28...0x3E => {
                _ = try reader.readU32(); // align
                _ = try reader.readU32(); // offset
            },
            0x3F, 0x40 => _ = try reader.readU32(),
            0x11 => {
                _ = try reader.readU32();
                _ = try reader.readU32();
            },
            0xD0 => _ = try reader.readByte(), // ref.null <reftype>
            0xD2 => _ = try reader.readU32(), // ref.func <funcidx>
            0xFC => {
                // Prefixed (saturating-truncation / bulk-memory) family
                const sub = try reader.readU32();
                switch (sub) {
                    0...7 => {}, // i32/i64.trunc_sat_* — no immediates
                    8 => { // memory.init dataidx memidx
                        _ = try reader.readU32();
                        _ = try reader.readU32();
                    },
                    9 => _ = try reader.readU32(), // data.drop dataidx
                    10 => { // memory.copy src dst
                        _ = try reader.readU32();
                        _ = try reader.readU32();
                    },
                    11 => _ = try reader.readU32(), // memory.fill memidx
                    12 => { // table.init elemidx tableidx
                        _ = try reader.readU32();
                        _ = try reader.readU32();
                    },
                    13 => _ = try reader.readU32(), // elem.drop elemidx
                    14 => { // table.copy dst src
                        _ = try reader.readU32();
                        _ = try reader.readU32();
                    },
                    15, 16, 17 => _ = try reader.readU32(), // table.grow/size/fill
                    else => return error.InvalidCode,
                }
            },
            else => {},
        }
    }

    if (reader.pos - func_start != declared_size) return error.InvalidCode;

    return .{
        .locals = locals,
        .body = reader.data[body_start..reader.pos],
    };
}

/// Consume a constant expression (`expr` terminated by the `end` opcode,
/// 0x0B) and return the encoded bytes, borrowed from the reader's buffer.
/// Every constant opcode's immediates must be consumed, or an immediate byte
/// gets mistaken for the terminator.
fn readConstExpr(reader: *Reader) ![]const u8 {
    const start = reader.pos;
    while (true) {
        const byte = try reader.readByte();
        if (byte == 0x0B) break; // end
        switch (byte) {
            0x41 => _ = try reader.readI32(), // i32.const
            0x42 => _ = try reader.readI64(), // i64.const
            0x43 => _ = try reader.readBytes(4), // f32.const
            0x44 => _ = try reader.readBytes(8), // f64.const
            0x23 => _ = try reader.readU32(), // global.get
            0xD0 => _ = try reader.readByte(), // ref.null
            0xD2 => _ = try reader.readU32(), // ref.func
            else => {},
        }
    }
    return reader.data[start..reader.pos];
}

/// Parse one element segment.
///
/// Spec: https://webassembly.github.io/spec/core/binary/modules.html#element-section
/// The flags field selects among seven encodings (0..7); the bit meanings are
/// bit0 = passive/declarative, bit1 = explicit table index / declarative,
/// bit2 = element expressions rather than function indices.
fn parseElement(allocator: std.mem.Allocator, reader: *Reader) !types.Elem {
    const flags = try reader.readU32();
    if (flags > 7) return error.InvalidElement;

    const uses_expressions = (flags & 0x04) != 0;
    const is_passive_or_declarative = (flags & 0x01) != 0;
    const has_explicit_table = (flags & 0x02) != 0;

    var table_idx: u32 = 0;
    var offset_bytes: []const u8 = &.{};

    if (!is_passive_or_declarative) {
        // Active segment: optional table index, then the offset expression.
        if (has_explicit_table) table_idx = try reader.readU32();
        offset_bytes = try readConstExpr(reader);
    }

    // Element kind / reference type byte. Present for every form except the
    // two "active, table 0, funcidx vector" shorthands (flags 0 and 4).
    var elem_type: ValType = .funcref;
    if (flags != 0 and flags != 4) {
        if (uses_expressions) {
            elem_type = try reader.readValType();
        } else {
            const kind = try reader.readByte();
            if (kind != 0x00) return error.InvalidElement; // only elemkind 0 (funcref) exists
            elem_type = .funcref;
        }
    }

    const count = try reader.readCount();
    const inits = try allocator.alloc(types.InitExpr, count);
    errdefer allocator.free(inits);

    // Track how many synthesized encodings have been allocated so a failure
    // partway through the vector frees exactly those, and no more.
    var built: usize = 0;
    errdefer if (!uses_expressions) {
        for (inits[0..built]) |ie| allocator.free(ie.instrs);
    };

    for (inits) |*ie| {
        if (uses_expressions) {
            ie.* = .{ .instrs = try readConstExpr(reader) };
        } else {
            // A bare funcidx; synthesize the equivalent `ref.func x; end`
            // encoding so the interpreter's single evalInitExpr path handles
            // both forms identically.
            const func_idx = try reader.readU32();
            var buf: [6]u8 = undefined;
            buf[0] = 0xD2; // ref.func
            var n: usize = 1;
            var v = func_idx;
            while (true) {
                var b: u8 = @intCast(v & 0x7F);
                v >>= 7;
                if (v != 0) b |= 0x80;
                buf[n] = b;
                n += 1;
                if (v == 0) break;
            }
            buf[n] = 0x0B; // end
            n += 1;
            ie.* = .{ .instrs = try allocator.dupe(u8, buf[0..n]) };
        }
        built += 1;
    }

    // Owned only for the synthesized-encoding path; the expression path
    // borrows from the module buffer. Track which so deinit frees correctly.
    return .{
        .type = elem_type,
        .init = inits,
        .owns_init_bytes = !uses_expressions,
        .mode = if (is_passive_or_declarative)
            (if (has_explicit_table) types.Elem.Mode{ .declarative = {} } else types.Elem.Mode{ .passive = {} })
        else
            types.Elem.Mode{ .active = .{ .table_idx = table_idx, .offset = .{ .instrs = offset_bytes } } },
    };
}

fn parseDataEntry(allocator: std.mem.Allocator, reader: *Reader) !types.Data {
    const flags = try reader.readU32();

    switch (flags) {
        0 => {
            // Active data with memory 0 and offset expression
            const expr_instrs = try allocator.dupe(u8, try readConstExpr(reader));
            // The data-length read below can fail on a malformed module; without
            // this the offset expression leaks on that path.
            errdefer allocator.free(expr_instrs);

            // Read data bytes
            // `readBytes` bounds-checks `data_len` (attacker-controlled) before
            // slicing; the previous direct slice panicked on an over-long
            // declared length.
            const data_len = try reader.readU32();
            const init = try allocator.dupe(u8, try reader.readBytes(data_len));

            return .{
                .init = init,
                .mode = .{ .active = .{
                    .mem_idx = 0,
                    .offset = .{ .instrs = expr_instrs },
                } },
            };
        },
        1 => {
            // Passive data segment
            // `readBytes` bounds-checks `data_len` (attacker-controlled) before
            // slicing; the previous direct slice panicked on an over-long
            // declared length.
            const data_len = try reader.readU32();
            const init = try allocator.dupe(u8, try reader.readBytes(data_len));

            return .{
                .init = init,
                .mode = .passive,
            };
        },
        2 => {
            // Active data with explicit memory index
            const mem_idx = try reader.readU32();

            const expr_instrs = try allocator.dupe(u8, try readConstExpr(reader));
            // The data-length read below can fail on a malformed module; without
            // this the offset expression leaks on that path.
            errdefer allocator.free(expr_instrs);

            // `readBytes` bounds-checks `data_len` (attacker-controlled) before
            // slicing; the previous direct slice panicked on an over-long
            // declared length.
            const data_len = try reader.readU32();
            const init = try allocator.dupe(u8, try reader.readBytes(data_len));

            return .{
                .init = init,
                .mode = .{ .active = .{
                    .mem_idx = mem_idx,
                    .offset = .{ .instrs = expr_instrs },
                } },
            };
        },
        else => return error.InvalidData,
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════════

test "LEB128 decoding" {
    // Test unsigned LEB128
    var reader = Reader.init(&[_]u8{ 0xE5, 0x8E, 0x26 }); // 624485
    try std.testing.expectEqual(@as(u32, 624485), try reader.readU32());

    // Test signed LEB128
    reader = Reader.init(&[_]u8{ 0x9B, 0xF1, 0x59 }); // -624485
    try std.testing.expectEqual(@as(i32, -624485), try reader.readI32());
}

test "parse minimal module" {
    // Minimal valid WASM module (just magic + version)
    const minimal = MAGIC ++ VERSION;
    var module = try parse(std.testing.allocator, &minimal);
    defer module.deinit();

    try std.testing.expectEqual(@as(usize, 0), module.types.len);
}
