# zats JetStream — Persistence Layer Spec

## Context

zats is a working NATS-compatible message broker (57 tests, 3 binaries, live pub/sub verified). JetStream extends it with persistence: streams store messages, consumers track delivery state, and publishers get acknowledgments. This turns zats from a fire-and-forget broker into a durable messaging system suitable for the MFD telemetry pipeline, chaos rocket event sourcing, and general inter-service reliability.

**Critical architectural insight**: JetStream is NOT a separate protocol. It runs entirely over standard NATS request/reply. Clients publish JSON to `$JS.API.*` subjects, the server processes them and replies. All stream publishes and consumer deliveries use standard `PUB`/`MSG`/`HPUB`/`HMSG` wire protocol messages. The existing zats protocol parser, subject trie, and router carry all JetStream traffic unchanged.

---

## What Gets Added vs What Already Exists

### Already exists in zats (no changes needed)
- TCP listener, connection accept, connection state machine
- NATS protocol parser (`PUB`, `SUB`, `UNSUB`, `CONNECT`, `PING/PONG`, `INFO`)
- Subject trie with `*` and `>` wildcard matching
- Subscription router with message delivery
- Request/reply pattern (client sets reply-to, another client responds)
- Client library with publish/subscribe/request

### Must be added for JetStream
- `HPUB` / `HMSG` protocol support (headers — needed for ack metadata, dedup, status codes)
- Stream engine: message storage, indexing, retention enforcement
- Consumer engine: delivery tracking, ack processing, redelivery
- JetStream API handler: JSON request/reply services on `$JS.API.*`
- Publish acknowledgments: `PubAck` responses to stream publishes
- File-based and memory-based storage backends
- WAL (Write-Ahead Log) for crash recovery on file storage

### Nice to have (Phase 2+)
- Key-Value store (thin layer over streams with specific subject conventions)
- Object Store
- Stream mirroring/sourcing
- Clustering/replication (Raft)

---

## Directory Structure

New files added to the existing `programs/zats/src/` directory:

```
programs/zats/src/
  # Existing (unchanged)
  lib.zig                    — Public API exports
  protocol.zig               — NATS wire protocol parser/encoder
  connection.zig             — Client connection state machine
  server.zig                 — TCP server, accept loop, dispatch
  trie.zig                   — Subject trie with wildcard matching
  router.zig                 — Subscription manager, message delivery
  client.zig                 — NATS client library

  # New — JetStream
  jetstream.zig              — JetStream engine: top-level coordinator
  stream.zig                 — Stream: message storage + retention + limits
  consumer.zig               — Consumer: delivery state machine + ack tracking
  store/
    memory_store.zig         — In-memory message store (ArrayListUnmanaged)
    file_store.zig           — File-backed message store with WAL
    store.zig                — Storage interface (vtable pattern)
  js_api.zig                 — JetStream API: JSON request/reply handlers on $JS.API.*
  headers.zig                — NATS header parser/encoder (HPUB/HMSG support)
```

---

## Protocol Extensions: HPUB / HMSG

JetStream requires message headers for ack metadata, dedup IDs, and status responses.

### HPUB (Header Publish)
```
HPUB <subject> [reply-to] <header_bytes> <total_bytes>\r\n
<headers>\r\n\r\n<payload>\r\n
```

Header format follows HTTP-style:
```
NATS/1.0\r\n
Nats-Msg-Id: abc-123\r\n
\r\n
```

Status headers (used for JetStream control messages):
```
NATS/1.0 404 No Messages\r\n
\r\n
```
```
NATS/1.0 100 Idle Heartbeat\r\n
\r\n
```
```
NATS/1.0 409 Max Ack Pending\r\n
\r\n
```

### HMSG (Header Message — delivered to subscribers)
```
HMSG <subject> <sid> [reply-to] <header_bytes> <total_bytes>\r\n
<headers>\r\n\r\n<payload>\r\n
```

### Implementation in protocol.zig

Add to existing `MsgType` enum:
```zig
pub const MsgType = enum {
    // Existing
    pub_msg,
    sub,
    unsub,
    connect,
    ping,
    pong,
    info,
    ok,
    err,
    // New
    hpub,
    hmsg,
};
```

Add to existing `ParsedMsg`:
```zig
pub const ParsedMsg = struct {
    // Existing fields...
    msg_type: MsgType,
    subject: []const u8,
    reply_to: ?[]const u8,
    payload: []const u8,
    sid: ?[]const u8,
    // New for HPUB/HMSG
    headers: ?[]const u8,       // Raw header bytes (null for PUB/MSG)
    header_len: u32,            // Byte count of headers section
    total_len: u32,             // header_len + payload len
};
```

### headers.zig

```zig
pub const Headers = struct {
    /// Raw header buffer — no allocation, indexes into original message
    raw: []const u8,

    pub const Status = struct {
        code: u16,          // 100, 404, 408, 409, 503
        description: []const u8,
    };

    pub const Iterator = struct {
        raw: []const u8,
        pos: usize,

        pub fn next(self: *Iterator) ?struct { name: []const u8, value: []const u8 } {
            // Parse "Name: Value\r\n" pairs
        }
    };

    /// Parse status line: "NATS/1.0 404 No Messages\r\n"
    pub fn status(self: Headers) ?Status

    /// Get first value for a header name (case-insensitive match)
    pub fn get(self: Headers, name: []const u8) ?[]const u8

    /// Iterate all header key-value pairs
    pub fn iterator(self: Headers) Iterator

    /// Encode headers into buffer. Returns bytes written.
    pub fn encode(
        buf: []u8,
        status_code: ?u16,
        status_desc: ?[]const u8,
        kvs: []const struct { name: []const u8, value: []const u8 },
    ) !usize
};
```

