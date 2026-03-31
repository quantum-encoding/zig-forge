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
        if (self.pos + len > self.data.len) return error.UnexpectedEof;
        const bytes = self.data[self.pos..][0..len];
        self.pos += len;
        return bytes;
    }

    pub fn peekByte(self: *const Reader) !u8 {
        if (self.pos >= self.data.len) return error.UnexpectedEof;
        return self.data[self.pos];
    }

    /// Read unsigned LEB128
    pub fn readU32(self: *Reader) !u32 {
        var result: u32 = 0;
        var shift: u5 = 0;

        while (true) {
            const byte = try self.readByte();
            result |= @as(u32, byte & 0x7F) << shift;

            if (byte & 0x80 == 0) break;

            shift += 7;
            if (shift >= 35) return error.InvalidLeb128;
        }

        return result;
    }

    /// Read signed LEB128 (i32)
    pub fn readI32(self: *Reader) !i32 {
        var result: i32 = 0;
        var shift: u5 = 0;

        while (true) {
            const byte = try self.readByte();
            result |= @as(i32, byte & 0x7F) << shift;
            shift += 7;

            if (byte & 0x80 == 0) {
                // Sign extend if needed
                if (shift < 32 and (byte & 0x40) != 0) {
                    result |= @as(i32, -1) << shift;
                }
                break;
            }

            if (shift >= 35) return error.InvalidLeb128;
        }

        return result;
    }

    /// Read signed LEB128 (i64)
    pub fn readI64(self: *Reader) !i64 {
        var result: i64 = 0;
        var shift: u6 = 0;

        while (true) {
            const byte = try self.readByte();
            result |= @as(i64, byte & 0x7F) << shift;
            shift += 7;

            if (byte & 0x80 == 0) {
                if (shift < 64 and (byte & 0x40) != 0) {
                    result |= @as(i64, -1) << shift;
                }
                break;
            }

            if (shift >= 70) return error.InvalidLeb128;
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

    pub fn readLimits(self: *Reader) !Limits {
        const flags = try self.readByte();
        const min = try self.readU32();

        if (flags & 0x01 != 0) {
            const max = try self.readU32();
            return .{ .min = min, .max = max };
        }

        return .{ .min = min };
    }

    pub fn readMemType(self: *Reader) !MemType {
        return .{ .limits = try self.readLimits() };
    }

    pub fn readTableType(self: *Reader) !TableType {
        const elem_type = try self.readValType();
        const limits = try self.readLimits();
        return .{ .elem_type = elem_type, .limits = limits };
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

    // Parse sections
    while (!reader.isEof()) {
        const section_id_byte = reader.readByte() catch break;
        const section_id: SectionId = @enumFromInt(section_id_byte);
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
                const count = section_reader.readU32() catch return error.InvalidSection;
                var i: u32 = 0;
                while (i < count) : (i += 1) {
                    const ft = parseType(allocator, &section_reader) catch return error.InvalidFuncType;
                    types_list.append(allocator, ft) catch return error.OutOfMemory;
                }
            },

            .import => {
                const count = section_reader.readU32() catch return error.InvalidSection;
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
                const count = section_reader.readU32() catch return error.InvalidSection;
                var i: u32 = 0;
                while (i < count) : (i += 1) {
                    const type_idx = section_reader.readU32() catch return error.InvalidSection;
                    func_types_list.append(allocator, type_idx) catch return error.OutOfMemory;
                }
            },

            .table => {
                const count = section_reader.readU32() catch return error.InvalidSection;
                var i: u32 = 0;
                while (i < count) : (i += 1) {
                    const tt = section_reader.readTableType() catch return error.InvalidSection;
                    tables_list.append(allocator, tt) catch return error.OutOfMemory;
                }
            },

            .memory => {
                const count = section_reader.readU32() catch return error.InvalidSection;
                var i: u32 = 0;
                while (i < count) : (i += 1) {
                    const mt = section_reader.readMemType() catch return error.InvalidSection;
                    memories_list.append(allocator, mt) catch return error.OutOfMemory;
                }
            },

            .global => {
                const count = section_reader.readU32() catch return error.InvalidSection;
                var i: u32 = 0;
                while (i < count) : (i += 1) {
                    const g = parseGlobal(allocator, &section_reader) catch return error.InvalidGlobal;
                    globals_list.append(allocator, g) catch return error.OutOfMemory;
                }
            },

            .@"export" => {
                const count = section_reader.readU32() catch return error.InvalidSection;
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
                // Skip for now - complex parsing
            },

            .code => {
                const count = section_reader.readU32() catch return error.InvalidSection;
                var i: u32 = 0;
                while (i < count) : (i += 1) {
                    const code = parseCode(allocator, &section_reader) catch return error.InvalidCode;
                    codes_list.append(allocator, code) catch return error.OutOfMemory;
                }
            },

            .data => {
                const count = section_reader.readU32() catch return error.InvalidSection;
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

    return module;
}

fn parseType(allocator: std.mem.Allocator, reader: *Reader) !FuncType {
    const form = try reader.readByte();
    if (form != 0x60) return error.InvalidFuncType;

    // Params
    const param_count = try reader.readU32();
    const params = try allocator.alloc(ValType, param_count);
    errdefer allocator.free(params);
    for (params) |*p| {
        p.* = try reader.readValType();
    }

    // Results
    const result_count = try reader.readU32();
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
    const kind: ExternKind = @enumFromInt(kind_byte);

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
    const idx = try reader.readU32();

    return .{
        .name = name,
        .desc = .{
            .kind = @enumFromInt(kind_byte),
            .idx = idx,
        },
    };
}

fn parseGlobal(allocator: std.mem.Allocator, reader: *Reader) !Module.Global {
    const gt = try reader.readGlobalType();

    // Read init expression until end opcode
    const init_start = reader.pos;
    while (true) {
        const byte = try reader.readByte();
        if (byte == 0x0B) break; // end opcode
        // Skip immediate bytes based on opcode
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

    const init = try allocator.dupe(u8, reader.data[init_start..reader.pos]);

    return .{
        .type = gt,
        .init = init,
    };
}

fn parseCode(allocator: std.mem.Allocator, reader: *Reader) !Module.Code {
    _ = try reader.readU32(); // size - we don't need it, we track position

    // Parse locals
    const local_count = try reader.readU32();
    const locals = try allocator.alloc(Module.LocalDecl, local_count);
    errdefer allocator.free(locals);

    for (locals) |*l| {
        l.count = try reader.readU32();
        l.val_type = try reader.readValType();
    }

    // Body is remaining bytes (including end opcode)
    const body_start = reader.pos;

    // Skip to find end of function
    var depth: u32 = 1;
    while (depth > 0) {
        const byte = try reader.readByte();
        switch (byte) {
            0x02, 0x03, 0x04 => depth += 1, // block, loop, if
            0x0B => depth -= 1, // end
            0x41 => _ = try reader.readI32(),
            0x42 => _ = try reader.readI64(),
            0x43 => _ = try reader.readBytes(4),
            0x44 => _ = try reader.readBytes(8),
            0x0C, 0x0D, 0x10, 0x20, 0x21, 0x22, 0x23, 0x24 => _ = try reader.readU32(),
            0x28...0x3E => {
                _ = try reader.readU32(); // align
                _ = try reader.readU32(); // offset
            },
            0x3F, 0x40 => _ = try reader.readU32(),
            0x11 => {
                _ = try reader.readU32();
                _ = try reader.readU32();
            },
            else => {},
        }
    }

    return .{
        .locals = locals,
        .body = reader.data[body_start..reader.pos],
    };
}

fn parseDataEntry(allocator: std.mem.Allocator, reader: *Reader) !types.Data {
    const flags = try reader.readU32();

    switch (flags) {
        0 => {
            // Active data with memory 0 and offset expression
            const expr_start = reader.pos;
            // Skip to end of init expression
            while (true) {
                const byte = try reader.readByte();
                if (byte == 0x0b) break; // end
                switch (byte) {
                    0x41 => _ = try reader.readI32(),
                    0x42 => _ = try reader.readI64(),
                    0x23 => _ = try reader.readU32(), // global.get
                    else => {},
                }
            }
            const expr_instrs = try allocator.dupe(u8, reader.data[expr_start..reader.pos]);

            // Read data bytes
            const data_len = try reader.readU32();
            const init = try allocator.dupe(u8, reader.data[reader.pos..][0..data_len]);
            reader.pos += data_len;

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
            const data_len = try reader.readU32();
            const init = try allocator.dupe(u8, reader.data[reader.pos..][0..data_len]);
            reader.pos += data_len;

            return .{
                .init = init,
                .mode = .passive,
            };
        },
        2 => {
            // Active data with explicit memory index
            const mem_idx = try reader.readU32();

            const expr_start = reader.pos;
            while (true) {
                const byte = try reader.readByte();
                if (byte == 0x0b) break;
                switch (byte) {
                    0x41 => _ = try reader.readI32(),
                    0x42 => _ = try reader.readI64(),
                    0x23 => _ = try reader.readU32(),
                    else => {},
                }
            }
            const expr_instrs = try allocator.dupe(u8, reader.data[expr_start..reader.pos]);

            const data_len = try reader.readU32();
            const init = try allocator.dupe(u8, reader.data[reader.pos..][0..data_len]);
            reader.pos += data_len;

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
