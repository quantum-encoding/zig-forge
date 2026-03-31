// Media CLI - Command-line interface for image and video generation

const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("types.zig");
const storage = @import("storage.zig");
const providers = @import("providers/mod.zig");
const templates = @import("templates.zig");

const ImageProvider = types.ImageProvider;
const ImageRequest = types.ImageRequest;
const VideoProvider = types.VideoProvider;
const VideoRequest = types.VideoRequest;
const MusicProvider = types.MusicProvider;
const MusicRequest = types.MusicRequest;
const MediaConfig = types.MediaConfig;
const Quality = types.Quality;
const Style = types.Style;

/// Run media generation based on command line arguments
/// Returns true if a media command was handled
pub fn run(allocator: Allocator, args: []const []const u8) !bool {
    if (args.len < 2) return false;

    const command = args[1];

    // Check if this is a music command
    if (MusicProvider.fromString(command)) |music_provider| {
        return runMusic(allocator, args, music_provider);
    }

    // Check if this is a video command
    if (VideoProvider.fromString(command)) |video_provider| {
        return runVideo(allocator, args, video_provider);
    }

    // Check if this is a logo command (preset template)
    if (std.mem.eql(u8, command, "logo")) {
        return runLogo(allocator, args);
    }

    // Check if this is an edit command
    if (std.mem.eql(u8, command, "edit")) {
        return runEdit(allocator, args);
    }

    // Check if this is an image command
    const provider = ImageProvider.fromString(command) orelse return false;

    // Parse arguments
    var prompt: ?[]const u8 = null;
    var count: u8 = 1;
    var size: ?[]const u8 = null;
    var aspect_ratio: ?[]const u8 = null;
    var quality: ?Quality = null;
    var style: ?Style = null;
    var output_path: ?[]const u8 = null;
    var template_name: ?[]const u8 = null;
    var background: ?types.Background = null;

    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "-n") or std.mem.eql(u8, arg, "--count")) {
            i += 1;
            if (i < args.len) {
                count = std.fmt.parseInt(u8, args[i], 10) catch 1;
            }
        } else if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--size")) {
            i += 1;
            if (i < args.len) {
                size = args[i];
            }
        } else if (std.mem.eql(u8, arg, "-a") or std.mem.eql(u8, arg, "--aspect-ratio")) {
            i += 1;
            if (i < args.len) {
                aspect_ratio = args[i];
            }
        } else if (std.mem.eql(u8, arg, "-q") or std.mem.eql(u8, arg, "--quality")) {
            i += 1;
            if (i < args.len) {
                quality = Quality.fromString(args[i]);
            }
        } else if (std.mem.eql(u8, arg, "--style")) {
            i += 1;
            if (i < args.len) {
                style = Style.fromString(args[i]);
            }
        } else if (std.mem.eql(u8, arg, "-t") or std.mem.eql(u8, arg, "--template")) {
            i += 1;
            if (i < args.len) {
                template_name = args[i];
            }
        } else if (std.mem.eql(u8, arg, "--templates")) {
            printTemplateList();
            return true;
        } else if (std.mem.eql(u8, arg, "--fast")) {
            quality = .low;
        } else if (std.mem.eql(u8, arg, "--transparent")) {
            background = .transparent;
        } else if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
            i += 1;
            if (i < args.len) {
                output_path = args[i];
            }
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            printMediaHelp(command);
            return true;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            // Positional argument = prompt
            prompt = arg;
        }
    }

    if (prompt == null) {
        std.debug.print("Error: No prompt provided\n\nUsage: zig-ai {s} \"your prompt\" [options]\n", .{command});
        return true;
    }

    // Apply template if specified
    var final_prompt: []const u8 = prompt.?;
    var templated_prompt: ?[]u8 = null;
    if (template_name) |tname| {
        if (templates.findTemplate(tname)) |tmpl| {
            templated_prompt = templates.buildTemplatedPrompt(allocator, tmpl, prompt.?) catch null;
            if (templated_prompt) |tp| {
                final_prompt = tp;
                std.debug.print("\x1b[90mTemplate: {s} ({s})\x1b[0m\n", .{ tmpl.name, tmpl.description });
            }
        } else {
            std.debug.print("Error: Unknown template '{s}'\n", .{tname});
            std.debug.print("Run 'zig-ai <provider> --templates' to see available templates.\n", .{});
            return true;
        }
    }
    defer if (templated_prompt) |tp| allocator.free(tp);

    // Load config and check API key
    const config = MediaConfig.loadFromEnv();
    if (!config.hasProvider(provider)) {
        std.debug.print("Error: {s} not set\n", .{provider.getEnvVar()});
        std.debug.print("Set it with: export {s}=your-api-key\n", .{provider.getEnvVar()});
        return true;
    }

    // Build request
    const request = ImageRequest{
        .prompt = final_prompt,
        .provider = provider,
        .count = count,
        .size = size,
        .aspect_ratio = aspect_ratio,
        .quality = quality,
        .style = style,
        .output_path = output_path,
        .background = background,
    };

    // Generate image
    std.debug.print("\x1b[36m⚡\x1b[0m Generating image with {s}...\n", .{provider.getName()});

    var response = providers.generateImage(allocator, request, config) catch |err| {
        std.debug.print("\x1b[31m✗\x1b[0m Generation failed: {any}\n", .{err});
        return true;
    };
    defer response.deinit();

    // Print results
    printSavedPaths(&response);

    std.debug.print("\n\x1b[90mJob ID: {s}\x1b[0m\n", .{response.job_id});
    std.debug.print("\x1b[90mTime: {d}ms\x1b[0m\n", .{response.processing_time_ms});

    if (response.revised_prompt) |rp| {
        std.debug.print("\x1b[90mRevised prompt: {s}\x1b[0m\n", .{rp});
    }

    return true;
}

