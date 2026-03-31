// Image batch processing module
// CSV-driven batch image generation with sequential execution and rate limiting

pub const types = @import("types.zig");
pub const csv_parser = @import("csv_parser.zig");
pub const executor = @import("executor.zig");
pub const writer = @import("writer.zig");

pub const ImageBatchRequest = types.ImageBatchRequest;
pub const ImageBatchResult = types.ImageBatchResult;
pub const ImageBatchConfig = types.ImageBatchConfig;
pub const ImageBatchExecutor = executor.ImageBatchExecutor;

pub const parseFile = csv_parser.parseFile;
pub const parseContent = csv_parser.parseContent;
pub const isBatchMode = csv_parser.isBatchMode;
pub const writeResults = writer.writeResults;
pub const generateOutputFilename = writer.generateOutputFilename;

test {
    @import("std").testing.refAllDecls(@This());
}
