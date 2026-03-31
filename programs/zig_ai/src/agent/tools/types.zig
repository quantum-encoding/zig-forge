// Copyright (c) 2025 QUANTUM ENCODING LTD
// Licensed under the MIT License.

//! Tool type definitions for the agent system
//! Compatible with AI provider tool calling formats

const std = @import("std");

pub const ToolError = error{
    ToolNotFound,
    InvalidArguments,
    ExecutionFailed,
    PathOutsideSandbox,
    PathNotWritable,
    CommandNotAllowed,
    FileTooLarge,
    Timeout,
    OutOfMemory,
};

/// Tool definition for AI providers
pub const ToolDefinition = struct {
    name: []const u8,
    description: []const u8,
    input_schema: []const u8, // JSON schema string
};

/// Result of tool execution
pub const ToolOutput = struct {
    success: bool,
    content: []const u8,
    error_message: ?[]const u8 = null,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *ToolOutput) void {
        self.allocator.free(self.content);
        if (self.error_message) |msg| {
            self.allocator.free(msg);
        }
    }

    pub fn success_result(allocator: std.mem.Allocator, content: []const u8) !ToolOutput {
        return ToolOutput{
            .success = true,
            .content = try allocator.dupe(u8, content),
            .allocator = allocator,
        };
    }

    pub fn error_result(allocator: std.mem.Allocator, message: []const u8) !ToolOutput {
        return ToolOutput{
            .success = false,
            .content = try allocator.dupe(u8, ""),
            .error_message = try allocator.dupe(u8, message),
            .allocator = allocator,
        };
    }
};

// Tool definitions for AI providers

pub const read_file_def = ToolDefinition{
    .name = "read_file",
    .description = "Read the contents of a file within the sandbox. Returns the file content as text.",
    .input_schema =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "path": {
    \\      "type": "string",
    \\      "description": "File path relative to sandbox root"
    \\    },
    \\    "offset": {
    \\      "type": "integer",
    \\      "description": "Line number to start reading from (1-based)",
    \\      "default": 1
    \\    },
    \\    "limit": {
    \\      "type": "integer",
    \\      "description": "Maximum number of lines to read",
    \\      "default": 500
    \\    }
    \\  },
    \\  "required": ["path"]
    \\}
    ,
};

pub const write_file_def = ToolDefinition{
    .name = "write_file",
    .description = "Write content to a file within the sandbox. Creates the file if it doesn't exist, overwrites if it does.",
    .input_schema =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "path": {
    \\      "type": "string",
    \\      "description": "File path relative to sandbox root"
    \\    },
    \\    "content": {
    \\      "type": "string",
    \\      "description": "Content to write to the file"
    \\    }
    \\  },
    \\  "required": ["path", "content"]
    \\}
    ,
};

pub const list_files_def = ToolDefinition{
    .name = "list_files",
    .description = "List files and directories in a path within the sandbox.",
    .input_schema =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "path": {
    \\      "type": "string",
    \\      "description": "Directory path relative to sandbox root",
    \\      "default": "."
    \\    },
    \\    "recursive": {
    \\      "type": "boolean",
    \\      "description": "List recursively",
    \\      "default": false
    \\    },
    \\    "max_depth": {
    \\      "type": "integer",
    \\      "description": "Maximum directory depth for recursive listing",
    \\      "default": 3
    \\    }
    \\  },
    \\  "required": []
    \\}
    ,
};

pub const search_files_def = ToolDefinition{
    .name = "search_files",
    .description = "Search for text patterns in files within the sandbox (like grep).",
    .input_schema =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "pattern": {
    \\      "type": "string",
    \\      "description": "Text pattern to search for"
    \\    },
    \\    "path": {
    \\      "type": "string",
    \\      "description": "Directory or file to search in",
    \\      "default": "."
    \\    },
    \\    "file_pattern": {
    \\      "type": "string",
    \\      "description": "Glob pattern for files to search (e.g., '*.zig')",
    \\      "default": "*"
    \\    },
    \\    "max_results": {
    \\      "type": "integer",
    \\      "description": "Maximum number of results to return",
    \\      "default": 50
    \\    }
    \\  },
    \\  "required": ["pattern"]
    \\}
    ,
};