/// Run video generation
fn runVideo(allocator: Allocator, args: []const []const u8, provider: VideoProvider) !bool {
    const command = args[1];

    // Parse arguments
    var prompt: ?[]const u8 = null;
    var duration: ?u8 = null;
    var size: ?[]const u8 = null;
    var aspect_ratio: ?[]const u8 = null;
    var resolution: ?[]const u8 = null;
    var model: ?[]const u8 = null;
    var output_path: ?[]const u8 = null;

    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "-d") or std.mem.eql(u8, arg, "--duration")) {
            i += 1;
            if (i < args.len) {
                duration = std.fmt.parseInt(u8, args[i], 10) catch null;
            }
        } else if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--size")) {
            i += 1;
            if (i < args.len) {
                size = args[i];
            }
        } else if (std.mem.eql(u8, arg, "-a") or std.mem.eql(u8, arg, "--aspect-ratio")) {
            i += 1;
            if (i < args.len) {
                aspect_ratio = args[i];
            }
        } else if (std.mem.eql(u8, arg, "-r") or std.mem.eql(u8, arg, "--resolution")) {
            i += 1;
            if (i < args.len) {
                resolution = args[i];
            }
        } else if (std.mem.eql(u8, arg, "-m") or std.mem.eql(u8, arg, "--model")) {
            i += 1;
            if (i < args.len) {
                model = args[i];
            }
        } else if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
            i += 1;
            if (i < args.len) {
                output_path = args[i];
            }
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            printVideoHelp(command);
            return true;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            prompt = arg;
        }
    }

    if (prompt == null) {
        std.debug.print("Error: No prompt provided\n\nUsage: zig-ai {s} \"your prompt\" [options]\n", .{command});
        return true;
    }

    // Load config and check API key
    const config = MediaConfig.loadFromEnv();
    if (!config.hasVideoProvider(provider)) {
        std.debug.print("Error: {s} not set\n", .{provider.getEnvVar()});
        std.debug.print("Set it with: export {s}=your-api-key\n", .{provider.getEnvVar()});
        return true;
    }

    // Build request
    const request = VideoRequest{
        .prompt = prompt.?,
        .provider = provider,
        .model = model,
        .duration = duration,
        .size = size,
        .aspect_ratio = aspect_ratio,
        .resolution = resolution,
        .output_path = output_path,
    };

    // Generate video
    std.debug.print("\x1b[36m📹\x1b[0m Generating video with {s}...\n", .{provider.getName()});

    var response = providers.generateVideo(allocator, request, config) catch |err| {
        std.debug.print("\x1b[31m✗\x1b[0m Generation failed: {any}\n", .{err});
        return true;
    };
    defer response.deinit();

    // Print results
    printSavedVideos(&response);

    std.debug.print("\n\x1b[90mJob ID: {s}\x1b[0m\n", .{response.job_id});
    std.debug.print("\x1b[90mTime: {d}ms\x1b[0m\n", .{response.processing_time_ms});

    return true;
}

