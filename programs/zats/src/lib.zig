//! zats — A NATS-compatible messaging system in Zig
//!
//! Provides both server and client implementations of the NATS protocol.
//! Two consumption models: callback-based and channel-based (bounded queue).
//! JetStream support for persistent messaging with streams.

const std = @import("std");

// Sub-module namespaced access
pub const protocol = @import("protocol.zig");
pub const trie = @import("trie.zig");
pub const router = @import("router.zig");
pub const connection = @import("connection.zig");
pub const server = @import("server.zig");
pub const client = @import("client.zig");
pub const headers = @import("headers.zig");
pub const store = @import("store/store.zig");
pub const memory_store = @import("store/memory_store.zig");
pub const file_store = @import("store/file_store.zig");
pub const stream = @import("stream.zig");
pub const consumer = @import("consumer.zig");
pub const jetstream = @import("jetstream.zig");
pub const js_api = @import("js_api.zig");

// Flat convenience re-exports

// Server
pub const NatsServer = server.NatsServer;
pub const ServerConfig = server.ServerConfig;
pub const Stats = server.Stats;

// Client
pub const NatsClient = client.NatsClient;
pub const ClientConfig = client.ClientConfig;
pub const Message = client.Message;
pub const ChannelSubscription = client.ChannelSubscription;

// Protocol
pub const Command = protocol.Command;
pub const Opcode = protocol.Opcode;
pub const ParseError = protocol.ParseError;
pub const parse = protocol.parse;
pub const encodePub = protocol.encodePub;
pub const encodeSub = protocol.encodeSub;
pub const encodeMsg = protocol.encodeMsg;
pub const encodeHpub = protocol.encodeHpub;
pub const encodeHmsg = protocol.encodeHmsg;
pub const encodePing = protocol.encodePing;
pub const encodePong = protocol.encodePong;
pub const encodeOk = protocol.encodeOk;
pub const encodeErr = protocol.encodeErr;

// Router
pub const Router = router.Router;
pub const Subscription = router.Subscription;

// Trie
pub const SubjectTrie = trie.SubjectTrie;

// Connection
pub const ClientConnection = connection.ClientConnection;
pub const ConnectionState = connection.ConnectionState;

// Headers
pub const Headers = headers.Headers;

// JetStream
pub const JetStream = jetstream.JetStream;
pub const JetStreamConfig = jetstream.JetStreamConfig;
pub const Stream = stream.Stream;
pub const StreamConfig = stream.StreamConfig;

// File Store
pub const FileStore = file_store.FileStore;

// Consumers
pub const Consumer = consumer.Consumer;
pub const ConsumerConfig = consumer.ConsumerConfig;
pub const AckType = consumer.AckType;
pub const DeliverPolicy = consumer.DeliverPolicy;
pub const AckPolicy = consumer.AckPolicy;

test {
    std.testing.refAllDecls(@This());
}
