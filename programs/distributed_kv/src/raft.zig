//! Raft Consensus Implementation
//!
//! Implements the Raft consensus algorithm for distributed consensus:
//! - Leader election with randomized timeouts
//! - Log replication with consistency guarantees
//! - Membership changes (single-server)
//!
//! Based on "In Search of an Understandable Consensus Algorithm" (Ongaro & Ousterhout)
//!
//! State transitions:
//!   Follower -> Candidate (election timeout)
//!   Candidate -> Leader (majority votes)
//!   Candidate -> Follower (discover higher term)
//!   Leader -> Follower (discover higher term)

const std = @import("std");
const wal = @import("wal.zig");

// Zig 0.16 compatible Mutex using pthreads
const Mutex = struct {
    inner: std.c.pthread_mutex_t = std.c.PTHREAD_MUTEX_INITIALIZER,

    pub fn lock(self: *Mutex) void {
        _ = std.c.pthread_mutex_lock(&self.inner);
    }

    pub fn unlock(self: *Mutex) void {
        _ = std.c.pthread_mutex_unlock(&self.inner);
    }
};

/// Get current time in milliseconds (Zig 0.16 compatible)
fn currentTimeMs() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.REALTIME, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(ts.nsec, 1_000_000);
}

// =============================================================================
// Constants
// =============================================================================

/// Election timeout range (milliseconds)
pub const ELECTION_TIMEOUT_MIN_MS: u64 = 150;
pub const ELECTION_TIMEOUT_MAX_MS: u64 = 300;

/// Heartbeat interval (milliseconds) - must be << election timeout
pub const HEARTBEAT_INTERVAL_MS: u64 = 50;

/// Maximum entries per AppendEntries RPC
pub const MAX_ENTRIES_PER_RPC: usize = 100;

/// Maximum log size before snapshot
pub const SNAPSHOT_THRESHOLD: u64 = 10000;

// =============================================================================
// Types
// =============================================================================

/// Unique identifier for a Raft node
pub const NodeId = u64;

/// Term number (monotonically increasing)
pub const Term = u64;

/// Log index (1-indexed, 0 means no entry)
pub const LogIndex = u64;

/// Raft node state
pub const State = enum {
    follower,
    candidate,
    leader,

    pub fn toString(self: State) []const u8 {
        return switch (self) {
            .follower => "Follower",
            .candidate => "Candidate",
            .leader => "Leader",
        };
    }
};

/// Command types for the state machine
pub const CommandType = enum(u8) {
    noop = 0, // No operation (used for leader commit)
    set = 1, // Set key-value
    delete = 2, // Delete key
    cas = 3, // Compare-and-swap
    config_change = 4, // Cluster configuration change

    pub fn fromByte(b: u8) ?CommandType {
        return switch (b) {
            0 => .noop,
            1 => .set,
            2 => .delete,
            3 => .cas,
            4 => .config_change,
            else => null,
        };
    }
};

/// Log entry in the Raft log
pub const LogEntry = struct {
    term: Term,
    index: LogIndex,
    command_type: CommandType,
    data: []const u8, // Serialized command data

    pub fn encode(self: *const LogEntry, allocator: std.mem.Allocator) ![]u8 {
        // Format: term(8) + index(8) + cmd_type(1) + data_len(4) + data
        const total_len = 8 + 8 + 1 + 4 + self.data.len;
        var buf = try allocator.alloc(u8, total_len);

        std.mem.writeInt(u64, buf[0..8], self.term, .little);
        std.mem.writeInt(u64, buf[8..16], self.index, .little);
        buf[16] = @intFromEnum(self.command_type);
        std.mem.writeInt(u32, buf[17..21], @intCast(self.data.len), .little);
        if (self.data.len > 0) {
            @memcpy(buf[21..], self.data);
        }

        return buf;
    }

    pub fn decode(allocator: std.mem.Allocator, buf: []const u8) !LogEntry {
        if (buf.len < 21) return error.InvalidLogEntry;

        const term = std.mem.readInt(u64, buf[0..8], .little);
        const index = std.mem.readInt(u64, buf[8..16], .little);
        const cmd_type = CommandType.fromByte(buf[16]) orelse return error.InvalidLogEntry;
        const data_len = std.mem.readInt(u32, buf[17..21], .little);

        if (buf.len < 21 + data_len) return error.InvalidLogEntry;

        const data = try allocator.dupe(u8, buf[21 .. 21 + data_len]);

        return LogEntry{
            .term = term,
            .index = index,
            .command_type = cmd_type,
            .data = data,
        };
    }

    pub fn deinit(self: *LogEntry, allocator: std.mem.Allocator) void {
        if (self.data.len > 0) {
            allocator.free(@constCast(self.data));
        }
    }
};