/// Run music generation
fn runMusic(allocator: Allocator, args: []const []const u8, provider: MusicProvider) !bool {
    const command = args[1];

    // Parse arguments
    var prompt: ?[]const u8 = null;
    var duration: u32 = 30;
    var count: u8 = 1;
    var bpm: ?u16 = null;
    var seed: ?u64 = null;
    var negative_prompt: ?[]const u8 = null;
    var output_path: ?[]const u8 = null;

    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "-d") or std.mem.eql(u8, arg, "--duration")) {
            i += 1;
            if (i < args.len) {
                duration = std.fmt.parseInt(u32, args[i], 10) catch 30;
            }
        } else if (std.mem.eql(u8, arg, "-n") or std.mem.eql(u8, arg, "--count")) {
            i += 1;
            if (i < args.len) {
                count = std.fmt.parseInt(u8, args[i], 10) catch 1;
            }
        } else if (std.mem.eql(u8, arg, "--bpm")) {
            i += 1;
            if (i < args.len) {
                bpm = std.fmt.parseInt(u16, args[i], 10) catch null;
            }
        } else if (std.mem.eql(u8, arg, "--seed")) {
            i += 1;
            if (i < args.len) {
                seed = std.fmt.parseInt(u64, args[i], 10) catch null;
            }
        } else if (std.mem.eql(u8, arg, "--negative") or std.mem.eql(u8, arg, "--neg")) {
            i += 1;
            if (i < args.len) {
                negative_prompt = args[i];
            }
        } else if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
            i += 1;
            if (i < args.len) {
                output_path = args[i];
            }
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            printMusicHelp(command);
            return true;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            prompt = arg;
        }
    }

    if (prompt == null) {
        std.debug.print("Error: No prompt provided\n\nUsage: zig-ai {s} \"your prompt\" [options]\n", .{command});
        return true;
    }

    // Load config and check API key
    const config = MediaConfig.loadFromEnv();
    if (!config.hasMusicProvider(provider)) {
        std.debug.print("Error: {s} not set\n", .{provider.getEnvVar()});
        std.debug.print("Set it with: export {s}=your-api-key\n", .{provider.getEnvVar()});
        return true;
    }

    // Build request
    const request = MusicRequest{
        .prompt = prompt.?,
        .provider = provider,
        .count = count,
        .duration_seconds = duration,
        .bpm = bpm,
        .seed = seed,
        .negative_prompt = negative_prompt,
        .output_path = output_path,
    };

    // Generate music
    std.debug.print("\x1b[36m🎵\x1b[0m Generating music with {s}...\n", .{provider.getName()});

    var response = providers.generateMusic(allocator, request, config) catch |err| {
        std.debug.print("\x1b[31m✗\x1b[0m Generation failed: {any}\n", .{err});
        return true;
    };
    defer response.deinit();

    // Print results
    printSavedMusic(&response);

    std.debug.print("\n\x1b[90mJob ID: {s}\x1b[0m\n", .{response.job_id});
    std.debug.print("\x1b[90mTime: {d}ms\x1b[0m\n", .{response.processing_time_ms});
    if (response.bpm) |b| {
        std.debug.print("\x1b[90mBPM: {d}\x1b[0m\n", .{b});
    }

    return true;
}

/// Run logo generation (preset template for gpt-image-1/1.5)
fn runLogo(allocator: Allocator, args: []const []const u8) !bool {
    var description: ?[]const u8 = null;
    var count: u8 = 4; // Default: 4 variations for logos
    var size: ?[]const u8 = null;
    var feel: []const u8 = "clean, professional, and memorable";
    var background: []const u8 = "plain white";
    var extra: []const u8 = "";
    var output_path: ?[]const u8 = null;
    var use_v1: bool = false;

    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "-n") or std.mem.eql(u8, arg, "--count")) {
            i += 1;
            if (i < args.len) {
                count = std.fmt.parseInt(u8, args[i], 10) catch 4;
            }
        } else if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--size")) {
            i += 1;
            if (i < args.len) {
                size = args[i];
            }
        } else if (std.mem.eql(u8, arg, "--feel")) {
            i += 1;
            if (i < args.len) {
                feel = args[i];
            }
        } else if (std.mem.eql(u8, arg, "--bg") or std.mem.eql(u8, arg, "--background")) {
            i += 1;
            if (i < args.len) {
                background = args[i];
            }
        } else if (std.mem.eql(u8, arg, "--extra")) {
            i += 1;
            if (i < args.len) {
                extra = args[i];
            }
        } else if (std.mem.eql(u8, arg, "--model")) {
            i += 1;
            if (i < args.len) {
                if (std.mem.eql(u8, args[i], "gpt-image") or std.mem.eql(u8, args[i], "gpt-image-1")) {
                    use_v1 = true;
                }
            }
        } else if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
            i += 1;
            if (i < args.len) {
                output_path = args[i];
            }
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            printLogoHelp();
            return true;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            description = arg;
        }
    }

    if (description == null) {
        std.debug.print(
            \\Error: No brand description provided
            \\
            \\Usage: zig-ai logo "Company Name, a brief description" [options]
            \\
            \\Run 'zig-ai logo --help' for full options.
            \\
        , .{});
        return true;
    }

    // Load config and check API key
    const config = MediaConfig.loadFromEnv();
    if (config.openai_api_key == null) {
        std.debug.print("Error: OPENAI_API_KEY not set\n", .{});
        std.debug.print("Set it with: export OPENAI_API_KEY=your-api-key\n", .{});
        return true;
    }

    // Build logo prompt from template
    const logo_prompt = templates.buildLogoPrompt(allocator, .{
        .description = description.?,
        .feel = feel,
        .background = background,
        .extra = extra,
    }) catch {
        std.debug.print("Error: Failed to build logo prompt\n", .{});
        return true;
    };
    defer allocator.free(logo_prompt);

    const provider: types.ImageProvider = if (use_v1) .gpt_image else .gpt_image_15;
    const model_name = if (use_v1) "GPT-Image 1" else "GPT-Image 1.5";

    // Build request
    const request = ImageRequest{
        .prompt = logo_prompt,
        .provider = provider,
        .count = count,
        .size = size orelse "1024x1024",
        .quality = .auto,
        .output_path = output_path,
    };

    // Generate
    std.debug.print("\x1b[36m⚡\x1b[0m Generating {d} logo variation(s) with {s}...\n", .{ count, model_name });
    std.debug.print("\x1b[90mBrand: {s}\x1b[0m\n", .{description.?});
    std.debug.print("\x1b[90mFeel: {s}\x1b[0m\n", .{feel});

    var response = providers.generateImage(allocator, request, config) catch |err| {
        std.debug.print("\x1b[31m✗\x1b[0m Logo generation failed: {any}\n", .{err});
        return true;
    };
    defer response.deinit();

    // Print results
    printSavedPaths(&response);

    std.debug.print("\n\x1b[90mJob ID: {s}\x1b[0m\n", .{response.job_id});
    std.debug.print("\x1b[90mTime: {d}ms\x1b[0m\n", .{response.processing_time_ms});

    if (response.revised_prompt) |rp| {
        std.debug.print("\x1b[90mRevised prompt: {s}\x1b[0m\n", .{rp});
    }

    return true;
}

