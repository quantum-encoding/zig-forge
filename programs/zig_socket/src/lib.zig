// Copyright (c) 2026 QUANTUM ENCODING LTD
// Contact: info@quantumencoding.io
// Website: https://quantumencoding.io
//
// Licensed under the MIT License. See LICENSE file for details.

//! zig_socket - Standalone Socket Library
//!
//! Two sub-modules:
//! - `tcp`: Raw TCP/UDP socket abstraction (cross-platform Linux/macOS/BSD)
//! - `websocket`: RFC 6455 WebSocket protocol (frame parsing, handshake, connection state)
//! - `ws_client`: WebSocket client using std.Io.Threaded

const std = @import("std");

// Sub-modules (namespaced access)
pub const tcp = @import("tcp.zig");
pub const websocket = @import("websocket.zig");
pub const ws_client = @import("client.zig");

// === TCP convenience re-exports ===
pub const socket_t = tcp.socket_t;
pub const fd_t = tcp.fd_t;
pub const AF = tcp.AF;
pub const SOCK = tcp.SOCK;
pub const IPPROTO = tcp.IPPROTO;
pub const sockaddr_in = tcp.sockaddr_in;
pub const SocketError = tcp.SocketError;

pub const createTcpSocket = tcp.createTcpSocket;
pub const createTcpSocketNonblock = tcp.createTcpSocketNonblock;
pub const close = tcp.close;
pub const connect = tcp.connect;
pub const connectFromString = tcp.connectFromString;
pub const send = tcp.send;
pub const recv = tcp.recv;
pub const recvNonblock = tcp.recvNonblock;
pub const setRecvTimeout = tcp.setRecvTimeout;
pub const setNoDelay = tcp.setNoDelay;
pub const setNonblocking = tcp.setNonblocking;

// === WebSocket convenience re-exports ===
pub const Opcode = websocket.Opcode;
pub const CloseCode = websocket.CloseCode;
pub const FrameHeader = websocket.FrameHeader;
pub const Frame = websocket.Frame;
pub const CloseFrame = websocket.CloseFrame;
pub const Handshake = websocket.Handshake;
pub const Connection = websocket.Connection;
pub const ConnectionState = websocket.ConnectionState;

// === WebSocket client re-exports ===
pub const Client = ws_client.Client;
pub const Message = ws_client.Message;

test {
    std.testing.refAllDecls(@This());
}
