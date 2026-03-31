//! Zig Ingest Library
//!
//! Library root providing both Zig and C FFI APIs for ingesting
//! Zig code graphs (functions + call edges) into SurrealDB.

const std = @import("std");
pub const types = @import("types.zig");
pub const surreal = @import("surreal.zig");
pub const parser = @import("parser.zig");
pub const walker = @import("walker.zig");

const Config = types.Config;
const SurrealClient = surreal.SurrealClient;
const IngestResult = types.IngestResult;
const ParseResult = types.ParseResult;

// Re-export C types
pub const CString = types.CString;
pub const CConfig = types.CConfig;
pub const CIngestResult = types.CIngestResult;
pub const CIngestStats = types.CIngestStats;
pub const CStringResult = types.CStringResult;
pub const CZigIngest = types.CZigIngest;
pub const ErrorCode = types.ErrorCode;

// =============================================================================
// Zig API
// =============================================================================

/// High-level Zig API wrapping SurrealDB client + ingest operations.
pub const ZigIngest = struct {
    allocator: std.mem.Allocator,
    client: SurrealClient,
    io_threaded: *std.Io.Threaded,
    config: Config,

    pub fn init(allocator: std.mem.Allocator, config: Config, environ: std.process.Environ) !ZigIngest {
        const io_threaded = try allocator.create(std.Io.Threaded);
        io_threaded.* = std.Io.Threaded.init(allocator, .{ .environ = environ });

        return .{
            .allocator = allocator,
            .client = try SurrealClient.init(allocator, config, environ),
            .io_threaded = io_threaded,
            .config = config,
        };
    }

    pub fn deinit(self: *ZigIngest) void {
        self.client.deinit();
        self.io_threaded.deinit();
        self.allocator.destroy(self.io_threaded);
    }

    /// Ingest all .zig files in a directory tree into SurrealDB.
    pub fn ingestDirectory(self: *ZigIngest, source_dir: []const u8) !IngestResult {
        var cfg = self.config;
        cfg.source_dir = source_dir;
        const io = self.io_threaded.io();
        return walker.ingestDirectory(self.allocator, io, &self.client, cfg);
    }

    /// Parse a single file without inserting into DB.
    pub fn ingestFile(self: *ZigIngest, file_path: []const u8, relative_path: []const u8) !ParseResult {
        const io = self.io_threaded.io();
        return parser.parseFile(self.allocator, io, file_path, relative_path, self.config.verbose);
    }

    /// Insert parsed functions into SurrealDB.
    pub fn insertFunctions(self: *ZigIngest, functions: []const types.FunctionInfo) !usize {
        return walker.insertFunctions(
            self.allocator,
            &self.client,
            functions,
            self.config.dry_run,
            self.config.verbose,
        );
    }

    /// Insert parsed call edges into SurrealDB.
    pub fn insertCalls(self: *ZigIngest, calls: []const types.CallEdge) !usize {
        return walker.insertCalls(
            self.allocator,
            &self.client,
            calls,
            self.config.dry_run,
            self.config.verbose,
        );
    }

    /// Execute a raw SQL query and return the JSON response.
    /// Caller owns the returned slice.
    pub fn rawQuery(self: *ZigIngest, sql: []const u8) ![]const u8 {
        return self.client.executeQuery(sql);
    }
};

// =============================================================================
// C FFI Exports
// =============================================================================
const ffi_allocator = std.heap.c_allocator;

/// Internal handle storing the ZigIngest instance for FFI.
const FFIHandle = struct {
    zi: ZigIngest,

    fn deinit(self: *FFIHandle) void {
        self.zi.deinit();
    }
};

fn makeErrorString(msg: []const u8) CString {
    const duped = ffi_allocator.dupe(u8, msg) catch return CString{};
    return CString.fromSlice(duped);
}

// -- Lifecycle --