/// Run image editing
fn runEdit(allocator: Allocator, args: []const []const u8) !bool {
    var prompt: ?[]const u8 = null;
    var count: u8 = 1;
    var size: ?[]const u8 = null;
    var quality: ?Quality = null;
    var fidelity: ?types.InputFidelity = null;
    var background: ?types.Background = null;
    var output_path: ?[]const u8 = null;
    var template_name: ?[]const u8 = null;
    var edit_provider: types.EditProvider = .gpt_image;

    // Collect image paths (files with image extensions)
    var image_paths: std.ArrayListUnmanaged([]const u8) = .empty;
    defer image_paths.deinit(allocator);

    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "-n") or std.mem.eql(u8, arg, "--count")) {
            i += 1;
            if (i < args.len) {
                count = std.fmt.parseInt(u8, args[i], 10) catch 1;
            }
        } else if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--size")) {
            i += 1;
            if (i < args.len) {
                size = args[i];
            }
        } else if (std.mem.eql(u8, arg, "-q") or std.mem.eql(u8, arg, "--quality")) {
            i += 1;
            if (i < args.len) {
                quality = Quality.fromString(args[i]);
            }
        } else if (std.mem.eql(u8, arg, "--fidelity")) {
            i += 1;
            if (i < args.len) {
                if (std.mem.eql(u8, args[i], "high")) {
                    fidelity = .high;
                } else {
                    fidelity = .low;
                }
            }
        } else if (std.mem.eql(u8, arg, "--provider") or std.mem.eql(u8, arg, "-p")) {
            i += 1;
            if (i < args.len) {
                if (std.mem.eql(u8, args[i], "grok")) {
                    edit_provider = .grok;
                } else if (std.mem.eql(u8, args[i], "openai") or std.mem.eql(u8, args[i], "gpt-image")) {
                    edit_provider = .gpt_image;
                }
            }
        } else if (std.mem.eql(u8, arg, "--fast")) {
            quality = .low;
        } else if (std.mem.eql(u8, arg, "--transparent")) {
            background = .transparent;
        } else if (std.mem.eql(u8, arg, "-t") or std.mem.eql(u8, arg, "--template")) {
            i += 1;
            if (i < args.len) {
                template_name = args[i];
            }
        } else if (std.mem.eql(u8, arg, "--templates")) {
            printEditTemplateList();
            return true;
        } else if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
            i += 1;
            if (i < args.len) {
                output_path = args[i];
            }
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            printEditHelp();
            return true;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            // Check if it looks like an image file
            if (isImagePath(arg)) {
                try image_paths.append(allocator, arg);
            } else {
                // Must be the prompt
                prompt = arg;
            }
        }
    }

    if (image_paths.items.len == 0) {
        std.debug.print("Error: No input images provided\n\nUsage: zig-ai edit <image1> [image2...] \"prompt\" [options]\n", .{});
        std.debug.print("Run 'zig-ai edit --help' for full options.\n", .{});
        return true;
    }

    if (prompt == null) {
        std.debug.print("Error: No prompt provided\n\nUsage: zig-ai edit <image1> [image2...] \"prompt\" [options]\n", .{});
        return true;
    }

    // Apply edit template if specified
    var final_prompt: []const u8 = prompt.?;
    var templated_prompt: ?[]u8 = null;
    if (template_name) |tname| {
        if (templates.findEditTemplate(tname)) |tmpl| {
            templated_prompt = templates.buildEditPrompt(allocator, tmpl, prompt.?) catch null;
            if (templated_prompt) |tp| {
                final_prompt = tp;
                std.debug.print("\x1b[90mEdit template: {s} ({s})\x1b[0m\n", .{ tmpl.name, tmpl.description });
            }
        } else {
            std.debug.print("Error: Unknown edit template '{s}'\n", .{tname});
            std.debug.print("Run 'zig-ai edit --templates' to see available edit templates.\n", .{});
            return true;
        }
    }
    defer if (templated_prompt) |tp| allocator.free(tp);

    // Load config and check API key
    const config = MediaConfig.loadFromEnv();
    const env_var = edit_provider.getEnvVar();
    const has_key = switch (edit_provider) {
        .gpt_image => config.openai_api_key != null,
        .grok => config.xai_api_key != null,
        .gemini_flash, .gemini_pro => config.genai_api_key != null,
    };
    if (!has_key) {
        std.debug.print("Error: {s} not set\n", .{env_var});
        std.debug.print("Set it with: export {s}=your-api-key\n", .{env_var});
        return true;
    }

    // Build request
    const request = types.EditRequest{
        .prompt = final_prompt,
        .image_paths = image_paths.items,
        .provider = edit_provider,
        .count = count,
        .size = size,
        .quality = quality,
        .input_fidelity = fidelity,
        .background = background,
        .output_path = output_path,
    };

    // Edit image
    std.debug.print("\x1b[36m⚡\x1b[0m Editing {d} image(s) with {s}...\n", .{ image_paths.items.len, edit_provider.getName() });

    var response = providers.editImage(allocator, request, config) catch |err| {
        std.debug.print("\x1b[31m✗\x1b[0m Edit failed: {any}\n", .{err});
        return true;
    };
    defer response.deinit();

    // Print results
    printSavedPaths(&response);

    std.debug.print("\n\x1b[90mJob ID: {s}\x1b[0m\n", .{response.job_id});
    std.debug.print("\x1b[90mTime: {d}ms\x1b[0m\n", .{response.processing_time_ms});

    if (response.revised_prompt) |rp| {
        std.debug.print("\x1b[90mRevised prompt: {s}\x1b[0m\n", .{rp});
    }

    return true;
}

