// FFI Files - C bindings for xAI Files API (upload, list, delete)

const std = @import("std");
const types = @import("types.zig");
const http_sentinel = @import("http-sentinel");

const CString = types.CString;
const CBuffer = types.CBuffer;
const CFileResponse = types.CFileResponse;
const CStringResult = types.CStringResult;
const CResult = types.CResult;
const ErrorCode = types.ErrorCode;

// Global allocator for FFI
const allocator = std.heap.c_allocator;

// ============================================================================
// File Upload
// ============================================================================

/// Upload a file to xAI for use with Grok file_search
/// Returns file ID on success
export fn zig_ai_file_upload(
    api_key: CString,
    file_data: CBuffer,
    filename: CString,
    response_out: *CFileResponse,
) void {
    response_out.* = std.mem.zeroes(CFileResponse);

    const key = api_key.toSlice();
    if (key.len == 0) {
        response_out.success = false;
        response_out.error_code = ErrorCode.AUTH_ERROR;
        response_out.error_message = makeErrorString("XAI_API_KEY not set");
        return;
    }

    const data = file_data.toSlice();
    if (data.len == 0) {
        response_out.success = false;
        response_out.error_code = ErrorCode.INVALID_ARGUMENT;
        response_out.error_message = makeErrorString("File data is empty");
        return;
    }

    // 48 MB limit
    if (data.len > 48 * 1024 * 1024) {
        response_out.success = false;
        response_out.error_code = ErrorCode.INVALID_ARGUMENT;
        response_out.error_message = makeErrorString("File exceeds 48 MB limit");
        return;
    }

    const name = if (filename.len > 0) filename.toSlice() else "file.txt";

    // Create Grok client and upload
    var client = http_sentinel.GrokClient.init(allocator, key) catch |err| {
        response_out.success = false;
        response_out.error_code = mapError(err);
        response_out.error_message = makeErrorString(@errorName(err));
        return;
    };
    defer client.deinit();

    const result_json = client.uploadFile(data, name) catch |err| {
        response_out.success = false;
        response_out.error_code = mapError(err);
        response_out.error_message = makeErrorString(@errorName(err));
        return;
    };
    defer allocator.free(result_json);

    // Parse JSON response to extract file_id
    const file_id_copy = allocator.dupeZ(u8, result_json) catch {
        response_out.success = false;
        response_out.error_code = ErrorCode.OUT_OF_MEMORY;
        return;
    };

    response_out.success = true;
    response_out.error_code = ErrorCode.SUCCESS;
    response_out.file_id = .{ .ptr = file_id_copy.ptr, .len = result_json.len };

    // Copy filename
    const name_copy = allocator.dupeZ(u8, name) catch null;
    if (name_copy) |nc| {
        response_out.filename = .{ .ptr = nc.ptr, .len = name.len };
    }
    response_out.bytes = @intCast(data.len);
    response_out.purpose = CString.fromSlice("assistants");
}

// ============================================================================
// File List
// ============================================================================

/// List all uploaded files. Returns JSON array string.
export fn zig_ai_file_list(
    api_key: CString,
    result_out: *CStringResult,
) void {
    result_out.* = std.mem.zeroes(CStringResult);

    const key = api_key.toSlice();
    if (key.len == 0) {
        result_out.success = false;
        result_out.error_code = ErrorCode.AUTH_ERROR;
        result_out.error_message = makeErrorString("XAI_API_KEY not set");
        return;
    }

    var client = http_sentinel.GrokClient.init(allocator, key) catch |err| {
        result_out.success = false;
        result_out.error_code = mapError(err);
        result_out.error_message = makeErrorString(@errorName(err));
        return;
    };
    defer client.deinit();

    const json = client.listFiles() catch |err| {
        result_out.success = false;
        result_out.error_code = mapError(err);
        result_out.error_message = makeErrorString(@errorName(err));
        return;
    };
    defer allocator.free(json);

    const json_copy = allocator.dupeZ(u8, json) catch {
        result_out.success = false;
        result_out.error_code = ErrorCode.OUT_OF_MEMORY;
        return;
    };

    result_out.success = true;
    result_out.error_code = ErrorCode.SUCCESS;
    result_out.value = .{ .ptr = json_copy.ptr, .len = json.len };
}

// ============================================================================
// File Delete
// ============================================================================

/// Delete an uploaded file by ID
export fn zig_ai_file_delete(
    api_key: CString,
    file_id: CString,
    result_out: *CResult,
) void {
    result_out.* = std.mem.zeroes(CResult);

    const key = api_key.toSlice();
    if (key.len == 0) {
        result_out.success = false;
        result_out.error_code = ErrorCode.AUTH_ERROR;
        result_out.error_message = makeErrorString("XAI_API_KEY not set");
        return;
    }

    const id = file_id.toSlice();
    if (id.len == 0) {
        result_out.success = false;
        result_out.error_code = ErrorCode.INVALID_ARGUMENT;
        result_out.error_message = makeErrorString("File ID is empty");
        return;
    }

    var client = http_sentinel.GrokClient.init(allocator, key) catch |err| {
        result_out.success = false;
        result_out.error_code = mapError(err);
        result_out.error_message = makeErrorString(@errorName(err));
        return;
    };
    defer client.deinit();

    client.deleteFile(id) catch |err| {
        result_out.success = false;
        result_out.error_code = mapError(err);
        result_out.error_message = makeErrorString(@errorName(err));
        return;
    };

    result_out.success = true;
    result_out.error_code = ErrorCode.SUCCESS;
}

// ============================================================================
// Memory Management
// ============================================================================

/// Free a file response
export fn zig_ai_file_response_free(response: *CFileResponse) void {
    freeString(response.file_id);
    freeString(response.filename);
    freeString(response.purpose);
    freeString(response.error_message);
    response.* = std.mem.zeroes(CFileResponse);
}

// ============================================================================
// Internal Helpers
// ============================================================================

fn mapError(err: anyerror) i32 {
    return switch (err) {
        error.OutOfMemory => ErrorCode.OUT_OF_MEMORY,
        error.ConnectionRefused, error.NetworkUnreachable => ErrorCode.NETWORK_ERROR,
        error.AuthenticationFailed => ErrorCode.AUTH_ERROR,
        error.Timeout => ErrorCode.TIMEOUT,
        else => ErrorCode.UNKNOWN_ERROR,
    };
}

fn makeErrorString(msg: []const u8) CString {
    const duped = allocator.dupeZ(u8, msg) catch return .{ .ptr = null, .len = 0 };
    return .{ .ptr = duped.ptr, .len = msg.len };
}

fn freeString(s: CString) void {
    if (s.ptr) |p| {
        allocator.free(p[0 .. s.len + 1]);
    }
}
