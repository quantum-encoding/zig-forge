// Copyright (c) 2025 QUANTUM ENCODING LTD
// Licensed under the MIT License.

//! zig-docx: DOCX to MDX converter
//!
//! Parses Microsoft Word DOCX files and converts them to MDX (Markdown with JSX)
//! format suitable for Svelte/Astro blog posts with YAML frontmatter.
//!
//! When images are present, creates an output folder containing:
//!   output-folder/
//!     post.mdx                    — the converted markdown
//!     images/
//!       1-image1.png              — extracted images, numbered top-to-bottom
//!       2-image2.jpeg

const std = @import("std");
const docx = @import("docx");

extern "c" fn fdopen(fd: c_int, mode: [*:0]const u8) ?*FILE;
extern "c" fn fflush(stream: ?*FILE) c_int;
extern "c" fn fopen(path: [*:0]const u8, mode: [*:0]const u8) ?*FILE;
extern "c" fn fclose(stream: *FILE) c_int;
extern "c" fn fread(ptr: [*]u8, size: usize, nmemb: usize, stream: *FILE) usize;
extern "c" fn fseek(stream: *FILE, offset: c_long, whence: c_int) c_int;
extern "c" fn ftell(stream: *FILE) c_long;
extern "c" fn mkdir(path: [*:0]const u8, mode: c_uint) c_int;
const FILE = std.c.FILE;

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.c_allocator;

    // Parse command line args
    var args_list: std.ArrayListUnmanaged([]const u8) = .empty;
    defer args_list.deinit(allocator);
    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    while (args_iter.next()) |arg| {
        try args_list.append(allocator, arg);
    }

    const parsed = parseArgs(args_list.items) orelse return;

    // Claude Code session export (directory of .jsonl files)
    // Check before folder mode so --claude-code on a directory doesn't fall into .docx scan
    if (parsed.claude_code_mode) {
        const out_dir = parsed.output_path orelse "claude_code_sessions";
        std.debug.print("Extracting Claude Code sessions to: {s}/\n", .{out_dir});

        const stats = docx.claude_code.extractAll(
            allocator,
            parsed.file_path,
            out_dir,
            .{ .only_project = parsed.only_project },
            writeToFile,
            writeDir,
        ) catch |err| {
            std.debug.print("Error extracting Claude Code sessions: {}\n", .{err});
            return;
        };

        std.debug.print("\nDone: {d} projects, {d} sessions, {d} messages, {d} tool calls, {d} subagents, {d} spilled results\n", .{
            stats.projects, stats.sessions, stats.messages, stats.tool_calls, stats.subagents, stats.spilled_results,
        });
        std.debug.print("Input: {d} bytes → Output: {s}/\n", .{ stats.total_bytes, out_dir });
        return;
    }

    // Folder mode: process all .docx files in a directory
    if (parsed.folder_mode) {
        processFolderMode(allocator, parsed);
        return;
    }

    // Anthropic conversations.json export
    const is_json = std.mem.endsWith(u8, parsed.file_path, ".json") or
        std.mem.endsWith(u8, parsed.file_path, ".JSON") or
        parsed.anthropic_mode;

    if (is_json) {
        // Read JSON file
        const json_data = blk: {
            const path_z = allocator.allocSentinel(u8, parsed.file_path.len, 0) catch {
                std.debug.print("Error: out of memory\n", .{});
                return;
            };
            defer allocator.free(path_z);
            @memcpy(path_z, parsed.file_path);

            const fp = fopen(path_z.ptr, "rb") orelse {
                std.debug.print("Error opening '{s}'\n", .{parsed.file_path});
                return;
            };
            defer _ = fclose(fp);

            _ = fseek(fp, 0, 2); // SEEK_END
            const size = ftell(fp);
            if (size <= 0) {
                std.debug.print("Error: file is empty\n", .{});
                return;
            }
            _ = fseek(fp, 0, 0); // SEEK_SET

            const buf = allocator.alloc(u8, @intCast(size)) catch {
                std.debug.print("Error: out of memory ({d} bytes)\n", .{size});
                return;
            };
            const n = fread(buf.ptr, 1, @intCast(size), fp);
            if (n != @as(usize, @intCast(size))) {
                allocator.free(buf);
                std.debug.print("Error: read failed\n", .{});
                return;
            }
            break :blk buf;
        };
        defer allocator.free(json_data);

        if (parsed.info_only) {
            const index = docx.anthropic.generateIndex(allocator, json_data) catch |err| {
                std.debug.print("Error parsing JSON: {}\n", .{err});
                return;
            };
            defer allocator.free(index);
            writeToStdout(index);
            return;
        }

        const out_dir = parsed.output_path orelse "claude_conversations";
        std.debug.print("Extracting Anthropic conversations to: {s}/\n", .{out_dir});

        const stats = docx.anthropic.extractExport(
            allocator, json_data, out_dir, writeToFile, writeDir,
        ) catch |err| {
            std.debug.print("Error extracting: {}\n", .{err});
            return;
        };

        std.debug.print("\nDone: {d} conversations, {d} messages, {d} artifacts\n", .{
            stats.conversations, stats.messages, stats.artifacts,
        });
        std.debug.print("Input: {d} bytes → Output: {s}/\n", .{ stats.total_bytes, out_dir });
        return;
    }

    // Detect plain text / markdown files — read directly, chunk or pass through
    const is_text = std.mem.endsWith(u8, parsed.file_path, ".md") or
        std.mem.endsWith(u8, parsed.file_path, ".MD") or
        std.mem.endsWith(u8, parsed.file_path, ".markdown") or
        std.mem.endsWith(u8, parsed.file_path, ".txt") or
        std.mem.endsWith(u8, parsed.file_path, ".TXT") or
        std.mem.endsWith(u8, parsed.file_path, ".mdx") or
        std.mem.endsWith(u8, parsed.file_path, ".MDX");

    if (is_text) {
        // Read file content
        const text = blk: {
            const path_z = allocator.allocSentinel(u8, parsed.file_path.len, 0) catch {
                std.debug.print("Error: out of memory\n", .{});
                return;
            };
            defer allocator.free(path_z);
            @memcpy(path_z, parsed.file_path);

            const fp = fopen(path_z.ptr, "rb") orelse {
                std.debug.print("Error opening '{s}'\n", .{parsed.file_path});
                return;
            };
            defer _ = fclose(fp);

            _ = fseek(fp, 0, 2);
            const size = ftell(fp);
            if (size <= 0) {
                std.debug.print("Error: file is empty\n", .{});
                return;
            }
            _ = fseek(fp, 0, 0);

            const buf = allocator.alloc(u8, @intCast(size)) catch {
                std.debug.print("Error: out of memory\n", .{});
                return;
            };
            const n = fread(buf.ptr, 1, @intCast(size), fp);
            if (n != @as(usize, @intCast(size))) {
                allocator.free(buf);
                std.debug.print("Error: read failed\n", .{});
                return;
            }
            break :blk buf;
        };
        defer allocator.free(text);

        if (parsed.info_only) {
            // Just show word/byte count
            var word_count: u32 = 0;
            var in_word = false;
            for (text) |c| {
                if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
                    if (in_word) word_count += 1;
                    in_word = false;
                } else {
                    in_word = true;
                }
            }
            if (in_word) word_count += 1;
            std.debug.print("Text: {s}\n  Bytes: {d}\n  Words: {d}\n", .{
                parsed.file_path, text.len, word_count,
            });
            return;
        }

        if (parsed.chunk_mode) {
            processChunking(allocator, text, parsed);
        } else if (parsed.output_path) |path| {
            writeToFile(allocator, path, text);
        } else {
            writeToStdout(text);
        }
        return;
    }

    // Detect PDF files — extract text, optionally chunk
    const is_pdf = std.mem.endsWith(u8, parsed.file_path, ".pdf") or
        std.mem.endsWith(u8, parsed.file_path, ".PDF");

    if (is_pdf) {
        var pdf_result = docx.pdf.extractPdf(allocator, parsed.file_path) catch |err| {
            std.debug.print("Error extracting PDF: {}\n", .{err});
            std.debug.print("  Requires 'pdftotext' (poppler) or 'mutool' (mupdf) on PATH\n", .{});
            return;
        };
        defer pdf_result.deinit();

        if (parsed.info_only) {
            std.debug.print("PDF: {s}\n  Pages: {d}\n  Text: {d} bytes\n  Method: {s}\n", .{
                parsed.file_path, pdf_result.page_count, pdf_result.text.len, pdf_result.method,
            });
            return;
        }

        // Convert to markdown
        const md = docx.pdf.textToMarkdown(allocator, pdf_result.text) catch |err| {
            std.debug.print("Error converting to markdown: {}\n", .{err});
            return;
        };
        defer allocator.free(md);

        if (parsed.chunk_mode) {
            processChunking(allocator, md, parsed);
        } else if (parsed.output_path) |path| {
            writeToFile(allocator, path, md);
        } else {
            writeToStdout(md);
        }
        return;
    }

    // Open DOCX/XLSX file
    var archive = docx.zip.ZipArchive.open(allocator, parsed.file_path) catch |err| {
        std.debug.print("Error opening '{s}': {}\n", .{ parsed.file_path, err });
        return;
    };
    defer archive.close();

    // --list: show all files in the DOCX ZIP
    if (parsed.list_only) {
        std.debug.print("Files in '{s}':\n", .{parsed.file_path});
        for (archive.entries) |entry| {
            std.debug.print("  {s}  ({d} bytes, method={d})\n", .{
                entry.filename,
                entry.uncompressed_size,
                entry.compression_method,
            });
        }
        return;
    }

    // Detect XLSX files and route to spreadsheet parser
    const is_xlsx = std.mem.endsWith(u8, parsed.file_path, ".xlsx") or
        std.mem.endsWith(u8, parsed.file_path, ".XLSX");

    if (is_xlsx) {
        var workbook = docx.xlsx.parseXlsx(allocator, &archive) catch |err| {
            std.debug.print("Error parsing XLSX: {}\n", .{err});
            return;
        };
        defer workbook.deinit();

        if (parsed.info_only) {
            std.debug.print("Workbook: {d} sheet(s)\n", .{workbook.sheets.len});
            for (workbook.sheets, 0..) |sheet, i| {
                std.debug.print("  Sheet {d}: \"{s}\" ({d} cells, {d} cols × {d} rows)\n", .{
                    i + 1, sheet.name, sheet.cells.len, sheet.max_col + 1, sheet.max_row,
                });
            }
            return;
        }

        // Output each sheet
        for (workbook.sheets, 0..) |*sheet, i| {
            if (workbook.sheets.len > 1) {
                const header = std.fmt.allocPrint(allocator, "# {s}\n\n", .{sheet.name}) catch continue;
                defer allocator.free(header);
                writeToStdout(header);
            }

            // Default: CSV output. Use --markdown for markdown table format.
            const output = if (parsed.markdown_mode)
                docx.xlsx.sheetToMarkdown(allocator, sheet) catch continue
            else
                docx.xlsx.sheetToCsv(allocator, sheet) catch continue;
            defer allocator.free(output);

            if (parsed.output_path) |path| {
                if (workbook.sheets.len > 1) {
                    const sheet_path = std.fmt.allocPrint(allocator, "{s}_sheet{d}.csv", .{ path, i + 1 }) catch continue;
                    defer allocator.free(sheet_path);
                    writeToFile(allocator, sheet_path, output);
                } else {
                    writeToFile(allocator, path, output);
                }
            } else {
                writeToStdout(output);
            }
        }
        return;
    }

    // Parse DOCX document
    var doc = docx.parseDocument(allocator, &archive) catch |err| {
        std.debug.print("Error parsing DOCX: {}\n", .{err});
        return;
    };
    defer doc.deinit();

    // --info: show document structure
    if (parsed.info_only) {
        const info = docx.printDocumentInfo(allocator, &doc) catch |err| {
            std.debug.print("Error generating info: {}\n", .{err});
            return;
        };
        defer allocator.free(info);
        writeToStdout(info);
        return;
    }

    // Default: convert to MDX
    var result = docx.mdx.generateMdx(allocator, &doc, .{
        .title = parsed.title orelse "",
        .description = parsed.description orelse "",
        .author = parsed.author orelse "",
        .date = parsed.date orelse "",
        .slug = parsed.slug orelse "",
    }) catch |err| {
        std.debug.print("Error generating MDX: {}\n", .{err});
        return;
    };
    defer result.deinit();

    const has_images = result.images.len > 0;

    if (parsed.output_path) |path| {
        if (has_images) {
            writeOutputFolder(allocator, path, result.mdx, result.images, &doc);
        } else {
            writeToFile(allocator, path, result.mdx);
        }
    } else {
        if (has_images) {
            std.debug.print("Note: {d} image(s) found. Use -o <path> to extract them.\n", .{result.images.len});
        }
        writeToStdout(result.mdx);
    }
}