/// Check if a path looks like an image file
fn isImagePath(path: []const u8) bool {
    const extensions = [_][]const u8{ ".png", ".jpg", ".jpeg", ".webp", ".gif", ".bmp" };
    for (extensions) |ext| {
        if (std.mem.endsWith(u8, path, ext)) return true;
    }
    return false;
}

/// Print saved paths to stderr (using debug.print)
fn printSavedPaths(response: *const types.ImageResponse) void {
    std.debug.print("\n\x1b[32m✓\x1b[0m Saved {d} image(s):\n", .{response.images.len});
    for (response.images) |img| {
        const size = storage.formatSize(img.data.len);
        std.debug.print("  → {s} ({d:.1} {s})\n", .{ img.local_path, size.value, size.unit });
    }
}

/// Print saved video paths
fn printSavedVideos(response: *const types.VideoResponse) void {
    std.debug.print("\n\x1b[32m✓\x1b[0m Saved {d} video(s):\n", .{response.videos.len});
    for (response.videos) |vid| {
        const size = storage.formatSize(vid.data.len);
        std.debug.print("  → {s} ({d:.1} {s})\n", .{ vid.local_path, size.value, size.unit });
    }
}

/// Print saved music paths
fn printSavedMusic(response: *const types.MusicResponse) void {
    std.debug.print("\n\x1b[32m✓\x1b[0m Saved {d} audio track(s):\n", .{response.tracks.len});
    for (response.tracks) |track| {
        const size = storage.formatSize(track.data.len);
        std.debug.print("  → {s} ({d:.1} {s})\n", .{ track.local_path, size.value, size.unit });
    }
}

