// Copyright (c) 2025 QUANTUM ENCODING LTD
// Author: Rich <rich@quantumencoding.io>
// Website: https://quantumencoding.io
//
// Licensed under the MIT License. See LICENSE file for details.

//! Batch processing module - CSV batch/parallel prompt processing

pub const types = @import("batch/types.zig");
pub const csv_parser = @import("batch/csv_parser.zig");
pub const executor = @import("batch/executor.zig");
pub const writer = @import("batch/writer.zig");

pub const BatchRequest = types.BatchRequest;
pub const BatchResult = types.BatchResult;
pub const BatchConfig = types.BatchConfig;
pub const BatchExecutor = executor.BatchExecutor;

pub const parseFile = csv_parser.parseFile;
pub const parseContent = csv_parser.parseContent;
pub const writeResults = writer.writeResults;
pub const generateOutputFilename = writer.generateOutputFilename;
