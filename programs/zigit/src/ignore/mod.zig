// .gitignore implementation. See docs/V1_1_SPEC.md.
//
// Public API:
//   * `compile(allocator, raw_line) → ?Pattern` — compiles one
//     .gitignore line. Returns null for blanks / comments.
//   * `Pattern.matches(path, is_dir) → bool` — strict glob match;
//     `*` does not cross `/`, `**` does. Pattern's `anchored` flag is
//     METADATA for the higher-level ruleset to consume — `matches`
//     itself always treats the path as the full string to match.
//
// `ruleset.zig` (cascading-file resolution) and CLI integration live
// in follow-up commits; this module is the matching primitive.

pub const pattern = @import("pattern.zig");
pub const Pattern = pattern.Pattern;
pub const Segment = pattern.Segment;
pub const Error = pattern.Error;
pub const compile = pattern.compile;
pub const matches = pattern.matches;

test {
    _ = pattern;
}