---

## Stream Engine (stream.zig)

A Stream captures messages published to matching subjects, stores them durably, and enforces retention/limits.

### StreamConfig

```zig
pub const RetentionPolicy = enum {
    limits,         // Default: keep until limits hit
    interest,       // Remove when all consumers have acked
    workqueue,      // Remove when any consumer acks (single consumer per subject)
};

pub const DiscardPolicy = enum {
    old,            // Remove oldest when limit hit
    new,            // Reject new message when limit hit
};

pub const StorageType = enum {
    file,
    memory,
};

pub const StreamConfig = struct {
    name: []const u8,                       // Required. No spaces/tabs/periods.
    subjects: []const []const u8 = &.{},    // Subjects to capture. Default: [name]
    retention: RetentionPolicy = .limits,
    max_consumers: i64 = -1,                // -1 = unlimited
    max_msgs: i64 = -1,                     // -1 = unlimited
    max_bytes: i64 = -1,                    // -1 = unlimited
    max_age_ns: i64 = 0,                    // 0 = unlimited, nanoseconds
    max_msg_size: i32 = -1,                 // -1 = server default (1MB)
    storage: StorageType = .file,
    num_replicas: u8 = 1,                   // 1 = no replication (single node for now)
    no_ack: bool = false,                   // If true, don't ack publishes
    duplicate_window_ns: i64 = 120_000_000_000, // 2 minutes default
    description: ?[]const u8 = null,
    max_msgs_per_subject: i64 = -1,
    discard: DiscardPolicy = .old,
    deny_delete: bool = false,
    deny_purge: bool = false,
    allow_rollup: bool = false,
};
```

### StreamState

```zig
pub const StreamState = struct {
    messages: u64,          // Total messages currently stored
    bytes: u64,             // Total bytes currently stored
    first_seq: u64,         // Sequence of first message
    first_ts: i64,          // Timestamp of first message (nanos since epoch)
    last_seq: u64,          // Sequence of last message
    last_ts: i64,           // Timestamp of last message
    consumer_count: u32,    // Number of consumers defined
    num_subjects: u32,      // Unique subjects in stream
    num_deleted: u64,       // Number of deleted messages (gaps)
};
```

### StoredMessage

```zig
pub const StoredMessage = struct {
    sequence: u64,
    subject: []const u8,
    headers: ?[]const u8,
    data: []const u8,
    timestamp: i64,         // Nanoseconds since epoch
    // Internal
    raw_size: u64,          // Total size for accounting
};
```

### Stream struct

```zig
pub const Stream = struct {
    config: StreamConfig,
    state: StreamState,
    store: store.MessageStore,          // vtable: memory or file backend
    consumers: std.StringHashMap(*Consumer),
    mu: std.Thread.Mutex,

    // Deduplication: tracks Nats-Msg-Id headers within duplicate_window
    dedup_map: std.StringHashMap(u64),  // msg_id -> sequence
    dedup_window_ns: i64,

    allocator: std.mem.Allocator,

    // --- Core operations ---

    /// Store a message. Returns PubAck with sequence number.
    /// Enforces limits, dedup, max_msg_size.
    /// Called by JetStream engine when a PUB matches stream subjects.
    pub fn storeMessage(
        self: *Stream,
        subject: []const u8,
        headers: ?[]const u8,
        data: []const u8,
        msg_id: ?[]const u8,    // From Nats-Msg-Id header
    ) !PubAck

    /// Get message by sequence
    pub fn getMessage(self: *Stream, seq: u64) !?StoredMessage

    /// Get message by subject (last message on subject)
    pub fn getMessageBySubject(self: *Stream, subject: []const u8) !?StoredMessage

    /// Delete specific message by sequence
    pub fn deleteMessage(self: *Stream, seq: u64) !void

    /// Purge all messages (or by subject filter)
    pub fn purge(self: *Stream, subject_filter: ?[]const u8) !PurgeResponse

    /// Enforce retention: age, count, bytes limits
    /// Called after each store and periodically
    pub fn enforceRetention(self: *Stream) !void

    /// Interest-based retention check: remove messages acked by all consumers
    pub fn enforceInterestRetention(self: *Stream) !void

    /// Work-queue retention: remove message once acked by the single consumer
    pub fn enforceWorkqueueRetention(self: *Stream, seq: u64) !void

    // --- Consumer management ---

    pub fn addConsumer(self: *Stream, config: ConsumerConfig) !*Consumer
    pub fn deleteConsumer(self: *Stream, name: []const u8) !void
    pub fn getConsumer(self: *Stream, name: []const u8) ?*Consumer
    pub fn listConsumers(self: *Stream) []ConsumerInfo

    // --- Lifecycle ---

    pub fn init(allocator: std.mem.Allocator, config: StreamConfig, data_dir: []const u8) !Stream
    pub fn deinit(self: *Stream) void
    pub fn snapshot(self: *Stream) !StreamInfo  // Full state for API responses
};

pub const PubAck = struct {
    stream: []const u8,
    seq: u64,
    duplicate: bool,        // True if dedup detected
    domain: ?[]const u8,
};

pub const PurgeResponse = struct {
    success: bool,
    purged: u64,
};

pub const StreamInfo = struct {
    config: StreamConfig,
    state: StreamState,
    created: i64,           // Creation timestamp
};
```

---

## Consumer Engine (consumer.zig)

