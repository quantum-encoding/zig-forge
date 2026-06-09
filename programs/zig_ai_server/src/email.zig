// Transactional email via Resend.
//
//   POST /qai/v1/quantify/email/send   → Resend /emails
//
// Forwards a {from?, to, subject, html|text} payload to the Resend API with
// the server's RESEND_API_KEY. `from` defaults to a configured sender
// (QAI_EMAIL_FROM) when the client omits it. The client body is re-serialized
// via Stringify (escaped) — never hand-interpolated.

const std = @import("std");
const http = std.http;
const hs = @import("http-sentinel");
const json_util = @import("json.zig");
const router = @import("router.zig");
const Response = router.Response;

const EmailRequest = struct {
    from: ?[]const u8 = null,
    to: []const u8 = "",
    subject: []const u8 = "",
    html: ?[]const u8 = null,
    text: ?[]const u8 = null,
};

pub fn handleSend(
    request: *http.Server.Request,
    allocator: std.mem.Allocator,
    environ_map: *const std.process.Environ.Map,
) Response {
    const key = hs.ai.getApiKeyFromEnv(environ_map, "RESEND_API_KEY") catch
        return err(.service_unavailable);

    const body = json_util.readBody(request, allocator, 1 * 1024 * 1024) catch return err(.bad_request);
    defer allocator.free(body);
    const parsed = std.json.parseFromSlice(EmailRequest, allocator, body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch
        return err(.bad_request);
    defer parsed.deinit();
    const req = parsed.value;
    if (req.to.len == 0 or req.subject.len == 0) return err(.bad_request);
    if (req.html == null and req.text == null) return err(.bad_request);

    const from = req.from orelse (hs.ai.getApiKeyFromEnv(environ_map, "QAI_EMAIL_FROM") catch "noreply@quantumencoding.io");

    const out_body = std.json.Stringify.valueAlloc(allocator, .{
        .from = from,
        .to = req.to,
        .subject = req.subject,
        .html = req.html,
        .text = req.text,
    }, .{ .emit_null_optional_fields = false }) catch return err(.internal_server_error);
    defer allocator.free(out_body);

    var client = hs.HttpClient.init(allocator) catch return err(.internal_server_error);
    defer client.deinit();
    const auth_header = std.fmt.allocPrint(allocator, "Bearer {s}", .{key}) catch return err(.internal_server_error);
    defer allocator.free(auth_header);
    const headers = [_]http.Header{
        .{ .name = "Content-Type", .value = "application/json" },
        .{ .name = "Authorization", .value = auth_header },
    };

    var resp = client.post("https://api.resend.com/emails", &headers, out_body) catch return err(.bad_gateway);
    defer resp.deinit();
    if (@intFromEnum(resp.status) >= 300) return err(.bad_gateway);

    const out = allocator.dupe(u8, resp.body) catch return err(.internal_server_error);
    return .{ .status = .ok, .body = out };
}

fn err(status: http.Status) Response {
    return switch (status) {
        .bad_request => .{ .status = .bad_request, .body = "{\"error\":\"invalid_request\",\"message\":\"to, subject, and html|text are required\"}" },
        .service_unavailable => .{ .status = .service_unavailable, .body = "{\"error\":\"unavailable\",\"message\":\"email not configured (RESEND_API_KEY unset)\"}" },
        .bad_gateway => .{ .status = .bad_gateway, .body = "{\"error\":\"provider_error\",\"message\":\"email send failed\"}" },
        else => .{ .status = .internal_server_error, .body = "{\"error\":\"internal\",\"message\":\"email send failed\"}" },
    };
}