fn writeOutputFolder(
    allocator: std.mem.Allocator,
    output_path: []const u8,
    mdx_data: []const u8,
    images: []const docx.mdx.ImageRef,
    doc: *const docx.Document,
) void {
    // Determine folder path and MDX filename
    // If output_path ends in .mdx, use parent dir as folder, filename as MDX name
    // Otherwise, treat output_path as folder name, use "post.mdx" as default
    var folder_path: []const u8 = undefined;
    var mdx_filename: []const u8 = undefined;

    if (std.mem.endsWith(u8, output_path, ".mdx") or std.mem.endsWith(u8, output_path, ".md")) {
        // e.g. "/tmp/my-post.mdx" -> folder="/tmp/my-post", mdx="my-post.mdx"
        if (std.mem.lastIndexOfScalar(u8, output_path, '/')) |slash| {
            // Get the basename without extension for folder
            const basename = output_path[slash + 1 ..];
            const stem = if (std.mem.lastIndexOfScalar(u8, basename, '.')) |dot|
                basename[0..dot]
            else
                basename;

            // Folder = parent/stem
            const parent = output_path[0..slash];
            folder_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ parent, stem }) catch {
                std.debug.print("Error: out of memory\n", .{});
                return;
            };
            mdx_filename = basename;
        } else {
            // No slash — current dir
            const stem = if (std.mem.lastIndexOfScalar(u8, output_path, '.')) |dot|
                output_path[0..dot]
            else
                output_path;
            folder_path = allocator.dupe(u8, stem) catch return;
            mdx_filename = output_path;
        }
    } else {
        // Treat as folder name
        folder_path = allocator.dupe(u8, output_path) catch return;
        mdx_filename = "post.mdx";
    }
    defer allocator.free(folder_path);

    // Create folder
    mkdirZ(allocator, folder_path);

    // Create images/ subfolder
    const images_dir = std.fmt.allocPrint(allocator, "{s}/images", .{folder_path}) catch return;
    defer allocator.free(images_dir);
    mkdirZ(allocator, images_dir);

    // Write MDX file
    const mdx_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ folder_path, mdx_filename }) catch return;
    defer allocator.free(mdx_path);
    writeToFile(allocator, mdx_path, mdx_data);

    // Extract and write images
    var written_count: u16 = 0;
    for (images) |img_ref| {
        // Find the media data for this image
        const media_data = findMediaData(doc, img_ref.media_name) orelse {
            std.debug.print("  Warning: image '{s}' not found in media files\n", .{img_ref.media_name});
            continue;
        };

        const img_path = std.fmt.allocPrint(allocator, "{s}/images/{s}", .{ folder_path, img_ref.filename }) catch continue;
        defer allocator.free(img_path);

        writeToFile(allocator, img_path, media_data);
        written_count += 1;
    }

    std.debug.print("Output folder: {s}/\n", .{folder_path});
    std.debug.print("  {s} ({d} bytes)\n", .{ mdx_filename, mdx_data.len });
    if (written_count > 0) {
        std.debug.print("  images/ ({d} file(s))\n", .{written_count});
        for (images) |img_ref| {
            std.debug.print("    {s}\n", .{img_ref.filename});
        }
    }
}

