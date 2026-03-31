// CLI handler for the image-batch command
// Parses CLI arguments, loads CSV, runs the batch executor, and writes results

const std = @import("std");
const Allocator = std.mem.Allocator;
const image_batch = @import("batch/mod.zig");
const media_types = @import("types.zig");
const storage = @import("storage.zig");

const ImageProvider = media_types.ImageProvider;
const Quality = media_types.Quality;
const Style = media_types.Style;
const MediaConfig = media_types.MediaConfig;
const Background = media_types.Background;

/// Run the image-batch command
/// Usage: zig-ai image-batch <csv-file> [options]
pub fn run(allocator: Allocator, args: []const []const u8) !void {
    // Parse CLI arguments
    var csv_file: ?[]const u8 = null;
    var config = image_batch.ImageBatchConfig{
        .input_file = undefined,
    };

    var i: usize = 2; // Skip program name and "image-batch"
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--provider")) {
            i += 1;
            if (i < args.len) {
                config.default_provider = ImageProvider.fromString(args[i]);
                if (config.default_provider == null) {
                    std.debug.print("Error: Unknown provider '{s}'\n", .{args[i]});
                    std.debug.print("Valid providers: dalle3, dalle2, gpt-image, gpt-image-15, grok-image, imagen, vertex-image, gemini-image, gemini-image-pro\n", .{});
                    return;
                }
            }
        } else if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--size")) {
            i += 1;
            if (i < args.len) config.default_size = args[i];
        } else if (std.mem.eql(u8, arg, "-q") or std.mem.eql(u8, arg, "--quality")) {
            i += 1;
            if (i < args.len) config.default_quality = Quality.fromString(args[i]);
        } else if (std.mem.eql(u8, arg, "--style")) {
            i += 1;
            if (i < args.len) config.default_style = Style.fromString(args[i]);
        } else if (std.mem.eql(u8, arg, "-a") or std.mem.eql(u8, arg, "--aspect-ratio")) {
            i += 1;
            if (i < args.len) config.default_aspect_ratio = args[i];
        } else if (std.mem.eql(u8, arg, "-t") or std.mem.eql(u8, arg, "--template")) {
            i += 1;
            if (i < args.len) config.default_template = args[i];
        } else if (std.mem.eql(u8, arg, "-n") or std.mem.eql(u8, arg, "--count")) {
            i += 1;
            if (i < args.len) {
                config.default_count = std.fmt.parseInt(u8, args[i], 10) catch 1;
            }
        } else if (std.mem.eql(u8, arg, "--fast")) {
            config.default_quality = .low;
        } else if (std.mem.eql(u8, arg, "--transparent")) {
            config.default_background = .transparent;
        } else if (std.mem.eql(u8, arg, "-d") or std.mem.eql(u8, arg, "--delay")) {
            i += 1;
            if (i < args.len) {
                config.delay_ms = std.fmt.parseInt(u64, args[i], 10) catch 2000;
            }
        } else if (std.mem.eql(u8, arg, "-r") or std.mem.eql(u8, arg, "--retry")) {
            i += 1;
            if (i < args.len) {
                config.retry_count = std.fmt.parseInt(u32, args[i], 10) catch 2;
            }
        } else if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output-dir")) {
            i += 1;
            if (i < args.len) config.output_dir = args[i];
        } else if (std.mem.eql(u8, arg, "--results")) {
            i += 1;
            if (i < args.len) config.results_file = args[i];
        } else if (std.mem.eql(u8, arg, "--dry-run")) {
            config.dry_run = true;
        } else if (std.mem.eql(u8, arg, "--start-from")) {
            i += 1;
            if (i < args.len) {
                config.start_from = std.fmt.parseInt(u32, args[i], 10) catch 1;
            }
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            printHelp();
            return;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            // Positional argument = CSV file
            if (csv_file == null) {
                csv_file = arg;
            } else {
                std.debug.print("Error: Multiple CSV files specified. Only one is supported.\n", .{});
                return;
            }
        } else {
            std.debug.print("Error: Unknown option: {s}\n", .{arg});
            printHelp();
            return;
        }
    }

    // Validate CSV file
    const input_file = csv_file orelse {
        std.debug.print("Error: No CSV file specified\n\n", .{});
        printHelp();
        return;
    };
    config.input_file = input_file;

    // Parse CSV file
    std.debug.print("Parsing CSV: {s}\n", .{input_file});
    const requests = image_batch.parseFile(allocator, input_file) catch |err| {
        std.debug.print("Error parsing CSV: {}\n", .{err});
        return;
    };
    defer {
        for (requests) |*req| req.deinit();
        allocator.free(requests);
    }

    // Detect batch vs per-prompt mode
    const file_content = storage.readFile(allocator, input_file) catch null;
    defer if (file_content) |c| allocator.free(c);
    const is_batch = if (file_content) |c| image_batch.isBatchMode(c) else true;

    // In batch mode, provider is required from CLI
    if (is_batch and config.default_provider == null) {
        std.debug.print("Error: Batch mode requires --provider flag\n", .{});
        std.debug.print("CSV has no 'provider' column, so you must specify one on the command line.\n\n", .{});
        std.debug.print("Example: zig-ai image-batch {s} --provider gpt-image-15\n", .{input_file});
        return;
    }

    // Load media config (API keys from environment)
    const media_config = MediaConfig.loadFromEnv();

    // Check that the required provider has an API key
    if (config.default_provider) |provider| {
        if (!media_config.hasProvider(provider)) {
            std.debug.print("Error: {s} not set\n", .{provider.getEnvVar()});
            std.debug.print("Set it with: export {s}=your-api-key\n", .{provider.getEnvVar()});
            return;
        }
    }

    // Print batch info
    const mode_str = if (is_batch) "batch" else "per-prompt";
    std.debug.print("\nImage Batch: {} prompts from {s}\n", .{ requests.len, input_file });
    std.debug.print("Mode: {s}\n", .{mode_str});
    if (config.default_provider) |p| {
        std.debug.print("Provider: {s}\n", .{p.getName()});
    }
    if (config.default_quality) |q| {
        std.debug.print("Quality: {s}\n", .{q.toString()});
    }
    if (config.default_size) |s| {
        std.debug.print("Size: {s}\n", .{s});
    }
    std.debug.print("Delay: {}ms, Retries: {}\n", .{ config.delay_ms, config.retry_count });
    std.debug.print("Output: {s}\n", .{config.output_dir});

    // Dry run: just show what would be generated
    if (config.dry_run) {
        std.debug.print("\n--- DRY RUN (no images will be generated) ---\n\n", .{});
        for (requests, 0..) |req, idx| {
            const provider_name = if (req.provider) |p| p.getName() else if (config.default_provider) |p| p.getName() else "???";
            const prompt_preview = if (req.prompt.len > 80) req.prompt[0..80] else req.prompt;
            std.debug.print("  {}: [{s}] \"{s}\"\n", .{ idx + 1, provider_name, prompt_preview });
        }
        std.debug.print("\n{} images would be generated.\n", .{requests.len});
        return;
    }

    std.debug.print("\n", .{});

    // Create output directory if needed
    if (!std.mem.eql(u8, config.output_dir, ".")) {
        var dir_buf: [4096]u8 = undefined;
        const dir_z = std.fmt.bufPrintZ(&dir_buf, "{s}", .{config.output_dir}) catch {
            std.debug.print("Error: Output directory path too long\n", .{});
            return;
        };
        _ = std.c.mkdir(dir_z, 0o755);
    }

    // Execute batch
    var batch_executor = image_batch.ImageBatchExecutor.init(allocator, config, media_config);
    defer batch_executor.deinit();

    try batch_executor.execute(requests);

    // Write results CSV
    const results = batch_executor.getResults();
    if (results.len > 0) {
        const results_file = config.results_file orelse blk: {
            const generated = try image_batch.generateOutputFilename(allocator);
            break :blk generated;
        };
        defer if (config.results_file == null) allocator.free(results_file);

        image_batch.writeResults(allocator, results, results_file) catch |err| {
            std.debug.print("Warning: Failed to write results CSV: {}\n", .{err});
        };
    }
}

