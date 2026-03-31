//! ═══════════════════════════════════════════════════════════════════════════
//! WASM INTERPRETER - Stack-Based Bytecode Execution Engine
//! ═══════════════════════════════════════════════════════════════════════════
//!
//! Executes WebAssembly instructions according to the spec:
//! https://webassembly.github.io/spec/core/exec/index.html

const std = @import("std");
const types = @import("types.zig");
const binary = @import("binary.zig");
const opcodes = @import("opcodes.zig");

const ValType = types.ValType;
const Value = types.Value;
const FuncType = types.FuncType;
const Module = binary.Module;
const Opcode = opcodes.Opcode;

/// Execution error types
pub const TrapError = error{
    Unreachable,
    IntegerOverflow,
    IntegerDivideByZero,
    InvalidConversionToInteger,
    OutOfBoundsMemoryAccess,
    IndirectCallTypeMismatch,
    UndefinedElement,
    UninitializedElement,
    OutOfBoundsTableAccess,
    StackOverflow,
    StackUnderflow,
    CallStackExhaustion,
    InvalidFunction,
    InvalidLocal,
    InvalidGlobal,
    InvalidMemory,
    InvalidTable,
    UnexpectedEnd,
    UnknownOpcode,
    OutOfMemory,
};

/// Call frame for function invocation
pub const Frame = struct {
    /// Function index
    func_idx: u32,
    /// Local variables (params + locals)
    locals: []Value,
    /// Module reference
    module: *const Module,
    /// Return address (instruction pointer)
    return_ip: usize,
    /// Stack base index
    stack_base: usize,
    /// Allocator for locals
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Frame) void {
        self.allocator.free(self.locals);
    }
};

/// Label for control flow
const Label = struct {
    /// Opcode that created this label (block, loop, if)
    opcode: Opcode,
    /// Stack height when label was created
    stack_height: usize,
    /// Target instruction pointer for br
    target_ip: usize,
    /// Result arity
    arity: u32,
};