fn findMediaData(doc: *const docx.Document, media_name: []const u8) ?[]const u8 {
    for (doc.media) |media| {
        if (std.mem.eql(u8, media.name, media_name)) return media.data;
    }
    return null;
}

fn mkdirZ(allocator: std.mem.Allocator, path: []const u8) void {
    const path_z = allocator.allocSentinel(u8, path.len, 0) catch return;
    defer allocator.free(path_z);
    @memcpy(path_z, path);
    _ = mkdir(path_z.ptr, 0o755);
}

fn processChunking(allocator: std.mem.Allocator, markdown: []const u8, parsed: Args) void {
    const source = std.fs.path.basename(parsed.file_path);

    // Build chunker config, overriding defaults with any CLI flags
    var config = docx.chunker.ChunkConfig{};
    if (parsed.chunk_target_words) |tw| config.target_words = tw;
    if (parsed.chunk_min_words) |mw| config.min_words = mw;
    if (parsed.chunk_max_words) |mw| config.max_words = mw;

    var result = docx.chunker.chunkDocument(allocator, markdown, source, config) catch |err| {
        std.debug.print("Error chunking: {}\n", .{err});
        return;
    };
    defer result.deinit();

    std.debug.print("Chunked '{s}': {d} chunks, {d} total words\n", .{
        source, result.chunks.len, result.total_words,
    });

    if (parsed.output_path) |out_dir| {
        // Create output directory with chunk files
        // Create output directory
        {
            const dir_z = allocator.allocSentinel(u8, out_dir.len, 0) catch return;
            defer allocator.free(dir_z);
            @memcpy(dir_z, out_dir);
            _ = mkdir(dir_z.ptr, 0o755);
        }

        // Write index.md
        const index = result.generateIndex(allocator) catch return;
        defer allocator.free(index);
        const index_path = std.fmt.allocPrint(allocator, "{s}/index.md", .{out_dir}) catch return;
        defer allocator.free(index_path);
        writeToFile(allocator, index_path, index);

        // Write each chunk
        for (result.chunks, 0..) |chunk, i| {
            const chunk_md = result.generateChunkMd(allocator, i) catch continue;
            defer allocator.free(chunk_md);
            const fname = docx.chunker.chunkFilename(allocator, chunk.index, chunk.title) catch continue;
            defer allocator.free(fname);
            const chunk_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ out_dir, fname }) catch continue;
            defer allocator.free(chunk_path);
            writeToFile(allocator, chunk_path, chunk_md);
        }

        std.debug.print("  Written to: {s}/\n", .{out_dir});
    } else {
        // Stdout: write index then all chunks
        const index = result.generateIndex(allocator) catch return;
        defer allocator.free(index);
        writeToStdout(index);

        for (result.chunks, 0..) |_, i| {
            const chunk_md = result.generateChunkMd(allocator, i) catch continue;
            defer allocator.free(chunk_md);
            writeToStdout(chunk_md);
        }
    }
}

