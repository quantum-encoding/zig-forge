// Copyright (c) 2025 QUANTUM ENCODING LTD
// Licensed under the MIT License.

//! CLI handlers for structured output commands
//!
//! Commands:
//!   zig-ai structured "prompt" --schema <name> [options]
//!   zig-ai schemas list|show|path

const std = @import("std");
const types = @import("types.zig");
const schema_loader = @import("schema_loader.zig");
const providers = @import("providers/mod.zig");
const templates = @import("templates.zig");

// C file functions for Zig 0.16 compatibility
const FILE = std.c.FILE;
extern "c" fn fopen(path: [*:0]const u8, mode: [*:0]const u8) ?*FILE;
extern "c" fn fclose(stream: *FILE) c_int;
extern "c" fn fwrite(ptr: [*]const u8, size: usize, nmemb: usize, stream: *FILE) usize;
extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;

/// Run the 'structured' command
pub fn runStructured(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var config = StructuredConfig{};

    // Template options
    var template_name: ?[]const u8 = null;
    var template_params = std.StringHashMapUnmanaged([]const u8){};
    defer template_params.deinit(allocator);

    // Parse arguments
    var i: usize = 2; // Skip "zig-ai" and "structured"
    var prompt: ?[]const u8 = null;

    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            printStructuredHelp();
            return;
        } else if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--schema")) {
            i += 1;
            if (i >= args.len) {
                printErr("Error: --schema requires a value\n");
                return;
            }
            config.schema_name = args[i];
        } else if (std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--provider")) {
            i += 1;
            if (i >= args.len) {
                printErr("Error: --provider requires a value\n");
                return;
            }
            config.provider = types.Provider.fromString(args[i]) orelse {
                printErr("Error: Unknown provider '");
                printErr(args[i]);
                printErr("'. Valid: openai, claude, gemini, grok, deepseek\n");
                return;
            };
        } else if (std.mem.eql(u8, arg, "-m") or std.mem.eql(u8, arg, "--model")) {
            i += 1;
            if (i >= args.len) {
                printErr("Error: --model requires a value\n");
                return;
            }
            config.model = args[i];
        } else if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
            i += 1;
            if (i >= args.len) {
                printErr("Error: --output requires a value\n");
                return;
            }
            config.output_file = args[i];
        } else if (std.mem.eql(u8, arg, "--system")) {
            i += 1;
            if (i >= args.len) {
                printErr("Error: --system requires a value\n");
                return;
            }
            config.system_prompt = args[i];
        } else if (std.mem.eql(u8, arg, "--max-tokens")) {
            i += 1;
            if (i >= args.len) {
                printErr("Error: --max-tokens requires a value\n");
                return;
            }
            config.max_tokens = std.fmt.parseInt(u32, args[i], 10) catch {
                printErr("Error: Invalid --max-tokens value\n");
                return;
            };
        } else if (std.mem.eql(u8, arg, "--raw")) {
            config.show_raw = true;
        } else if (std.mem.eql(u8, arg, "-T") or std.mem.eql(u8, arg, "--template")) {
            i += 1;
            if (i >= args.len) {
                printErr("Error: --template requires a name\n");
                return;
            }
            template_name = args[i];
        } else if (std.mem.eql(u8, arg, "-P") or std.mem.eql(u8, arg, "--param")) {
            i += 1;
            if (i >= args.len) {
                printErr("Error: --param requires key=value\n");
                return;
            }
            if (std.mem.indexOf(u8, args[i], "=")) |eq_pos| {
                const key = args[i][0..eq_pos];
                const value = args[i][eq_pos + 1 ..];
                template_params.put(allocator, key, value) catch {
                    printErr("Error: Out of memory\n");
                    return;
                };
            } else {
                printErr("Error: --param format is key=value\n");
                return;
            }
        } else if (std.mem.eql(u8, arg, "--struct-templates")) {
            templates.listTemplates();
            return;
        } else if (arg.len > 0 and arg[0] != '-') {
            prompt = arg;
        } else {
            printErr("Error: Unknown option '");
            printErr(arg);
            printErr("'\n");
            return;
        }
    }

    // Validate required arguments
    if (prompt == null) {
        printErr("Error: Missing prompt\n");
        printStructuredHelp();
        return;
    }

    // Error if both --schema and -T provided
    if (config.schema_name != null and template_name != null) {
        printErr("Error: Cannot use both --schema and --template. Choose one.\n");
        return;
    }

    if (config.schema_name == null and template_name == null) {
        printErr("Error: --schema or --template (-T) is required\n");
        printStructuredHelp();
        return;
    }

    // Resolve schema: from template or from file
    var template_schema: ?types.Schema = null;
    defer if (template_schema) |*ts| ts.deinit();

    var template_system_prompt: ?[]u8 = null;
    defer if (template_system_prompt) |sp| allocator.free(sp);

    var file_schema: ?*const types.Schema = null;
    var loader: ?schema_loader.SchemaLoader = null;
    defer if (loader) |*l| l.deinit();

    if (template_name) |tname| {
        // Template-based schema
        const tmpl = templates.findTemplate(tname) orelse {
            printErr("Error: Unknown template '");
            printErr(tname);
            printErr("'\n");
            printErr("Use 'zig-ai struct-templates' to see available templates\n");
            return;
        };

        template_schema = templates.toSchema(allocator, tmpl) catch {
            printErr("Error: Failed to create schema from template\n");
            return;
        };

        // Build system prompt from template (interpolate params)
        const tmpl_sys = templates.buildSystemPrompt(allocator, tmpl, &template_params) catch {
            printErr("Error: Failed to build system prompt from template\n");
            return;
        };

        // Stack template system prompt with --system if both provided
        if (config.system_prompt) |existing| {
            template_system_prompt = std.fmt.allocPrint(allocator, "{s}\n\n{s}", .{ tmpl_sys, existing }) catch {
                allocator.free(tmpl_sys);
                printErr("Error: Out of memory\n");
                return;
            };
            allocator.free(tmpl_sys);
        } else {
            template_system_prompt = tmpl_sys;
        }
    } else {
        // File-based schema
        loader = schema_loader.SchemaLoader.init(allocator);

        loader.?.loadAll() catch |err| {
            printErr("Error loading schemas: ");
            printErr(@errorName(err));
            printErr("\n");
            return;
        };

        file_schema = loader.?.get(config.schema_name.?) orelse {
            printErr("Error: Schema '");
            printErr(config.schema_name.?);
            printErr("' not found\n");
            printErr("Use 'zig-ai schemas list' to see available schemas\n");
            return;
        };
    }

    const schema: *const types.Schema = if (template_schema) |*ts| ts else file_schema.?;

    // Get API key
    const env_var = config.provider.getEnvVar();
    const api_key_ptr = getenv(env_var.ptr);
    if (api_key_ptr == null) {
        printErr("Error: ");
        printErr(env_var);
        printErr(" environment variable not set\n");
        return;
    }
    const api_key = std.mem.span(api_key_ptr.?);

    // Build request — template system prompt overrides config if set
    const final_system_prompt: ?[]const u8 = if (template_system_prompt) |sp| sp else config.system_prompt;

    const request = types.StructuredRequest{
        .prompt = prompt.?,
        .schema = schema,
        .provider = config.provider,
        .model = config.model,
        .system_prompt = final_system_prompt,
        .max_tokens = config.max_tokens,
    };

    // Generate structured output
    var response = providers.generate(allocator, api_key, request) catch |err| {
        printErr("Error: ");
        printErr(switch (err) {
            types.StructuredError.InvalidApiKey => "Invalid API key",
            types.StructuredError.RateLimitExceeded => "Rate limit exceeded",
            types.StructuredError.InvalidRequest => "Invalid request",
            types.StructuredError.ServerError => "Server error",
            types.StructuredError.InvalidResponse => "Invalid response from API",
            types.StructuredError.ParseError => "Failed to parse response",
            types.StructuredError.RefusalError => "Model refused to respond",
            types.StructuredError.MaxTokensExceeded => "Max tokens exceeded",
            else => @errorName(err),
        });
        printErr("\n");
        return;
    };
    defer response.deinit();

    // Output to file if requested
    if (config.output_file) |output_path| {
        // Allocate null-terminated path
        const path_z = allocator.allocSentinel(u8, output_path.len, 0) catch {
            printErr("Error: Out of memory\n");
            return;
        };
        defer allocator.free(path_z);
        @memcpy(path_z, output_path);

        const file = fopen(path_z.ptr, "wb");
        if (file == null) {
            printErr("Error: Could not open output file '");
            printErr(output_path);
            printErr("'\n");
            return;
        }
        defer _ = fclose(file.?);

        _ = fwrite(response.json_output.ptr, 1, response.json_output.len, file.?);
        _ = fwrite("\n", 1, 1, file.?);

        printOut("Output written to: ");
        printOut(output_path);
        printOut("\n");
    } else {
        // Output to stdout
        printOut(response.json_output);
        printOut("\n");
    }

    // Show raw response if requested
    if (config.show_raw) {
        if (response.raw_response) |raw| {
            printErr("\n--- Raw Response ---\n");
            printErr(raw);
            printErr("\n");
        }
    }

    // Show usage stats
    if (response.usage) |usage| {
        var buf: [128]u8 = undefined;
        const stats = std.fmt.bufPrint(&buf, "\nTokens: {d} input, {d} output, {d} total\n", .{
            usage.input_tokens,
            usage.output_tokens,
            usage.total_tokens,
        }) catch return;
        printErr(stats);
    }
}

