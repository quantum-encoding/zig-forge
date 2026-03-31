//! zcurl - Command-line HTTP client
//!
//! A curl-like HTTP client built on Zig's std.http.
//! Supports GET, POST, PUT, DELETE, HEAD with TLS.

const std = @import("std");
const http = std.http;
const posix = std.posix;
const libc = std.c;

const VERSION = "1.0.0";

const Config = struct {
    method: http.Method = .GET,
    url: ?[]const u8 = null,
    headers: [32]http.Header = undefined,
    header_count: usize = 0,
    data: ?[]const u8 = null,
    output_file: ?[]const u8 = null,
    include_headers: bool = false,
    verbose: bool = false,
    silent: bool = false,
    follow_redirects: bool = false,
    max_redirects: u8 = 10,
    head_only: bool = false,
    user_agent: []const u8 = "zcurl/" ++ VERSION,
};

fn writeStdout(data: []const u8) void {
    _ = libc.write(libc.STDOUT_FILENO, data.ptr, data.len);
}

fn writeStderr(data: []const u8) void {
    _ = libc.write(libc.STDERR_FILENO, data.ptr, data.len);
}

fn printUsage() void {
    const usage =
        \\Usage: zcurl [OPTIONS] URL
        \\Transfer data from or to a server using HTTP/HTTPS.
        \\
        \\Options:
        \\  -X, --request METHOD  HTTP method (GET, POST, PUT, DELETE, HEAD, PATCH)
        \\  -H, --header HEADER   Add header (format: "Name: Value")
        \\  -d, --data DATA       HTTP POST/PUT data
        \\  -o, --output FILE     Write output to file instead of stdout
        \\  -i, --include         Include response headers in output
        \\  -I, --head            Fetch headers only (HEAD request)
        \\  -L, --location        Follow redirects
        \\  -s, --silent          Silent mode (no progress/errors)
        \\  -v, --verbose         Verbose mode (show request details)
        \\  -A, --user-agent STR  Set User-Agent header
        \\      --help            Display this help
        \\      --version         Show version
        \\
        \\Examples:
        \\  zcurl https://example.com
        \\  zcurl -X POST -d '{"key":"value"}' -H "Content-Type: application/json" URL
        \\  zcurl -o output.html https://example.com
        \\  zcurl -I https://example.com
        \\
    ;
    writeStderr(usage);
}

fn printVersion() void {
    writeStderr("zcurl " ++ VERSION ++ " - Zig HTTP client\n");
}