export fn zi_init(c_config: ?*const CConfig) ?*CZigIngest {
    const cfg = if (c_config) |cc| cc.toConfig() else Config{};

    // Construct Environ from C environ pointer for FFI consumers
    const c_env: [*:null]const ?[*:0]const u8 = @ptrCast(std.c.environ);
    const environ: std.process.Environ = .{ .block = .{ .slice = std.mem.span(c_env) } };

    const handle = ffi_allocator.create(FFIHandle) catch return null;
    handle.* = .{
        .zi = ZigIngest.init(ffi_allocator, cfg, environ) catch {
            ffi_allocator.destroy(handle);
            return null;
        },
    };
    return @ptrCast(handle);
}

export fn zi_deinit(opaque_handle: ?*CZigIngest) void {
    if (opaque_handle == null) return;
    const handle: *FFIHandle = @ptrCast(@alignCast(opaque_handle));
    handle.deinit();
    ffi_allocator.destroy(handle);
}

// -- Ingestion --

export fn zi_ingest_directory(opaque_handle: ?*CZigIngest, source_dir: CString, result_out: *CIngestResult) void {
    result_out.* = CIngestResult{};

    if (opaque_handle == null) {
        result_out.error_code = ErrorCode.INVALID_ARGUMENT;
        result_out.error_message = makeErrorString("Handle is null");
        return;
    }

    const handle: *FFIHandle = @ptrCast(@alignCast(opaque_handle));
    const dir_slice = source_dir.toSlice();
    if (dir_slice.len == 0) {
        result_out.error_code = ErrorCode.INVALID_ARGUMENT;
        result_out.error_message = makeErrorString("Source directory is empty");
        return;
    }

    const ir = handle.zi.ingestDirectory(dir_slice) catch {
        result_out.error_code = ErrorCode.IO_ERROR;
        result_out.error_message = makeErrorString("Ingestion failed");
        return;
    };

    result_out.success = true;
    result_out.files_processed = @intCast(ir.stats.files_processed);
    result_out.functions_found = @intCast(ir.stats.functions_found);
    result_out.calls_found = @intCast(ir.stats.calls_found);
    result_out.parse_errors = @intCast(ir.stats.parse_errors);
    result_out.insert_errors = @intCast(ir.stats.insert_errors);
    result_out.functions_inserted = @intCast(ir.functions_inserted);
    result_out.calls_inserted = @intCast(ir.calls_inserted);
}

// -- Raw Query --

export fn zi_raw_query(opaque_handle: ?*CZigIngest, sql: CString, result_out: *CStringResult) void {
    result_out.* = CStringResult{};

    if (opaque_handle == null) {
        result_out.error_code = ErrorCode.INVALID_ARGUMENT;
        return;
    }

    const handle: *FFIHandle = @ptrCast(@alignCast(opaque_handle));
    const sql_slice = sql.toSlice();

    const response = handle.zi.rawQuery(sql_slice) catch {
        result_out.error_code = ErrorCode.NETWORK_ERROR;
        result_out.error_message = makeErrorString("Query failed");
        return;
    };

    result_out.success = true;
    result_out.value = CString.fromSlice(response);
}

// -- Memory Management --

export fn zi_free_result(result_ptr: ?*CIngestResult) void {
    if (result_ptr) |r| {
        if (r.error_message.ptr) |p| {
            ffi_allocator.free(p[0..r.error_message.len]);
        }
        r.* = CIngestResult{};
    }
}

export fn zi_free_string(s: CString) void {
    if (s.ptr) |p| {
        ffi_allocator.free(p[0..s.len]);
    }
}

export fn zi_free_string_result(result_ptr: ?*CStringResult) void {
    if (result_ptr) |r| {
        if (r.value.ptr) |p| {
            ffi_allocator.free(p[0..r.value.len]);
        }
        if (r.error_message.ptr) |p| {
            ffi_allocator.free(p[0..r.error_message.len]);
        }
        r.* = CStringResult{};
    }
}