/// Run the 'schemas' command
pub fn runSchemas(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len < 3) {
        printSchemasHelp();
        return;
    }

    const subcommand = args[2];

    if (std.mem.eql(u8, subcommand, "list")) {
        try listSchemas(allocator);
    } else if (std.mem.eql(u8, subcommand, "show")) {
        if (args.len < 4) {
            printErr("Error: 'schemas show' requires a schema name\n");
            return;
        }
        try showSchema(allocator, args[3]);
    } else if (std.mem.eql(u8, subcommand, "path")) {
        printSchemaPaths();
    } else if (std.mem.eql(u8, subcommand, "-h") or std.mem.eql(u8, subcommand, "--help")) {
        printSchemasHelp();
    } else {
        printErr("Error: Unknown subcommand '");
        printErr(subcommand);
        printErr("'\n");
        printSchemasHelp();
    }
}

fn listSchemas(allocator: std.mem.Allocator) !void {
    var loader = schema_loader.SchemaLoader.init(allocator);
    defer loader.deinit();

    loader.loadAll() catch |err| {
        printErr("Error loading schemas: ");
        printErr(@errorName(err));
        printErr("\n");
        return;
    };

    const names = loader.listNames(allocator) catch {
        printErr("Error: Out of memory\n");
        return;
    };
    defer allocator.free(names);

    if (names.len == 0) {
        printOut("No schemas found.\n");
        printOut("Create schemas in:\n");
        printOut("  ~/.config/zig_ai/schemas/\n");
        printOut("  ./config/schemas/\n");
        return;
    }

    printOut("Available schemas:\n");
    for (names) |name| {
        printOut("  ");
        printOut(name);
        printOut("\n");
    }
}