fn writeDir(allocator: std.mem.Allocator, path: []const u8) void {
    const path_z = allocator.allocSentinel(u8, path.len, 0) catch return;
    defer allocator.free(path_z);
    @memcpy(path_z, path);
    _ = mkdir(path_z.ptr, 0o755);
}

fn writeToFile(allocator: std.mem.Allocator, path: []const u8, data: []const u8) void {
    const path_z = allocator.allocSentinel(u8, path.len, 0) catch {
        std.debug.print("Error: out of memory\n", .{});
        return;
    };
    defer allocator.free(path_z);
    @memcpy(path_z, path);

    const f = std.c.fopen(path_z.ptr, "wb") orelse {
        std.debug.print("Error: cannot open '{s}' for writing\n", .{path});
        return;
    };
    _ = std.c.fwrite(data.ptr, 1, data.len, f);
    _ = std.c.fclose(f);
}

fn writeToStdout(data: []const u8) void {
    const stdout = fdopen(1, "wb") orelse {
        std.debug.print("Error: cannot open stdout\n", .{});
        return;
    };
    _ = std.c.fwrite(data.ptr, 1, data.len, stdout);
    _ = fflush(stdout);
}

const Args = struct {
    file_path: []const u8 = "",
    output_path: ?[]const u8 = null,
    title: ?[]const u8 = null,
    description: ?[]const u8 = null,
    author: ?[]const u8 = null,
    date: ?[]const u8 = null,
    slug: ?[]const u8 = null,
    list_only: bool = false,
    info_only: bool = false,
    folder_mode: bool = false,
    markdown_mode: bool = false,
    chunk_mode: bool = false,
    anthropic_mode: bool = false,
    claude_code_mode: bool = false,
    only_project: ?[]const u8 = null,
    // Chunker config (only used when --chunk is set)
    chunk_target_words: ?u32 = null,
    chunk_min_words: ?u32 = null,
    chunk_max_words: ?u32 = null,
};