A Consumer is a stateful view on a Stream that tracks which messages have been delivered and acknowledged.

### ConsumerConfig

```zig
pub const DeliverPolicy = enum {
    all,                // Start from first message
    last,               // Start from last message
    new,                // Start from messages published after consumer creation
    by_start_sequence,  // Start from specific sequence
    by_start_time,      // Start from specific timestamp
    last_per_subject,   // Last message for each subject
};

pub const AckPolicy = enum {
    none,       // No acks required
    all,        // Acking a message implicitly acks all prior
    explicit,   // Each message must be individually acked
};

pub const ReplayPolicy = enum {
    instant,    // Deliver as fast as possible
    original,   // Deliver at the rate they were published
};

pub const ConsumerConfig = struct {
    // Identity
    name: ?[]const u8 = null,               // For named consumers (server 2.9+)
    durable_name: ?[]const u8 = null,       // Legacy durable name

    // Delivery
    deliver_policy: DeliverPolicy = .all,
    opt_start_seq: ?u64 = null,             // For by_start_sequence
    opt_start_time: ?i64 = null,            // For by_start_time (nanos)
    deliver_subject: ?[]const u8 = null,    // Push consumer delivery subject
    deliver_group: ?[]const u8 = null,      // Queue group for push delivery

    // Filtering
    filter_subject: ?[]const u8 = null,     // Only messages matching this subject
    filter_subjects: ?[]const []const u8 = null, // Multiple filter subjects

    // Acknowledgments
    ack_policy: AckPolicy = .explicit,
    ack_wait_ns: i64 = 30_000_000_000,      // 30 seconds default
    max_deliver: i64 = -1,                   // -1 = unlimited redeliveries
    max_ack_pending: i64 = 1000,            // Max unacked messages in flight

    // Flow control
    max_waiting: i64 = 512,                 // Max outstanding pull requests
    max_batch: i64 = 0,                     // Max messages per pull (0=no limit)
    max_bytes: i64 = 0,                     // Max bytes per pull (0=no limit)

    // Behavior
    replay_policy: ReplayPolicy = .instant,
    sample_freq: ?[]const u8 = null,        // Sampling percentage "100" = all
    inactive_threshold_ns: i64 = 0,         // Auto-delete ephemeral after inactivity
    num_replicas: u8 = 0,                   // 0 = stream's replica count
    mem_storage: bool = false,              // Force memory storage for consumer state
    description: ?[]const u8 = null,

    // Headers only mode
    headers_only: bool = false,
};
```

### Consumer State

```zig
pub const SequencePair = struct {
    stream_seq: u64,    // Sequence in the stream
    consumer_seq: u64,  // Sequence delivered to this consumer
};

pub const ConsumerState = struct {
    // Delivery tracking
    delivered: SequencePair,    // Last delivered sequence pair
    ack_floor: SequencePair,   // All messages up to here are acked
    num_ack_pending: u64,
    num_redelivered: u64,
    num_waiting: u64,           // Outstanding pull requests
    num_pending: u64,           // Messages available but not yet delivered

    // Pending acks: stream_seq -> delivery metadata
    pending: std.AutoHashMap(u64, PendingMessage),
};

pub const PendingMessage = struct {
    consumer_seq: u64,
    deliver_count: u32,
    timestamp: i64,         // When last delivered (for ack_wait timeout)
};
```

### Consumer struct

```zig
pub const Consumer = struct {
    config: ConsumerConfig,
    state: ConsumerState,
    stream: *Stream,
    created: i64,
    allocator: std.mem.Allocator,

    // For push consumers
    push_subscription: ?PushSub,

    // For pull consumers: pending pull requests
    pull_requests: std.ArrayList(PullRequest),

    // Ack wait timer tracking
    ack_pending_deadlines: std.AutoHashMap(u64, i64), // seq -> deadline_ns

    // --- Pull consumer operations ---

    /// Process a pull request: fetch batch of messages
    /// Returns messages immediately if available, or parks the request
    pub fn fetch(self: *Consumer, batch: u32, no_wait: bool, expires_ns: ?i64) !FetchResult

    /// Called by timer or on new message: try to satisfy pending pull requests
    pub fn processPendingPulls(self: *Consumer) !void

    // --- Push consumer operations ---

    /// Deliver next available messages to push delivery subject
    pub fn pushDeliver(self: *Consumer) !void

    // --- Ack processing ---

    /// Process an acknowledgment
    /// ack_type: +ACK, -NAK, +WPI (work in progress), +NXT, +TERM
    pub fn processAck(self: *Consumer, stream_seq: u64, ack_type: AckType) !void

    /// Check for ack_wait timeouts, redeliver expired messages
    pub fn checkAckTimeouts(self: *Consumer, now_ns: i64) !void

    // --- Message selection ---

    /// Get next message(s) matching this consumer's filter from the stream
    /// Respects deliver_policy, filter_subject, pending acks
    pub fn nextMessages(self: *Consumer, max_batch: u32) ![]StoredMessage

    // --- Info ---

    pub fn info(self: *Consumer) ConsumerInfo

    pub fn init(allocator: std.mem.Allocator, config: ConsumerConfig, stream: *Stream) !Consumer
    pub fn deinit(self: *Consumer) void
};

pub const AckType = enum {
    ack,        // +ACK — message processed successfully
    nak,        // -NAK — negative ack, redeliver immediately
    progress,   // +WPI — work in progress, reset ack_wait timer
    next,       // +NXT — ack + request next (pull only)
    term,       // +TERM — ack + don't redeliver even on failure
};

pub const PullRequest = struct {
    reply_to: []const u8,       // Inbox to deliver messages to
    batch: u32,                 // How many messages requested
    max_bytes: u64,             // Max bytes (0 = no limit)
    no_wait: bool,              // Return 404 immediately if no messages
    expires: ?i64,              // Absolute deadline (nanos since epoch)
    delivered: u32,             // How many already delivered for this request
};

pub const PushSub = struct {
    deliver_subject: []const u8,
    deliver_group: ?[]const u8,
};

pub const FetchResult = struct {
    messages: []StoredMessage,
    pending: u64,               // Remaining messages after this batch
};

pub const ConsumerInfo = struct {
    stream_name: []const u8,
    name: []const u8,
    config: ConsumerConfig,
    state: ConsumerState,
    created: i64,
    push_bound: bool,
};
```