/// Print help for the image-batch command
fn printHelp() void {
    std.debug.print(
        \\
        \\Usage: zig-ai image-batch <csv-file> [options]
        \\
        \\Generate images in batch from a CSV file. Each row is a prompt.
        \\Processes sequentially with configurable delay to respect API rate limits.
        \\
        \\CSV Format (batch mode - one provider for all rows):
        \\  prompt
        \\  a cosmic duck floating in space
        \\  quantum computer visualization
        \\
        \\CSV Format (per-prompt mode - each row has its own settings):
        \\  prompt,provider,size,quality,style,aspect_ratio,template,filename,count,background
        \\  cosmic duck,gpt-image-15,1024x1024,high,,,,cosmic,1,
        \\
        \\Options:
        \\  -p, --provider <NAME>     Image provider (required in batch mode)
        \\                            dalle3, dalle2, gpt-image, gpt-image-15,
        \\                            grok-image, imagen, vertex-image,
        \\                            gemini-image, gemini-image-pro
        \\  -s, --size <SIZE>         Default image size (e.g., 1024x1024)
        \\  -q, --quality <Q>         Default quality (standard, hd, high, medium, low)
        \\      --style <STYLE>       Default style (vivid, natural)
        \\  -a, --aspect-ratio <AR>   Default aspect ratio (1:1, 16:9, 9:16)
        \\  -t, --template <NAME>     Default prompt template (photo, cyberpunk, product...)
        \\  -n, --count <N>           Default images per prompt (default: 1)
        \\      --fast                Use low quality for faster generation
        \\      --transparent         Transparent background (GPT-Image only)
        \\  -d, --delay <MS>          Delay between requests in ms (default: 2000)
        \\  -r, --retry <N>           Max retries per request (default: 2)
        \\  -o, --output-dir <DIR>    Output directory for images (default: .)
        \\      --results <PATH>      Custom results CSV path
        \\      --dry-run             Validate CSV without generating images
        \\      --start-from <N>      Resume from row N (1-indexed, default: 1)
        \\  -h, --help                Show this help
        \\
        \\Examples:
        \\  zig-ai image-batch prompts.csv --provider gpt-image-15 --quality high
        \\  zig-ai image-batch prompts.csv --provider dalle3 --delay 3000 --retry 3
        \\  zig-ai image-batch multi.csv  (per-prompt mode, provider in CSV)
        \\  zig-ai image-batch prompts.csv --provider imagen -o ./output --dry-run
        \\  zig-ai image-batch prompts.csv --provider dalle3 --start-from 25
        \\
        \\
    , .{});
}
