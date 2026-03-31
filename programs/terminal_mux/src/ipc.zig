//! IPC (Inter-Process Communication)
//!
//! Unix domain socket protocol for client-server communication.
//! Allows clients to attach to, detach from, and control sessions.

const std = @import("std");
const posix = std.posix;
const c = std.c;

/// Message types for the protocol
pub const MessageType = enum(u8) {
    // Client → Server
    attach = 0x01,
    detach = 0x02,
    new_session = 0x03,
    new_window = 0x04,
    split_pane = 0x05,
    kill_pane = 0x06,
    resize = 0x07,
    input = 0x08,
    list_sessions = 0x09,
    select_window = 0x0A,
    select_pane = 0x0B,
    rename_session = 0x0C,
    rename_window = 0x0D,
    kill_session = 0x0E,
    kill_window = 0x0F,

    // Server → Client
    output = 0x80,
    session_info = 0x81,
    error_msg = 0x82,
    sync_state = 0x83,
    pong = 0x84,

    // Bidirectional
    ping = 0x90,
};

/// Message header (fixed size)
pub const MessageHeader = extern struct {
    magic: [4]u8 = .{ 'T', 'M', 'U', 'X' },
    version: u8 = 1,
    msg_type: MessageType,
    flags: u16 = 0,
    payload_len: u32,

    pub const SIZE = 12;
};

/// Attach request
pub const AttachRequest = struct {
    session_name: []const u8,
    rows: u16,
    cols: u16,
};

/// Resize notification
pub const ResizeMessage = struct {
    rows: u16,
    cols: u16,
};

/// Input data
pub const InputMessage = struct {
    data: []const u8,
};

/// Split request
pub const SplitMessage = struct {
    horizontal: bool,
};

/// Select window request
pub const SelectWindowMessage = struct {
    index: u8,
};

/// Session info response
pub const SessionInfo = struct {
    name: []const u8,
    window_count: u8,
    active_window: u8,
};

/// Error response
pub const ErrorMessage = struct {
    code: ErrorCode,
    message: []const u8,

    pub const ErrorCode = enum(u8) {
        unknown = 0,
        session_not_found = 1,
        session_exists = 2,
        invalid_message = 3,
        internal_error = 4,
    };
};

/// IPC Server
pub const Server = struct {
    allocator: std.mem.Allocator,
    socket_path: []const u8,
    listen_fd: posix.fd_t,
    clients: std.ArrayListUnmanaged(Client),

    pub const Client = struct {
        fd: posix.fd_t,
        session_name: ?[]const u8,
        rows: u16,
        cols: u16,
    };

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, socket_path: []const u8) !Self {
        // Create Unix domain socket
        const fd = c.socket(c.AF.UNIX, c.SOCK.STREAM, 0);
        if (fd < 0) return error.SocketCreateFailed;
        errdefer _ = std.c.close(fd);

        // Remove existing socket file
        unlinkPath(socket_path);

        // Bind to path
        var addr: c.sockaddr.un = .{
            .family = c.AF.UNIX,
            .path = undefined,
        };
        @memset(&addr.path, 0);
        const path_len = @min(socket_path.len, addr.path.len - 1);
        @memcpy(addr.path[0..path_len], socket_path[0..path_len]);

        if (c.bind(fd, @ptrCast(&addr), @sizeOf(c.sockaddr.un)) < 0) return error.BindFailed;

        // Listen
        if (c.listen(fd, 16) < 0) return error.ListenFailed;

        return Self{
            .allocator = allocator,
            .socket_path = socket_path,
            .listen_fd = fd,
            .clients = .empty,
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.clients.items) |client| {
            _ = std.c.close(client.fd);
        }
        self.clients.deinit(self.allocator);

        _ = std.c.close(self.listen_fd);
        unlinkPath(self.socket_path);
    }

    /// Accept a new client connection
    pub fn accept(self: *Self) !?Client {
        const client_fd = posix.accept(self.listen_fd, null, null, posix.SOCK.NONBLOCK) catch |err| {
            if (err == error.WouldBlock) return null;
            return err;
        };

        const client = Client{
            .fd = client_fd,
            .session_name = null,
            .rows = 24,
            .cols = 80,
        };

        try self.clients.append(self.allocator, client);
        return client;
    }

    /// Remove a client
    pub fn removeClient(self: *Self, fd: posix.fd_t) void {
        for (self.clients.items, 0..) |client, i| {
            if (client.fd == fd) {
                _ = std.c.close(client.fd);
                _ = self.clients.orderedRemove(i);
                return;
            }
        }
    }

    /// Send a message to a client
    pub fn send(self: *Self, client_fd: posix.fd_t, msg_type: MessageType, payload: []const u8) !void {
        _ = self;
        const header = MessageHeader{
            .msg_type = msg_type,
            .payload_len = @intCast(payload.len),
        };

        const header_bytes = std.mem.asBytes(&header);
        _ = try posix.write(client_fd, header_bytes);

        if (payload.len > 0) {
            _ = try posix.write(client_fd, payload);
        }
    }

    /// Broadcast to all attached clients
    pub fn broadcast(self: *Self, msg_type: MessageType, payload: []const u8) void {
        for (self.clients.items) |client| {
            self.send(client.fd, msg_type, payload) catch {};
        }
    }

    /// Get file descriptor for polling
    pub fn getFd(self: *const Self) posix.fd_t {
        return self.listen_fd;
    }
};

