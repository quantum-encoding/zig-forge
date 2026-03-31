// Re-export humanize module contents
pub const Humanize = @import("humanize.zig");

pub const ByteFormat = Humanize.ByteFormat;
pub const formatBytes = Humanize.formatBytes;
pub const formatBytesOptions = Humanize.formatBytesOptions;
pub const formatDuration = Humanize.formatDuration;
pub const formatNumber = Humanize.formatNumber;
pub const ordinalSuffix = Humanize.ordinalSuffix;
pub const formatOrdinal = Humanize.formatOrdinal;
pub const formatPercentage = Humanize.formatPercentage;
pub const RelativeTimeOptions = Humanize.RelativeTimeOptions;
pub const formatRelativeTime = Humanize.formatRelativeTime;
pub const formatList = Humanize.formatList;

const std = @import("std");

test "all humanize tests" {
    std.testing.refAllDecls(Humanize);
}