/// Cluster configuration
pub const ClusterConfig = struct {
    nodes: []const NodeId,
    // For joint consensus during config changes
    old_nodes: ?[]const NodeId = null,

    pub fn quorumSize(self: *const ClusterConfig) usize {
        const n = self.nodes.len;
        if (self.old_nodes) |old| {
            // Joint consensus: need majority in both configs
            const old_n = old.len;
            return @max((n / 2) + 1, (old_n / 2) + 1);
        }
        return (n / 2) + 1;
    }

    pub fn contains(self: *const ClusterConfig, node_id: NodeId) bool {
        for (self.nodes) |id| {
            if (id == node_id) return true;
        }
        if (self.old_nodes) |old| {
            for (old) |id| {
                if (id == node_id) return true;
            }
        }
        return false;
    }
};

// =============================================================================
// RPC Messages
// =============================================================================

/// RequestVote RPC request
pub const RequestVoteRequest = struct {
    term: Term,
    candidate_id: NodeId,
    last_log_index: LogIndex,
    last_log_term: Term,

    pub fn encode(self: *const RequestVoteRequest) [32]u8 {
        var buf: [32]u8 = undefined;
        std.mem.writeInt(u64, buf[0..8], self.term, .little);
        std.mem.writeInt(u64, buf[8..16], self.candidate_id, .little);
        std.mem.writeInt(u64, buf[16..24], self.last_log_index, .little);
        std.mem.writeInt(u64, buf[24..32], self.last_log_term, .little);
        return buf;
    }

    pub fn decode(buf: []const u8) !RequestVoteRequest {
        if (buf.len < 32) return error.InvalidMessage;
        return RequestVoteRequest{
            .term = std.mem.readInt(u64, buf[0..8], .little),
            .candidate_id = std.mem.readInt(u64, buf[8..16], .little),
            .last_log_index = std.mem.readInt(u64, buf[16..24], .little),
            .last_log_term = std.mem.readInt(u64, buf[24..32], .little),
        };
    }
};

/// RequestVote RPC response
pub const RequestVoteResponse = struct {
    term: Term,
    vote_granted: bool,

    pub fn encode(self: *const RequestVoteResponse) [9]u8 {
        var buf: [9]u8 = undefined;
        std.mem.writeInt(u64, buf[0..8], self.term, .little);
        buf[8] = if (self.vote_granted) 1 else 0;
        return buf;
    }

    pub fn decode(buf: []const u8) !RequestVoteResponse {
        if (buf.len < 9) return error.InvalidMessage;
        return RequestVoteResponse{
            .term = std.mem.readInt(u64, buf[0..8], .little),
            .vote_granted = buf[8] != 0,
        };
    }
};

/// AppendEntries RPC request
pub const AppendEntriesRequest = struct {
    term: Term,
    leader_id: NodeId,
    prev_log_index: LogIndex,
    prev_log_term: Term,
    entries: []const LogEntry,
    leader_commit: LogIndex,

    pub fn encodeHeader(self: *const AppendEntriesRequest) [48]u8 {
        var buf: [48]u8 = undefined;
        std.mem.writeInt(u64, buf[0..8], self.term, .little);
        std.mem.writeInt(u64, buf[8..16], self.leader_id, .little);
        std.mem.writeInt(u64, buf[16..24], self.prev_log_index, .little);
        std.mem.writeInt(u64, buf[24..32], self.prev_log_term, .little);
        std.mem.writeInt(u64, buf[32..40], self.entries.len, .little);
        std.mem.writeInt(u64, buf[40..48], self.leader_commit, .little);
        return buf;
    }
};

