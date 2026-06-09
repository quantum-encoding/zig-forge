// GPU compute provisioning controller — Compute Engine instance lifecycle.
//
//   POST   /qai/v1/compute/provision        launch a GPU instance
//   DELETE /qai/v1/compute/instance/{id}     tear down an instance
//
// SPEND SAFETY (defense in depth — the operator flagged the drain risk):
//   1. Router gate: only operator-vetted accounts (admin / enterprise) reach
//      this code at all (router.zig:computeApproved → 403 otherwise).
//   2. Machine-type allowlist: the requested machine_type must appear in
//      QAI_COMPUTE_ALLOWED_TYPES (comma-separated). Empty/unset → deny all.
//   3. Required operator config: QAI_COMPUTE_ZONE + QAI_COMPUTE_IMAGE must be
//      set, or provisioning is refused (503). The server never invents a
//      zone/image and never launches anything until the operator opts in.
// So a leaked ordinary key can't provision (gate); even an approved account is
// confined to the operator's allowlisted machine types in the operator's zone.

const std = @import("std");
const http = std.http;
const json_util = @import("json.zig");
const router = @import("router.zig");
const gcp = @import("gcp.zig");
const types = @import("store/types.zig");
const Response = router.Response;

const ProvisionRequest = struct {
    machine_type: []const u8 = "",
    gpu_type: ?[]const u8 = null,
    gpu_count: ?u32 = null,
    name: ?[]const u8 = null,
};