### Ack Subject Format

When messages are delivered to consumers, the reply-to subject encodes the ack metadata:

```
$JS.ACK.<stream>.<consumer>.<deliver_count>.<stream_seq>.<consumer_seq>.<timestamp>.<pending>
```

Example:
```
$JS.ACK.ORDERS.processor.1.42.17.1708632000000000000.5
```

The consumer processes acks by:
1. Subscribing to `$JS.ACK.<stream>.<consumer>.>` internally
2. Parsing the stream_seq from the ack subject
3. Calling `processAck(stream_seq, ack_type)` based on the payload

Ack payloads:
| Payload | AckType | Behavior |
|---------|---------|----------|
| `""` or `"+ACK"` | ack | Message processed OK |
| `"-NAK"` | nak | Redeliver immediately |
| `"+WPI"` | progress | Reset ack_wait timer |
| `"+NXT"` | next | Ack + pull next (pull consumers) |
| `"+TERM"` | term | Terminal failure, don't redeliver |

---

## Storage Interface (store/store.zig)

```zig
pub const MessageStore = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        store: *const fn (ptr: *anyopaque, seq: u64, subject: []const u8, headers: ?[]const u8, data: []const u8, ts: i64) anyerror!void,
        load: *const fn (ptr: *anyopaque, seq: u64) anyerror!?StoredMessage,
        delete: *const fn (ptr: *anyopaque, seq: u64) anyerror!void,
        purge: *const fn (ptr: *anyopaque) anyerror!u64,
        /// Get the last message for a specific subject
        loadBySubject: *const fn (ptr: *anyopaque, subject: []const u8) anyerror!?StoredMessage,
        /// Total bytes on disk/memory
        bytes: *const fn (ptr: *anyopaque) u64,
        /// Flush/sync to persistent storage (no-op for memory)
        flush: *const fn (ptr: *anyopaque) anyerror!void,
    };

    // Delegate methods
    pub fn store(self: MessageStore, seq: u64, subject: []const u8, headers: ?[]const u8, data: []const u8, ts: i64) !void {
        return self.vtable.store(self.ptr, seq, subject, headers, data, ts);
    }
    // ... etc for each vtable method
};
```

### Memory Store (store/memory_store.zig)

```zig
pub const MemoryStore = struct {
    messages: std.AutoHashMap(u64, StoredMessage),
    subject_index: std.StringHashMap(u64),  // subject -> last seq
    bytes_total: u64,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) MemoryStore
    pub fn deinit(self: *MemoryStore) void
    pub fn messageStore(self: *MemoryStore) MessageStore  // Returns vtable wrapper
};
```

### File Store (store/file_store.zig)

Append-only log with index. Inspired by the distributed_kv WAL already in the monorepo.

```zig
pub const FileStore = struct {
    data_dir: []const u8,
    /// WAL: append-only data file
    /// Format per record:
    ///   [4 bytes: total_len][8 bytes: seq][8 bytes: timestamp]
    ///   [2 bytes: subject_len][subject_bytes]
    ///   [4 bytes: header_len][header_bytes]  (0 if no headers)
    ///   [4 bytes: data_len][data_bytes]
    ///   [4 bytes: CRC32]
    data_file: std.fs.File,
    data_offset: u64,

    /// Index: seq -> file offset for O(1) lookup
    /// Periodically checkpointed to disk
    index: std.AutoHashMap(u64, u64),

    /// Subject index: subject -> last seq
    subject_last_seq: std.StringHashMap(u64),

    bytes_total: u64,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, data_dir: []const u8) !FileStore
    pub fn deinit(self: *FileStore) void
    pub fn recover(self: *FileStore) !void  // Replay WAL on startup
    pub fn messageStore(self: *FileStore) MessageStore
};
```

---

## JetStream Engine (jetstream.zig)

Top-level coordinator that owns all streams and wires into the server.