/// IPC Client
pub const IpcClient = struct {
    allocator: std.mem.Allocator,
    fd: posix.fd_t,
    recv_buffer: [65536]u8,
    recv_len: usize,

    const Self = @This();

    pub fn connect(allocator: std.mem.Allocator, socket_path: []const u8) !Self {
        const fd = c.socket(c.AF.UNIX, c.SOCK.STREAM, 0);
        if (fd < 0) return error.SocketCreateFailed;
        errdefer _ = std.c.close(fd);

        var addr: c.sockaddr.un = .{
            .family = c.AF.UNIX,
            .path = undefined,
        };
        @memset(&addr.path, 0);
        const path_len = @min(socket_path.len, addr.path.len - 1);
        @memcpy(addr.path[0..path_len], socket_path[0..path_len]);

        if (c.connect(fd, @ptrCast(&addr), @sizeOf(c.sockaddr.un)) < 0) return error.ConnectFailed;

        return Self{
            .allocator = allocator,
            .fd = fd,
            .recv_buffer = undefined,
            .recv_len = 0,
        };
    }

    pub fn deinit(self: *Self) void {
        _ = std.c.close(self.fd);
    }

    /// Send a message
    pub fn send(self: *Self, msg_type: MessageType, payload: []const u8) !void {
        const header = MessageHeader{
            .msg_type = msg_type,
            .payload_len = @intCast(payload.len),
        };

        const header_bytes = std.mem.asBytes(&header);
        _ = try posix.write(self.fd, header_bytes);

        if (payload.len > 0) {
            _ = try posix.write(self.fd, payload);
        }
    }

    /// Receive a message (blocks until complete message received)
    pub fn receive(self: *Self) !?ReceivedMessage {
        // Read header
        var header: MessageHeader = undefined;
        const header_bytes = std.mem.asBytes(&header);

        var total_read: usize = 0;
        while (total_read < MessageHeader.SIZE) {
            const n = try posix.read(self.fd, header_bytes[total_read..]);
            if (n == 0) return null; // Connection closed
            total_read += n;
        }

        // Validate header
        if (!std.mem.eql(u8, &header.magic, "TMUX")) {
            return error.InvalidHeader;
        }

        // Read payload
        if (header.payload_len > 0) {
            if (header.payload_len > self.recv_buffer.len) {
                return error.PayloadTooLarge;
            }

            var payload_read: usize = 0;
            while (payload_read < header.payload_len) {
                const n = try posix.read(self.fd, self.recv_buffer[payload_read..header.payload_len]);
                if (n == 0) return null;
                payload_read += n;
            }
            self.recv_len = header.payload_len;
        } else {
            self.recv_len = 0;
        }

        return ReceivedMessage{
            .msg_type = header.msg_type,
            .payload = self.recv_buffer[0..self.recv_len],
        };
    }

    /// Get file descriptor for polling
    pub fn getFd(self: *const Self) posix.fd_t {
        return self.fd;
    }
};