pub const execute_command_def = ToolDefinition{
    .name = "execute_command",
    .description = "Execute a shell command within the sandbox. Only allowed commands can be run.",
    .input_schema =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "command": {
    \\      "type": "string",
    \\      "description": "Shell command to execute"
    \\    },
    \\    "working_dir": {
    \\      "type": "string",
    \\      "description": "Working directory (relative to sandbox root)",
    \\      "default": "."
    \\    }
    \\  },
    \\  "required": ["command"]
    \\}
    ,
};

pub const confirm_action_def = ToolDefinition{
    .name = "confirm_action",
    .description = "Request human confirmation before performing a potentially dangerous action. Use this before destructive operations like deleting files, modifying critical configs, or running risky commands. Returns 'approved' or 'denied'.",
    .input_schema =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "action": {
    \\      "type": "string",
    \\      "description": "Brief description of the action requiring confirmation"
    \\    },
    \\    "details": {
    \\      "type": "string",
    \\      "description": "Additional details about what will happen"
    \\    },
    \\    "risk_level": {
    \\      "type": "string",
    \\      "enum": ["low", "medium", "high", "critical"],
    \\      "description": "Risk level of the action",
    \\      "default": "medium"
    \\    }
    \\  },
    \\  "required": ["action"]
    \\}
    ,
};

pub const trash_file_def = ToolDefinition{
    .name = "trash_file",
    .description = "Safely delete a file by moving it to the trash/recycle bin instead of permanent deletion. The file can be recovered from trash if needed.",
    .input_schema =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "path": {
    \\      "type": "string",
    \\      "description": "File path relative to sandbox root to move to trash"
    \\    }
    \\  },
    \\  "required": ["path"]
    \\}
    ,
};

pub const grep_def = ToolDefinition{
    .name = "grep",
    .description = "Search for text patterns in files. Returns matching lines with file names and line numbers.",
    .input_schema =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "pattern": {
    \\      "type": "string",
    \\      "description": "Text pattern to search for (substring match)"
    \\    },
    \\    "path": {
    \\      "type": "string",
    \\      "description": "File or directory to search in",
    \\      "default": "."
    \\    },
    \\    "recursive": {
    \\      "type": "boolean",
    \\      "description": "Search recursively in directories",
    \\      "default": true
    \\    },
    \\    "ignore_case": {
    \\      "type": "boolean",
    \\      "description": "Case-insensitive matching",
    \\      "default": false
    \\    },
    \\    "invert_match": {
    \\      "type": "boolean",
    \\      "description": "Select non-matching lines",
    \\      "default": false
    \\    },
    \\    "context_lines": {
    \\      "type": "integer",
    \\      "description": "Number of context lines before and after match",
    \\      "default": 0
    \\    },
    \\    "max_matches": {
    \\      "type": "integer",
    \\      "description": "Maximum number of matches to return",
    \\      "default": 100
    \\    },
    \\    "include_pattern": {
    \\      "type": "string",
    \\      "description": "Only search files matching this glob pattern (e.g., '*.zig')"
    \\    }
    \\  },
    \\  "required": ["pattern"]
    \\}
    ,
};

pub const cat_def = ToolDefinition{
    .name = "cat",
    .description = "Concatenate and display file contents. Can read multiple files and show line numbers.",
    .input_schema =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "paths": {
    \\      "type": "array",
    \\      "items": {"type": "string"},
    \\      "description": "List of file paths to concatenate"
    \\    },
    \\    "number_lines": {
    \\      "type": "boolean",
    \\      "description": "Number all output lines",
    \\      "default": false
    \\    },
    \\    "number_nonblank": {
    \\      "type": "boolean",
    \\      "description": "Number non-blank lines only",
    \\      "default": false
    \\    },
    \\    "show_ends": {
    \\      "type": "boolean",
    \\      "description": "Display $ at end of each line",
    \\      "default": false
    \\    },
    \\    "squeeze_blank": {
    \\      "type": "boolean",
    \\      "description": "Suppress repeated empty lines",
    \\      "default": false
    \\    }
    \\  },
    \\  "required": ["paths"]
    \\}
    ,
};