fn showSchema(allocator: std.mem.Allocator, name: []const u8) !void {
    var loader = schema_loader.SchemaLoader.init(allocator);
    defer loader.deinit();

    loader.loadAll() catch |err| {
        printErr("Error loading schemas: ");
        printErr(@errorName(err));
        printErr("\n");
        return;
    };

    const schema = loader.get(name) orelse {
        printErr("Error: Schema '");
        printErr(name);
        printErr("' not found\n");
        return;
    };

    printOut("Schema: ");
    printOut(schema.name);
    printOut("\n");

    if (schema.description) |desc| {
        printOut("Description: ");
        printOut(desc);
        printOut("\n");
    }

    printOut("\nJSON Schema:\n");
    printOut(schema.schema_json);
    printOut("\n");
}

fn printSchemaPaths() void {
    printOut("Schema directories (in priority order):\n");
    printOut("  1. ~/.config/zig_ai/schemas/  (user schemas)\n");
    printOut("  2. ./config/schemas/          (project schemas)\n");
    printOut("\nUser schemas override project schemas with the same name.\n");
}

const StructuredConfig = struct {
    schema_name: ?[]const u8 = null,
    provider: types.Provider = .gemini,
    model: ?[]const u8 = null,
    output_file: ?[]const u8 = null,
    system_prompt: ?[]const u8 = null,
    max_tokens: u32 = 64000,
    show_raw: bool = false,
};

