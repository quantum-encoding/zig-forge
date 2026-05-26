//! zig_toml — full TOML 1.0.0 parser.
//!
//! See `src/toml.zig` for the threat model + lifetime contract. This file
//! is a thin re-export of the parser surface, plus a `refAllDecls` trampoline
//! so `zig build test` discovers the Tier-2 / Tier-3 tests in toml.zig.

const toml_impl = @import("toml.zig");

pub const Table = toml_impl.Table;
pub const Value = toml_impl.Value;
pub const Array = toml_impl.Array;
pub const Parser = toml_impl.Parser;
pub const ParseError = toml_impl.ParseError;
pub const DEFAULT_MAX_DEPTH = toml_impl.DEFAULT_MAX_DEPTH;
pub const parseToml = toml_impl.parseToml;

test {
    @import("std").testing.refAllDecls(toml_impl);
}