/// AppendEntries RPC response
pub const AppendEntriesResponse = struct {
    term: Term,
    success: bool,
    // For fast log backup (optimization)
    conflict_index: LogIndex = 0,
    conflict_term: Term = 0,

    pub fn encode(self: *const AppendEntriesResponse) [25]u8 {
        var buf: [25]u8 = undefined;
        std.mem.writeInt(u64, buf[0..8], self.term, .little);
        buf[8] = if (self.success) 1 else 0;
        std.mem.writeInt(u64, buf[9..17], self.conflict_index, .little);
        std.mem.writeInt(u64, buf[17..25], self.conflict_term, .little);
        return buf;
    }

    pub fn decode(buf: []const u8) !AppendEntriesResponse {
        if (buf.len < 25) return error.InvalidMessage;
        return AppendEntriesResponse{
            .term = std.mem.readInt(u64, buf[0..8], .little),
            .success = buf[8] != 0,
            .conflict_index = std.mem.readInt(u64, buf[9..17], .little),
            .conflict_term = std.mem.readInt(u64, buf[17..25], .little),
        };
    }
};

// =============================================================================
// Raft Node
// =============================================================================

/// Transport interface for sending RPCs
pub const Transport = struct {
    ctx: *anyopaque,
    sendRequestVoteFn: *const fn (ctx: *anyopaque, target: NodeId, req: RequestVoteRequest) void,
    sendAppendEntriesFn: *const fn (ctx: *anyopaque, target: NodeId, req: AppendEntriesRequest) void,

    pub fn sendRequestVote(self: *Transport, target: NodeId, req: RequestVoteRequest) void {
        self.sendRequestVoteFn(self.ctx, target, req);
    }

    pub fn sendAppendEntries(self: *Transport, target: NodeId, req: AppendEntriesRequest) void {
        self.sendAppendEntriesFn(self.ctx, target, req);
    }
};

/// State machine interface
pub const StateMachine = struct {
    ctx: *anyopaque,
    applyFn: *const fn (ctx: *anyopaque, entry: *const LogEntry) anyerror!void,

    pub fn apply(self: *StateMachine, entry: *const LogEntry) !void {
        try self.applyFn(self.ctx, entry);
    }
};

/// Per-peer replication state (leader only)
pub const PeerState = struct {
    next_index: LogIndex, // Next log entry to send
    match_index: LogIndex, // Highest replicated entry
    vote_granted: bool, // Vote received in current election
    last_contact: i64, // Last successful RPC timestamp
};

