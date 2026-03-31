//! Guardian Shield - eBPF-based System Security Framework
//!
//! Copyright (c) 2025 Richard Tune / Quantum Encoding Ltd
//! Author: Richard Tune
//! Contact: info@quantumencoding.io
//! Website: https://quantumencoding.io
//!
//! License: Dual License - MIT (Non-Commercial) / Commercial License
//!
//! NON-COMMERCIAL USE (MIT License):
//! Permission is hereby granted, free of charge, to any person obtaining a copy
//! of this software and associated documentation files (the "Software"), to deal
//! in the Software without restriction for NON-COMMERCIAL purposes, including
//! without limitation the rights to use, copy, modify, merge, publish, distribute,
//! sublicense, and/or sell copies of the Software for non-commercial purposes,
//! and to permit persons to whom the Software is furnished to do so, subject to
//! the following conditions:
//!
//! The above copyright notice and this permission notice shall be included in all
//! copies or substantial portions of the Software.
//!
//! THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//! IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//! FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//! AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//! LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//! OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
//! SOFTWARE.
//!
//! COMMERCIAL USE:
//! Commercial use of this software requires a separate commercial license.
//! Contact info@quantumencoding.io for commercial licensing terms.


// dbus_interface.zig - D-Bus Interface for Chronos Daemon
// Purpose: Provide secure, unprivileged access to Sovereign Clock via D-Bus
//
// D-Bus Service: org.jesternet.Chronos
// Object Path: /org/jesternet/Chronos
// Interface: org.jesternet.Chronos
//
// Methods:
//   GetTick() -> u64               - Get current tick (non-destructive)
//   NextTick() -> u64              - Increment and return next tick
//   GetPhiTimestamp(agent: String) -> String - Generate Phi timestamp
//   LogEvent(agent: String, action: String, status: String, details: String) -> String
//
// Security Model:
//   - Only chronosd daemon runs with privilege to write /var/lib/chronos/tick.dat
//   - All clients (chronos-ctl, agents) make unprivileged D-Bus calls
//   - D-Bus policy enforces access control

const std = @import("std");

/// D-Bus service configuration
pub const DBUS_SERVICE = "org.jesternet.Chronos";
pub const DBUS_PATH = "/org/jesternet/Chronos";
pub const DBUS_INTERFACE = "org.jesternet.Chronos";

/// D-Bus introspection XML
pub const INTROSPECTION_XML =
    \\<!DOCTYPE node PUBLIC "-//freedesktop//DTD D-BUS Object Introspection 1.0//EN"
    \\ "http://www.freedesktop.org/standards/dbus/1.0/introspect.dtd">
    \\<node>
    \\  <interface name="org.jesternet.Chronos">
    \\    <method name="GetTick">
    \\      <arg direction="out" type="t" name="tick"/>
    \\    </method>
    \\    <method name="NextTick">
    \\      <arg direction="out" type="t" name="tick"/>
    \\    </method>
    \\    <method name="GetPhiTimestamp">
    \\      <arg direction="in" type="s" name="agent_id"/>
    \\      <arg direction="out" type="s" name="timestamp"/>
    \\    </method>
    \\    <method name="LogEvent">
    \\      <arg direction="in" type="s" name="agent_id"/>
    \\      <arg direction="in" type="s" name="action"/>
    \\      <arg direction="in" type="s" name="status"/>
    \\      <arg direction="in" type="s" name="details"/>
    \\      <arg direction="out" type="s" name="log_json"/>
    \\    </method>
    \\    <method name="Shutdown"/>
    \\  </interface>
    \\  <interface name="org.freedesktop.DBus.Introspectable">
    \\    <method name="Introspect">
    \\      <arg direction="out" type="s" name="xml"/>
    \\    </method>
    \\  </interface>
    \\</node>
;

/// D-Bus error messages
pub const Error = error{
    DBusConnectionFailed,
    DBusRequestNameFailed,
    DBusMessageAllocationFailed,
    DBusMethodCallFailed,
    DBusArgumentParsingFailed,
};