```zig
pub const JetStreamConfig = struct {
    store_dir: []const u8 = "/tmp/zats-jetstream",
    max_memory: i64 = -1,      // -1 = unlimited
    max_store: i64 = -1,       // -1 = unlimited
    max_streams: i64 = -1,
    max_consumers: i64 = -1,
    domain: ?[]const u8 = null, // JetStream domain
};

pub const JetStream = struct {
    config: JetStreamConfig,
    streams: std.StringHashMap(*Stream),
    allocator: std.mem.Allocator,

    // Stats
    total_memory: u64,
    total_store: u64,

    // API prefix: "$JS.API" or "$JS.<domain>.API" if domain set
    api_prefix: []const u8,

    // --- Lifecycle ---

    pub fn init(allocator: std.mem.Allocator, config: JetStreamConfig) !JetStream
    pub fn deinit(self: *JetStream) void

    // --- Stream management ---

    pub fn createStream(self: *JetStream, config: StreamConfig) !*Stream
    pub fn updateStream(self: *JetStream, config: StreamConfig) !*Stream
    pub fn deleteStream(self: *JetStream, name: []const u8) !void
    pub fn getStream(self: *JetStream, name: []const u8) ?*Stream
    pub fn listStreams(self: *JetStream) []StreamInfo
    pub fn streamNames(self: *JetStream) [][]const u8

    // --- Message interception ---

    /// Called by the server for every PUB/HPUB.
    /// Checks if any stream captures this subject.
    /// If so, stores the message and sends PubAck on reply-to.
    /// Returns true if a stream captured the message.
    pub fn interceptPublish(
        self: *JetStream,
        subject: []const u8,
        reply_to: ?[]const u8,
        headers: ?[]const u8,
        data: []const u8,
    ) !bool

    // --- Ack interception ---

    /// Called when server receives a publish to $JS.ACK.*
    /// Routes to the appropriate consumer's ack handler.
    pub fn interceptAck(
        self: *JetStream,
        subject: []const u8,
        data: []const u8,
    ) !void

    // --- Periodic maintenance ---

    /// Run retention enforcement, ack timeout checks, etc.
    /// Called from server's tick loop.
    pub fn tick(self: *JetStream, now_ns: i64) !void

    // --- Account info ---

    pub fn accountInfo(self: *JetStream) AccountInfo
};

pub const AccountInfo = struct {
    memory: u64,
    storage: u64,
    streams: u64,
    consumers: u64,
    limits: JetStreamConfig,
};
```

---

## JetStream API Handler (js_api.zig)

Maps `$JS.API.*` subjects to handler functions. Each handler parses JSON request, calls JetStream engine, returns JSON response.

```zig
pub const JsApiHandler = struct {
    js: *JetStream,
    allocator: std.mem.Allocator,

    /// Route an API request to the appropriate handler.
    /// Called by the server when a PUB matches $JS.API.>
    /// Returns JSON response to send to reply-to subject.
    pub fn handleRequest(
        self: *JsApiHandler,
        subject: []const u8,
        data: []const u8,
        reply_to: []const u8,
    ) ![]const u8
};
```

### API Subject Routing Table

All handlers receive JSON payload and return JSON response via request/reply.

| Subject Pattern | Handler | Request | Response |
|---|---|---|---|
| `$JS.API.INFO` | `handleAccountInfo` | `""` | `AccountInfoResponse` |
| **Streams** | | | |
| `$JS.API.STREAM.CREATE.<stream>` | `handleStreamCreate` | `StreamConfig` (JSON) | `StreamInfoResponse` |
| `$JS.API.STREAM.UPDATE.<stream>` | `handleStreamUpdate` | `StreamConfig` (JSON) | `StreamInfoResponse` |
| `$JS.API.STREAM.DELETE.<stream>` | `handleStreamDelete` | `""` | `{success: true}` |
| `$JS.API.STREAM.INFO.<stream>` | `handleStreamInfo` | `""` | `StreamInfoResponse` |
| `$JS.API.STREAM.PURGE.<stream>` | `handleStreamPurge` | `{filter?: "subject"}` | `{success, purged}` |
| `$JS.API.STREAM.LIST` | `handleStreamList` | `{offset?: N}` | `StreamListResponse` |
| `$JS.API.STREAM.NAMES` | `handleStreamNames` | `{offset?: N}` | `StreamNamesResponse` |
| `$JS.API.STREAM.MSG.GET.<stream>` | `handleStreamMsgGet` | `{seq: N}` or `{last_by_subj: "s"}` | `StreamMsgGetResponse` |
| `$JS.API.STREAM.MSG.DELETE.<stream>` | `handleStreamMsgDelete` | `{seq: N}` | `{success: true}` |
| **Consumers** | | | |
| `$JS.API.CONSUMER.CREATE.<stream>` | `handleConsumerCreate` | `ConsumerConfig` | `ConsumerInfoResponse` |
| `$JS.API.CONSUMER.CREATE.<stream>.<consumer>.<filter>` | `handleConsumerCreateFiltered` | `ConsumerConfig` | `ConsumerInfoResponse` |
| `$JS.API.CONSUMER.DURABLE.CREATE.<stream>.<consumer>` | `handleDurableCreate` | `ConsumerConfig` | `ConsumerInfoResponse` |
| `$JS.API.CONSUMER.DELETE.<stream>.<consumer>` | `handleConsumerDelete` | `""` | `{success: true}` |
| `$JS.API.CONSUMER.INFO.<stream>.<consumer>` | `handleConsumerInfo` | `""` | `ConsumerInfoResponse` |
| `$JS.API.CONSUMER.LIST.<stream>` | `handleConsumerList` | `{offset?: N}` | `ConsumerListResponse` |
| `$JS.API.CONSUMER.NAMES.<stream>` | `handleConsumerNames` | `{offset?: N}` | `ConsumerNamesResponse` |
| `$JS.API.CONSUMER.MSG.NEXT.<stream>.<consumer>` | `handleConsumerPull` | `"N"` or `{batch, expires?, no_wait?}` | Messages via reply-to |

### JSON Response Format

All admin API responses include a `type` field for schema identification:

```json
{
  "type": "io.nats.jetstream.api.v1.stream_create_response",
  "config": { ... },
  "state": { ... },
  "created": "2026-02-22T19:00:00.000Z"
}
```

