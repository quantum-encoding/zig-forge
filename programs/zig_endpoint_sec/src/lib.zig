//! zig_endpoint_sec: Apple EndpointSecurity client library for Zig.
//!
//! `sys` is the raw C surface (types and functions named as in the SDK).
//! Everything else is the Zig layer: `Client` owns the ES connection and the
//! Objective-C handler block, `Message` is a retain/release handle on one
//! delivered event, `Event` is the typed view of its payload and `Exec` unpacks
//! argv/envp. Fields the kernel only fills from a given message version come
//! back as optionals (`versioned`).
//!
//! Minimal client:
//!
//!     var state = State{};
//!     var client = try es.Client.init(State, &state, onMessage);
//!     defer client.deinit();
//!     try client.subscribe(&.{ .ES_EVENT_TYPE_NOTIFY_EXEC, .ES_EVENT_TYPE_AUTH_UNLINK });
//!
//!     fn onMessage(state: *State, client: es.Client, msg: es.Message) void {
//!         if (msg.exec()) |x| { ... x.target().executable().path(), x.args() ... }
//!         if (msg.isAuth()) client.respond(msg, .allow, false) catch {};
//!     }

pub const sys = @import("sys.zig");
pub const darwin = @import("darwin_kit");
pub const versioned = @import("versioned.zig");

const message = @import("message.zig");
const event = @import("event.zig");
const client = @import("client.zig");

pub const Client = client.Client;
pub const NewClientError = client.NewClientError;
pub const Error = client.Error;
pub const RespondError = client.RespondError;
pub const ClearCacheError = client.ClearCacheError;
pub const Decision = client.Decision;
pub const MutedProcesses = client.MutedProcesses;
pub const MutedPaths = client.MutedPaths;

pub const Message = message.Message;
pub const Process = message.Process;
pub const File = message.File;
pub const Thread = message.Thread;
pub const Action = message.Action;

pub const Event = event.Event;
pub const Kind = event.Kind;
pub const Exec = event.Exec;
pub const StringIterator = event.StringIterator;
pub const kindOf = event.kindOf;
pub const isAuth = event.isAuth;
pub const isNotify = event.isNotify;
pub const shortName = event.shortName;

pub const EventType = sys.es_event_type_t;
pub const AuthResult = sys.es_auth_result_t;
pub const MutePathType = sys.es_mute_path_type_t;
pub const MuteInversionType = sys.es_mute_inversion_type_t;
pub const DeadlineMissMode = sys.es_deadline_miss_mode_t;
pub const AuditToken = darwin.AuditToken;

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("anchors_test.zig");
    _ = message;
    _ = event;
    _ = client;
    _ = versioned;
}
