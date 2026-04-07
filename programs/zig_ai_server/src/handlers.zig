// Handlers — request handler implementations

const std = @import("std");
const http = std.http;
const router = @import("router.zig");
const Response = router.Response;

pub fn health(_: *http.Server.Request, _: std.mem.Allocator) Response {
    return .{
        .body =
        \\{"status":"ok","service":"zig-ai-server","version":"0.1.0"}
        ,
    };
}

pub fn root(_: *http.Server.Request, _: std.mem.Allocator) Response {
    return .{
        .body =
        \\{"service":"zig-ai-server","version":"0.1.0","docs":"/qai/v1/"}
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

// Placeholder handlers for Phase 2+ endpoints
pub fn chatPlaceholder(_: *http.Server.Request, _: std.mem.Allocator) Response {
    return .{
        .status = .service_unavailable,
        .body =
        \\{"error":"not_implemented","message":"POST /qai/v1/chat — coming in Phase 3"}
        ,
    };
}

pub fn modelsPlaceholder(_: *http.Server.Request, _: std.mem.Allocator) Response {
    return .{
        .status = .service_unavailable,
        .body =
        \\{"error":"not_implemented","message":"GET /qai/v1/models — coming in Phase 4"}
        ,
    };
}

pub fn balancePlaceholder(_: *http.Server.Request, _: std.mem.Allocator) Response {
    return .{
        .status = .service_unavailable,
        .body =
        \\{"error":"not_implemented","message":"GET /qai/v1/account/balance — coming in Phase 4"}
        ,
    };
}