Error responses:
```json
{
  "type": "io.nats.jetstream.api.v1.stream_create_response",
  "error": {
    "code": 404,
    "err_code": 10059,
    "description": "stream not found"
  }
}
```

### JetStream Error Codes (subset for initial implementation)

| err_code | HTTP code | Description |
|----------|-----------|-------------|
| 10039 | 400 | stream name invalid |
| 10058 | 400 | stream name already in use |
| 10059 | 404 | stream not found |
| 10014 | 404 | consumer not found |
| 10012 | 400 | consumer name already in use |
| 10013 | 400 | consumer config invalid |
| 10037 | 400 | no message found |
| 10071 | 503 | insufficient resources |
| 10052 | 400 | duplicate message |

---

## Server Integration

### How JetStream plugs into server.zig

The server's main dispatch loop needs minimal changes:

```zig
// In server.zig handleMessage():

fn handleMessage(self: *Server, conn: *Connection, msg: ParsedMsg) !void {
    switch (msg.msg_type) {
        .pub_msg, .hpub => {
            // 1. Check if JetStream captures this subject
            if (self.jetstream) |js| {
                if (msg.subject.len > 0 and msg.subject[0] == '$') {
                    // $JS.API.* → route to API handler
                    if (std.mem.startsWith(u8, msg.subject, js.api_prefix)) {
                        const response = try self.js_api.handleRequest(
                            msg.subject, msg.payload, msg.reply_to orelse return,
                        );
                        try self.publishInternal(msg.reply_to.?, response);
                        return;
                    }
                    // $JS.ACK.* → route to ack handler
                    if (std.mem.startsWith(u8, msg.subject, "$JS.ACK.")) {
                        try js.interceptAck(msg.subject, msg.payload);
                        return;
                    }
                }

                // Regular publish — check if any stream captures it
                _ = try js.interceptPublish(
                    msg.subject,
                    msg.reply_to,
                    msg.headers,
                    msg.payload,
                );
            }

            // 2. Normal pub/sub delivery (unchanged)
            try self.router.routeMessage(msg);
        },
        // ... existing handlers unchanged
    }
}
```

### Publish Interception Flow

```
Client: PUB ORDERS.new reply-inbox 5\r\nhello\r\n

Server dispatch:
  1. js.interceptPublish("ORDERS.new", "reply-inbox", null, "hello")
  2. Stream "ORDERS" matches subject "ORDERS.*"? → Yes
  3. stream.storeMessage("ORDERS.new", null, "hello", null)
     → Assigns seq=42, stores in WAL, enforces limits
  4. Send PubAck to reply-inbox:
     PUB reply-inbox 0 48\r\n
     {"stream":"ORDERS","seq":42,"duplicate":false}\r\n
  5. Push consumers watching ORDERS.new get notified
  6. Normal pub/sub delivery also happens (non-JetStream subscribers see it too)
```

### Consumer Pull Flow

```
Client: PUB $JS.API.CONSUMER.MSG.NEXT.ORDERS.worker reply-inbox 1\r\n1\r\n

Server dispatch:
  1. Matches $JS.API prefix → js_api.handleConsumerPull("ORDERS", "worker")
  2. consumer.fetch(batch=1, no_wait=false)
  3. If messages available:
     → Deliver via HMSG with ack reply subject:
     HMSG ORDERS.new <sid> $JS.ACK.ORDERS.worker.1.42.17.1708632000.5 <hdr_len> <total_len>
     NATS/1.0\r\n
     Nats-Sequence: 42\r\n
     \r\n
     hello
  4. If no messages:
     → Park the pull request, deliver when message arrives
```

### Consumer Ack Flow

```
Client: PUB $JS.ACK.ORDERS.worker.1.42.17.1708632000.5 0\r\n\r\n

Server dispatch:
  1. Matches $JS.ACK.* → js.interceptAck(subject, "")
  2. Parse: stream=ORDERS, consumer=worker, stream_seq=42
  3. consumer.processAck(42, .ack)
     → Remove from pending, advance ack_floor
     → If workqueue retention: stream.enforceWorkqueueRetention(42)
```

---

## INFO Extension

The server's INFO message should advertise JetStream support:

```json
{
  "server_id": "zats-001",
  "server_name": "zats",
  "version": "1.0.0",
  "proto": 1,
  "headers": true,
  "jetstream": true,
  "max_payload": 1048576
}
```

Key additions:
- `"headers": true` — signals HPUB/HMSG support
- `"jetstream": true` — signals JetStream API availability

---

## Implementation Phases

### Phase 1: Headers + Memory Store + Stream CRUD

**Files**: `headers.zig`, `store/store.zig`, `store/memory_store.zig`, `stream.zig`, `jetstream.zig`, `js_api.zig`

1. Add HPUB/HMSG parsing to `protocol.zig`
2. Implement `headers.zig` — parse/encode NATS headers
3. Implement `store/memory_store.zig` — in-memory message storage
4. Implement `stream.zig` — StreamConfig, store/get/delete, limits enforcement
5. Implement `jetstream.zig` — create/delete streams, interceptPublish
6. Implement `js_api.zig` — Stream CRUD API handlers (CREATE, DELETE, INFO, LIST, PURGE, MSG.GET)
7. Wire into `server.zig` — `$JS.API.*` routing, publish interception, PubAck
8. Update INFO to include `headers: true, jetstream: true`