fn parseArgs(args: []const []const u8) ?Args {
    var result = Args{};
    var got_file = false;

    var i: usize = 1; // skip program name
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printHelp();
            return null;
        } else if (std.mem.eql(u8, arg, "--list") or std.mem.eql(u8, arg, "-l")) {
            result.list_only = true;
        } else if (std.mem.eql(u8, arg, "--info") or std.mem.eql(u8, arg, "-i")) {
            result.info_only = true;
        } else if (std.mem.eql(u8, arg, "--markdown") or std.mem.eql(u8, arg, "--md") or std.mem.eql(u8, arg, "-m")) {
            result.markdown_mode = true;
        } else if (std.mem.eql(u8, arg, "--chunk") or std.mem.eql(u8, arg, "-c")) {
            result.chunk_mode = true;
        } else if (std.mem.eql(u8, arg, "--chunk-target-words")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --chunk-target-words requires a value\n", .{});
                return null;
            }
            result.chunk_target_words = std.fmt.parseInt(u32, args[i], 10) catch {
                std.debug.print("Error: --chunk-target-words must be a positive integer\n", .{});
                return null;
            };
        } else if (std.mem.eql(u8, arg, "--chunk-min-words")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --chunk-min-words requires a value\n", .{});
                return null;
            }
            result.chunk_min_words = std.fmt.parseInt(u32, args[i], 10) catch {
                std.debug.print("Error: --chunk-min-words must be a positive integer\n", .{});
                return null;
            };
        } else if (std.mem.eql(u8, arg, "--chunk-max-words")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --chunk-max-words requires a value\n", .{});
                return null;
            }
            result.chunk_max_words = std.fmt.parseInt(u32, args[i], 10) catch {
                std.debug.print("Error: --chunk-max-words must be a positive integer\n", .{});
                return null;
            };
        } else if (std.mem.eql(u8, arg, "--anthropic") or std.mem.eql(u8, arg, "--claude")) {
            result.anthropic_mode = true;
        } else if (std.mem.eql(u8, arg, "--claude-code")) {
            result.claude_code_mode = true;
        } else if (std.mem.eql(u8, arg, "--only-project")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --only-project requires a value\n", .{});
                return null;
            }
            result.only_project = args[i];
        } else if (std.mem.eql(u8, arg, "--title")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --title requires a value\n", .{});
                return null;
            }
            result.title = args[i];
        } else if (std.mem.eql(u8, arg, "--description")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --description requires a value\n", .{});
                return null;
            }
            result.description = args[i];
        } else if (std.mem.eql(u8, arg, "--author")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --author requires a value\n", .{});
                return null;
            }
            result.author = args[i];
        } else if (std.mem.eql(u8, arg, "--date")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --date requires a value\n", .{});
                return null;
            }
            result.date = args[i];
        } else if (std.mem.eql(u8, arg, "--slug")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --slug requires a value\n", .{});
                return null;
            }
            result.slug = args[i];
        } else if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: -o requires a file path\n", .{});
                return null;
            }
            result.output_path = args[i];
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            result.file_path = arg;
            got_file = true;
        } else {
            std.debug.print("Unknown option: {s}\n", .{arg});
            return null;
        }
    }

    if (!got_file) {
        std.debug.print("Error: No input file specified\n\n", .{});
        printHelp();
        return null;
    }

    // Detect folder mode: path ends with / or doesn't end with .docx
    if (std.mem.endsWith(u8, result.file_path, "/") or
        (!std.mem.endsWith(u8, result.file_path, ".docx") and
        !std.mem.endsWith(u8, result.file_path, ".DOCX") and
        isDirectory(result.file_path)))
    {
        result.folder_mode = true;
    }

    return result;
}