/// Raft consensus node
pub const RaftNode = struct {
    allocator: std.mem.Allocator,

    // Identity
    id: NodeId,
    config: ClusterConfig,

    // Persistent state (on all servers)
    current_term: Term,
    voted_for: ?NodeId,
    log: std.ArrayListUnmanaged(LogEntry),

    // Volatile state (on all servers)
    state: State,
    commit_index: LogIndex,
    last_applied: LogIndex,

    // Volatile state (leaders only)
    peer_states: std.AutoHashMapUnmanaged(NodeId, PeerState),

    // Timing
    election_timeout_ms: u64,
    last_heartbeat: i64,
    random: std.Random,

    // External interfaces
    transport: ?*Transport,
    state_machine: ?*StateMachine,
    wal_writer: ?*wal.WalWriter,

    // Mutex for thread safety
    mutex: Mutex,

    pub fn init(
        allocator: std.mem.Allocator,
        id: NodeId,
        config: ClusterConfig,
    ) RaftNode {
        var prng = std.Random.DefaultPrng.init(@bitCast(currentTimeMs()));

        return RaftNode{
            .allocator = allocator,
            .id = id,
            .config = config,
            .current_term = 0,
            .voted_for = null,
            .log = .empty,
            .state = .follower,
            .commit_index = 0,
            .last_applied = 0,
            .peer_states = .empty,
            .election_timeout_ms = ELECTION_TIMEOUT_MIN_MS + prng.random().uintLessThan(u64, ELECTION_TIMEOUT_MAX_MS - ELECTION_TIMEOUT_MIN_MS),
            .last_heartbeat = currentTimeMs(),
            .random = prng.random(),
            .transport = null,
            .state_machine = null,
            .wal_writer = null,
            .mutex = .{},
        };
    }

    pub fn deinit(self: *RaftNode) void {
        for (self.log.items) |*entry| {
            entry.deinit(self.allocator);
        }
        self.log.deinit(self.allocator);
        self.peer_states.deinit(self.allocator);
    }

    pub fn setTransport(self: *RaftNode, transport: *Transport) void {
        self.transport = transport;
    }

    pub fn setStateMachine(self: *RaftNode, sm: *StateMachine) void {
        self.state_machine = sm;
    }

    pub fn setWal(self: *RaftNode, w: *wal.WalWriter) void {
        self.wal_writer = w;
    }

    // -------------------------------------------------------------------------
    // Core Raft Logic
    // -------------------------------------------------------------------------

    /// Called periodically to check timeouts and send heartbeats
    pub fn tick(self: *RaftNode) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const now = currentTimeMs();
        const elapsed = @as(u64, @intCast(now - self.last_heartbeat));

        switch (self.state) {
            .follower, .candidate => {
                // Check election timeout
                if (elapsed >= self.election_timeout_ms) {
                    try self.startElection();
                }
            },
            .leader => {
                // Send heartbeats
                if (elapsed >= HEARTBEAT_INTERVAL_MS) {
                    self.sendHeartbeats();
                    self.last_heartbeat = now;
                }
            },
        }

        // Apply committed entries to state machine
        try self.applyCommitted();
    }

    /// Start a new election
    fn startElection(self: *RaftNode) !void {
        self.current_term += 1;
        self.state = .candidate;
        self.voted_for = self.id;
        self.last_heartbeat = currentTimeMs();
        self.resetElectionTimeout();

        // Persist vote
        if (self.wal_writer) |w| {
            try w.writeVote(self.current_term, self.id);
        }

        // Reset vote tracking
        var iter = self.peer_states.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.vote_granted = false;
        }

        // Vote for self
        const self_state = self.peer_states.getPtr(self.id);
        if (self_state) |s| {
            s.vote_granted = true;
        }

        // Check if single-node cluster
        if (self.config.nodes.len == 1) {
            self.becomeLeader();
            return;
        }

        // Send RequestVote to all peers
        const last_log_index = self.getLastLogIndex();
        const last_log_term = self.getLastLogTerm();

        const req = RequestVoteRequest{
            .term = self.current_term,
            .candidate_id = self.id,
            .last_log_index = last_log_index,
            .last_log_term = last_log_term,
        };

        if (self.transport) |t| {
            for (self.config.nodes) |node_id| {
                if (node_id != self.id) {
                    t.sendRequestVote(node_id, req);
                }
            }
        }
    }

    /// Transition to leader state
    fn becomeLeader(self: *RaftNode) void {
        self.state = .leader;
        self.last_heartbeat = currentTimeMs();

        // Initialize peer states
        const last_index = self.getLastLogIndex();
        for (self.config.nodes) |node_id| {
            self.peer_states.put(self.allocator, node_id, PeerState{
                .next_index = last_index + 1,
                .match_index = 0,
                .vote_granted = false,
                .last_contact = currentTimeMs(),
            }) catch {};
        }

        // Append noop entry to commit entries from previous terms
        _ = self.appendEntry(.noop, &[_]u8{}) catch 0;

        // Send initial heartbeats
        self.sendHeartbeats();
    }

    /// Step down to follower
    fn stepDown(self: *RaftNode, term: Term) void {
        self.current_term = term;
        self.state = .follower;
        self.voted_for = null;
        self.resetElectionTimeout();
        self.last_heartbeat = currentTimeMs();
    }

    /// Send heartbeat/append entries to all followers
    fn sendHeartbeats(self: *RaftNode) void {
        if (self.transport == null) return;
        const t = self.transport.?;

        for (self.config.nodes) |node_id| {
            if (node_id == self.id) continue;

            const peer = self.peer_states.get(node_id) orelse continue;
            const prev_index = if (peer.next_index > 1) peer.next_index - 1 else 0;
            const prev_term = self.getTermAt(prev_index);

            // Get entries to send
            var entries: []const LogEntry = &[_]LogEntry{};
            if (peer.next_index <= self.getLastLogIndex()) {
                const start = peer.next_index;
                const end = @min(start + MAX_ENTRIES_PER_RPC, self.getLastLogIndex() + 1);
                if (start > 0 and start <= self.log.items.len) {
                    entries = self.log.items[start - 1 .. end - 1];
                }
            }

            const req = AppendEntriesRequest{
                .term = self.current_term,
                .leader_id = self.id,
                .prev_log_index = prev_index,
                .prev_log_term = prev_term,
                .entries = entries,
                .leader_commit = self.commit_index,
            };

            t.sendAppendEntries(node_id, req);
        }
    }

    /// Reset election timeout with randomization
    fn resetElectionTimeout(self: *RaftNode) void {
        self.election_timeout_ms = ELECTION_TIMEOUT_MIN_MS +
            self.random.uintLessThan(u64, ELECTION_TIMEOUT_MAX_MS - ELECTION_TIMEOUT_MIN_MS);
    }

    // -------------------------------------------------------------------------
    // RPC Handlers
    // -------------------------------------------------------------------------

    /// Handle RequestVote RPC
    pub fn handleRequestVote(self: *RaftNode, req: RequestVoteRequest) RequestVoteResponse {
        self.mutex.lock();
        defer self.mutex.unlock();

        var response = RequestVoteResponse{
            .term = self.current_term,
            .vote_granted = false,
        };

        // Reply false if term < currentTerm
        if (req.term < self.current_term) {
            return response;
        }

        // Step down if we see higher term
        if (req.term > self.current_term) {
            self.stepDown(req.term);
        }

        response.term = self.current_term;

        // Check if we can vote for this candidate
        const can_vote = (self.voted_for == null or self.voted_for.? == req.candidate_id);

        // Check if candidate's log is at least as up-to-date as ours
        const last_term = self.getLastLogTerm();
        const last_index = self.getLastLogIndex();
        const log_ok = (req.last_log_term > last_term) or
            (req.last_log_term == last_term and req.last_log_index >= last_index);

        if (can_vote and log_ok) {
            self.voted_for = req.candidate_id;
            response.vote_granted = true;
            self.last_heartbeat = currentTimeMs();

            // Persist vote
            if (self.wal_writer) |w| {
                w.writeVote(self.current_term, req.candidate_id) catch {};
            }
        }

        return response;
    }

    /// Handle RequestVote response
    pub fn handleRequestVoteResponse(self: *RaftNode, from: NodeId, resp: RequestVoteResponse) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Ignore if not candidate or term mismatch
        if (self.state != .candidate or resp.term != self.current_term) {
            if (resp.term > self.current_term) {
                self.stepDown(resp.term);
            }
            return;
        }

        // Record vote
        if (resp.vote_granted) {
            if (self.peer_states.getPtr(from)) |peer| {
                peer.vote_granted = true;
            } else {
                self.peer_states.put(self.allocator, from, PeerState{
                    .next_index = 1,
                    .match_index = 0,
                    .vote_granted = true,
                    .last_contact = currentTimeMs(),
                }) catch {};
            }

            // Count votes
            var votes: usize = 0;
            for (self.config.nodes) |node_id| {
                if (self.peer_states.get(node_id)) |peer| {
                    if (peer.vote_granted) votes += 1;
                }
            }

            // Check if we have majority
            if (votes >= self.config.quorumSize()) {
                self.becomeLeader();
            }
        }
    }

    /// Handle AppendEntries RPC
    pub fn handleAppendEntries(self: *RaftNode, req: AppendEntriesRequest) AppendEntriesResponse {
        self.mutex.lock();
        defer self.mutex.unlock();

        var response = AppendEntriesResponse{
            .term = self.current_term,
            .success = false,
        };

        // Reply false if term < currentTerm
        if (req.term < self.current_term) {
            return response;
        }

        // Step down if we see higher or equal term from leader
        if (req.term >= self.current_term) {
            if (self.state != .follower or req.term > self.current_term) {
                self.stepDown(req.term);
            }
            self.last_heartbeat = currentTimeMs();
        }

        response.term = self.current_term;

        // Check log consistency
        if (req.prev_log_index > 0) {
            if (req.prev_log_index > self.getLastLogIndex()) {
                // Log too short
                response.conflict_index = self.getLastLogIndex() + 1;
                return response;
            }

            const term_at_prev = self.getTermAt(req.prev_log_index);
            if (term_at_prev != req.prev_log_term) {
                // Term mismatch - find first entry of conflicting term
                response.conflict_term = term_at_prev;
                var i = req.prev_log_index;
                while (i > 0 and self.getTermAt(i) == term_at_prev) : (i -= 1) {}
                response.conflict_index = i + 1;
                return response;
            }
        }

        // Append entries
        for (req.entries, 0..) |entry, i| {
            const index = req.prev_log_index + 1 + i;

            if (index <= self.getLastLogIndex()) {
                // Check for conflict
                if (self.getTermAt(index) != entry.term) {
                    // Delete conflicting entries and all that follow
                    self.truncateLog(index);
                    self.appendEntryDirect(entry) catch {};
                }
            } else {
                // Append new entry
                self.appendEntryDirect(entry) catch {};
            }
        }

        // Update commit index
        if (req.leader_commit > self.commit_index) {
            self.commit_index = @min(req.leader_commit, self.getLastLogIndex());
        }

        response.success = true;
        return response;
    }

    /// Handle AppendEntries response
    pub fn handleAppendEntriesResponse(self: *RaftNode, from: NodeId, resp: AppendEntriesResponse) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.state != .leader) return;

        if (resp.term > self.current_term) {
            self.stepDown(resp.term);
            return;
        }

        if (resp.term != self.current_term) return;

        const peer = self.peer_states.getPtr(from) orelse return;

        if (resp.success) {
            // Update match_index and next_index
            const new_match = peer.next_index - 1 + MAX_ENTRIES_PER_RPC; // Approximate
            peer.match_index = @max(peer.match_index, @min(new_match, self.getLastLogIndex()));
            peer.next_index = peer.match_index + 1;
            peer.last_contact = currentTimeMs();

            // Try to advance commit index
            self.advanceCommitIndex();
        } else {
            // Log inconsistency - backtrack
            if (resp.conflict_term > 0) {
                // Find last entry of conflict term
                var i = self.getLastLogIndex();
                while (i > 0 and self.getTermAt(i) > resp.conflict_term) : (i -= 1) {}
                if (i > 0 and self.getTermAt(i) == resp.conflict_term) {
                    peer.next_index = i + 1;
                } else {
                    peer.next_index = resp.conflict_index;
                }
            } else {
                peer.next_index = resp.conflict_index;
            }
            peer.next_index = @max(1, peer.next_index);
        }
    }

    // -------------------------------------------------------------------------
    // Log Operations
    // -------------------------------------------------------------------------

    /// Get the last log index
    pub fn getLastLogIndex(self: *const RaftNode) LogIndex {
        return self.log.items.len;
    }

    /// Get the term of the last log entry
    pub fn getLastLogTerm(self: *const RaftNode) Term {
        if (self.log.items.len == 0) return 0;
        return self.log.items[self.log.items.len - 1].term;
    }

    /// Get the term at a specific log index (1-indexed)
    pub fn getTermAt(self: *const RaftNode, index: LogIndex) Term {
        if (index == 0 or index > self.log.items.len) return 0;
        return self.log.items[index - 1].term;
    }

    /// Truncate log from index onwards
    fn truncateLog(self: *RaftNode, from_index: LogIndex) void {
        if (from_index == 0 or from_index > self.log.items.len) return;

        // Free entries being removed
        for (self.log.items[from_index - 1 ..]) |*entry| {
            entry.deinit(self.allocator);
        }

        self.log.shrinkRetainingCapacity(from_index - 1);
    }

    /// Append a new entry (leader only)
    pub fn appendEntry(self: *RaftNode, cmd_type: CommandType, data: []const u8) !LogIndex {
        if (self.state != .leader) return error.NotLeader;

        const entry = LogEntry{
            .term = self.current_term,
            .index = self.getLastLogIndex() + 1,
            .command_type = cmd_type,
            .data = try self.allocator.dupe(u8, data),
        };

        try self.log.append(self.allocator, entry);

        // Persist to WAL
        if (self.wal_writer) |w| {
            const encoded = try entry.encode(self.allocator);
            defer self.allocator.free(encoded);
            try w.writeEntry(encoded);
        }

        return entry.index;
    }

    /// Append entry directly (for replication)
    fn appendEntryDirect(self: *RaftNode, entry: LogEntry) !void {
        const new_entry = LogEntry{
            .term = entry.term,
            .index = entry.index,
            .command_type = entry.command_type,
            .data = try self.allocator.dupe(u8, entry.data),
        };

        try self.log.append(self.allocator, new_entry);

        // Persist to WAL
        if (self.wal_writer) |w| {
            const encoded = try new_entry.encode(self.allocator);
            defer self.allocator.free(encoded);
            try w.writeEntry(encoded);
        }
    }

    /// Advance commit index based on match indices (leader only)
    fn advanceCommitIndex(self: *RaftNode) void {
        if (self.state != .leader) return;

        // Find the highest index replicated on majority
        var match_indices: [16]LogIndex = undefined;
        var count: usize = 0;

        for (self.config.nodes) |node_id| {
            if (node_id == self.id) {
                match_indices[count] = self.getLastLogIndex();
            } else if (self.peer_states.get(node_id)) |peer| {
                match_indices[count] = peer.match_index;
            } else {
                match_indices[count] = 0;
            }
            count += 1;
            if (count >= 16) break;
        }

        // Sort and find median
        std.mem.sort(LogIndex, match_indices[0..count], {}, std.sort.asc(LogIndex));
        const median_idx = count - self.config.quorumSize();
        const new_commit = match_indices[median_idx];

        // Only commit if entry is from current term
        if (new_commit > self.commit_index and self.getTermAt(new_commit) == self.current_term) {
            self.commit_index = new_commit;
        }
    }

    /// Apply committed entries to state machine
    fn applyCommitted(self: *RaftNode) !void {
        while (self.last_applied < self.commit_index) {
            self.last_applied += 1;
            const entry = &self.log.items[self.last_applied - 1];

            if (self.state_machine) |sm| {
                try sm.apply(entry);
            }
        }
    }

    // -------------------------------------------------------------------------
    // Client Interface
    // -------------------------------------------------------------------------

    /// Submit a command (leader only)
    pub fn submit(self: *RaftNode, cmd_type: CommandType, data: []const u8) !LogIndex {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.state != .leader) return error.NotLeader;

        return self.appendEntry(cmd_type, data);
    }

    /// Check if this node is the leader
    pub fn isLeader(self: *RaftNode) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.state == .leader;
    }

    /// Get the current leader (if known)
    pub fn getLeader(self: *RaftNode) ?NodeId {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.state == .leader) return self.id;
        // For followers, we'd need to track this from AppendEntries
        return null;
    }

    /// Get current state
    pub fn getState(self: *RaftNode) State {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.state;
    }

    /// Get current term
    pub fn getTerm(self: *RaftNode) Term {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.current_term;
    }
};