/// Runtime memory instance
pub const Memory = struct {
    data: []u8,
    limits: types.Limits,
    allocator: std.mem.Allocator,

    pub const PAGE_SIZE: usize = 65536;

    pub fn init(allocator: std.mem.Allocator, limits: types.Limits) !Memory {
        const initial_size = @as(usize, limits.min) * PAGE_SIZE;
        const data = try allocator.alloc(u8, initial_size);
        @memset(data, 0);
        return .{
            .data = data,
            .limits = limits,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Memory) void {
        self.allocator.free(self.data);
    }

    pub fn grow(self: *Memory, pages: u32) !i32 {
        const old_pages = @as(u32, @intCast(self.data.len / PAGE_SIZE));
        const new_pages = old_pages + pages;

        if (self.limits.max) |max| {
            if (new_pages > max) return -1;
        }

        if (new_pages > 65536) return -1; // Max 4GB

        const new_size = @as(usize, new_pages) * PAGE_SIZE;
        const new_data = self.allocator.realloc(self.data, new_size) catch return -1;
        @memset(new_data[self.data.len..], 0);
        self.data = new_data;

        return @intCast(old_pages);
    }

    pub fn size(self: *const Memory) u32 {
        return @intCast(self.data.len / PAGE_SIZE);
    }

    pub fn loadI32(self: *const Memory, addr: u32) TrapError!i32 {
        if (addr + 4 > self.data.len) return error.OutOfBoundsMemoryAccess;
        return std.mem.readInt(i32, self.data[addr..][0..4], .little);
    }

    pub fn loadI64(self: *const Memory, addr: u32) TrapError!i64 {
        if (addr + 8 > self.data.len) return error.OutOfBoundsMemoryAccess;
        return std.mem.readInt(i64, self.data[addr..][0..8], .little);
    }

    pub fn loadF32(self: *const Memory, addr: u32) TrapError!f32 {
        const bits = try self.loadI32(addr);
        return @bitCast(@as(u32, @bitCast(bits)));
    }

    pub fn loadF64(self: *const Memory, addr: u32) TrapError!f64 {
        const bits = try self.loadI64(addr);
        return @bitCast(@as(u64, @bitCast(bits)));
    }

    pub fn loadI8(self: *const Memory, addr: u32) TrapError!i8 {
        if (addr >= self.data.len) return error.OutOfBoundsMemoryAccess;
        return @bitCast(self.data[addr]);
    }

    pub fn loadU8(self: *const Memory, addr: u32) TrapError!u8 {
        if (addr >= self.data.len) return error.OutOfBoundsMemoryAccess;
        return self.data[addr];
    }

    pub fn loadI16(self: *const Memory, addr: u32) TrapError!i16 {
        if (addr + 2 > self.data.len) return error.OutOfBoundsMemoryAccess;
        return std.mem.readInt(i16, self.data[addr..][0..2], .little);
    }

    pub fn loadU16(self: *const Memory, addr: u32) TrapError!u16 {
        if (addr + 2 > self.data.len) return error.OutOfBoundsMemoryAccess;
        return std.mem.readInt(u16, self.data[addr..][0..2], .little);
    }

    pub fn loadI32_8s(self: *const Memory, addr: u32) TrapError!i32 {
        return @as(i32, try self.loadI8(addr));
    }

    pub fn loadI32_8u(self: *const Memory, addr: u32) TrapError!i32 {
        return @as(i32, try self.loadU8(addr));
    }

    pub fn loadI32_16s(self: *const Memory, addr: u32) TrapError!i32 {
        return @as(i32, try self.loadI16(addr));
    }

    pub fn loadI32_16u(self: *const Memory, addr: u32) TrapError!i32 {
        return @as(i32, try self.loadU16(addr));
    }

    pub fn storeI32(self: *Memory, addr: u32, val: i32) TrapError!void {
        if (addr + 4 > self.data.len) return error.OutOfBoundsMemoryAccess;
        std.mem.writeInt(i32, self.data[addr..][0..4], val, .little);
    }

    pub fn storeI64(self: *Memory, addr: u32, val: i64) TrapError!void {
        if (addr + 8 > self.data.len) return error.OutOfBoundsMemoryAccess;
        std.mem.writeInt(i64, self.data[addr..][0..8], val, .little);
    }

    pub fn storeF32(self: *Memory, addr: u32, val: f32) TrapError!void {
        try self.storeI32(addr, @bitCast(val));
    }

    pub fn storeF64(self: *Memory, addr: u32, val: f64) TrapError!void {
        try self.storeI64(addr, @bitCast(val));
    }

    pub fn storeI8(self: *Memory, addr: u32, val: i32) TrapError!void {
        if (addr >= self.data.len) return error.OutOfBoundsMemoryAccess;
        self.data[addr] = @truncate(@as(u32, @bitCast(val)));
    }

    pub fn storeI16(self: *Memory, addr: u32, val: i32) TrapError!void {
        if (addr + 2 > self.data.len) return error.OutOfBoundsMemoryAccess;
        std.mem.writeInt(i16, self.data[addr..][0..2], @truncate(@as(i32, val)), .little);
    }
};

/// Global variable instance
pub const Global = struct {
    value: Value,
    mutable: bool,
};

/// Table instance
pub const Table = struct {
    data: []?u32, // Array of function indices or null
    limits: types.Limits,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, limits: types.Limits) !Table {
        const initial_size = @as(usize, limits.min);
        const data = try allocator.alloc(?u32, initial_size);
        for (data) |*entry| {
            entry.* = null;
        }
        return .{
            .data = data,
            .limits = limits,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Table) void {
        self.allocator.free(self.data);
    }

    pub fn get(self: *const Table, idx: u32) TrapError!?u32 {
        if (idx >= self.data.len) return error.OutOfBoundsTableAccess;
        return self.data[idx];
    }

    pub fn set(self: *Table, idx: u32, val: ?u32) TrapError!void {
        if (idx >= self.data.len) return error.OutOfBoundsTableAccess;
        self.data[idx] = val;
    }

    pub fn grow(self: *Table, count: u32) !i32 {
        const old_size = @as(i32, @intCast(self.data.len));
        const new_size = @as(usize, @intCast(old_size)) + count;

        if (self.limits.max) |max| {
            if (new_size > max) return -1;
        }

        const new_data = self.allocator.realloc(self.data, new_size) catch return -1;
        for (new_data[self.data.len..]) |*entry| {
            entry.* = null;
        }
        self.data = new_data;

        return old_size;
    }

    pub fn size(self: *const Table) u32 {
        return @intCast(self.data.len);
    }
};

/// Import resolver function type
/// Called when an imported function is invoked
/// Parameters: module name, function name, arguments
/// Returns: result value (or null for void functions)
pub const ImportResolver = *const fn (
    ctx: *anyopaque,
    module: []const u8,
    name: []const u8,
    args: []const Value,
) TrapError!?Value;

/// WASM interpreter instance
pub const Instance = struct {
    allocator: std.mem.Allocator,
    module: *const Module,

    /// Operand stack
    stack: std.ArrayList(Value),
    /// Call stack
    call_stack: std.ArrayList(Frame),
    /// Label stack (for control flow)
    labels: std.ArrayList(Label),

    /// Memory instances
    memories: []Memory,
    /// Global instances
    globals: []Global,
    /// Table instances
    tables: []Table,

    /// Host functions
    host_funcs: std.StringHashMap(*const fn (*Instance, []const Value) TrapError!?Value),

    /// Import resolver for handling imported functions
    import_resolver: ?ImportResolver = null,
    import_resolver_ctx: ?*anyopaque = null,

    /// Maximum stack depth
    max_stack_depth: usize = 1024,
    max_call_depth: usize = 512,

    pub fn init(allocator: std.mem.Allocator, module: *const Module) !Instance {
        var instance = Instance{
            .allocator = allocator,
            .module = module,
            .stack = .empty,
            .call_stack = .empty,
            .labels = .empty,
            .memories = &.{},
            .globals = &.{},
            .tables = &.{},
            .host_funcs = std.StringHashMap(*const fn (*Instance, []const Value) TrapError!?Value).init(allocator),
        };

        // Initialize memories
        const mem_count = module.import_mem_count + @as(u32, @intCast(module.memories.len));
        if (mem_count > 0) {
            instance.memories = try allocator.alloc(Memory, mem_count);
            var i: usize = 0;

            // Import memories
            for (module.imports) |imp| {
                switch (imp.desc) {
                    .mem => |mem_type| {
                        // Create imported memory instance
                        instance.memories[i] = try Memory.init(allocator, mem_type.limits);
                        i += 1;
                    },
                    else => {},
                }
            }

            // Module-defined memories
            for (module.memories) |mt| {
                instance.memories[i] = try Memory.init(allocator, mt.limits);
                i += 1;
            }
        }

        // Initialize globals
        const global_count = module.import_global_count + @as(u32, @intCast(module.globals.len));
        if (global_count > 0) {
            instance.globals = try allocator.alloc(Global, global_count);
            var i: usize = 0;

            // Import globals
            for (module.imports) |imp| {
                switch (imp.desc) {
                    .global => |global_type| {
                        // Create imported global with null/zero value
                        instance.globals[i] = .{
                            .value = switch (global_type.val_type) {
                                .i32 => .{ .i32 = 0 },
                                .i64 => .{ .i64 = 0 },
                                .f32 => .{ .f32 = 0.0 },
                                .f64 => .{ .f64 = 0.0 },
                                .v128 => .{ .v128 = 0 },
                                .funcref => .{ .funcref = null },
                                .externref => .{ .externref = null },
                            },
                            .mutable = global_type.mutable,
                        };
                        i += 1;
                    },
                    else => {},
                }
            }

            // Module-defined globals
            for (module.globals) |g| {
                const val = try instance.evalInitExpr(g.init);
                instance.globals[i] = .{
                    .value = val,
                    .mutable = g.type.mutable,
                };
                i += 1;
            }
        }

        // Initialize tables
        const table_count = module.import_table_count + @as(u32, @intCast(module.tables.len));
        if (table_count > 0) {
            instance.tables = try allocator.alloc(Table, table_count);
            var i: usize = 0;

            // Import tables (skip for now)
            // Module-defined tables
            for (module.tables) |tt| {
                instance.tables[i] = try Table.init(allocator, tt.limits);
                i += 1;
            }
        }

        // Initialize element segments
        for (module.elements) |elem| {
            switch (elem.mode) {
                .active => |active| {
                    const offset_val = try instance.evalInitExpr(active.offset.instrs);
                    const offset: u32 = @bitCast(offset_val.asI32());

                    if (active.table_idx < instance.tables.len) {
                        const table = &instance.tables[active.table_idx];
                        for (elem.init, 0..) |init_expr, idx| {
                            const func_val = try instance.evalInitExpr(init_expr.instrs);
                            const func_idx = func_val.funcref orelse null;
                            if (offset + @as(u32, @intCast(idx)) < table.data.len) {
                                table.data[offset + @as(u32, @intCast(idx))] = func_idx;
                            }
                        }
                    }
                },
                .passive => {},
                .declarative => {},
            }
        }

        // Initialize data segments
        for (module.datas) |data| {
            switch (data.mode) {
                .active => |active| {
                    const offset_val = try instance.evalInitExpr(active.offset.instrs);
                    const offset: usize = @intCast(@as(u32, @bitCast(offset_val.asI32())));

                    if (active.mem_idx < instance.memories.len) {
                        const mem = &instance.memories[active.mem_idx];
                        if (offset + data.init.len <= mem.data.len) {
                            @memcpy(mem.data[offset..][0..data.init.len], data.init);
                        }
                    }
                },
                .passive => {},
            }
        }

        return instance;
    }

    pub fn deinit(self: *Instance) void {
        self.stack.deinit(self.allocator);

        for (self.call_stack.items) |*frame| {
            frame.deinit();
        }
        self.call_stack.deinit(self.allocator);

        self.labels.deinit(self.allocator);

        for (self.memories) |*mem| {
            mem.deinit();
        }
        self.allocator.free(self.memories);

        for (self.tables) |*table| {
            table.deinit();
        }
        self.allocator.free(self.tables);

        self.allocator.free(self.globals);
        self.host_funcs.deinit();
    }

    /// Evaluate a constant initialization expression
    fn evalInitExpr(self: *Instance, code: []const u8) TrapError!Value {
        var reader = binary.Reader.init(code);

        while (!reader.isEof()) {
            const byte = reader.readByte() catch return error.UnexpectedEnd;
            const op: Opcode = @enumFromInt(byte);

            switch (op) {
                .i32_const => {
                    const val = reader.readI32() catch return error.UnexpectedEnd;
                    return .{ .i32 = val };
                },
                .i64_const => {
                    const val = reader.readI64() catch return error.UnexpectedEnd;
                    return .{ .i64 = val };
                },
                .f32_const => {
                    const val = reader.readF32() catch return error.UnexpectedEnd;
                    return .{ .f32 = val };
                },
                .f64_const => {
                    const val = reader.readF64() catch return error.UnexpectedEnd;
                    return .{ .f64 = val };
                },
                .global_get => {
                    const idx = reader.readU32() catch return error.UnexpectedEnd;
                    if (idx >= self.globals.len) return error.InvalidGlobal;
                    return self.globals[idx].value;
                },
                .ref_null => {
                    _ = reader.readByte() catch return error.UnexpectedEnd;
                    return .{ .funcref = null };
                },
                .ref_func => {
                    const idx = reader.readU32() catch return error.UnexpectedEnd;
                    return .{ .funcref = idx };
                },
                .end => break,
                else => return error.UnknownOpcode,
            }
        }

        return .{ .i32 = 0 };
    }

    /// Call an exported function by name
    pub fn call(self: *Instance, name: []const u8, args: []const Value) TrapError!?Value {
        const exp = self.module.findExport(name) orelse return error.InvalidFunction;
        if (exp.desc.kind != .func) return error.InvalidFunction;
        return self.callFunc(exp.desc.idx, args);
    }

    /// Call a function by index (external API - pushes args to stack)
    pub fn callFunc(self: *Instance, func_idx: u32, args: []const Value) TrapError!?Value {
        const func_type = self.module.getFuncType(func_idx) orelse return error.InvalidFunction;

        // Validate argument count
        if (args.len != func_type.params.len) return error.InvalidFunction;

        // Push arguments to stack
        for (args) |arg| {
            self.stack.append(self.allocator, arg) catch return error.OutOfMemory;
        }

        // Execute internal call
        return self.callFuncInternal(func_idx);
    }

    /// Internal function call - assumes args already on stack
    fn callFuncInternal(self: *Instance, func_idx: u32) TrapError!?Value {
        const func_type = self.module.getFuncType(func_idx) orelse return error.InvalidFunction;

        // Check if import or defined
        if (func_idx < self.module.import_func_count) {
            // Import function - use import resolver
            if (self.import_resolver) |resolver| {
                // Get import info
                const import = self.module.getImport(func_idx) orelse return error.InvalidFunction;

                // Pop args from stack for the resolver
                var call_args = self.allocator.alloc(Value, func_type.params.len) catch return error.OutOfMemory;
                defer self.allocator.free(call_args);

                var i: usize = func_type.params.len;
                while (i > 0) {
                    i -= 1;
                    call_args[i] = self.stack.pop() orelse return error.StackUnderflow;
                }

                const result = try resolver(self.import_resolver_ctx.?, import.module, import.name, call_args);
                if (result) |val| {
                    self.stack.append(self.allocator, val) catch return error.OutOfMemory;
                }
                return result;
            }
            return error.InvalidFunction;
        }

        // Get function code
        const local_idx = func_idx - self.module.import_func_count;
        if (local_idx >= self.module.codes.len) return error.InvalidFunction;
        const code = self.module.codes[local_idx];

        // Create frame
        var frame = try self.createFrame(func_idx, func_type, code);
        errdefer frame.deinit();

        self.call_stack.append(self.allocator, frame) catch return error.OutOfMemory;

        // Execute
        try self.execute(code.body);

        // Get return value
        if (func_type.results.len > 0) {
            if (self.stack.items.len == 0) return error.StackUnderflow;
            return self.stack.pop();
        }

        return null;
    }

    fn createFrame(self: *Instance, func_idx: u32, func_type: FuncType, code: Module.Code) TrapError!Frame {
        // Calculate total locals
        var total_locals: usize = func_type.params.len;
        for (code.locals) |local| {
            total_locals += local.count;
        }

        var locals = self.allocator.alloc(Value, total_locals) catch return error.OutOfMemory;
        errdefer self.allocator.free(locals);

        // Copy params from stack
        var param_idx: usize = func_type.params.len;
        while (param_idx > 0) {
            param_idx -= 1;
            locals[param_idx] = self.stack.pop() orelse return error.StackUnderflow;
        }

        // Initialize remaining locals to zero
        var local_idx = func_type.params.len;
        for (code.locals) |local| {
            var i: u32 = 0;
            while (i < local.count) : (i += 1) {
                locals[local_idx] = switch (local.val_type) {
                    .i32 => .{ .i32 = 0 },
                    .i64 => .{ .i64 = 0 },
                    .f32 => .{ .f32 = 0 },
                    .f64 => .{ .f64 = 0 },
                    .funcref => .{ .funcref = null },
                    .externref => .{ .externref = null },
                    .v128 => .{ .v128 = 0 },
                };
                local_idx += 1;
            }
        }

        return Frame{
            .func_idx = func_idx,
            .locals = locals,
            .module = self.module,
            .return_ip = 0,
            .stack_base = self.stack.items.len,
            .allocator = self.allocator,
        };
    }

    /// Main execution loop
    fn execute(self: *Instance, code: []const u8) TrapError!void {
        var reader = binary.Reader.init(code);

        while (!reader.isEof()) {
            const byte = reader.readByte() catch return error.UnexpectedEnd;
            const op: Opcode = @enumFromInt(byte);

            try self.executeOp(op, &reader);

            // Check for end of function
            if (op == .end and self.labels.items.len == 0) {
                break;
            }
        }
    }

    fn executeOp(self: *Instance, op: Opcode, reader: *binary.Reader) TrapError!void {
        switch (op) {
            // Control flow
            .@"unreachable" => return error.Unreachable,
            .nop => {},

            .block => {
                const block_type = reader.readBlockType() catch return error.UnexpectedEnd;
                const arity = self.getBlockArity(block_type);
                self.labels.append(self.allocator, .{
                    .opcode = .block,
                    .stack_height = self.stack.items.len,
                    .target_ip = 0, // Will be set when we find end
                    .arity = arity,
                }) catch return error.OutOfMemory;
            },

            .loop => {
                const block_type = reader.readBlockType() catch return error.UnexpectedEnd;
                const arity = self.getBlockArity(block_type);
                self.labels.append(self.allocator, .{
                    .opcode = .loop,
                    .stack_height = self.stack.items.len,
                    .target_ip = reader.pos,
                    .arity = arity,
                }) catch return error.OutOfMemory;
            },

            .@"if" => {
                const block_type = reader.readBlockType() catch return error.UnexpectedEnd;
                const arity = self.getBlockArity(block_type);
                const cond = self.popI32();
                if (cond == 0) {
                    // Skip to else or end
                    try self.skipToElseOrEnd(reader);
                }
                self.labels.append(self.allocator, .{
                    .opcode = .@"if",
                    .stack_height = self.stack.items.len,
                    .target_ip = 0,
                    .arity = arity,
                }) catch return error.OutOfMemory;
            },

            .@"else" => {
                // Skip to end
                try self.skipToEnd(reader);
            },

            .end => {
                if (self.labels.items.len > 0) {
                    _ = self.labels.pop();
                }
            },

            .br => {
                const depth = reader.readU32() catch return error.UnexpectedEnd;
                try self.branch(depth, reader);
            },

            .br_if => {
                const depth = reader.readU32() catch return error.UnexpectedEnd;
                const cond = self.popI32();
                if (cond != 0) {
                    try self.branch(depth, reader);
                }
            },

            .br_table => {
                const count = reader.readU32() catch return error.UnexpectedEnd;
                const idx: u32 = @bitCast(self.popI32());

                var target: u32 = 0;
                var i: u32 = 0;
                while (i <= count) : (i += 1) {
                    const label = reader.readU32() catch return error.UnexpectedEnd;
                    if (i == idx or i == count) {
                        target = label;
                        if (i == idx) break;
                    }
                }

                // Skip remaining labels if we found target early
                while (i < count) : (i += 1) {
                    _ = reader.readU32() catch return error.UnexpectedEnd;
                }

                try self.branch(target, reader);
            },

            .@"return" => {
                // Return from current function
                if (self.call_stack.pop()) |frame| {
                    var f = frame;
                    f.deinit();
                }
                // Signal to exit execute loop
                self.labels.clearRetainingCapacity();
            },

            .call => {
                const func_idx = reader.readU32() catch return error.UnexpectedEnd;
                _ = try self.callFuncInternal(func_idx);
            },

            .call_indirect => {
                const type_idx = reader.readU32() catch return error.UnexpectedEnd;
                const table_idx: u32 = reader.readU32() catch return error.UnexpectedEnd;

                const elem_idx: u32 = @bitCast(self.popI32());

                // Validate table index
                if (table_idx >= self.tables.len) return error.InvalidTable;
                const table = &self.tables[table_idx];

                // Get function index from table
                const func_idx = try table.get(elem_idx) orelse return error.UndefinedElement;

                // Validate function index
                if (func_idx >= self.module.funcCount()) return error.InvalidFunction;

                // Get expected type
                if (type_idx >= self.module.types.len) return error.InvalidFunction;
                const expected_type = self.module.types[type_idx];

                // Get actual type
                const actual_type = self.module.getFuncType(func_idx) orelse return error.InvalidFunction;

                // Verify type matches
                if (!expected_type.eql(actual_type)) {
                    return error.IndirectCallTypeMismatch;
                }

                // Call the function
                _ = try self.callFuncInternal(func_idx);
            },

            // Parametric
            .drop => {
                _ = self.stack.pop();
            },

            .select, .select_t => {
                if (op == .select_t) {
                    // Read value types (currently ignored)
                    const count = reader.readU32() catch return error.UnexpectedEnd;
                    var i: u32 = 0;
                    while (i < count) : (i += 1) {
                        _ = reader.readByte() catch return error.UnexpectedEnd;
                    }
                }

                const cond = self.popI32();
                const val2 = self.stack.pop() orelse return error.StackUnderflow;
                const val1 = self.stack.pop() orelse return error.StackUnderflow;

                self.stack.append(self.allocator, if (cond != 0) val1 else val2) catch return error.OutOfMemory;
            },

            // Variable access
            .local_get => {
                const idx = reader.readU32() catch return error.UnexpectedEnd;
                if (self.call_stack.items.len == 0) return error.InvalidLocal;
                const frame = &self.call_stack.items[self.call_stack.items.len - 1];
                if (idx >= frame.locals.len) return error.InvalidLocal;
                self.stack.append(self.allocator, frame.locals[idx]) catch return error.OutOfMemory;
            },

            .local_set => {
                const idx = reader.readU32() catch return error.UnexpectedEnd;
                if (self.call_stack.items.len == 0) return error.InvalidLocal;
                const frame = &self.call_stack.items[self.call_stack.items.len - 1];
                if (idx >= frame.locals.len) return error.InvalidLocal;
                frame.locals[idx] = self.stack.pop() orelse return error.StackUnderflow;
            },

            .local_tee => {
                const idx = reader.readU32() catch return error.UnexpectedEnd;
                if (self.call_stack.items.len == 0) return error.InvalidLocal;
                const frame = &self.call_stack.items[self.call_stack.items.len - 1];
                if (idx >= frame.locals.len) return error.InvalidLocal;
                if (self.stack.items.len == 0) return error.StackUnderflow;
                frame.locals[idx] = self.stack.items[self.stack.items.len - 1];
            },

            .global_get => {
                const idx = reader.readU32() catch return error.UnexpectedEnd;
                if (idx >= self.globals.len) return error.InvalidGlobal;
                self.stack.append(self.allocator, self.globals[idx].value) catch return error.OutOfMemory;
            },

            .global_set => {
                const idx = reader.readU32() catch return error.UnexpectedEnd;
                if (idx >= self.globals.len) return error.InvalidGlobal;
                if (!self.globals[idx].mutable) return error.InvalidGlobal;
                self.globals[idx].value = self.stack.pop() orelse return error.StackUnderflow;
            },

            // Memory operations
            .i32_load => {
                const mem_arg = try self.readMemArg(reader);
                const base: u32 = @bitCast(self.popI32());
                const addr = base +% mem_arg.offset;
                const val = try self.memories[0].loadI32(addr);
                self.stack.append(self.allocator, .{ .i32 = val }) catch return error.OutOfMemory;
            },

            .i64_load => {
                const mem_arg = try self.readMemArg(reader);
                const base: u32 = @bitCast(self.popI32());
                const addr = base +% mem_arg.offset;
                const val = try self.memories[0].loadI64(addr);
                self.stack.append(self.allocator, .{ .i64 = val }) catch return error.OutOfMemory;
            },

            .f32_load => {
                const mem_arg = try self.readMemArg(reader);
                const base: u32 = @bitCast(self.popI32());
                const addr = base +% mem_arg.offset;
                const val = try self.memories[0].loadF32(addr);
                self.stack.append(self.allocator, .{ .f32 = val }) catch return error.OutOfMemory;
            },

            .f64_load => {
                const mem_arg = try self.readMemArg(reader);
                const base: u32 = @bitCast(self.popI32());
                const addr = base +% mem_arg.offset;
                const val = try self.memories[0].loadF64(addr);
                self.stack.append(self.allocator, .{ .f64 = val }) catch return error.OutOfMemory;
            },

            .i32_load8_s => {
                const mem_arg = try self.readMemArg(reader);
                const base: u32 = @bitCast(self.popI32());
                const addr = base +% mem_arg.offset;
                const val = try self.memories[0].loadI32_8s(addr);
                self.stack.append(self.allocator, .{ .i32 = val }) catch return error.OutOfMemory;
            },

            .i32_load8_u => {
                const mem_arg = try self.readMemArg(reader);
                const base: u32 = @bitCast(self.popI32());
                const addr = base +% mem_arg.offset;
                const val = try self.memories[0].loadI32_8u(addr);
                self.stack.append(self.allocator, .{ .i32 = val }) catch return error.OutOfMemory;
            },

            .i32_load16_s => {
                const mem_arg = try self.readMemArg(reader);
                const base: u32 = @bitCast(self.popI32());
                const addr = base +% mem_arg.offset;
                const val = try self.memories[0].loadI32_16s(addr);
                self.stack.append(self.allocator, .{ .i32 = val }) catch return error.OutOfMemory;
            },

            .i32_load16_u => {
                const mem_arg = try self.readMemArg(reader);
                const base: u32 = @bitCast(self.popI32());
                const addr = base +% mem_arg.offset;
                const val = try self.memories[0].loadI32_16u(addr);
                self.stack.append(self.allocator, .{ .i32 = val }) catch return error.OutOfMemory;
            },

            .i32_store => {
                const mem_arg = try self.readMemArg(reader);
                const val = self.popI32();
                const base: u32 = @bitCast(self.popI32());
                const addr = base +% mem_arg.offset;
                try self.memories[0].storeI32(addr, val);
            },

            .i64_store => {
                const mem_arg = try self.readMemArg(reader);
                const val = self.popI64();
                const base: u32 = @bitCast(self.popI32());
                const addr = base +% mem_arg.offset;
                try self.memories[0].storeI64(addr, val);
            },

            .f32_store => {
                const mem_arg = try self.readMemArg(reader);
                const val = self.popF32();
                const base: u32 = @bitCast(self.popI32());
                const addr = base +% mem_arg.offset;
                try self.memories[0].storeF32(addr, val);
            },

            .f64_store => {
                const mem_arg = try self.readMemArg(reader);
                const val = self.popF64();
                const base: u32 = @bitCast(self.popI32());
                const addr = base +% mem_arg.offset;
                try self.memories[0].storeF64(addr, val);
            },

            .i32_store8 => {
                const mem_arg = try self.readMemArg(reader);
                const val = self.popI32();
                const base: u32 = @bitCast(self.popI32());
                const addr = base +% mem_arg.offset;
                try self.memories[0].storeI8(addr, val);
            },

            .i32_store16 => {
                const mem_arg = try self.readMemArg(reader);
                const val = self.popI32();
                const base: u32 = @bitCast(self.popI32());
                const addr = base +% mem_arg.offset;
                try self.memories[0].storeI16(addr, val);
            },

            .memory_size => {
                _ = reader.readU32() catch return error.UnexpectedEnd;
                const size: i32 = @intCast(self.memories[0].size());
                self.stack.append(self.allocator, .{ .i32 = size }) catch return error.OutOfMemory;
            },

            .memory_grow => {
                _ = reader.readU32() catch return error.UnexpectedEnd;
                const pages: u32 = @bitCast(self.popI32());
                const result = self.memories[0].grow(pages) catch -1;
                self.stack.append(self.allocator, .{ .i32 = result }) catch return error.OutOfMemory;
            },

            // Constants
            .i32_const => {
                const val = reader.readI32() catch return error.UnexpectedEnd;
                self.stack.append(self.allocator, .{ .i32 = val }) catch return error.OutOfMemory;
            },

            .i64_const => {
                const val = reader.readI64() catch return error.UnexpectedEnd;
                self.stack.append(self.allocator, .{ .i64 = val }) catch return error.OutOfMemory;
            },

            .f32_const => {
                const val = reader.readF32() catch return error.UnexpectedEnd;
                self.stack.append(self.allocator, .{ .f32 = val }) catch return error.OutOfMemory;
            },

            .f64_const => {
                const val = reader.readF64() catch return error.UnexpectedEnd;
                self.stack.append(self.allocator, .{ .f64 = val }) catch return error.OutOfMemory;
            },

            // i32 comparisons
            .i32_eqz => {
                const a = self.popI32();
                self.pushBool(a == 0);
            },
            .i32_eq => {
                const b = self.popI32();
                const a = self.popI32();
                self.pushBool(a == b);
            },
            .i32_ne => {
                const b = self.popI32();
                const a = self.popI32();
                self.pushBool(a != b);
            },
            .i32_lt_s => {
                const b = self.popI32();
                const a = self.popI32();
                self.pushBool(a < b);
            },
            .i32_lt_u => {
                const b: u32 = @bitCast(self.popI32());
                const a: u32 = @bitCast(self.popI32());
                self.pushBool(a < b);
            },
            .i32_gt_s => {
                const b = self.popI32();
                const a = self.popI32();
                self.pushBool(a > b);
            },
            .i32_gt_u => {
                const b: u32 = @bitCast(self.popI32());
                const a: u32 = @bitCast(self.popI32());
                self.pushBool(a > b);
            },
            .i32_le_s => {
                const b = self.popI32();
                const a = self.popI32();
                self.pushBool(a <= b);
            },
            .i32_le_u => {
                const b: u32 = @bitCast(self.popI32());
                const a: u32 = @bitCast(self.popI32());
                self.pushBool(a <= b);
            },
            .i32_ge_s => {
                const b = self.popI32();
                const a = self.popI32();
                self.pushBool(a >= b);
            },
            .i32_ge_u => {
                const b: u32 = @bitCast(self.popI32());
                const a: u32 = @bitCast(self.popI32());
                self.pushBool(a >= b);
            },

            // i64 comparisons
            .i64_eqz => {
                const a = self.popI64();
                self.pushBool(a == 0);
            },
            .i64_eq => {
                const b = self.popI64();
                const a = self.popI64();
                self.pushBool(a == b);
            },
            .i64_ne => {
                const b = self.popI64();
                const a = self.popI64();
                self.pushBool(a != b);
            },
            .i64_lt_s => {
                const b = self.popI64();
                const a = self.popI64();
                self.pushBool(a < b);
            },
            .i64_lt_u => {
                const b: u64 = @bitCast(self.popI64());
                const a: u64 = @bitCast(self.popI64());
                self.pushBool(a < b);
            },
            .i64_gt_s => {
                const b = self.popI64();
                const a = self.popI64();
                self.pushBool(a > b);
            },
            .i64_gt_u => {
                const b: u64 = @bitCast(self.popI64());
                const a: u64 = @bitCast(self.popI64());
                self.pushBool(a > b);
            },
            .i64_le_s => {
                const b = self.popI64();
                const a = self.popI64();
                self.pushBool(a <= b);
            },
            .i64_le_u => {
                const b: u64 = @bitCast(self.popI64());
                const a: u64 = @bitCast(self.popI64());
                self.pushBool(a <= b);
            },
            .i64_ge_s => {
                const b = self.popI64();
                const a = self.popI64();
                self.pushBool(a >= b);
            },
            .i64_ge_u => {
                const b: u64 = @bitCast(self.popI64());
                const a: u64 = @bitCast(self.popI64());
                self.pushBool(a >= b);
            },

            // f32 comparisons
            .f32_eq => {
                const b = self.popF32();
                const a = self.popF32();
                self.pushBool(a == b);
            },
            .f32_ne => {
                const b = self.popF32();
                const a = self.popF32();
                self.pushBool(a != b);
            },
            .f32_lt => {
                const b = self.popF32();
                const a = self.popF32();
                self.pushBool(a < b);
            },
            .f32_gt => {
                const b = self.popF32();
                const a = self.popF32();
                self.pushBool(a > b);
            },
            .f32_le => {
                const b = self.popF32();
                const a = self.popF32();
                self.pushBool(a <= b);
            },
            .f32_ge => {
                const b = self.popF32();
                const a = self.popF32();
                self.pushBool(a >= b);
            },

            // f64 comparisons
            .f64_eq => {
                const b = self.popF64();
                const a = self.popF64();
                self.pushBool(a == b);
            },
            .f64_ne => {
                const b = self.popF64();
                const a = self.popF64();
                self.pushBool(a != b);
            },
            .f64_lt => {
                const b = self.popF64();
                const a = self.popF64();
                self.pushBool(a < b);
            },
            .f64_gt => {
                const b = self.popF64();
                const a = self.popF64();
                self.pushBool(a > b);
            },
            .f64_le => {
                const b = self.popF64();
                const a = self.popF64();
                self.pushBool(a <= b);
            },
            .f64_ge => {
                const b = self.popF64();
                const a = self.popF64();
                self.pushBool(a >= b);
            },

            // i32 arithmetic
            .i32_clz => {
                const a: u32 = @bitCast(self.popI32());
                self.stack.append(self.allocator, .{ .i32 = @intCast(@clz(a)) }) catch return error.OutOfMemory;
            },
            .i32_ctz => {
                const a: u32 = @bitCast(self.popI32());
                self.stack.append(self.allocator, .{ .i32 = @intCast(@ctz(a)) }) catch return error.OutOfMemory;
            },
            .i32_popcnt => {
                const a: u32 = @bitCast(self.popI32());
                self.stack.append(self.allocator, .{ .i32 = @intCast(@popCount(a)) }) catch return error.OutOfMemory;
            },
            .i32_add => {
                const b = self.popI32();
                const a = self.popI32();
                self.stack.append(self.allocator, .{ .i32 = a +% b }) catch return error.OutOfMemory;
            },
            .i32_sub => {
                const b = self.popI32();
                const a = self.popI32();
                self.stack.append(self.allocator, .{ .i32 = a -% b }) catch return error.OutOfMemory;
            },
            .i32_mul => {
                const b = self.popI32();
                const a = self.popI32();
                self.stack.append(self.allocator, .{ .i32 = a *% b }) catch return error.OutOfMemory;
            },
            .i32_div_s => {
                const b = self.popI32();
                const a = self.popI32();
                if (b == 0) return error.IntegerDivideByZero;
                if (a == std.math.minInt(i32) and b == -1) return error.IntegerOverflow;
                self.stack.append(self.allocator, .{ .i32 = @divTrunc(a, b) }) catch return error.OutOfMemory;
            },
            .i32_div_u => {
                const b: u32 = @bitCast(self.popI32());
                const a: u32 = @bitCast(self.popI32());
                if (b == 0) return error.IntegerDivideByZero;
                self.stack.append(self.allocator, .{ .i32 = @bitCast(a / b) }) catch return error.OutOfMemory;
            },
            .i32_rem_s => {
                const b = self.popI32();
                const a = self.popI32();
                if (b == 0) return error.IntegerDivideByZero;
                self.stack.append(self.allocator, .{ .i32 = @rem(a, b) }) catch return error.OutOfMemory;
            },
            .i32_rem_u => {
                const b: u32 = @bitCast(self.popI32());
                const a: u32 = @bitCast(self.popI32());
                if (b == 0) return error.IntegerDivideByZero;
                self.stack.append(self.allocator, .{ .i32 = @bitCast(a % b) }) catch return error.OutOfMemory;
            },
            .i32_and => {
                const b = self.popI32();
                const a = self.popI32();
                self.stack.append(self.allocator, .{ .i32 = a & b }) catch return error.OutOfMemory;
            },
            .i32_or => {
                const b = self.popI32();
                const a = self.popI32();
                self.stack.append(self.allocator, .{ .i32 = a | b }) catch return error.OutOfMemory;
            },
            .i32_xor => {
                const b = self.popI32();
                const a = self.popI32();
                self.stack.append(self.allocator, .{ .i32 = a ^ b }) catch return error.OutOfMemory;
            },
            .i32_shl => {
                const b: u5 = @truncate(@as(u32, @bitCast(self.popI32())));
                const a = self.popI32();
                self.stack.append(self.allocator, .{ .i32 = a << b }) catch return error.OutOfMemory;
            },
            .i32_shr_s => {
                const b: u5 = @truncate(@as(u32, @bitCast(self.popI32())));
                const a = self.popI32();
                self.stack.append(self.allocator, .{ .i32 = a >> b }) catch return error.OutOfMemory;
            },
            .i32_shr_u => {
                const b: u5 = @truncate(@as(u32, @bitCast(self.popI32())));
                const a: u32 = @bitCast(self.popI32());
                self.stack.append(self.allocator, .{ .i32 = @bitCast(a >> b) }) catch return error.OutOfMemory;
            },
            .i32_rotl => {
                const b: u5 = @truncate(@as(u32, @bitCast(self.popI32())));
                const a: u32 = @bitCast(self.popI32());
                self.stack.append(self.allocator, .{ .i32 = @bitCast(std.math.rotl(u32, a, b)) }) catch return error.OutOfMemory;
            },
            .i32_rotr => {
                const b: u5 = @truncate(@as(u32, @bitCast(self.popI32())));
                const a: u32 = @bitCast(self.popI32());
                self.stack.append(self.allocator, .{ .i32 = @bitCast(std.math.rotr(u32, a, b)) }) catch return error.OutOfMemory;
            },

            // i64 arithmetic
            .i64_clz => {
                const a: u64 = @bitCast(self.popI64());
                self.stack.append(self.allocator, .{ .i64 = @intCast(@clz(a)) }) catch return error.OutOfMemory;
            },
            .i64_ctz => {
                const a: u64 = @bitCast(self.popI64());
                self.stack.append(self.allocator, .{ .i64 = @intCast(@ctz(a)) }) catch return error.OutOfMemory;
            },
            .i64_popcnt => {
                const a: u64 = @bitCast(self.popI64());
                self.stack.append(self.allocator, .{ .i64 = @intCast(@popCount(a)) }) catch return error.OutOfMemory;
            },
            .i64_add => {
                const b = self.popI64();
                const a = self.popI64();
                self.stack.append(self.allocator, .{ .i64 = a +% b }) catch return error.OutOfMemory;
            },
            .i64_sub => {
                const b = self.popI64();
                const a = self.popI64();
                self.stack.append(self.allocator, .{ .i64 = a -% b }) catch return error.OutOfMemory;
            },
            .i64_mul => {
                const b = self.popI64();
                const a = self.popI64();
                self.stack.append(self.allocator, .{ .i64 = a *% b }) catch return error.OutOfMemory;
            },
            .i64_div_s => {
                const b = self.popI64();
                const a = self.popI64();
                if (b == 0) return error.IntegerDivideByZero;
                if (a == std.math.minInt(i64) and b == -1) return error.IntegerOverflow;
                self.stack.append(self.allocator, .{ .i64 = @divTrunc(a, b) }) catch return error.OutOfMemory;
            },
            .i64_div_u => {
                const b: u64 = @bitCast(self.popI64());
                const a: u64 = @bitCast(self.popI64());
                if (b == 0) return error.IntegerDivideByZero;
                self.stack.append(self.allocator, .{ .i64 = @bitCast(a / b) }) catch return error.OutOfMemory;
            },
            .i64_rem_s => {
                const b = self.popI64();
                const a = self.popI64();
                if (b == 0) return error.IntegerDivideByZero;
                self.stack.append(self.allocator, .{ .i64 = @rem(a, b) }) catch return error.OutOfMemory;
            },
            .i64_rem_u => {
                const b: u64 = @bitCast(self.popI64());
                const a: u64 = @bitCast(self.popI64());
                if (b == 0) return error.IntegerDivideByZero;
                self.stack.append(self.allocator, .{ .i64 = @bitCast(a % b) }) catch return error.OutOfMemory;
            },
            .i64_and => {
                const b = self.popI64();
                const a = self.popI64();
                self.stack.append(self.allocator, .{ .i64 = a & b }) catch return error.OutOfMemory;
            },
            .i64_or => {
                const b = self.popI64();
                const a = self.popI64();
                self.stack.append(self.allocator, .{ .i64 = a | b }) catch return error.OutOfMemory;
            },
            .i64_xor => {
                const b = self.popI64();
                const a = self.popI64();
                self.stack.append(self.allocator, .{ .i64 = a ^ b }) catch return error.OutOfMemory;
            },
            .i64_shl => {
                const b: u6 = @truncate(@as(u64, @bitCast(self.popI64())));
                const a = self.popI64();
                self.stack.append(self.allocator, .{ .i64 = a << b }) catch return error.OutOfMemory;
            },
            .i64_shr_s => {
                const b: u6 = @truncate(@as(u64, @bitCast(self.popI64())));
                const a = self.popI64();
                self.stack.append(self.allocator, .{ .i64 = a >> b }) catch return error.OutOfMemory;
            },
            .i64_shr_u => {
                const b: u6 = @truncate(@as(u64, @bitCast(self.popI64())));
                const a: u64 = @bitCast(self.popI64());
                self.stack.append(self.allocator, .{ .i64 = @bitCast(a >> b) }) catch return error.OutOfMemory;
            },
            .i64_rotl => {
                const b: u6 = @truncate(@as(u64, @bitCast(self.popI64())));
                const a: u64 = @bitCast(self.popI64());
                self.stack.append(self.allocator, .{ .i64 = @bitCast(std.math.rotl(u64, a, b)) }) catch return error.OutOfMemory;
            },
            .i64_rotr => {
                const b: u6 = @truncate(@as(u64, @bitCast(self.popI64())));
                const a: u64 = @bitCast(self.popI64());
                self.stack.append(self.allocator, .{ .i64 = @bitCast(std.math.rotr(u64, a, b)) }) catch return error.OutOfMemory;
            },

            // f32 operations
            .f32_abs => {
                const a = self.popF32();
                self.stack.append(self.allocator, .{ .f32 = @abs(a) }) catch return error.OutOfMemory;
            },
            .f32_neg => {
                const a = self.popF32();
                self.stack.append(self.allocator, .{ .f32 = -a }) catch return error.OutOfMemory;
            },
            .f32_ceil => {
                const a = self.popF32();
                self.stack.append(self.allocator, .{ .f32 = @ceil(a) }) catch return error.OutOfMemory;
            },
            .f32_floor => {
                const a = self.popF32();
                self.stack.append(self.allocator, .{ .f32 = @floor(a) }) catch return error.OutOfMemory;
            },
            .f32_trunc => {
                const a = self.popF32();
                self.stack.append(self.allocator, .{ .f32 = @trunc(a) }) catch return error.OutOfMemory;
            },
            .f32_nearest => {
                const a = self.popF32();
                self.stack.append(self.allocator, .{ .f32 = @round(a) }) catch return error.OutOfMemory;
            },
            .f32_sqrt => {
                const a = self.popF32();
                self.stack.append(self.allocator, .{ .f32 = @sqrt(a) }) catch return error.OutOfMemory;
            },
            .f32_add => {
                const b = self.popF32();
                const a = self.popF32();
                self.stack.append(self.allocator, .{ .f32 = a + b }) catch return error.OutOfMemory;
            },
            .f32_sub => {
                const b = self.popF32();
                const a = self.popF32();
                self.stack.append(self.allocator, .{ .f32 = a - b }) catch return error.OutOfMemory;
            },
            .f32_mul => {
                const b = self.popF32();
                const a = self.popF32();
                self.stack.append(self.allocator, .{ .f32 = a * b }) catch return error.OutOfMemory;
            },
            .f32_div => {
                const b = self.popF32();
                const a = self.popF32();
                self.stack.append(self.allocator, .{ .f32 = a / b }) catch return error.OutOfMemory;
            },
            .f32_min => {
                const b = self.popF32();
                const a = self.popF32();
                self.stack.append(self.allocator, .{ .f32 = @min(a, b) }) catch return error.OutOfMemory;
            },
            .f32_max => {
                const b = self.popF32();
                const a = self.popF32();
                self.stack.append(self.allocator, .{ .f32 = @max(a, b) }) catch return error.OutOfMemory;
            },
            .f32_copysign => {
                const b = self.popF32();
                const a = self.popF32();
                self.stack.append(self.allocator, .{ .f32 = std.math.copysign(a, b) }) catch return error.OutOfMemory;
            },

            // f64 operations
            .f64_abs => {
                const a = self.popF64();
                self.stack.append(self.allocator, .{ .f64 = @abs(a) }) catch return error.OutOfMemory;
            },
            .f64_neg => {
                const a = self.popF64();
                self.stack.append(self.allocator, .{ .f64 = -a }) catch return error.OutOfMemory;
            },
            .f64_ceil => {
                const a = self.popF64();
                self.stack.append(self.allocator, .{ .f64 = @ceil(a) }) catch return error.OutOfMemory;
            },
            .f64_floor => {
                const a = self.popF64();
                self.stack.append(self.allocator, .{ .f64 = @floor(a) }) catch return error.OutOfMemory;
            },
            .f64_trunc => {
                const a = self.popF64();
                self.stack.append(self.allocator, .{ .f64 = @trunc(a) }) catch return error.OutOfMemory;
            },
            .f64_nearest => {
                const a = self.popF64();
                self.stack.append(self.allocator, .{ .f64 = @round(a) }) catch return error.OutOfMemory;
            },
            .f64_sqrt => {
                const a = self.popF64();
                self.stack.append(self.allocator, .{ .f64 = @sqrt(a) }) catch return error.OutOfMemory;
            },
            .f64_add => {
                const b = self.popF64();
                const a = self.popF64();
                self.stack.append(self.allocator, .{ .f64 = a + b }) catch return error.OutOfMemory;
            },
            .f64_sub => {
                const b = self.popF64();
                const a = self.popF64();
                self.stack.append(self.allocator, .{ .f64 = a - b }) catch return error.OutOfMemory;
            },
            .f64_mul => {
                const b = self.popF64();
                const a = self.popF64();
                self.stack.append(self.allocator, .{ .f64 = a * b }) catch return error.OutOfMemory;
            },
            .f64_div => {
                const b = self.popF64();
                const a = self.popF64();
                self.stack.append(self.allocator, .{ .f64 = a / b }) catch return error.OutOfMemory;
            },
            .f64_min => {
                const b = self.popF64();
                const a = self.popF64();
                self.stack.append(self.allocator, .{ .f64 = @min(a, b) }) catch return error.OutOfMemory;
            },
            .f64_max => {
                const b = self.popF64();
                const a = self.popF64();
                self.stack.append(self.allocator, .{ .f64 = @max(a, b) }) catch return error.OutOfMemory;
            },
            .f64_copysign => {
                const b = self.popF64();
                const a = self.popF64();
                self.stack.append(self.allocator, .{ .f64 = std.math.copysign(a, b) }) catch return error.OutOfMemory;
            },

            // Conversions
            .i32_wrap_i64 => {
                const a = self.popI64();
                self.stack.append(self.allocator, .{ .i32 = @truncate(a) }) catch return error.OutOfMemory;
            },
            .i32_trunc_f32_s => {
                const a = self.popF32();
                if (std.math.isNan(a)) return error.InvalidConversionToInteger;
                if (a < @as(f32, @floatFromInt(std.math.minInt(i32))) or
                    a >= @as(f32, @floatFromInt(std.math.maxInt(i32))))
                {
                    return error.IntegerOverflow;
                }
                self.stack.append(self.allocator, .{ .i32 = @intFromFloat(a) }) catch return error.OutOfMemory;
            },
            .i32_trunc_f32_u => {
                const a = self.popF32();
                if (std.math.isNan(a)) return error.InvalidConversionToInteger;
                if (a < 0 or a >= @as(f32, @floatFromInt(std.math.maxInt(u32)))) {
                    return error.IntegerOverflow;
                }
                const u: u32 = @intFromFloat(a);
                self.stack.append(self.allocator, .{ .i32 = @bitCast(u) }) catch return error.OutOfMemory;
            },
            .i32_trunc_f64_s => {
                const a = self.popF64();
                if (std.math.isNan(a)) return error.InvalidConversionToInteger;
                if (a < @as(f64, @floatFromInt(std.math.minInt(i32))) or
                    a >= @as(f64, @floatFromInt(std.math.maxInt(i32))))
                {
                    return error.IntegerOverflow;
                }
                self.stack.append(self.allocator, .{ .i32 = @intFromFloat(a) }) catch return error.OutOfMemory;
            },
            .i32_trunc_f64_u => {
                const a = self.popF64();
                if (std.math.isNan(a)) return error.InvalidConversionToInteger;
                if (a < 0 or a >= @as(f64, @floatFromInt(std.math.maxInt(u32)))) {
                    return error.IntegerOverflow;
                }
                const u: u32 = @intFromFloat(a);
                self.stack.append(self.allocator, .{ .i32 = @bitCast(u) }) catch return error.OutOfMemory;
            },
            .i64_extend_i32_s => {
                const a = self.popI32();
                self.stack.append(self.allocator, .{ .i64 = @as(i64, a) }) catch return error.OutOfMemory;
            },
            .i64_extend_i32_u => {
                const a: u32 = @bitCast(self.popI32());
                self.stack.append(self.allocator, .{ .i64 = @as(i64, a) }) catch return error.OutOfMemory;
            },
            .i64_trunc_f32_s => {
                const a = self.popF32();
                if (std.math.isNan(a)) return error.InvalidConversionToInteger;
                self.stack.append(self.allocator, .{ .i64 = @intFromFloat(a) }) catch return error.OutOfMemory;
            },
            .i64_trunc_f32_u => {
                const a = self.popF32();
                if (std.math.isNan(a) or a < 0) return error.InvalidConversionToInteger;
                const u: u64 = @intFromFloat(a);
                self.stack.append(self.allocator, .{ .i64 = @bitCast(u) }) catch return error.OutOfMemory;
            },
            .i64_trunc_f64_s => {
                const a = self.popF64();
                if (std.math.isNan(a)) return error.InvalidConversionToInteger;
                self.stack.append(self.allocator, .{ .i64 = @intFromFloat(a) }) catch return error.OutOfMemory;
            },
            .i64_trunc_f64_u => {
                const a = self.popF64();
                if (std.math.isNan(a) or a < 0) return error.InvalidConversionToInteger;
                const u: u64 = @intFromFloat(a);
                self.stack.append(self.allocator, .{ .i64 = @bitCast(u) }) catch return error.OutOfMemory;
            },
            .f32_convert_i32_s => {
                const a = self.popI32();
                self.stack.append(self.allocator, .{ .f32 = @floatFromInt(a) }) catch return error.OutOfMemory;
            },
            .f32_convert_i32_u => {
                const a: u32 = @bitCast(self.popI32());
                self.stack.append(self.allocator, .{ .f32 = @floatFromInt(a) }) catch return error.OutOfMemory;
            },
            .f32_convert_i64_s => {
                const a = self.popI64();
                self.stack.append(self.allocator, .{ .f32 = @floatFromInt(a) }) catch return error.OutOfMemory;
            },
            .f32_convert_i64_u => {
                const a: u64 = @bitCast(self.popI64());
                self.stack.append(self.allocator, .{ .f32 = @floatFromInt(a) }) catch return error.OutOfMemory;
            },
            .f32_demote_f64 => {
                const a = self.popF64();
                self.stack.append(self.allocator, .{ .f32 = @floatCast(a) }) catch return error.OutOfMemory;
            },
            .f64_convert_i32_s => {
                const a = self.popI32();
                self.stack.append(self.allocator, .{ .f64 = @floatFromInt(a) }) catch return error.OutOfMemory;
            },
            .f64_convert_i32_u => {
                const a: u32 = @bitCast(self.popI32());
                self.stack.append(self.allocator, .{ .f64 = @floatFromInt(a) }) catch return error.OutOfMemory;
            },
            .f64_convert_i64_s => {
                const a = self.popI64();
                self.stack.append(self.allocator, .{ .f64 = @floatFromInt(a) }) catch return error.OutOfMemory;
            },
            .f64_convert_i64_u => {
                const a: u64 = @bitCast(self.popI64());
                self.stack.append(self.allocator, .{ .f64 = @floatFromInt(a) }) catch return error.OutOfMemory;
            },
            .f64_promote_f32 => {
                const a = self.popF32();
                self.stack.append(self.allocator, .{ .f64 = @floatCast(a) }) catch return error.OutOfMemory;
            },

            // Reinterpret
            .i32_reinterpret_f32 => {
                const a = self.popF32();
                self.stack.append(self.allocator, .{ .i32 = @bitCast(a) }) catch return error.OutOfMemory;
            },
            .i64_reinterpret_f64 => {
                const a = self.popF64();
                self.stack.append(self.allocator, .{ .i64 = @bitCast(a) }) catch return error.OutOfMemory;
            },
            .f32_reinterpret_i32 => {
                const a = self.popI32();
                self.stack.append(self.allocator, .{ .f32 = @bitCast(a) }) catch return error.OutOfMemory;
            },
            .f64_reinterpret_i64 => {
                const a = self.popI64();
                self.stack.append(self.allocator, .{ .f64 = @bitCast(a) }) catch return error.OutOfMemory;
            },

            // Sign extension
            .i32_extend8_s => {
                const a: i8 = @truncate(self.popI32());
                self.stack.append(self.allocator, .{ .i32 = @as(i32, a) }) catch return error.OutOfMemory;
            },
            .i32_extend16_s => {
                const a: i16 = @truncate(self.popI32());
                self.stack.append(self.allocator, .{ .i32 = @as(i32, a) }) catch return error.OutOfMemory;
            },
            .i64_extend8_s => {
                const a: i8 = @truncate(self.popI64());
                self.stack.append(self.allocator, .{ .i64 = @as(i64, a) }) catch return error.OutOfMemory;
            },
            .i64_extend16_s => {
                const a: i16 = @truncate(self.popI64());
                self.stack.append(self.allocator, .{ .i64 = @as(i64, a) }) catch return error.OutOfMemory;
            },
            .i64_extend32_s => {
                const a: i32 = @truncate(self.popI64());
                self.stack.append(self.allocator, .{ .i64 = @as(i64, a) }) catch return error.OutOfMemory;
            },

            // Extended opcodes
            .prefix_fc => {
                const ext_opcode_num = reader.readU32() catch return error.UnexpectedEnd;
                const ext_opcode: opcodes.ExtOpcode = @enumFromInt(ext_opcode_num);

                switch (ext_opcode) {
                    // Saturating truncation - i32
                    .i32_trunc_sat_f32_s => {
                        const val = self.popF32();
                        const result: i32 = if (std.math.isNan(val)) 0 else if (std.math.isInf(val)) (if (val < 0) @as(i32, -2147483648) else @as(i32, 2147483647)) else @as(i32, @intFromFloat(val));
                        self.stack.append(self.allocator, .{ .i32 = result }) catch return error.OutOfMemory;
                    },
                    .i32_trunc_sat_f32_u => {
                        const val = self.popF32();
                        const result: u32 = if (std.math.isNan(val)) 0 else if (std.math.isInf(val)) (if (val < 0) @as(u32, 0) else @as(u32, 4294967295)) else @as(u32, @intFromFloat(val));
                        self.stack.append(self.allocator, .{ .i32 = @bitCast(result) }) catch return error.OutOfMemory;
                    },
                    .i32_trunc_sat_f64_s => {
                        const val = self.popF64();
                        const result: i32 = if (std.math.isNan(val)) 0 else if (std.math.isInf(val)) (if (val < 0) @as(i32, -2147483648) else @as(i32, 2147483647)) else @as(i32, @intFromFloat(val));
                        self.stack.append(self.allocator, .{ .i32 = result }) catch return error.OutOfMemory;
                    },
                    .i32_trunc_sat_f64_u => {
                        const val = self.popF64();
                        const result: u32 = if (std.math.isNan(val)) 0 else if (std.math.isInf(val)) (if (val < 0) @as(u32, 0) else @as(u32, 4294967295)) else @as(u32, @intFromFloat(val));
                        self.stack.append(self.allocator, .{ .i32 = @bitCast(result) }) catch return error.OutOfMemory;
                    },

                    // Saturating truncation - i64
                    .i64_trunc_sat_f32_s => {
                        const val = self.popF32();
                        const result: i64 = if (std.math.isNan(val)) 0 else if (std.math.isInf(val)) (if (val < 0) @as(i64, -9223372036854775808) else @as(i64, 9223372036854775807)) else @as(i64, @intFromFloat(val));
                        self.stack.append(self.allocator, .{ .i64 = result }) catch return error.OutOfMemory;
                    },
                    .i64_trunc_sat_f32_u => {
                        const val = self.popF32();
                        const result: u64 = if (std.math.isNan(val)) 0 else if (std.math.isInf(val)) (if (val < 0) @as(u64, 0) else @as(u64, 18446744073709551615)) else @as(u64, @intFromFloat(val));
                        self.stack.append(self.allocator, .{ .i64 = @bitCast(result) }) catch return error.OutOfMemory;
                    },
                    .i64_trunc_sat_f64_s => {
                        const val = self.popF64();
                        const result: i64 = if (std.math.isNan(val)) 0 else if (std.math.isInf(val)) (if (val < 0) @as(i64, -9223372036854775808) else @as(i64, 9223372036854775807)) else @as(i64, @intFromFloat(val));
                        self.stack.append(self.allocator, .{ .i64 = result }) catch return error.OutOfMemory;
                    },
                    .i64_trunc_sat_f64_u => {
                        const val = self.popF64();
                        const result: u64 = if (std.math.isNan(val)) 0 else if (std.math.isInf(val)) (if (val < 0) @as(u64, 0) else @as(u64, 18446744073709551615)) else @as(u64, @intFromFloat(val));
                        self.stack.append(self.allocator, .{ .i64 = @bitCast(result) }) catch return error.OutOfMemory;
                    },

                    // Bulk memory operations
                    .memory_init => {
                        // memory_init data_idx mem_idx
                        const data_idx = reader.readU32() catch return error.UnexpectedEnd;
                        _ = reader.readU32() catch return error.UnexpectedEnd; // mem_idx (must be 0)

                        if (data_idx >= self.module.datas.len) return error.OutOfBoundsMemoryAccess;
                        const data_segment = self.module.datas[data_idx];

                        const size = self.popI32();
                        const offset = self.popI32();
                        const dest = self.popI32();

                        if (size < 0 or offset < 0 or dest < 0) return error.OutOfBoundsMemoryAccess;

                        const size_u = @as(u32, @bitCast(size));
                        const offset_u = @as(u32, @bitCast(offset));
                        const dest_u = @as(u32, @bitCast(dest));

                        if (offset_u + size_u > data_segment.init.len) return error.OutOfBoundsMemoryAccess;
                        if (dest_u + size_u > self.memories[0].data.len) return error.OutOfBoundsMemoryAccess;

                        if (size_u > 0) {
                            @memcpy(self.memories[0].data[dest_u..][0..size_u], data_segment.init[offset_u..][0..size_u]);
                        }
                    },

                    .data_drop => {
                        // data_drop data_idx - just consume the index, data is already in memory
                        const _data_idx = reader.readU32() catch return error.UnexpectedEnd;
                        _ = _data_idx;
                    },

                    .memory_copy => {
                        const size = self.popI32();
                        const src = self.popI32();
                        const dest = self.popI32();

                        if (size < 0 or src < 0 or dest < 0) return error.OutOfBoundsMemoryAccess;

                        const size_u = @as(u32, @bitCast(size));
                        const src_u = @as(u32, @bitCast(src));
                        const dest_u = @as(u32, @bitCast(dest));

                        if (src_u + size_u > self.memories[0].data.len) return error.OutOfBoundsMemoryAccess;
                        if (dest_u + size_u > self.memories[0].data.len) return error.OutOfBoundsMemoryAccess;

                        if (size_u > 0) {
                            // Use memmove to handle overlapping regions
                            std.mem.copyForwards(u8, self.memories[0].data[dest_u..][0..size_u], self.memories[0].data[src_u..][0..size_u]);
                        }
                    },

                    .memory_fill => {
                        const size = self.popI32();
                        const value = self.popI32();
                        const offset = self.popI32();

                        if (size < 0 or offset < 0) return error.OutOfBoundsMemoryAccess;

                        const size_u = @as(u32, @bitCast(size));
                        const offset_u = @as(u32, @bitCast(offset));
                        const value_u = @as(u8, @truncate(@as(u32, @bitCast(value))));

                        if (offset_u + size_u > self.memories[0].data.len) return error.OutOfBoundsMemoryAccess;

                        if (size_u > 0) {
                            @memset(self.memories[0].data[offset_u..][0..size_u], value_u);
                        }
                    },

                    // Table operations (not fully implemented - stub versions)
                    .table_init, .elem_drop, .table_copy, .table_grow, .table_size, .table_fill => {
                        return error.UnknownOpcode; // Not yet implemented
                    },

                    _ => return error.UnknownOpcode,
                }
            },

            else => return error.UnknownOpcode,
        }
    }

    fn readMemArg(self: *Instance, reader: *binary.Reader) TrapError!opcodes.MemArg {
        _ = self;
        const alignment = reader.readU32() catch return error.UnexpectedEnd;
        const offset = reader.readU32() catch return error.UnexpectedEnd;
        return .{ .alignment = alignment, .offset = offset };
    }

    fn branch(self: *Instance, depth: u32, reader: *binary.Reader) TrapError!void {
        if (depth >= self.labels.items.len) {
            // Branch out of function
            self.labels.clearRetainingCapacity();
            return;
        }

        const target_idx = self.labels.items.len - 1 - depth;
        const label = self.labels.items[target_idx];

        // Pop labels up to and including target
        self.labels.shrinkRetainingCapacity(target_idx + 1);

        if (label.opcode == .loop) {
            // For loop, jump back to start
            reader.pos = label.target_ip;
            // Re-push the label for the loop
            self.labels.append(self.allocator, label) catch return error.OutOfMemory;
        } else {
            // For block/if, skip to end
            try self.skipToEnd(reader);
            _ = self.labels.pop();
        }
    }

    fn skipToElseOrEnd(_: *Instance, reader: *binary.Reader) TrapError!void {
        var depth: u32 = 1;
        while (depth > 0 and !reader.isEof()) {
            const byte = reader.readByte() catch return error.UnexpectedEnd;
            switch (byte) {
                0x02, 0x03, 0x04 => depth += 1,
                0x05 => if (depth == 1) return, // Found else at same level
                0x0B => depth -= 1,
                else => try skipImmediate(byte, reader),
            }
        }
    }

    fn skipToEnd(_: *Instance, reader: *binary.Reader) TrapError!void {
        var depth: u32 = 1;
        while (depth > 0 and !reader.isEof()) {
            const byte = reader.readByte() catch return error.UnexpectedEnd;
            switch (byte) {
                0x02, 0x03, 0x04 => depth += 1,
                0x0B => depth -= 1,
                else => try skipImmediate(byte, reader),
            }
        }
    }

    fn skipImmediate(opcode: u8, reader: *binary.Reader) TrapError!void {
        switch (opcode) {
            0x41 => _ = reader.readI32() catch return error.UnexpectedEnd,
            0x42 => _ = reader.readI64() catch return error.UnexpectedEnd,
            0x43 => _ = reader.readBytes(4) catch return error.UnexpectedEnd,
            0x44 => _ = reader.readBytes(8) catch return error.UnexpectedEnd,
            0x0C, 0x0D, 0x10, 0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26 => {
                _ = reader.readU32() catch return error.UnexpectedEnd;
            },
            0x28...0x3E => {
                _ = reader.readU32() catch return error.UnexpectedEnd;
                _ = reader.readU32() catch return error.UnexpectedEnd;
            },
            0x3F, 0x40 => _ = reader.readU32() catch return error.UnexpectedEnd,
            0x11 => {
                _ = reader.readU32() catch return error.UnexpectedEnd;
                _ = reader.readU32() catch return error.UnexpectedEnd;
            },
            0x0E => {
                // br_table
                const count = reader.readU32() catch return error.UnexpectedEnd;
                var i: u32 = 0;
                while (i <= count) : (i += 1) {
                    _ = reader.readU32() catch return error.UnexpectedEnd;
                }
            },
            0x1C => {
                // select_t
                const count = reader.readU32() catch return error.UnexpectedEnd;
                var i: u32 = 0;
                while (i < count) : (i += 1) {
                    _ = reader.readByte() catch return error.UnexpectedEnd;
                }
            },
            else => {},
        }
    }

    // Block arity helper
    fn getBlockArity(self: *const Instance, block_type: types.BlockType) u32 {
        switch (block_type) {
            .empty => return 0,
            .val_type => return 1,
            .type_idx => |idx| {
                if (idx < self.module.types.len) {
                    return @intCast(self.module.types[idx].results.len);
                }
                return 0;
            },
        }
    }

    // Stack helpers
    fn popI32(self: *Instance) i32 {
        const val = self.stack.pop() orelse return 0;
        return val.asI32();
    }

    fn popI64(self: *Instance) i64 {
        const val = self.stack.pop() orelse return 0;
        return val.asI64();
    }

    fn popF32(self: *Instance) f32 {
        const val = self.stack.pop() orelse return 0;
        return val.asF32();
    }

    fn popF64(self: *Instance) f64 {
        const val = self.stack.pop() orelse return 0;
        return val.asF64();
    }

    fn pushBool(self: *Instance, b: bool) void {
        self.stack.append(self.allocator, .{ .i32 = if (b) 1 else 0 }) catch {};
    }
};

// ═══════════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════════

test "memory operations" {
    var mem = try Memory.init(std.testing.allocator, .{ .min = 1 });
    defer mem.deinit();

    try mem.storeI32(0, 0x12345678);
    try std.testing.expectEqual(@as(i32, 0x12345678), try mem.loadI32(0));

    try mem.storeI64(8, 0x123456789ABCDEF0);
    try std.testing.expectEqual(@as(i64, 0x123456789ABCDEF0), try mem.loadI64(8));
}

test "memory grow" {
    var mem = try Memory.init(std.testing.allocator, .{ .min = 1, .max = 3 });
    defer mem.deinit();

    try std.testing.expectEqual(@as(u32, 1), mem.size());

    const result = try mem.grow(1);
    try std.testing.expectEqual(@as(i32, 1), result);
    try std.testing.expectEqual(@as(u32, 2), mem.size());
}