/// Print help for image commands
fn printMediaHelp(command: []const u8) void {
    std.debug.print(
        \\
        \\Usage: zig-ai {0s} "prompt" [options]
        \\
        \\Generate images using AI
        \\
        \\Options:
        \\  -n, --count <N>         Number of images (1-10, default: 1)
        \\  -s, --size <SIZE>       Image size (e.g., 1024x1024, 1792x1024)
        \\  -a, --aspect-ratio <AR> Aspect ratio (e.g., 1:1, 16:9, 9:16)
        \\  -q, --quality <Q>       Quality (standard, hd, high, medium, low)
        \\      --style <STYLE>     Style (vivid, natural) - DALL-E 3 only
        \\      --fast              Use low quality for faster generation
        \\      --transparent       Transparent background (GPT-Image only)
        \\  -t, --template <NAME>   Apply prompt template (e.g., photo, cyberpunk, product)
        \\      --templates         List all available templates
        \\  -o, --output <PATH>     Custom output path
        \\  -h, --help              Show this help
        \\
        \\Examples:
        \\  zig-ai {0s} "a cosmic duck in space"
        \\  zig-ai {0s} "quantum computer" -n 4 -s 1024x1024
        \\  zig-ai {0s} "sunset over mountains" --quality hd --style vivid
        \\  zig-ai {0s} "a pair of running shoes" -t product
        \\  zig-ai {0s} "neon city at night" -t cyberpunk -n 4
        \\  zig-ai {0s} "product on white" --transparent --fast
        \\
        \\
    , .{command});
}

/// Print all available templates grouped by category
fn printTemplateList() void {
    std.debug.print(
        \\
        \\Available Prompt Templates (-t / --template):
        \\
    , .{});

    const categories = [_]templates.Category{
        .photography, .digital_art, .themed, .business,
        .construction, .food, .artistic,
    };

    for (categories) |cat| {
        std.debug.print("\n  \x1b[1m{s}\x1b[0m\n", .{cat.getName()});
        for (&templates.all_templates) |t| {
            if (t.category == cat) {
                std.debug.print("    {s: <14} {s}\n", .{ t.name, t.description });
            }
        }
    }

    std.debug.print(
        \\
        \\Usage: zig-ai <provider> "your prompt" -t <template>
        \\  e.g., zig-ai gpt-image-15 "a sunset" -t landscape
        \\
        \\
    , .{});
}

/// Print all available edit templates
fn printEditTemplateList() void {
    std.debug.print(
        \\
        \\Available Edit Templates (-t / --template):
        \\
    , .{});

    for (&templates.edit_templates) |t| {
        std.debug.print("  {s: <16} {s}\n", .{ t.name, t.description });
    }

    std.debug.print(
        \\
        \\Usage: zig-ai edit <image> "prompt" -t <template>
        \\  e.g., zig-ai edit photo.png "make it snowy" -t weather-change
        \\
        \\
    , .{});
}

/// Print help for edit command
fn printEditHelp() void {
    std.debug.print(
        \\
        \\Usage: zig-ai edit <image1> [image2...] "prompt" [options]
        \\
        \\Edit images using GPT-Image 1.5 or Grok Imagine Image
        \\
        \\Providers:
        \\  openai (default)        GPT-Image 1.5 — supports 1-16 input images
        \\  grok                    Grok Imagine Image — single input image
        \\
        \\Options:
        \\  -p, --provider <NAME>   Provider: openai (default) or grok
        \\  -n, --count <N>         Number of output images (default: 1)
        \\  -s, --size <SIZE>       Output size (1024x1024, 1024x1536, 1536x1024)
        \\  -q, --quality <Q>       Quality (auto, low, medium, high)
        \\      --fidelity <F>      Input fidelity: low (default) or high (OpenAI only)
        \\      --fast              Use low quality for faster generation
        \\      --transparent       Transparent background output (OpenAI only)
        \\  -t, --template <NAME>   Apply edit template
        \\      --templates         List all edit templates
        \\  -o, --output <PATH>     Custom output path
        \\  -h, --help              Show this help
        \\
        \\Edit Templates:
        \\  style-transfer          Apply source image style to new content
        \\  try-on                  Virtual try-on (person + clothing images)
        \\  sketch-render           Convert sketch/drawing to photo
        \\  bg-remove               Remove background from product
        \\  weather-change          Change weather/lighting conditions
        \\  object-remove           Remove object from image
        \\
        \\Examples:
        \\  zig-ai edit photo.png "make the sky dramatic and stormy"
        \\  zig-ai edit photo.png "make it winter" -t weather-change --fidelity high
        \\  zig-ai edit photo.png "add snow" --provider grok
        \\  zig-ai edit person.png shirt.png "dress in this outfit" -t try-on
        \\  zig-ai edit product.png "clean product shot" -t bg-remove --transparent
        \\  zig-ai edit sketch.png "render this" -t sketch-render -n 4
        \\  zig-ai edit room.png "remove the plant" -t object-remove
        \\
        \\
    , .{});
}

