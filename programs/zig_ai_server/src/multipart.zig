// multipart/form-data builder
//
// The in-tree HTTP client (`http_sentinel`) POSTs a raw byte body with a
// caller-supplied Content-Type, so multipart uploads need no client change:
// build the body here, then pass `Content-Type: multipart/form-data;
// boundary=<boundary()>` in the headers slice.
//
// Used by the file-upload AI endpoints (audio/stt, images/edit) that OpenAI
// only accepts as multipart form posts.

const std = @import("std");

pub const Builder = struct {
    buf: std.ArrayListUnmanaged(u8) = .empty,
    allocator: std.mem.Allocator,
    boundary_buf: [48]u8 = undefined,
    boundary_len: usize = 0,
    finished: bool = false,

    /// Initialise with a random boundary drawn from the injected CSPRNG
    /// (`io.random`, same source keys.zig uses). A random boundary avoids any
    /// chance of colliding with bytes inside an uploaded binary file.
    pub fn init(allocator: std.mem.Allocator, io: std.Io) Builder {
        var b: Builder = .{ .allocator = allocator };
        const prefix = "----qaiboundary";
        @memcpy(b.boundary_buf[0..prefix.len], prefix);
        var rand: [16]u8 = undefined;
        io.random(&rand);
        const hex = "0123456789abcdef";
        var i: usize = 0;
        while (i < rand.len) : (i += 1) {
            b.boundary_buf[prefix.len + i * 2] = hex[rand[i] >> 4];
            b.boundary_buf[prefix.len + i * 2 + 1] = hex[rand[i] & 0x0F];
        }
        b.boundary_len = prefix.len + rand.len * 2;
        return b;
    }

    pub fn deinit(self: *Builder) void {
        self.buf.deinit(self.allocator);
    }

    pub fn boundary(self: *const Builder) []const u8 {
        return self.boundary_buf[0..self.boundary_len];
    }

    /// `Content-Type` header value for this body, e.g.
    /// "multipart/form-data; boundary=----qaiboundary...". Caller owns it.
    pub fn contentType(self: *const Builder, allocator: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(allocator, "multipart/form-data; boundary={s}", .{self.boundary()});
    }

    /// Add a simple text field. `name` is a fixed server-chosen key (not
    /// caller-controlled); values are written verbatim.
    pub fn addField(self: *Builder, name: []const u8, value: []const u8) !void {
        try self.writeBoundary();
        try self.buf.appendSlice(self.allocator, "Content-Disposition: form-data; name=\"");
        try self.buf.appendSlice(self.allocator, name);
        try self.buf.appendSlice(self.allocator, "\"\r\n\r\n");
        try self.buf.appendSlice(self.allocator, value);
        try self.buf.appendSlice(self.allocator, "\r\n");
    }

    /// Add a file part. `filename` is sanitised (quotes / CR / LF stripped) so
    /// a hostile filename can't break out of the Content-Disposition header.
    pub fn addFile(self: *Builder, name: []const u8, filename: []const u8, content_type: []const u8, data: []const u8) !void {
        try self.writeBoundary();
        try self.buf.appendSlice(self.allocator, "Content-Disposition: form-data; name=\"");
        try self.buf.appendSlice(self.allocator, name);
        try self.buf.appendSlice(self.allocator, "\"; filename=\"");
        for (filename) |c| {
            switch (c) {
                '"', '\r', '\n', '\\' => try self.buf.append(self.allocator, '_'),
                else => try self.buf.append(self.allocator, c),
            }
        }
        try self.buf.appendSlice(self.allocator, "\"\r\nContent-Type: ");
        try self.buf.appendSlice(self.allocator, content_type);
        try self.buf.appendSlice(self.allocator, "\r\n\r\n");
        try self.buf.appendSlice(self.allocator, data);
        try self.buf.appendSlice(self.allocator, "\r\n");
    }

    fn writeBoundary(self: *Builder) !void {
        try self.buf.appendSlice(self.allocator, "--");
        try self.buf.appendSlice(self.allocator, self.boundary());
        try self.buf.appendSlice(self.allocator, "\r\n");
    }

    /// Append the closing boundary and hand ownership of the body to the
    /// caller.
    pub fn finish(self: *Builder) ![]u8 {
        try self.buf.appendSlice(self.allocator, "--");
        try self.buf.appendSlice(self.allocator, self.boundary());
        try self.buf.appendSlice(self.allocator, "--\r\n");
        self.finished = true;
        return self.buf.toOwnedSlice(self.allocator);
    }
};
