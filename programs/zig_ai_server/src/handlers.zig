// Handlers — request handler implementations

const std = @import("std");
const http = std.http;
const router = @import("router.zig");
const Response = router.Response;

pub fn health(_: *http.Server.Request, _: std.mem.Allocator) Response {
    return .{
        .body =
        \\{"status":"ok","service":"zig-ai-server","version":"0.2.0"}
        ,
    };
}

pub fn root(_: *http.Server.Request, _: std.mem.Allocator) Response {
    return .{
        .body =
        \\{"service":"zig-ai-server","version":"0.2.0","api":"/qai/v1/","docs":"https://api.cosmicduck.dev"}
        ,
    };
}

pub fn notFound(_: *http.Server.Request, _: std.mem.Allocator) Response {
    return .{
        .status = .not_found,
        .body =
        \\{"error":"not_found","message":"The requested endpoint does not exist"}
        ,
    };
}

pub fn methodNotAllowed(_: *http.Server.Request, _: std.mem.Allocator) Response {
    return .{
        .status = .method_not_allowed,
        .body =
        \\{"error":"method_not_allowed","message":"HTTP method not supported for this endpoint"}
        ,
    };
}

/// Generic stub for endpoints that exist in the contract but aren't implemented yet
pub fn stub(_: *http.Server.Request, allocator: std.mem.Allocator, endpoint: []const u8) Response {
    const body = std.fmt.allocPrint(allocator,
        \\{{"error":"not_implemented","endpoint":"{s}","message":"This endpoint is registered but not yet implemented"}}
    , .{endpoint}) catch
        \\{"error":"not_implemented","message":"Endpoint not yet implemented"}
    ;
    return .{
        .status = .not_implemented,
        .body = body,
    };
}