fn isDirectory(path: []const u8) bool {
    const cstat = @cImport({ @cInclude("sys/stat.h"); });
    const path_z = std.heap.c_allocator.allocSentinel(u8, path.len, 0) catch return false;
    defer std.heap.c_allocator.free(path_z);
    @memcpy(path_z, path);

    var stat_buf: cstat.struct_stat = undefined;
    if (cstat.stat(path_z.ptr, &stat_buf) != 0) return false;
    return (stat_buf.st_mode & 0o170000) == 0o040000; // S_IFDIR
}

/// Process all .docx files in a folder, outputting .mdx files alongside them.
fn processFolderMode(allocator: std.mem.Allocator, parsed: Args) void {
    const dir_path = if (std.mem.endsWith(u8, parsed.file_path, "/"))
        parsed.file_path[0 .. parsed.file_path.len - 1]
    else
        parsed.file_path;

    // Use C opendir/readdir for directory iteration (Zig 0.16 std.fs has no cwd())
    const cdir = @cImport({ @cInclude("dirent.h"); });
    const dir_z = allocator.allocSentinel(u8, dir_path.len, 0) catch return;
    defer allocator.free(dir_z);
    @memcpy(dir_z, dir_path);

    const dir = cdir.opendir(dir_z.ptr) orelse {
        std.debug.print("Error: cannot open directory '{s}'\n", .{dir_path});
        return;
    };
    defer _ = cdir.closedir(dir);

    var count: u32 = 0;
    var success: u32 = 0;

    while (cdir.readdir(dir)) |entry| {
        const d_name: [*]const u8 = @ptrCast(&entry.*.d_name);
        const name_len = std.mem.indexOfScalar(u8, d_name[0..256], 0) orelse 256;
        const name = d_name[0..name_len];
        if (!std.mem.endsWith(u8, name, ".docx") and !std.mem.endsWith(u8, name, ".DOCX")) continue;

        count += 1;

        // Build full path: dir/file.docx
        const full_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, name }) catch continue;
        defer allocator.free(full_path);

        // Output path: dir/file.mdx (replace .docx with .mdx)
        const stem = name[0 .. name.len - 5]; // strip .docx
        const out_path = std.fmt.allocPrint(allocator, "{s}/{s}.mdx", .{ dir_path, stem }) catch continue;
        defer allocator.free(out_path);

        std.debug.print("[{d}] {s} → {s}.mdx ... ", .{ count, name, stem });

        if (processSingleFile(allocator, full_path, out_path, parsed)) {
            success += 1;
            std.debug.print("OK\n", .{});
        } else {
            std.debug.print("FAILED\n", .{});
        }
    }

    if (count == 0) {
        std.debug.print("No .docx files found in '{s}'\n", .{dir_path});
    } else {
        std.debug.print("\n{d}/{d} files converted\n", .{ success, count });
    }
}