**Verification**:
```bash
# Create a stream
echo '{"name":"ORDERS","subjects":["ORDERS.>"],"retention":"limits","storage":"memory"}' | \
  zats-pub -s localhost:4222 '$JS.API.STREAM.CREATE.ORDERS'

# Publish a message (gets stored + acked)
zats-pub -s localhost:4222 ORDERS.new "order 1"

# Get stream info
zats-pub -s localhost:4222 '$JS.API.STREAM.INFO.ORDERS' ""

# Retrieve by sequence
echo '{"seq":1}' | zats-pub -s localhost:4222 '$JS.API.STREAM.MSG.GET.ORDERS'

zig build test  # All new + existing tests pass
```

### Phase 2: Pull Consumers + Acks

**Files**: `consumer.zig`, extend `js_api.zig`, extend `jetstream.zig`

1. Implement `consumer.zig` — ConsumerConfig, state tracking, pending acks
2. Add consumer CRUD to `js_api.zig` (CREATE, DELETE, INFO, LIST)
3. Implement pull consumer: `MSG.NEXT` handler, batch delivery, no_wait, expires
4. Implement ack processing: `$JS.ACK.*` interception, all ack types
5. Implement ack_wait timeout with redelivery
6. Wire retention policies: interest, workqueue (triggered by ack processing)
7. Implement ack subject encoding/decoding

**Verification**:
```bash
# Create consumer
echo '{"durable_name":"processor","ack_policy":"explicit"}' | \
  zats-pub '$JS.API.CONSUMER.DURABLE.CREATE.ORDERS.processor'

# Pull messages
zats-pub '$JS.API.CONSUMER.MSG.NEXT.ORDERS.processor' '1'
# → receives message with ack reply subject

# Ack (publish to the reply subject)
zats-pub '$JS.ACK.ORDERS.processor.1.1.1.1708632000.0' ''

zig build test
```

### Phase 3: Push Consumers + Dedup + File Store

**Files**: `store/file_store.zig`, extend `consumer.zig`

1. Implement push consumer delivery: subscribe to delivery subject, auto-deliver
2. Implement message deduplication via `Nats-Msg-Id` header tracking
3. Implement `store/file_store.zig` — WAL with CRC32 checksums, index, crash recovery
4. Wire file store into Stream creation when `storage: file`
5. Periodic tick: retention enforcement, ack timeout scanning, ephemeral consumer cleanup

**Verification**:
```bash
# File-backed stream survives restart
zats-server --jetstream --store-dir /tmp/zats-js &
# Create stream, publish messages, kill server, restart
# Messages are still there

# Push consumer
echo '{"deliver_subject":"my.delivery","ack_policy":"explicit"}' | \
  zats-pub '$JS.API.CONSUMER.CREATE.ORDERS'
zats-sub 'my.delivery'  # Receives messages as they're published

# Dedup
HPUB ORDERS.new reply 25 30
NATS/1.0\r\nNats-Msg-Id: abc\r\n\r\nhello
# Publishing same Nats-Msg-Id within window returns duplicate=true

zig build test
```

### Phase 4: Key-Value Store (built on streams)

KV is a thin API layer over streams with subject convention `$KV.<bucket>.<key>`:

| KV Operation | Maps To |
|---|---|
| `PUT key value` | Publish to `$KV.<bucket>.<key>` with value as payload |
| `GET key` | Stream MSG.GET with `last_by_subj: "$KV.<bucket>.<key>"` |
| `DELETE key` | Publish empty message with `KV-Operation: DEL` header |
| `WATCH key` | Consumer with filter `$KV.<bucket>.<key>` |
| `KEYS` | Consumer with filter `$KV.<bucket>.>`, deliver last per subject |

Stream config for KV bucket:
```json
{
  "name": "KV_<bucket>",
  "subjects": ["$KV.<bucket>.>"],
  "max_msgs_per_subject": 1,
  "discard": "new",
  "allow_rollup": true,
  "deny_delete": true,
  "deny_purge": false
}
```

This is a straightforward layer once Phases 1-3 are solid.

---

## CLI Extensions

### zats-server

```bash
zats-server --jetstream                     # Enable JetStream with defaults
zats-server --jetstream --store-dir /data   # Custom storage directory
zats-server --jetstream --max-mem 1G        # Limit memory storage
zats-server --jetstream --max-store 10G     # Limit file storage
```

### zats-stream (new binary)

```bash
zats-stream create ORDERS --subjects "ORDERS.>" --retention limits --storage memory
zats-stream info ORDERS
zats-stream list
zats-stream delete ORDERS
zats-stream purge ORDERS
zats-stream get ORDERS --seq 42
```

### zats-consumer (new binary)

```bash
zats-consumer create ORDERS processor --ack explicit --deliver all --pull
zats-consumer info ORDERS processor
zats-consumer list ORDERS
zats-consumer delete ORDERS processor
zats-consumer next ORDERS processor --batch 10
```

---

## Testing Strategy

### Unit Tests

1. **headers.zig**: Parse/encode NATS headers, status lines, edge cases
2. **store/memory_store.zig**: Store/load/delete/purge, byte accounting
3. **store/file_store.zig**: WAL write/read, CRC validation, crash recovery (truncated writes)
4. **stream.zig**: Limits enforcement (max_msgs, max_bytes, max_age), retention policies, dedup window, subject filtering, purge
5. **consumer.zig**: Deliver policy (all, last, new, by_seq), ack processing (all types), ack_wait timeout + redelivery, pull request parking + expiry, max_ack_pending enforcement
6. **js_api.zig**: JSON request/response round-trip for each API endpoint, error responses for invalid inputs

### Integration Tests

