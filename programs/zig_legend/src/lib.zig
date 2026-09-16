//! zig_legend: typed `{VARIABLE}` substitution driven by a legend.
//!
//! A legend (TOML) declares each variable's type, candidate values, defaults
//! and named scenarios. A template holds `{NAME}` placeholders, filters and
//! `{?VAR=value}…{:}…{/}` blocks. Plans decide which candidate each variant
//! takes: a scenario, a round-robin sequence, or the full matrix.

pub const diag = @import("diag.zig");
pub const template = @import("template.zig");
pub const legend = @import("legend.zig");
pub const render = @import("render.zig");
pub const plan = @import("plan.zig");

pub const Diag = diag.Diag;
pub const Template = template.Template;
pub const Legend = legend.Legend;
pub const Bindings = render.Bindings;
pub const KV = legend.KV;

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("golden_test.zig");
}