pub const wc_def = ToolDefinition{
    .name = "wc",
    .description = "Count lines, words, and bytes in files.",
    .input_schema =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "paths": {
    \\      "type": "array",
    \\      "items": {"type": "string"},
    \\      "description": "List of file paths to count"
    \\    },
    \\    "lines": {
    \\      "type": "boolean",
    \\      "description": "Count lines",
    \\      "default": true
    \\    },
    \\    "words": {
    \\      "type": "boolean",
    \\      "description": "Count words",
    \\      "default": true
    \\    },
    \\    "bytes": {
    \\      "type": "boolean",
    \\      "description": "Count bytes",
    \\      "default": true
    \\    },
    \\    "chars": {
    \\      "type": "boolean",
    \\      "description": "Count characters (UTF-8 aware)",
    \\      "default": false
    \\    }
    \\  },
    \\  "required": ["paths"]
    \\}
    ,
};

pub const find_def = ToolDefinition{
    .name = "find",
    .description = "Find files and directories matching criteria. Returns paths of matching items.",
    .input_schema =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "path": {
    \\      "type": "string",
    \\      "description": "Starting directory for search",
    \\      "default": "."
    \\    },
    \\    "name": {
    \\      "type": "string",
    \\      "description": "Glob pattern to match file names (e.g., '*.zig')"
    \\    },
    \\    "type": {
    \\      "type": "string",
    \\      "enum": ["f", "d", "l"],
    \\      "description": "File type: f=file, d=directory, l=symlink"
    \\    },
    \\    "max_depth": {
    \\      "type": "integer",
    \\      "description": "Maximum directory depth to search",
    \\      "default": 10
    \\    },
    \\    "min_size": {
    \\      "type": "integer",
    \\      "description": "Minimum file size in bytes"
    \\    },
    \\    "max_size": {
    \\      "type": "integer",
    \\      "description": "Maximum file size in bytes"
    \\    },
    \\    "max_results": {
    \\      "type": "integer",
    \\      "description": "Maximum number of results to return",
    \\      "default": 500
    \\    }
    \\  },
    \\  "required": []
    \\}
    ,
};

pub const rm_def = ToolDefinition{
    .name = "rm",
    .description = "Remove files or directories. Requires recursive flag for directories. Has safety caps on item count and depth.",
    .input_schema =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "path": {
    \\      "type": "string",
    \\      "description": "File or directory path to remove"
    \\    },
    \\    "recursive": {
    \\      "type": "boolean",
    \\      "description": "Remove directories and their contents recursively",
    \\      "default": false
    \\    },
    \\    "force": {
    \\      "type": "boolean",
    \\      "description": "Ignore nonexistent files",
    \\      "default": false
    \\    },
    \\    "reason": {
    \\      "type": "string",
    \\      "description": "Reason for the deletion"
    \\    }
    \\  },
    \\  "required": ["path"]
    \\}
    ,
};

pub const cp_def = ToolDefinition{
    .name = "cp",
    .description = "Copy a file to a new location. Does not overwrite by default.",
    .input_schema =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "source": {
    \\      "type": "string",
    \\      "description": "Source file path"
    \\    },
    \\    "destination": {
    \\      "type": "string",
    \\      "description": "Destination file path"
    \\    },
    \\    "overwrite": {
    \\      "type": "boolean",
    \\      "description": "Overwrite destination if it exists",
    \\      "default": false
    \\    },
    \\    "reason": {
    \\      "type": "string",
    \\      "description": "Reason for the copy"
    \\    }
    \\  },
    \\  "required": ["source", "destination"]
    \\}
    ,
};

pub const mv_def = ToolDefinition{
    .name = "mv",
    .description = "Move or rename a file or directory. Falls back to copy+delete for cross-filesystem moves.",
    .input_schema =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "source": {
    \\      "type": "string",
    \\      "description": "Source file or directory path"
    \\    },
    \\    "destination": {
    \\      "type": "string",
    \\      "description": "Destination path"
    \\    },
    \\    "overwrite": {
    \\      "type": "boolean",
    \\      "description": "Overwrite destination if it exists",
    \\      "default": false
    \\    },
    \\    "reason": {
    \\      "type": "string",
    \\      "description": "Reason for the move"
    \\    }
    \\  },
    \\  "required": ["source", "destination"]
    \\}
    ,
};