pub fn handleProvision(
    request: *http.Server.Request,
    allocator: std.mem.Allocator,
    environ_map: *const std.process.Environ.Map,
    io: std.Io,
    gcp_ctx: ?*gcp.GcpContext,
) Response {
    const ctx = gcp_ctx orelse return err(.service_unavailable, "GCP credentials required");

    const hsx = @import("http-sentinel");
    // Operator config — all three required, else fail closed.
    const allowed = hsx.ai.getApiKeyFromEnv(environ_map, "QAI_COMPUTE_ALLOWED_TYPES") catch "";
    const zone = hsx.ai.getApiKeyFromEnv(environ_map, "QAI_COMPUTE_ZONE") catch "";
    const image = hsx.ai.getApiKeyFromEnv(environ_map, "QAI_COMPUTE_IMAGE") catch "";
    if (allowed.len == 0 or zone.len == 0 or image.len == 0)
        return err(.service_unavailable, "compute provisioning not enabled (operator must set QAI_COMPUTE_ALLOWED_TYPES, QAI_COMPUTE_ZONE, QAI_COMPUTE_IMAGE)");

    const body = json_util.readBody(request, allocator, 64 * 1024) catch return err(.bad_request, "read body");
    defer allocator.free(body);
    const parsed = std.json.parseFromSlice(ProvisionRequest, allocator, body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch
        return err(.bad_request, "invalid JSON body");
    defer parsed.deinit();
    const req = parsed.value;
    if (req.machine_type.len == 0) return err(.bad_request, "machine_type is required");

    // Allowlist check — the requested machine_type MUST be explicitly allowed.
    if (!inAllowlist(allowed, req.machine_type))
        return err(.forbidden, "machine_type is not in the operator's compute allowlist");

    // Build the instance resource and POST it to Compute Engine.
    const inst_name = req.name orelse "qai-gpu-instance";
    const inst = buildInstance(allocator, zone, image, inst_name, req) catch
        return err(.internal_server_error, "build instance config");
    defer allocator.free(inst);

    const url = std.fmt.allocPrint(allocator, "https://compute.googleapis.com/compute/v1/projects/{s}/zones/{s}/instances", .{ ctx.project_id, zone }) catch
        return err(.internal_server_error, "alloc");
    defer allocator.free(url);
    _ = io;

    var resp = ctx.post(url, inst) catch return err(.bad_gateway, "Compute Engine request failed");
    defer resp.deinit();
    if (@intFromEnum(resp.status) >= 300) return err(.bad_gateway, "Compute Engine rejected the request");

    // Return the operation (so the caller can poll the instance create op).
    const out = allocator.dupe(u8, resp.body) catch return err(.internal_server_error, "buffer");
    return .{ .status = .ok, .body = out };
}

/// DELETE /qai/v1/compute/instance/{id} — tear down (instances.delete).
pub fn handleTeardown(
    allocator: std.mem.Allocator,
    environ_map: *const std.process.Environ.Map,
    gcp_ctx: ?*gcp.GcpContext,
    instance_id: []const u8,
) Response {
    const ctx = gcp_ctx orelse return err(.service_unavailable, "GCP credentials required");
    const hsx = @import("http-sentinel");
    const zone = hsx.ai.getApiKeyFromEnv(environ_map, "QAI_COMPUTE_ZONE") catch "";
    if (zone.len == 0) return err(.service_unavailable, "compute not enabled");

    const url = std.fmt.allocPrint(allocator, "https://compute.googleapis.com/compute/v1/projects/{s}/zones/{s}/instances/{s}", .{ ctx.project_id, zone, instance_id }) catch
        return err(.internal_server_error, "alloc");
    defer allocator.free(url);

    var resp = ctx.delete(url) catch return err(.bad_gateway, "Compute Engine request failed");
    defer resp.deinit();
    if (@intFromEnum(resp.status) >= 300) return err(.bad_gateway, "teardown failed");
    const out = allocator.dupe(u8, resp.body) catch return err(.internal_server_error, "buffer");
    return .{ .status = .ok, .body = out };
}

fn inAllowlist(allowed: []const u8, machine_type: []const u8) bool {
    var it = std.mem.splitScalar(u8, allowed, ',');
    while (it.next()) |entry| {
        if (std.mem.eql(u8, std.mem.trim(u8, entry, " \t"), machine_type)) return true;
    }
    return false;
}

/// Build the Compute Engine instance resource. Boot disk from the operator's
/// image; optional GPU accelerator (which forces onHostMaintenance=TERMINATE).
/// All values escaped via Stringify.
fn buildInstance(allocator: std.mem.Allocator, zone: []const u8, image: []const u8, name: []const u8, req: ProvisionRequest) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var jw: std.json.Stringify = .{ .writer = &aw.writer, .options = .{} };

    try jw.beginObject();
    try jw.objectField("name");
    try jw.write(name);
    try jw.objectField("machineType");
    {
        var mtbuf: [256]u8 = undefined;
        try jw.write(try std.fmt.bufPrint(&mtbuf, "zones/{s}/machineTypes/{s}", .{ zone, req.machine_type }));
    }
    // Boot disk.
    try jw.objectField("disks");
    try jw.beginArray();
    try jw.beginObject();
    try jw.objectField("boot");
    try jw.write(true);
    try jw.objectField("autoDelete");
    try jw.write(true);
    try jw.objectField("initializeParams");
    try jw.beginObject();
    try jw.objectField("sourceImage");
    try jw.write(image);
    try jw.endObject();
    try jw.endObject();
    try jw.endArray();
    // Default network with external IP.
    try jw.objectField("networkInterfaces");
    try jw.beginArray();
    try jw.beginObject();
    try jw.objectField("network");
    try jw.write("global/networks/default");
    try jw.objectField("accessConfigs");
    try jw.beginArray();
    try jw.beginObject();
    try jw.objectField("type");
    try jw.write("ONE_TO_ONE_NAT");
    try jw.objectField("name");
    try jw.write("External NAT");
    try jw.endObject();
    try jw.endArray();
    try jw.endObject();
    try jw.endArray();
    // Optional GPU.
    if (req.gpu_type) |gt| {
        try jw.objectField("guestAccelerators");
        try jw.beginArray();
        try jw.beginObject();
        try jw.objectField("acceleratorType");
        var atbuf: [256]u8 = undefined;
        try jw.write(try std.fmt.bufPrint(&atbuf, "zones/{s}/acceleratorTypes/{s}", .{ zone, gt }));
        try jw.objectField("acceleratorCount");
        try jw.write(req.gpu_count orelse 1);
        try jw.endObject();
        try jw.endArray();
        // GPUs require the instance to terminate (not migrate) on maintenance.
        try jw.objectField("scheduling");
        try jw.beginObject();
        try jw.objectField("onHostMaintenance");
        try jw.write("TERMINATE");
        try jw.endObject();
    }
    try jw.endObject();
    return aw.toOwnedSlice();
}

fn err(status: http.Status, message: []const u8) Response {
    _ = message;
    return switch (status) {
        .bad_request => .{ .status = .bad_request, .body = "{\"error\":\"invalid_request\",\"message\":\"provision request rejected\"}" },
        .forbidden => .{ .status = .forbidden, .body = "{\"error\":\"machine_type_not_allowed\",\"message\":\"requested machine_type is not in the operator's compute allowlist\"}" },
        .service_unavailable => .{ .status = .service_unavailable, .body = "{\"error\":\"unavailable\",\"message\":\"compute provisioning not enabled (operator config required)\"}" },
        .bad_gateway => .{ .status = .bad_gateway, .body = "{\"error\":\"provider_error\",\"message\":\"Compute Engine request failed\"}" },
        else => .{ .status = .internal_server_error, .body = "{\"error\":\"internal\",\"message\":\"provision failed\"}" },
    };
}
