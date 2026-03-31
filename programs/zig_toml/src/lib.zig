pub const toml = @import("toml.zig");
pub const Parser = toml.Parser;
pub const Value = toml.Value;
pub const parseToml = toml.parseToml;

pub const tests = struct {
    pub const toml_tests = @import("toml.zig");
};
