// blame — line-level attribution against the commit graph.
//
// See docs/BLAME_SPEC.md for the full design. Public API:
//   * `blameFile(allocator, repo, ref_oid, path, opts) → BlameResult`
//   * `BlameLine`, `BlameMetrics`, `BlameResult`, `BlameError`,
//     `BlameOptions`.
// Internals (region tracking, diff splitting) live in `region.zig`.

pub const region = @import("region.zig");
pub const Region = region.Region;

const blame = @import("blame.zig");
pub const blameFile = blame.blameFile;
pub const BlameLine = blame.BlameLine;
pub const BlameMetrics = blame.BlameMetrics;
pub const BlameResult = blame.BlameResult;
pub const BlameError = blame.BlameError;
pub const BlameOptions = blame.BlameOptions;

pub const format = @import("format.zig");
pub const writePorcelain = format.writePorcelain;
pub const writeHuman = format.writeHuman;

test {
    _ = region;
    _ = blame;
    _ = format;
}