// =============================================================================
// Tests
// =============================================================================

test "raft node initialization" {
    const allocator = std.testing.allocator;

    const nodes = [_]NodeId{ 1, 2, 3 };
    const config = ClusterConfig{ .nodes = &nodes };

    var raft = RaftNode.init(allocator, 1, config);
    defer raft.deinit();

    try std.testing.expectEqual(State.follower, raft.state);
    try std.testing.expectEqual(@as(Term, 0), raft.current_term);
    try std.testing.expectEqual(@as(?NodeId, null), raft.voted_for);
}

test "log entry encode/decode" {
    const allocator = std.testing.allocator;

    const data = "key=value";
    var entry = LogEntry{
        .term = 5,
        .index = 10,
        .command_type = .set,
        .data = data,
    };

    const encoded = try entry.encode(allocator);
    defer allocator.free(encoded);

    var decoded = try LogEntry.decode(allocator, encoded);
    defer decoded.deinit(allocator);

    try std.testing.expectEqual(@as(Term, 5), decoded.term);
    try std.testing.expectEqual(@as(LogIndex, 10), decoded.index);
    try std.testing.expectEqual(CommandType.set, decoded.command_type);
    try std.testing.expectEqualStrings(data, decoded.data);
}

test "request vote encoding" {
    const req = RequestVoteRequest{
        .term = 3,
        .candidate_id = 7,
        .last_log_index = 100,
        .last_log_term = 2,
    };

    const encoded = req.encode();
    const decoded = try RequestVoteRequest.decode(&encoded);

    try std.testing.expectEqual(@as(Term, 3), decoded.term);
    try std.testing.expectEqual(@as(NodeId, 7), decoded.candidate_id);
    try std.testing.expectEqual(@as(LogIndex, 100), decoded.last_log_index);
    try std.testing.expectEqual(@as(Term, 2), decoded.last_log_term);
}

test "quorum calculation" {
    const nodes3 = [_]NodeId{ 1, 2, 3 };
    const config3 = ClusterConfig{ .nodes = &nodes3 };
    try std.testing.expectEqual(@as(usize, 2), config3.quorumSize());

    const nodes5 = [_]NodeId{ 1, 2, 3, 4, 5 };
    const config5 = ClusterConfig{ .nodes = &nodes5 };
    try std.testing.expectEqual(@as(usize, 3), config5.quorumSize());
}