pub const mkdir_def = ToolDefinition{
    .name = "mkdir",
    .description = "Create a new directory. Use parents flag to create intermediate directories.",
    .input_schema =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "path": {
    \\      "type": "string",
    \\      "description": "Directory path to create"
    \\    },
    \\    "parents": {
    \\      "type": "boolean",
    \\      "description": "Create parent directories as needed",
    \\      "default": false
    \\    },
    \\    "reason": {
    \\      "type": "string",
    \\      "description": "Reason for creating the directory"
    \\    }
    \\  },
    \\  "required": ["path"]
    \\}
    ,
};

pub const touch_def = ToolDefinition{
    .name = "touch",
    .description = "Create an empty file or update the timestamp of an existing file.",
    .input_schema =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "path": {
    \\      "type": "string",
    \\      "description": "File path to create or update"
    \\    },
    \\    "reason": {
    \\      "type": "string",
    \\      "description": "Reason for the operation"
    \\    }
    \\  },
    \\  "required": ["path"]
    \\}
    ,
};

pub const kill_process_def = ToolDefinition{
    .name = "kill_process",
    .description = "Send a signal to a process spawned by execute_command. Only processes tracked by the agent can be killed.",
    .input_schema =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "pid": {
    \\      "type": "integer",
    \\      "description": "Process ID to send signal to"
    \\    },
    \\    "signal": {
    \\      "type": "string",
    \\      "enum": ["TERM", "KILL", "INT"],
    \\      "description": "Signal to send",
    \\      "default": "TERM"
    \\    },
    \\    "kill_group": {
    \\      "type": "boolean",
    \\      "description": "Send signal to entire process group instead of just the PID",
    \\      "default": false
    \\    },
    \\    "reason": {
    \\      "type": "string",
    \\      "description": "Reason for killing the process"
    \\    }
    \\  },
    \\  "required": ["pid"]
    \\}
    ,
};

pub const plan_tasks_def = @import("plan_tasks.zig").plan_tasks_def;

/// All available tool definitions
pub const all_tools = [_]ToolDefinition{
    read_file_def,
    write_file_def,
    list_files_def,
    search_files_def,
    execute_command_def,
    confirm_action_def,
    trash_file_def,
    grep_def,
    cat_def,
    wc_def,
    find_def,
    rm_def,
    cp_def,
    mv_def,
    mkdir_def,
    touch_def,
    kill_process_def,
    plan_tasks_def,
};

/// Get tool definition by name
pub fn getToolDef(name: []const u8) ?ToolDefinition {
    for (all_tools) |tool| {
        if (std.mem.eql(u8, tool.name, name)) {
            return tool;
        }
    }
    return null;
}

/// Format tools for Claude API
pub fn formatToolsForClaude(allocator: std.mem.Allocator, enabled_tools: []const []const u8) ![]const u8 {
    var result: std.ArrayListUnmanaged(u8) = .empty;
    errdefer result.deinit(allocator);

    try result.appendSlice(allocator, "[");

    var first = true;
    for (enabled_tools) |tool_name| {
        if (getToolDef(tool_name)) |tool| {
            if (!first) {
                try result.appendSlice(allocator, ",");
            }
            first = false;

            const tool_json = try std.fmt.allocPrint(allocator,
                \\{{"name":"{s}","description":"{s}","input_schema":{s}}}
            , .{ tool.name, tool.description, tool.input_schema });
            defer allocator.free(tool_json);
            try result.appendSlice(allocator, tool_json);
        }
    }

    try result.appendSlice(allocator, "]");

    return result.toOwnedSlice(allocator);
}

/// Format tools for OpenAI API (functions format)
pub fn formatToolsForOpenAI(allocator: std.mem.Allocator, enabled_tools: []const []const u8) ![]const u8 {
    var result: std.ArrayListUnmanaged(u8) = .empty;
    errdefer result.deinit(allocator);

    try result.appendSlice(allocator, "[");

    var first = true;
    for (enabled_tools) |tool_name| {
        if (getToolDef(tool_name)) |tool| {
            if (!first) {
                try result.appendSlice(allocator, ",");
            }
            first = false;

            const tool_json = try std.fmt.allocPrint(allocator,
                \\{{"type":"function","function":{{"name":"{s}","description":"{s}","parameters":{s}}}}}
            , .{ tool.name, tool.description, tool.input_schema });
            defer allocator.free(tool_json);
            try result.appendSlice(allocator, tool_json);
        }
    }

    try result.appendSlice(allocator, "]");

    return result.toOwnedSlice(allocator);
}
