// Copyright (c) 2025 QUANTUM ENCODING LTD
// Licensed under the MIT License.

//! Agent Security Module
//! Provides path validation, command validation, and sandboxing

pub const path_validator = @import("path_validator.zig");
pub const command_parser = @import("command_parser.zig");
pub const command_validator = @import("command_validator.zig");
pub const sandbox = @import("sandbox.zig");

// Re-export main types
pub const PathValidator = path_validator.PathValidator;
pub const PathError = path_validator.PathError;

pub const CommandParser = command_parser.CommandParser;
pub const ParsedCommand = command_parser.ParsedCommand;

pub const CommandValidator = command_validator.CommandValidator;
pub const CommandError = command_validator.CommandError;

pub const Sandbox = sandbox.Sandbox;
pub const SandboxConfig = sandbox.SandboxConfig;
pub const SandboxError = sandbox.SandboxError;

// Re-export defaults
pub const default_banned_patterns = sandbox.default_banned_patterns;
pub const default_allowed_commands = sandbox.default_allowed_commands;

// Utility functions
pub const globMatch = command_validator.globMatch;
pub const containsDangerousPattern = command_validator.containsDangerousPattern;
pub const canonicalizePath = path_validator.canonicalizePath;