/// Process a single .docx file to .mdx. Returns true on success.
fn processSingleFile(allocator: std.mem.Allocator, input_path: []const u8, output_path: []const u8, parsed: Args) bool {
    var archive = docx.zip.ZipArchive.open(allocator, input_path) catch return false;
    defer archive.close();

    var doc = docx.parseDocument(allocator, &archive) catch return false;
    defer doc.deinit();

    var result = docx.mdx.generateMdx(allocator, &doc, .{
        .title = parsed.title orelse "",
        .description = parsed.description orelse "",
        .author = parsed.author orelse "",
        .date = parsed.date orelse "",
        .slug = parsed.slug orelse "",
    }) catch return false;
    defer result.deinit();

    if (result.images.len > 0) {
        writeOutputFolder(allocator, output_path, result.mdx, result.images, &doc);
    } else {
        writeToFile(allocator, output_path, result.mdx);
    }

    return true;
}

fn printHelp() void {
    const help =
        \\zig-docx - Universal document converter & chunker
        \\
        \\Supported formats:
        \\  DOCX   →  MDX (Markdown with frontmatter)
        \\  PDF    →  Markdown (via pdftotext/mutool)
        \\  XLSX   →  CSV or Markdown table
        \\  JSON   →  Claude conversation markdown (Anthropic export)
        \\  MD/TXT →  Chunked markdown (for RAG / AI context)
        \\
        \\Usage:
        \\  zig-docx <file> [options]
        \\  zig-docx <folder/>              Batch mode (DOCX only)
        \\
        \\Commands:
        \\  (default)             Convert to appropriate output format
        \\  --info, -i            Show document structure / stats
        \\  --list, -l            List files in ZIP archive (DOCX/XLSX)
        \\  --chunk, -c           Chunk markdown output with hash navigation
        \\  --markdown, --md      XLSX: output markdown table instead of CSV
        \\  --anthropic           JSON: extract Claude conversations
        \\
        \\Options:
        \\  -o, --output <path>   Write output to file or folder
        \\  --title "..."         Set MDX frontmatter title (DOCX only)
        \\  --description "..."   Set MDX frontmatter description
        \\  --author "..."        Set MDX frontmatter author
        \\  --date "..."          Set MDX frontmatter date
        \\  --slug "..."          Set MDX frontmatter slug
        \\  -h, --help            Show this help
        \\
        \\Examples:
        \\  # DOCX → MDX
        \\  zig-docx post.docx -o post.mdx --title "My Post"
        \\
        \\  # PDF → Markdown
        \\  zig-docx manual.pdf -o manual.md
        \\
        \\  # PDF → Chunked RAG-ready markdown
        \\  zig-docx manual.pdf --chunk -o chunks/
        \\
        \\  # Markdown file → Chunked with hash-linked navigation
        \\  zig-docx document.md --chunk -o chunks/
        \\
        \\  # XLSX → CSV
        \\  zig-docx spreadsheet.xlsx -o data.csv
        \\
        \\  # XLSX → Markdown table
        \\  zig-docx spreadsheet.xlsx --markdown -o data.md
        \\
        \\  # Claude conversations.json → organized markdown
        \\  zig-docx conversations.json --anthropic -o chats/
        \\
    ;
    std.debug.print("{s}", .{help});
}
