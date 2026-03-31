//! Storage Interface for JetStream Messages
//!
//! Defines the StoredMessage type and the MessageStore vtable interface.
//! Implementations (memory, file) provide the concrete storage backend.

const std = @import("std");

pub const StoredMessage = struct {
    sequence: u64,
    subject: []const u8,
    headers: ?[]const u8,
    data: []const u8,
    timestamp_ns: i64,
    raw_size: usize, // headers + data size for accounting

    /// Total size used for limit accounting.
    pub fn size(self: *const StoredMessage) usize {
        return self.raw_size;
    }
};

pub const StoreError = error{
    NotFound,
    StoreFailed,
    OutOfMemory,
};

pub const MessageStore = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        store: *const fn (ptr: *anyopaque, seq: u64, subject: []const u8, headers: ?[]const u8, data: []const u8, timestamp_ns: i64) StoreError!void,
        load: *const fn (ptr: *anyopaque, seq: u64) ?StoredMessage,
        delete: *const fn (ptr: *anyopaque, seq: u64) bool,
        purge: *const fn (ptr: *anyopaque, subject_filter: ?[]const u8) u64,
        loadBySubject: *const fn (ptr: *anyopaque, subject: []const u8) ?StoredMessage,
        bytes: *const fn (ptr: *anyopaque) u64,
        count: *const fn (ptr: *anyopaque) u64,
    };

    pub fn store(self: *const MessageStore, seq: u64, subject: []const u8, headers: ?[]const u8, data: []const u8, timestamp_ns: i64) StoreError!void {
        return self.vtable.store(self.ptr, seq, subject, headers, data, timestamp_ns);
    }

    pub fn load(self: *const MessageStore, seq: u64) ?StoredMessage {
        return self.vtable.load(self.ptr, seq);
    }

    pub fn delete(self: *const MessageStore, seq: u64) bool {
        return self.vtable.delete(self.ptr, seq);
    }

    pub fn purge(self: *const MessageStore, subject_filter: ?[]const u8) u64 {
        return self.vtable.purge(self.ptr, subject_filter);
    }

    pub fn loadBySubject(self: *const MessageStore, subject: []const u8) ?StoredMessage {
        return self.vtable.loadBySubject(self.ptr, subject);
    }

    pub fn bytes(self: *const MessageStore) u64 {
        return self.vtable.bytes(self.ptr);
    }

    pub fn count(self: *const MessageStore) u64 {
        return self.vtable.count(self.ptr);
    }
};