fn parseArgs(args: [][*:0]u8, cfg: *Config) bool {
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = std.mem.span(args[i]);

        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printUsage();
            return false;
        } else if (std.mem.eql(u8, arg, "--version")) {
            printVersion();
            return false;
        } else if (std.mem.eql(u8, arg, "-X") or std.mem.eql(u8, arg, "--request")) {
            i += 1;
            if (i >= args.len) {
                writeStderr("zcurl: -X requires a method\n");
                return false;
            }
            const method_str = std.mem.span(args[i]);
            if (std.mem.eql(u8, method_str, "GET")) {
                cfg.method = .GET;
            } else if (std.mem.eql(u8, method_str, "POST")) {
                cfg.method = .POST;
            } else if (std.mem.eql(u8, method_str, "PUT")) {
                cfg.method = .PUT;
            } else if (std.mem.eql(u8, method_str, "DELETE")) {
                cfg.method = .DELETE;
            } else if (std.mem.eql(u8, method_str, "HEAD")) {
                cfg.method = .HEAD;
                cfg.head_only = true;
            } else if (std.mem.eql(u8, method_str, "PATCH")) {
                cfg.method = .PATCH;
            } else {
                writeStderr("zcurl: unknown method: ");
                writeStderr(method_str);
                writeStderr("\n");
                return false;
            }
        } else if (std.mem.eql(u8, arg, "-H") or std.mem.eql(u8, arg, "--header")) {
            i += 1;
            if (i >= args.len) {
                writeStderr("zcurl: -H requires a header\n");
                return false;
            }
            if (cfg.header_count < cfg.headers.len) {
                const header_str = std.mem.span(args[i]);
                // Parse "Name: Value"
                if (std.mem.indexOf(u8, header_str, ": ")) |sep| {
                    cfg.headers[cfg.header_count] = .{
                        .name = header_str[0..sep],
                        .value = header_str[sep + 2 ..],
                    };
                    cfg.header_count += 1;
                }
            }
        } else if (std.mem.eql(u8, arg, "-d") or std.mem.eql(u8, arg, "--data")) {
            i += 1;
            if (i >= args.len) {
                writeStderr("zcurl: -d requires data\n");
                return false;
            }
            cfg.data = std.mem.span(args[i]);
            if (cfg.method == .GET) cfg.method = .POST;
        } else if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
            i += 1;
            if (i >= args.len) {
                writeStderr("zcurl: -o requires a filename\n");
                return false;
            }
            cfg.output_file = std.mem.span(args[i]);
        } else if (std.mem.eql(u8, arg, "-i") or std.mem.eql(u8, arg, "--include")) {
            cfg.include_headers = true;
        } else if (std.mem.eql(u8, arg, "-I") or std.mem.eql(u8, arg, "--head")) {
            cfg.method = .HEAD;
            cfg.head_only = true;
            cfg.include_headers = true;
        } else if (std.mem.eql(u8, arg, "-L") or std.mem.eql(u8, arg, "--location")) {
            cfg.follow_redirects = true;
        } else if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--silent")) {
            cfg.silent = true;
        } else if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--verbose")) {
            cfg.verbose = true;
        } else if (std.mem.eql(u8, arg, "-A") or std.mem.eql(u8, arg, "--user-agent")) {
            i += 1;
            if (i >= args.len) {
                writeStderr("zcurl: -A requires a user-agent string\n");
                return false;
            }
            cfg.user_agent = std.mem.span(args[i]);
        } else if (arg.len > 0 and arg[0] != '-') {
            cfg.url = arg;
        }
    }

    if (cfg.url == null) {
        writeStderr("zcurl: no URL specified\n");
        writeStderr("Try 'zcurl --help' for more information.\n");
        return false;
    }

    return true;
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    // Collect args
    var args_list: std.ArrayListUnmanaged([*:0]u8) = .empty;
    defer args_list.deinit(allocator);
    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    while (args_iter.next()) |arg| {
        // Convert to [*:0]u8 by casting the const away (safe since we don't modify)
        try args_list.append(allocator, @constCast(arg.ptr));
    }

    var cfg = Config{};

    if (!parseArgs(args_list.items[1..], &cfg)) {
        return;
    }

    // Create HTTP client using init.io
    var client = http.Client{
        .allocator = allocator,
        .io = init.io,
    };
    defer client.deinit();

    // Add User-Agent header
    var all_headers: [33]http.Header = undefined;
    all_headers[0] = .{ .name = "User-Agent", .value = cfg.user_agent };
    for (cfg.headers[0..cfg.header_count], 0..) |h, j| {
        all_headers[j + 1] = h;
    }
    const headers = all_headers[0 .. cfg.header_count + 1];

    // Parse URL
    const uri = std.Uri.parse(cfg.url.?) catch {
        writeStderr("zcurl: invalid URL\n");
        return;
    };

    if (cfg.verbose) {
        writeStderr("> ");
        writeStderr(@tagName(cfg.method));
        writeStderr(" ");
        writeStderr(cfg.url.?);
        writeStderr("\n");
        for (headers) |h| {
            writeStderr("> ");
            writeStderr(h.name);
            writeStderr(": ");
            writeStderr(h.value);
            writeStderr("\n");
        }
        writeStderr(">\n");
    }

    // Make request
    var req = client.request(cfg.method, uri, .{
        .extra_headers = headers,
    }) catch |err| {
        if (!cfg.silent) {
            writeStderr("zcurl: connection failed: ");
            writeStderr(@errorName(err));
            writeStderr("\n");
        }
        std.process.exit(1);
    };
    defer req.deinit();

    // Send body if present
    if (cfg.data) |data| {
        req.transfer_encoding = .{ .content_length = data.len };
        var body_writer = req.sendBodyUnflushed(&.{}) catch |err| {
            if (!cfg.silent) {
                writeStderr("zcurl: send failed: ");
                writeStderr(@errorName(err));
                writeStderr("\n");
            }
            std.process.exit(1);
        };
        body_writer.writer.writeAll(data) catch {};
        body_writer.end() catch {};
        if (req.connection) |conn| conn.flush() catch {};
    } else {
        req.sendBodiless() catch |err| {
            if (!cfg.silent) {
                writeStderr("zcurl: send failed: ");
                writeStderr(@errorName(err));
                writeStderr("\n");
            }
            std.process.exit(1);
        };
    }

    // Receive response
    var response = req.receiveHead(&.{}) catch |err| {
        if (!cfg.silent) {
            writeStderr("zcurl: receive failed: ");
            writeStderr(@errorName(err));
            writeStderr("\n");
        }
        std.process.exit(1);
    };

    // Print status in verbose mode
    if (cfg.verbose or cfg.include_headers) {
        var status_buf: [64]u8 = undefined;
        const status_line = std.fmt.bufPrint(&status_buf, "HTTP/1.1 {d} {s}\n", .{
            @intFromEnum(response.head.status),
            @tagName(response.head.status),
        }) catch "HTTP/1.1 ???\n";
        writeStdout(status_line);
    }

    // Handle HEAD request (no body)
    if (cfg.head_only) {
        return;
    }

    // Read body (with decompression support for gzip/deflate)
    var transfer_buffer: [8192]u8 = undefined;
    var decompress: http.Decompress = undefined;
    var decompress_buffer: [std.compress.flate.max_window_len]u8 = undefined;
    const response_reader = response.readerDecompressing(&transfer_buffer, &decompress, &decompress_buffer);

    const body = response_reader.allocRemaining(allocator, std.Io.Limit.limited(50 * 1024 * 1024)) catch |err| {
        if (!cfg.silent) {
            writeStderr("zcurl: read failed: ");
            writeStderr(@errorName(err));
            writeStderr("\n");
        }
        std.process.exit(1);
    };
    defer allocator.free(body);

    // Write output
    if (cfg.output_file) |path| {
        var path_buf: [4096]u8 = undefined;
        const path_z = std.fmt.bufPrintZ(&path_buf, "{s}", .{path}) catch {
            writeStderr("zcurl: path too long\n");
            return;
        };
        const fd = libc.open(path_z.ptr, .{
            .ACCMODE = .WRONLY,
            .CREAT = true,
            .TRUNC = true,
        }, @as(libc.mode_t, 0o644));
        if (fd < 0) {
            writeStderr("zcurl: cannot create output file\n");
            return;
        }
        defer _ = libc.close(fd);
        _ = libc.write(fd, body.ptr, body.len);
    } else {
        writeStdout(body);
        // Add newline if body doesn't end with one
        if (body.len > 0 and body[body.len - 1] != '\n') {
            writeStdout("\n");
        }
    }
}