fn printStructuredHelp() void {
    const help =
        \\Usage: zig-ai structured "prompt" --schema <name> [options]
        \\       zig-ai structured "prompt" -T <template> [-P key=value] [options]
        \\
        \\Generate structured JSON output from AI using a schema or built-in template.
        \\
        \\Arguments:
        \\  prompt              The input prompt for the AI
        \\
        \\Schema Source (one required):
        \\  -s, --schema <name>       Schema name (from config file)
        \\  -T, --template <name>     Built-in template (includes schema + system prompt)
        \\
        \\Template Options:
        \\  -P, --param key=value     Set template parameter (repeatable)
        \\  --struct-templates         List all available templates
        \\
        \\Options:
        \\  -p, --provider <name>  Provider: openai, claude, gemini, grok, deepseek
        \\                         (default: gemini)
        \\  -m, --model <model>    Model override
        \\  -o, --output <file>    Save output to file (default: stdout)
        \\  --system <prompt>      System prompt (stacks with template's system prompt)
        \\  --max-tokens <n>       Max tokens (default: 4096)
        \\  --raw                  Also show raw API response
        \\  -h, --help             Show this help
        \\
        \\Examples:
        \\  zig-ai structured "Meeting: John and Jane, Monday 2pm" --schema meeting
        \\  zig-ai structured "Extract events" -s calendar -p openai -o events.json
        \\  zig-ai structured -T product-listing "iPhone 16 Pro Max"
        \\  zig-ai structured -T sentiment -P granularity=aspect-based "I love the design but hate the price"
        \\  zig-ai structured -T recipe -P cuisine=italian -P dietary=vegan "pasta dish"
        \\
        \\See 'zig-ai schemas list' for file schemas, 'zig-ai struct-templates' for built-in templates.
        \\
    ;
    printOut(help);
}

fn printSchemasHelp() void {
    const help =
        \\Usage: zig-ai schemas <command>
        \\
        \\Manage structured output schemas.
        \\
        \\Commands:
        \\  list              List all available schemas
        \\  show <name>       Show schema details
        \\  path              Show schema directories
        \\
        \\Schema File Format (JSON):
        \\  {
        \\    "name": "schema_name",
        \\    "description": "What this schema extracts",
        \\    "schema": {
        \\      "type": "object",
        \\      "properties": { ... },
        \\      "required": [...],
        \\      "additionalProperties": false
        \\    }
        \\  }
        \\
        \\Schema Directories:
        \\  ~/.config/zig_ai/schemas/   (user schemas, higher priority)
        \\  ./config/schemas/           (project schemas)
        \\
    ;
    printOut(help);
}

fn printOut(s: []const u8) void {
    std.debug.print("{s}", .{s});
}

fn printErr(s: []const u8) void {
    std.debug.print("{s}", .{s});
}
