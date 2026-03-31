//! zig_websocket - RFC 6455 WebSocket Protocol Library
//!
//! A pure Zig implementation of the WebSocket protocol (RFC 6455)
//! for frame parsing, building, and handshake validation.
//!
//! Features:
//! - Frame parsing and building
//! - Masking support (client-to-server)
//! - Handshake validation (Sec-WebSocket-Key -> Sec-WebSocket-Accept)
//! - Connection state machine
//! - Message fragmentation support
//! - Close frame handling with status codes
//! - Full RFC 6455 compliance
//! - WebSocket client with TLS support

pub const websocket = @import("websocket.zig");
pub const client = @import("client.zig");

// Protocol types
pub const Opcode = websocket.Opcode;
pub const CloseCode = websocket.CloseCode;
pub const FrameHeader = websocket.FrameHeader;
pub const Frame = websocket.Frame;
pub const CloseFrame = websocket.CloseFrame;
pub const Handshake = websocket.Handshake;
pub const Connection = websocket.Connection;
pub const ConnectionState = websocket.ConnectionState;

// Client types
pub const Client = client.Client;
pub const Message = client.Message;

test {
    _ = websocket;
    _ = client;
}