1. **Publish + store + retrieve**: Create stream → publish → MSG.GET → verify
2. **Pull consumer lifecycle**: Create stream → create consumer → pull → ack → verify state
3. **Push consumer**: Create stream → create push consumer → subscribe to delivery → publish → verify delivery
4. **Ack policies**: explicit (per-message), all (cumulative), none (no acking)
5. **Redelivery**: Publish → deliver → don't ack → wait ack_wait → verify redelivery
6. **Retention**: Limits (max_msgs/bytes/age), interest (all consumers acked), workqueue (single ack removes)
7. **Dedup**: Publish with same Nats-Msg-Id → verify duplicate=true
8. **Persistence**: File store → kill → restart → verify messages survive
9. **Interop**: Use official NATS client (Go or Rust) against zats JetStream (stretch goal)

### Performance Targets

| Operation | Target | Notes |
|---|---|---|
| Memory store write | < 1µs/msg | Append to map + accounting |
| Memory store read | < 500ns/msg | HashMap lookup |
| File store write | < 10µs/msg | WAL append + fsync interval |
| Pull consumer fetch | < 5µs/msg | Seq scan + delivery tracking |
| Ack processing | < 1µs/ack | HashMap remove + floor advance |
| Limit enforcement | < 100µs | Amortized over batch of stores |

---

## Key Design Decisions

1. **JetStream over standard NATS**: All JetStream traffic uses standard PUB/SUB/MSG. No special TCP framing. The existing protocol parser and router carry everything. New code is purely the persistence + consumer state machines + JSON API handlers.

2. **Memory store first**: Get the semantics right with in-memory storage. File store adds WAL complexity but the stream/consumer logic is identical. The storage vtable pattern makes this clean.

3. **No clustering in v1**: Single-node JetStream. `num_replicas` is accepted but ignored (always 1). Raft-based replication is a separate project. Single-node is still useful and the distributed_kv in the monorepo already has Raft if we want to adapt it later.

4. **Existing distributed_kv WAL pattern**: The `distributed_kv` program already has a WAL with CRC32 checksums and crash recovery. Reuse that pattern for file_store.zig rather than inventing from scratch.

5. **Pull consumers prioritized over push**: Pull is the recommended pattern in modern NATS. Push consumers are simpler but less controllable. Implement pull first, push second.

6. **Consumer state in memory with periodic checkpoint**: Consumer delivery state (pending acks, ack floor) lives in memory for speed, checkpointed to disk periodically. On restart, replay from last checkpoint + stream messages.

7. **Tick-based maintenance**: Ack timeout scanning, retention enforcement, and ephemeral consumer cleanup run on a periodic tick (e.g., every 250ms) rather than per-message timers. Simpler, more predictable, and batches work.

8. **Headers are mandatory for JetStream but optional for core NATS**: The protocol parser accepts both PUB and HPUB. Core NATS pub/sub works without headers. JetStream publish acks and consumer message delivery use headers for metadata.

---

## Wire Protocol Examples

### Full round-trip: create stream, publish, consume, ack

```
# Client connects
C: CONNECT {"verbose":false,"name":"my-app","headers":true,"no_responders":true}
S: INFO {"server_id":"zats","version":"1.0.0","headers":true,"jetstream":true,...}

# Create stream
C: SUB _INBOX.abc 1
C: PUB $JS.API.STREAM.CREATE.ORDERS _INBOX.abc 58
C: {"name":"ORDERS","subjects":["ORDERS.>"],"storage":"memory"}
S: MSG _INBOX.abc 1 195
S: {"type":"io.nats.jetstream.api.v1.stream_create_response","config":{"name":"ORDERS","subjects":["ORDERS.>"],...},"state":{"messages":0,...},"created":"2026-02-22T19:00:00Z"}

# Create consumer
C: SUB _INBOX.def 2
C: PUB $JS.API.CONSUMER.DURABLE.CREATE.ORDERS.proc _INBOX.def 45
C: {"durable_name":"proc","ack_policy":"explicit"}
S: MSG _INBOX.def 2 210
S: {"type":"io.nats.jetstream.api.v1.consumer_create_response","stream_name":"ORDERS","name":"proc","config":{...},...}

# Publish a message (with reply for PubAck)
C: SUB _INBOX.ghi 3
C: PUB ORDERS.new _INBOX.ghi 11
C: hello world
S: MSG _INBOX.ghi 3 46
S: {"stream":"ORDERS","seq":1,"duplicate":false}

# Pull next message
C: SUB _INBOX.jkl 4
C: PUB $JS.API.CONSUMER.MSG.NEXT.ORDERS.proc _INBOX.jkl 1
C: 1
S: HMSG ORDERS.new 4 $JS.ACK.ORDERS.proc.1.1.1.1708632000000000000.0 45 56
S: NATS/1.0
S: Nats-Sequence: 1
S:
S: hello world

# Ack the message
C: PUB $JS.ACK.ORDERS.proc.1.1.1.1708632000000000000.0 0
C:
```

---

## Monorepo Reuse

| Component | Source | Usage |
|---|---|---|
| WAL pattern | `distributed_kv/` | CRC32 checksums, crash recovery for file store |
| JSON parsing | `std.json` | All JetStream API request/response |
| HashMap/trie | `trie.zig` (existing zats) | Subject matching for stream capture |
| Build pattern | `zats/build.zig` | Extend for new binaries |
| Test harness | Existing zats test pattern | Integration tests |

---

## Build Targets

```bash
# Build everything
zig build

# Run server with JetStream
./zig-out/bin/zats-server --jetstream --store-dir /tmp/zats-js

# Run tests
zig build test

# New binaries
zig build zats-stream
zig build zats-consumer
```