pub const ReceivedMessage = struct {
    msg_type: MessageType,
    payload: []const u8,
};

/// Encode attach request
pub fn encodeAttachRequest(allocator: std.mem.Allocator, req: AttachRequest) ![]u8 {
    var buf = std.ArrayListUnmanaged(u8).empty;
    errdefer buf.deinit(allocator);

    // Session name length + name
    const name_len: u16 = @intCast(req.session_name.len);
    try buf.appendSlice(allocator, std.mem.asBytes(&name_len));
    try buf.appendSlice(allocator, req.session_name);

    // Rows and cols
    try buf.appendSlice(allocator, std.mem.asBytes(&req.rows));
    try buf.appendSlice(allocator, std.mem.asBytes(&req.cols));

    return buf.toOwnedSlice(allocator);
}

/// Decode attach request
pub fn decodeAttachRequest(data: []const u8) !AttachRequest {
    if (data.len < 6) return error.TooShort;

    const name_len = std.mem.readInt(u16, data[0..2], .little);
    if (data.len < 6 + name_len) return error.TooShort;

    const rows_offset = 2 + name_len;
    const cols_offset = 4 + name_len;

    return AttachRequest{
        .session_name = data[2 .. 2 + name_len],
        .rows = std.mem.readInt(u16, data[rows_offset..][0..2], .little),
        .cols = std.mem.readInt(u16, data[cols_offset..][0..2], .little),
    };
}

/// Get default socket path
pub fn getDefaultSocketPath(allocator: std.mem.Allocator) ![]u8 {
    // Try XDG_RUNTIME_DIR first
    if (std.c.getenv("XDG_RUNTIME_DIR")) |runtime_dir_ptr| {
        const runtime_dir = std.mem.sliceTo(runtime_dir_ptr, 0);
        return std.fmt.allocPrint(allocator, "{s}/terminal_mux.sock", .{runtime_dir});
    }

    // Fall back to /tmp with UID
    const uid = std.os.linux.getuid();
    return std.fmt.allocPrint(allocator, "/tmp/terminal_mux-{d}/default.sock", .{uid});
}

/// Ensure socket directory exists
pub fn ensureSocketDir(path: []const u8) !void {
    // Extract directory from path
    if (std.mem.lastIndexOf(u8, path, "/")) |idx| {
        const dir = path[0..idx];
        makeDirPath(dir) catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };
    }
}

/// Helper: unlink a file path using std.c.unlink
fn unlinkPath(path: []const u8) void {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (path.len >= path_buf.len) return;
    @memcpy(path_buf[0..path.len], path);
    path_buf[path.len] = 0;
    _ = std.c.unlink(@ptrCast(&path_buf));
}

/// Helper: create a directory using std.c.mkdir
fn makeDirPath(path: []const u8) !void {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (path.len >= path_buf.len) return error.NameTooLong;
    @memcpy(path_buf[0..path.len], path);
    path_buf[path.len] = 0;
    const result = std.c.mkdir(@ptrCast(&path_buf), 0o755);
    if (result < 0) {
        const err = std.posix.errno(result);
        if (err == .EXIST) return error.PathAlreadyExists;
        return error.MkdirFailed;
    }
}

// =============================================================================
// Tests
// =============================================================================

test "message header size" {
    try std.testing.expectEqual(@as(usize, 12), @sizeOf(MessageHeader));
}

test "attach request encode decode" {
    const allocator = std.testing.allocator;

    const req = AttachRequest{
        .session_name = "test",
        .rows = 24,
        .cols = 80,
    };

    const encoded = try encodeAttachRequest(allocator, req);
    defer allocator.free(encoded);

    const decoded = try decodeAttachRequest(encoded);

    try std.testing.expectEqualStrings("test", decoded.session_name);
    try std.testing.expectEqual(@as(u16, 24), decoded.rows);
    try std.testing.expectEqual(@as(u16, 80), decoded.cols);
}