/// Print help for logo command
fn printLogoHelp() void {
    std.debug.print(
        \\
        \\Usage: zig-ai logo "Brand Name, a brief description" [options]
        \\
        \\Generate professional logo variations using AI (GPT-Image 1.5)
        \\
        \\The logo template automatically applies best practices:
        \\  - Clean, vector-like shapes with strong silhouette
        \\  - Balanced negative space, scalable at all sizes
        \\  - Flat design, no gradients, generous padding
        \\
        \\Options:
        \\  -n, --count <N>         Number of variations (default: 4)
        \\  -s, --size <SIZE>       Image size (default: 1024x1024)
        \\      --feel <TEXT>       Logo personality (default: "clean, professional, and memorable")
        \\      --bg <TEXT>         Background (default: "plain white")
        \\      --extra <TEXT>      Additional instructions (e.g., "use blue and gold colors")
        \\      --model <MODEL>    Model: gpt-image-15 (default) or gpt-image
        \\  -o, --output <PATH>     Custom output path
        \\  -h, --help              Show this help
        \\
        \\Examples:
        \\  zig-ai logo "Field & Flour, a local bakery"
        \\  zig-ai logo "TechCorp, a cloud computing startup" --feel "modern, bold, and innovative"
        \\  zig-ai logo "NightOwl Security" --bg "plain black" --extra "use an owl silhouette"
        \\  zig-ai logo "GreenLeaf Organics" -n 8 --feel "natural, earthy, and fresh"
        \\  zig-ai logo "Quantum Labs" --model gpt-image -n 2
        \\
        \\
    , .{});
}

/// Print help for video commands
fn printVideoHelp(command: []const u8) void {
    std.debug.print(
        \\
        \\Usage: zig-ai {0s} "prompt" [options]
        \\
        \\Generate videos using AI
        \\
        \\Options:
        \\  -d, --duration <SEC>    Video duration in seconds (default: 5-8)
        \\  -s, --size <SIZE>       Video size (e.g., 1280x720, 1920x1080)
        \\  -a, --aspect-ratio <AR> Aspect ratio (16:9, 9:16)
        \\  -r, --resolution <RES>  Resolution (720p, 1080p)
        \\  -m, --model <MODEL>     Model variant (e.g., sora-2, sora-2-pro)
        \\  -o, --output <PATH>     Custom output path
        \\  -h, --help              Show this help
        \\
        \\Examples:
        \\  zig-ai {0s} "a cat playing piano"
        \\  zig-ai {0s} "drone flyover of mountains" -d 10 -r 1080p
        \\  zig-ai {0s} "timelapse of flowers blooming" --aspect-ratio 16:9
        \\
        \\
    , .{command});
}

/// Print help for music commands
fn printMusicHelp(command: []const u8) void {
    std.debug.print(
        \\
        \\Usage: zig-ai {0s} "prompt" [options]
        \\
        \\Generate music/audio using AI
        \\
        \\Options:
        \\  -d, --duration <SEC>    Duration in seconds (default: 30, 0 for instant)
        \\  -n, --count <N>         Number of tracks to generate (default: 1)
        \\      --bpm <BPM>         Target beats per minute
        \\      --seed <NUM>        Seed for reproducible generation
        \\      --negative <TEXT>   Negative prompt (things to avoid)
        \\  -o, --output <PATH>     Custom output path
        \\  -h, --help              Show this help
        \\
        \\Examples:
        \\  zig-ai {0s} "upbeat electronic music"
        \\  zig-ai {0s} "calm piano melody" -d 60 --bpm 80
        \\  zig-ai {0s} "epic orchestral" --negative "vocals drums"
        \\  zig-ai lyria-realtime "quick beat" -d 0    # Instant clip
        \\
        \\
    , .{command});
}

