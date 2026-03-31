//! Distributed KV Server
//!
//! Main server executable for running a distributed KV node.
//!
//! Usage:
//!   kv-server --id 1 --port 8000 --data /var/lib/kv/node1 \
//!             --peer 2=127.0.0.1:8001 --peer 3=127.0.0.1:8002
//!
//! Options:
//!   --id <n>           Node ID (required)
//!   --port <n>         Listen port (default: 8000)
//!   --data <path>      Data directory for WAL (default: ./data)
//!   --peer <id>=<addr> Peer node address (can specify multiple)
//!   --help             Show help

const std = @import("std");
const lib = @import("lib.zig");
const linux = std.os.linux;

const VERSION = "1.0.0";

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.c_allocator;

    // Collect args into array for indexed access
    var args_list: std.ArrayListUnmanaged([]const u8) = .empty;
    defer args_list.deinit(allocator);
    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    while (args_iter.next()) |arg| {
        try args_list.append(allocator, arg);
    }
    const args = args_list.items;

    var config = Config{
        .node_id = null,
        .port = 8000,
        .data_dir = "./data",
        .peers = std.ArrayListUnmanaged(Peer).empty,
    };
    defer config.peers.deinit(allocator);

    // Parse arguments
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printHelp();
            return;
        }

        if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-v")) {
            std.debug.print("kv-server {s}\n", .{VERSION});
            return;
        }

        if (std.mem.eql(u8, arg, "--id")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --id requires a value\n", .{});
                return;
            }
            config.node_id = std.fmt.parseInt(u64, args[i], 10) catch {
                std.debug.print("Error: Invalid node ID\n", .{});
                return;
            };
            continue;
        }

        if (std.mem.eql(u8, arg, "--port") or std.mem.eql(u8, arg, "-p")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --port requires a value\n", .{});
                return;
            }
            config.port = std.fmt.parseInt(u16, args[i], 10) catch {
                std.debug.print("Error: Invalid port\n", .{});
                return;
            };
            continue;
        }

        if (std.mem.eql(u8, arg, "--data") or std.mem.eql(u8, arg, "-d")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --data requires a value\n", .{});
                return;
            }
            config.data_dir = args[i];
            continue;
        }

        if (std.mem.eql(u8, arg, "--peer")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --peer requires a value\n", .{});
                return;
            }
            const peer = parsePeer(args[i]) catch {
                std.debug.print("Error: Invalid peer format. Use: id=host:port\n", .{});
                return;
            };
            try config.peers.append(allocator, peer);
            continue;
        }

        std.debug.print("Error: Unknown argument: {s}\n", .{arg});
        printHelp();
        return;
    }

    // Validate configuration
    const node_id = config.node_id orelse {
        std.debug.print("Error: --id is required\n", .{});
        printHelp();
        return;
    };

    // Build cluster node list
    var cluster_nodes = std.ArrayListUnmanaged(lib.NodeId).empty;
    defer cluster_nodes.deinit(allocator);

    try cluster_nodes.append(allocator, node_id);
    for (config.peers.items) |peer| {
        try cluster_nodes.append(allocator, peer.id);
    }

    // Build peer configs
    var peer_configs = std.ArrayListUnmanaged(lib.NodeConfig.PeerConfig).empty;
    defer peer_configs.deinit(allocator);

    for (config.peers.items) |peer| {
        try peer_configs.append(allocator, .{
            .node_id = peer.id,
            .address = peer.address,
        });
    }

    // Create node configuration
    const node_config = lib.NodeConfig{
        .node_id = node_id,
        .port = config.port,
        .data_dir = config.data_dir,
        .peers = peer_configs.items,
        .cluster_nodes = cluster_nodes.items,
    };

    // Print startup info
    std.debug.print("Starting Distributed KV Server v{s}\n", .{VERSION});
    std.debug.print("  Node ID: {d}\n", .{node_id});
    std.debug.print("  Port: {d}\n", .{config.port});
    std.debug.print("  Data Dir: {s}\n", .{config.data_dir});
    std.debug.print("  Cluster Size: {d}\n", .{cluster_nodes.items.len});
    for (config.peers.items) |peer| {
        std.debug.print("  Peer {d}: {s}\n", .{ peer.id, peer.address });
    }

    // Initialize and start node
    var node = lib.DistributedNode.init(allocator, node_config) catch |err| {
        std.debug.print("Error: Failed to initialize node: {}\n", .{err});
        return;
    };
    defer node.deinit();

    node.start() catch |err| {
        std.debug.print("Error: Failed to start node: {}\n", .{err});
        return;
    };

    std.debug.print("Node started. Press Ctrl+C to stop.\n", .{});

    // Wait for signal
    while (node.running.load(.acquire)) {
        var ts: linux.timespec = .{ .sec = 1, .nsec = 0 };
        _ = linux.nanosleep(&ts, null);

        // Print status periodically
        const state = node.getState();
        std.debug.print("Status: {s} | Term: {d}\n", .{
            state.toString(),
            node.raft_node.getTerm(),
        });
    }

    std.debug.print("Shutting down...\n", .{});
}

const Config = struct {
    node_id: ?u64,
    port: u16,
    data_dir: []const u8,
    peers: std.ArrayListUnmanaged(Peer),
};

const Peer = struct {
    id: u64,
    address: []const u8,
};

fn parsePeer(s: []const u8) !Peer {
    // Format: id=host:port
    const eq_idx = std.mem.indexOf(u8, s, "=") orelse return error.InvalidFormat;
    const id_str = s[0..eq_idx];
    const address = s[eq_idx + 1 ..];

    const id = try std.fmt.parseInt(u64, id_str, 10);

    // Validate address has port
    if (std.mem.lastIndexOf(u8, address, ":") == null) {
        return error.InvalidFormat;
    }

    return Peer{ .id = id, .address = address };
}

fn printHelp() void {
    std.debug.print(
        \\Distributed KV Server v{s}
        \\
        \\Usage: kv-server [OPTIONS]
        \\
        \\Options:
        \\  --id <n>           Node ID (required, unique per node)
        \\  --port <n>         Listen port (default: 8000)
        \\  --data <path>      Data directory for WAL (default: ./data)
        \\  --peer <id>=<addr> Peer node address (can specify multiple)
        \\  --help             Show this help
        \\  --version          Show version
        \\
        \\Example:
        \\  # Start a 3-node cluster
        \\  kv-server --id 1 --port 8000 --peer 2=127.0.0.1:8001 --peer 3=127.0.0.1:8002
        \\  kv-server --id 2 --port 8001 --peer 1=127.0.0.1:8000 --peer 3=127.0.0.1:8002
        \\  kv-server --id 3 --port 8002 --peer 1=127.0.0.1:8000 --peer 2=127.0.0.1:8001
        \\
    , .{VERSION});
}
