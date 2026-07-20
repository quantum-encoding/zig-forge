//! zcurl - Command-line HTTP client
//!
//! A curl-like HTTP client built on Zig's std.http.
//! Supports GET, POST, PUT, DELETE, HEAD with TLS.

const std = @import("std");
const http = std.http;
const posix = std.posix;
const libc = std.c;

const VERSION = "1.0.0";

// GNU curl exit-code scheme (subset we implement). See `man curl` EXIT CODES.
const EXIT_OK: u8 = 0;
const EXIT_USAGE: u8 = 2; // failed to init / bad usage
const EXIT_URL_MALFORMED: u8 = 3; // URL malformed
const EXIT_COULDNT_CONNECT: u8 = 7; // failed to connect / transfer

const Config = struct {
    method: http.Method = .GET,
    headers: [32]http.Header = undefined,
    header_count: usize = 0,
    data: ?[]const u8 = null,
    output_file: ?[]const u8 = null,
    include_headers: bool = false,
    verbose: bool = false,
    silent: bool = false,
    follow_redirects: bool = false,
    max_redirects: u16 = 50,
    head_only: bool = false,
    user_agent: []const u8 = "zcurl/" ++ VERSION,
};

const ParseResult = enum { proceed, help, version, usage_error };

/// Write the full slice, looping on short writes and retrying on EINTR.
/// Best-effort: errors other than EINTR terminate the loop (e.g. EPIPE).
fn writeAllFd(fd: c_int, data: []const u8) void {
    var written: usize = 0;
    while (written < data.len) {
        const n = libc.write(fd, data.ptr + written, data.len - written);
        if (n < 0) {
            if (libc._errno().* == @intFromEnum(libc.E.INTR)) continue;
            return; // real error (EPIPE, etc.) — nothing sane to do here
        }
        if (n == 0) return;
        written += @intCast(n);
    }
}

fn writeStdout(data: []const u8) void {
    writeAllFd(libc.STDOUT_FILENO, data);
}

fn writeStderr(data: []const u8) void {
    writeAllFd(libc.STDERR_FILENO, data);
}

fn printUsage() void {
    const usage =
        \\Usage: zcurl [OPTIONS] URL
        \\Transfer data from or to a server using HTTP/HTTPS.
        \\
        \\Options:
        \\  -X, --request METHOD  HTTP method (GET, POST, PUT, DELETE, HEAD, PATCH)
        \\  -H, --header HEADER   Add header (format: "Name: Value" or "Name:Value")
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
    writeStdout(usage);
}

fn printVersion() void {
    writeStdout("zcurl " ++ VERSION ++ " - Zig HTTP client\n");
}

/// Parse a single -H argument. curl accepts both "Name: Value" and "Name:Value";
/// the value's optional leading whitespace is trimmed. Returns false on a header
/// with no ':' separator (invalid) or when the fixed header array is full.
fn addHeader(cfg: *Config, header_str: []const u8) bool {
    const sep = std.mem.indexOfScalar(u8, header_str, ':') orelse return false;
    if (cfg.header_count >= cfg.headers.len) return false;
    const value = std.mem.trimStart(u8, header_str[sep + 1 ..], " \t");
    cfg.headers[cfg.header_count] = .{
        .name = header_str[0..sep],
        .value = value,
    };
    cfg.header_count += 1;
    return true;
}

fn parseArgs(
    allocator: std.mem.Allocator,
    args: [][*:0]u8,
    cfg: *Config,
    urls: *std.ArrayListUnmanaged([]const u8),
) ParseResult {
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = std.mem.span(args[i]);

        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            return .help;
        } else if (std.mem.eql(u8, arg, "--version")) {
            return .version;
        } else if (std.mem.eql(u8, arg, "-X") or std.mem.eql(u8, arg, "--request")) {
            i += 1;
            if (i >= args.len) {
                writeStderr("zcurl: -X requires a method\n");
                return .usage_error;
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
                return .usage_error;
            }
        } else if (std.mem.eql(u8, arg, "-H") or std.mem.eql(u8, arg, "--header")) {
            i += 1;
            if (i >= args.len) {
                writeStderr("zcurl: -H requires a header\n");
                return .usage_error;
            }
            if (!addHeader(cfg, std.mem.span(args[i]))) {
                writeStderr("zcurl: invalid or too many headers\n");
                return .usage_error;
            }
        } else if (std.mem.eql(u8, arg, "-d") or std.mem.eql(u8, arg, "--data")) {
            i += 1;
            if (i >= args.len) {
                writeStderr("zcurl: -d requires data\n");
                return .usage_error;
            }
            cfg.data = std.mem.span(args[i]);
            if (cfg.method == .GET) cfg.method = .POST;
        } else if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
            i += 1;
            if (i >= args.len) {
                writeStderr("zcurl: -o requires a filename\n");
                return .usage_error;
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
                return .usage_error;
            }
            cfg.user_agent = std.mem.span(args[i]);
        } else if (arg.len > 0 and arg[0] != '-') {
            // GNU curl fetches every URL argument in sequence.
            urls.append(allocator, arg) catch return .usage_error;
        } else {
            writeStderr("zcurl: unknown option: ");
            writeStderr(arg);
            writeStderr("\n");
            return .usage_error;
        }
    }

    if (urls.items.len == 0) {
        writeStderr("zcurl: no URL specified\n");
        writeStderr("Try 'zcurl --help' for more information.\n");
        return .usage_error;
    }

    return .proceed;
}