/// Print main help with all media commands
pub fn printHelp() void {
    std.debug.print(
        \\
        \\Image Generation Commands:
        \\
        \\  dalle3 <prompt>         OpenAI DALL-E 3 (requires OPENAI_API_KEY)
        \\  dalle2 <prompt>         OpenAI DALL-E 2 (requires OPENAI_API_KEY)
        \\  gpt-image <prompt>      OpenAI GPT-Image 1 (requires OPENAI_API_KEY)
        \\  gpt-image-15 <prompt>   OpenAI GPT-Image 1.5 (requires OPENAI_API_KEY)
        \\  grok-image <prompt>     xAI Grok-2-Image (requires XAI_API_KEY)
        \\  imagen <prompt>         Google Imagen via GenAI (requires GEMINI_API_KEY)
        \\  vertex-image <prompt>   Google Imagen via Vertex (requires VERTEX_PROJECT_ID)
        \\  gemini-image <prompt>   Gemini Flash image gen (requires GEMINI_API_KEY)
        \\  gemini-image-pro <prompt> Gemini Pro image gen (requires GEMINI_API_KEY)
        \\
        \\Preset Templates & Editing:
        \\
        \\  logo <description>      Generate logo variations (GPT-Image 1.5, 4 variants)
        \\  edit <imgs> <prompt>    Edit images (GPT-Image 1.5 or Grok, use -p to select)
        \\  --templates             List all prompt templates (photo, cyberpunk, product...)
        \\
        \\Batch Generation:
        \\
        \\  image-batch <csv>       Batch generate images from CSV file (sequential)
        \\
        \\Video Generation Commands:
        \\
        \\  sora <prompt>           OpenAI Sora 2 (requires OPENAI_API_KEY)
        \\  veo <prompt>            Google Veo 3.1 (requires GEMINI_API_KEY)
        \\  grok-video <prompt>     xAI Grok Imagine Video (requires XAI_API_KEY)
        \\
        \\Music Generation Commands:
        \\
        \\  lyria <prompt>          Google Lyria 2 (requires GEMINI_API_KEY)
        \\  lyria-realtime <prompt> Lyria RealTime for instant clips (requires GEMINI_API_KEY)
        \\
        \\Image Options:
        \\  -n, --count <N>         Number of images to generate
        \\  -s, --size <SIZE>       Image size (e.g., 1024x1024)
        \\  -a, --aspect-ratio <AR> Aspect ratio (e.g., 16:9)
        \\  -q, --quality <Q>       Quality level
        \\      --fast              Low quality for faster generation
        \\      --transparent       Transparent background (GPT-Image only)
        \\  -t, --template <NAME>   Apply prompt template (photo, cyberpunk, product...)
        \\  -o, --output <PATH>     Custom output path
        \\
        \\Video Options:
        \\  -d, --duration <SEC>    Video duration in seconds
        \\  -r, --resolution <RES>  Resolution (720p, 1080p)
        \\  -m, --model <MODEL>     Model variant (e.g., sora-2, sora-2-pro)
        \\  -a, --aspect-ratio <AR> Aspect ratio (16:9, 9:16)
        \\  -o, --output <PATH>     Custom output path
        \\
        \\Music Options:
        \\  -d, --duration <SEC>    Duration in seconds (default: 30, 0 for instant)
        \\      --bpm <BPM>         Target beats per minute
        \\      --seed <NUM>        Seed for reproducible generation
        \\      --negative <TEXT>   Negative prompt (things to avoid)
        \\  -o, --output <PATH>     Custom output path
        \\
        \\Examples:
        \\  zig-ai dalle3 "a cosmic duck floating in space"
        \\  zig-ai grok-image "quantum computer visualization" -n 2
        \\  zig-ai logo "Field & Flour, a local bakery"
        \\  zig-ai logo "TechCorp, a startup" --feel "modern and bold" -n 8
        \\  zig-ai sora "a cat playing piano" -d 10 -r 1080p
        \\  zig-ai edit photo.png "make it winter" -t weather-change
        \\  zig-ai edit photo.png "add snow" -p grok
        \\  zig-ai edit person.png shirt.png "dress in outfit" -t try-on
        \\  zig-ai lyria "upbeat electronic music" -d 60 --bpm 120
        \\  zig-ai lyria-realtime "quick beat" -d 0
        \\
        \\
    , .{});
}

/// List available providers based on configured API keys
pub fn listProviders() void {
    const config = MediaConfig.loadFromEnv();

    std.debug.print(
        \\
        \\Available Image Providers:
        \\
    , .{});

    inline for (std.meta.fields(ImageProvider)) |field| {
        const provider: ImageProvider = @enumFromInt(field.value);
        const available = config.hasProvider(provider);
        const status = if (available) "\x1b[32m✓\x1b[0m" else "\x1b[31m✗\x1b[0m";

        std.debug.print("  {s} {s}", .{ status, provider.getName() });
        if (!available) {
            std.debug.print(" (set {s})", .{provider.getEnvVar()});
        }
        std.debug.print("\n", .{});
    }

    std.debug.print(
        \\
        \\Available Video Providers:
        \\
    , .{});

    inline for (std.meta.fields(VideoProvider)) |field| {
        const provider: VideoProvider = @enumFromInt(field.value);
        const available = config.hasVideoProvider(provider);
        const status = if (available) "\x1b[32m✓\x1b[0m" else "\x1b[31m✗\x1b[0m";

        std.debug.print("  {s} {s}", .{ status, provider.getName() });
        if (!available) {
            std.debug.print(" (set {s})", .{provider.getEnvVar()});
        }
        std.debug.print("\n", .{});
    }

    std.debug.print(
        \\
        \\Available Music Providers:
        \\
    , .{});

    inline for (std.meta.fields(MusicProvider)) |field| {
        const provider: MusicProvider = @enumFromInt(field.value);
        const available = config.hasMusicProvider(provider);
        const status = if (available) "\x1b[32m✓\x1b[0m" else "\x1b[31m✗\x1b[0m";

        std.debug.print("  {s} {s}", .{ status, provider.getName() });
        if (!available) {
            std.debug.print(" (set {s})", .{provider.getEnvVar()});
        }
        std.debug.print("\n", .{});
    }

    std.debug.print("\n", .{});
}