/// Print the status line and headers of a response (for -i / -I / -v).
/// Uses the server's actual HTTP version and reason phrase.
fn writeHead(response: *http.Client.Response) void {
    var buf: [256]u8 = undefined;
    const reason = if (response.head.reason.len != 0)
        response.head.reason
    else
        (response.head.status.phrase() orelse "");
    const line = std.fmt.bufPrint(&buf, "{s} {d} {s}\r\n", .{
        @tagName(response.head.version),
        @intFromEnum(response.head.status),
        reason,
    }) catch "HTTP/1.1 ???\r\n";
    writeStdout(line);

    var it = response.head.iterateHeaders();
    while (it.next()) |h| {
        writeStdout(h.name);
        writeStdout(": ");
        writeStdout(h.value);
        writeStdout("\r\n");
    }
    writeStdout("\r\n");
}

/// Fetch a single URL. Returns the process exit code for this transfer.
fn fetchOne(
    allocator: std.mem.Allocator,
    io: std.Io,
    cfg: *const Config,
    url: []const u8,
) u8 {
    var client = http.Client{
        .allocator = allocator,
        .io = io,
    };
    defer client.deinit();

    const uri = std.Uri.parse(url) catch {
        if (!cfg.silent) writeStderr("zcurl: invalid URL\n");
        return EXIT_URL_MALFORMED;
    };

    // If following redirects, allow up to max_redirects; otherwise leave them
    // unhandled (curl without -L does not follow — it emits the 3xx response).
    const redirect_behavior: http.Client.Request.RedirectBehavior = if (cfg.follow_redirects)
        http.Client.Request.RedirectBehavior.init(cfg.max_redirects)
    else
        .unhandled;

    if (cfg.verbose) {
        writeStderr("> ");
        writeStderr(@tagName(cfg.method));
        writeStderr(" ");
        writeStderr(url);
        writeStderr("\n");
    }

    // The User-Agent goes through the standard, overridable header slot so the
    // client's built-in default is replaced (not appended to).
    var req = client.request(cfg.method, uri, .{
        .redirect_behavior = redirect_behavior,
        .extra_headers = cfg.headers[0..cfg.header_count],
        .headers = .{ .user_agent = .{ .override = cfg.user_agent } },
    }) catch |err| {
        if (!cfg.silent) {
            writeStderr("zcurl: connection failed: ");
            writeStderr(@errorName(err));
            writeStderr("\n");
        }
        return EXIT_COULDNT_CONNECT;
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
            return EXIT_COULDNT_CONNECT;
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
            return EXIT_COULDNT_CONNECT;
        };
    }

    // Receive response. A real redirect buffer must be supplied for -L to work.
    var redirect_buffer: [16 * 1024]u8 = undefined;
    var response = req.receiveHead(&redirect_buffer) catch |err| {
        if (!cfg.silent) {
            writeStderr("zcurl: receive failed: ");
            writeStderr(@errorName(err));
            writeStderr("\n");
        }
        return EXIT_COULDNT_CONNECT;
    };

    if (cfg.verbose or cfg.include_headers) {
        writeHead(&response);
    }

    // Handle HEAD request (no body)
    if (cfg.head_only) {
        return EXIT_OK;
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
        return EXIT_COULDNT_CONNECT;
    };
    defer allocator.free(body);

    // Write output — verbatim, no injected trailing newline (GNU curl does not add one).
    if (cfg.output_file) |path| {
        var path_buf: [4096]u8 = undefined;
        const path_z = std.fmt.bufPrintZ(&path_buf, "{s}", .{path}) catch {
            if (!cfg.silent) writeStderr("zcurl: path too long\n");
            return EXIT_COULDNT_CONNECT;
        };
        const fd = libc.open(path_z.ptr, .{
            .ACCMODE = .WRONLY,
            .CREAT = true,
            .TRUNC = true,
        }, @as(libc.mode_t, 0o644));
        if (fd < 0) {
            if (!cfg.silent) {
                const e: libc.E = @enumFromInt(libc._errno().*);
                writeStderr("zcurl: cannot create output file: ");
                writeStderr(@tagName(e));
                writeStderr("\n");
            }
            return EXIT_COULDNT_CONNECT;
        }
        defer _ = libc.close(fd);
        // Loop until every byte is flushed; surface a real error on failure.
        var written: usize = 0;
        while (written < body.len) {
            const n = libc.write(fd, body.ptr + written, body.len - written);
            if (n < 0) {
                if (libc._errno().* == @intFromEnum(libc.E.INTR)) continue;
                if (!cfg.silent) {
                    const e: libc.E = @enumFromInt(libc._errno().*);
                    writeStderr("zcurl: write failed: ");
                    writeStderr(@tagName(e));
                    writeStderr("\n");
                }
                return EXIT_COULDNT_CONNECT;
            }
            if (n == 0) break;
            written += @intCast(n);
        }
    } else {
        writeStdout(body);
    }

    return EXIT_OK;
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    // Collect args
    var args_list: std.ArrayListUnmanaged([*:0]u8) = .empty;
    defer args_list.deinit(allocator);
    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    while (args_iter.next()) |arg| {
        try args_list.append(allocator, @constCast(arg.ptr));
    }

    var cfg = Config{};
    var urls: std.ArrayListUnmanaged([]const u8) = .empty;
    defer urls.deinit(allocator);

    switch (parseArgs(allocator, args_list.items[1..], &cfg, &urls)) {
        .proceed => {},
        .help => {
            printUsage();
            std.process.exit(EXIT_OK);
        },
        .version => {
            printVersion();
            std.process.exit(EXIT_OK);
        },
        .usage_error => std.process.exit(EXIT_USAGE),
    }

    // Fetch every URL in sequence; the process exit code is the last failure
    // (curl continues past a failed transfer but reports a non-zero status).
    var exit_code: u8 = EXIT_OK;
    for (urls.items) |url| {
        const code = fetchOne(allocator, init.io, &cfg, url);
        if (code != EXIT_OK) exit_code = code;
    }
    std.process.exit(exit_code);
}
