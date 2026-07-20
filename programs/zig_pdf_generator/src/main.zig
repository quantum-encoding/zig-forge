//! Zig PDF Generator CLI
//!
//! Command-line interface for generating PDFs from JSON input.
//! Supports five explicit, mutually exclusive template modes:
//!   --basic, --minimalist, --letter, --presentation, --proposal
//!
//! Supports UNIX pipe composition:
//!   If input file is omitted, JSON is read from stdin.
//!   If output file is omitted, PDF binary bytes are written directly to stdout.

const std = @import("std");
const lib = @import("lib.zig");

const VERSION = "1.0.0";

// Global IO context from init
var global_io: std.Io = undefined;
var global_allocator: std.mem.Allocator = undefined;

const TemplateMode = enum {
    basic,
    minimalist,
    letter,
    letter_md,
    presentation,
    proposal,
    certificate,
    crg_report,
    health_report,
};

/// Company / legal document sub-types selected via `--certificate <type>`.
/// Grouping these under one flag keeps `--help` clean (one line instead of
/// nine), while still dispatching to a dedicated renderer per document.
const CertType = enum {
    contract,
    share_certificate,
    dividend_voucher,
    stock_transfer,
    board_resolution,
    director_consent,
    director_appointment,
    director_resignation,
    written_resolution,
};

/// Maps the CLI `<type>` token to a CertType. Tokens are hyphenated and match
/// the document name exactly so `--help` and the JSON schema docs line up.
const cert_type_map = std.StaticStringMap(CertType).initComptime(.{
    .{ "contract", .contract },
    .{ "share-certificate", .share_certificate },
    .{ "dividend-voucher", .dividend_voucher },
    .{ "stock-transfer", .stock_transfer },
    .{ "board-resolution", .board_resolution },
    .{ "director-consent", .director_consent },
    .{ "director-appointment", .director_appointment },
    .{ "director-resignation", .director_resignation },
    .{ "written-resolution", .written_resolution },
});

/// Human-readable list of valid `--certificate` tokens, reused by both the
/// usage text and the "unknown type" error path.
const cert_types_help =
    \\Valid <type> values for --certificate:
    \\  contract               share-certificate      dividend-voucher
    \\  stock-transfer         board-resolution       director-consent
    \\  director-appointment   director-resignation   written-resolution
    \\
;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    // Store globals
    global_io = io;
    global_allocator = allocator;

    var stdout_buffer: [8192]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    var stderr_buffer: [4096]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buffer);
    const stderr = &stderr_writer.interface;

    // Collect args into a slice
    var args_list: std.ArrayListUnmanaged([]const u8) = .empty;
    defer args_list.deinit(allocator);

    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    while (args_iter.next()) |arg| {
        try args_list.append(allocator, arg);
    }
    const args = args_list.items;

    // The `extract` verb is the inverse of generation: PDF in → MDX out. It is
    // dispatched before the template-flag parser so the two paths never tangle.
    if (args.len >= 2 and std.mem.eql(u8, args[1], "extract")) {
        runExtract(allocator, args[2..], stdout, stderr) catch |err| {
            stderr.print("Error: extraction failed: {s}\n", .{@errorName(err)}) catch {};
            stderr.flush() catch {};
            std.process.exit(1);
        };
        return;
    }

    // Parser state
    var opt_basic = false;
    var opt_minimalist = false;
    var opt_letter = false;
    var opt_letter_md = false;
    var opt_presentation = false;
    var opt_proposal = false;
    var opt_certificate = false;
    var opt_crg_report = false;
    var opt_health_report = false;
    var cert_type: ?CertType = null;

    var input_path: ?[]const u8 = null;
    var output_path: ?[]const u8 = null;
    var pos_arg_count: usize = 0;

    // Loop starts at 1 to skip executable name
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printUsage(stderr);
            return;
        } else if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-v")) {
            try stderr.print("zig-pdf-generator {s}\n", .{VERSION});
            try stderr.flush();
            return;
        } else if (std.mem.eql(u8, arg, "--basic")) {
            opt_basic = true;
        } else if (std.mem.eql(u8, arg, "--minimalist")) {
            opt_minimalist = true;
        } else if (std.mem.eql(u8, arg, "--letter")) {
            opt_letter = true;
        } else if (std.mem.eql(u8, arg, "--letter-md")) {
            opt_letter_md = true;
        } else if (std.mem.eql(u8, arg, "--presentation")) {
            opt_presentation = true;
        } else if (std.mem.eql(u8, arg, "--proposal")) {
            opt_proposal = true;
        } else if (std.mem.eql(u8, arg, "--crg-report")) {
            opt_crg_report = true;
        } else if (std.mem.eql(u8, arg, "--health-report")) {
            opt_health_report = true;
        } else if (std.mem.eql(u8, arg, "--certificate")) {
            opt_certificate = true;
            // Consume the next token as the document <type>. The loop's
            // continuation (i += 1) then skips past it so it is not mistaken
            // for the input path.
            i += 1;
            if (i >= args.len) {
                try stderr.writeAll("Error: --certificate requires a <type> argument.\n\n");
                try stderr.writeAll(cert_types_help);
                try stderr.flush();
                std.process.exit(1);
            }
            cert_type = cert_type_map.get(args[i]) orelse {
                try stderr.print("Error: Unknown certificate type '{s}'.\n\n", .{args[i]});
                try stderr.writeAll(cert_types_help);
                try stderr.flush();
                std.process.exit(1);
            };
        } else if (std.mem.startsWith(u8, arg, "-")) {
            try stderr.print("Error: Unrecognized flag '{s}'\n\n", .{arg});
            printUsage(stderr);
            std.process.exit(1);
        } else {
            // Positional argument
            if (pos_arg_count == 0) {
                input_path = arg;
                pos_arg_count += 1;
            } else if (pos_arg_count == 1) {
                output_path = arg;
                pos_arg_count += 1;
            } else {
                try stderr.writeAll("Error: Too many positional arguments. Max 2 expected: [input_file [output_file]]\n");
                try stderr.flush();
                std.process.exit(1);
            }
        }
    }

    // Arg Exclusivity Validation
    const basic_val: usize = if (opt_basic) 1 else 0;
    const minimalist_val: usize = if (opt_minimalist) 1 else 0;
    const letter_val: usize = if (opt_letter) 1 else 0;
    const presentation_val: usize = if (opt_presentation) 1 else 0;
    const proposal_val: usize = if (opt_proposal) 1 else 0;
    const certificate_val: usize = if (opt_certificate) 1 else 0;
    const crg_report_val: usize = if (opt_crg_report) 1 else 0;
    const health_report_val: usize = if (opt_health_report) 1 else 0;

    const total_flags = basic_val + minimalist_val + letter_val + presentation_val + proposal_val + certificate_val + crg_report_val + health_report_val;
    if (total_flags > 1) {
        try stderr.writeAll("Error: Multiple template flags specified. Template flags (--basic, --minimalist, --letter, --presentation, --proposal, --certificate) are mutually exclusive.\n");
        try stderr.flush();
        std.process.exit(1);
    }

    // Resolve template mode (default is basic)
    const mode: TemplateMode = if (opt_minimalist)
        .minimalist
    else if (opt_letter)
        .letter
    else if (opt_letter_md)
        .letter_md
    else if (opt_presentation)
        .presentation
    else if (opt_proposal)
        .proposal
    else if (opt_certificate)
        .certificate
    else if (opt_crg_report)
        .crg_report
    else if (opt_health_report)
        .health_report
    else
        .basic;

    // Load JSON data (max 50MB)
    const json_data = readInputData(allocator, input_path, stderr) catch |err| {
        try stderr.print("Error: Failed to read input data: {s}\n", .{@errorName(err)});
        try stderr.flush();
        std.process.exit(1);
    };
    defer allocator.free(json_data);

    // Generate PDF bytes. Schema-validation failures (missing required root
    // fields) surface as a specific, human-readable diagnostic and a non-zero
    // exit — never a silently-blank PDF.
    const pdf_bytes = generatePdfBytes(allocator, mode, cert_type, json_data) catch |err| {
        reportGenerationError(stderr, mode, err);
        std.process.exit(1);
    };
    defer allocator.free(pdf_bytes);

    // Write output PDF bytes
    writeOutputData(output_path, pdf_bytes, stdout, stderr) catch |err| {
        try stderr.print("Error: Failed to write output data: {s}\n", .{@errorName(err)});
        try stderr.flush();
        std.process.exit(1);
    };
}

/// `extract` verb: read a PDF and emit MDX (the inverse of generation).
///
///   pdf-gen extract <in.pdf> [-o out.mdx] [--meta]
///   cat in.pdf | pdf-gen extract > out.mdx
///
/// stdout carries the MDX (clean), stderr carries diagnostics + optional meta.
fn runExtract(allocator: std.mem.Allocator, args: []const []const u8, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !void {
    var input_path: ?[]const u8 = null;
    var output_path: ?[]const u8 = null;
    var want_meta = false;
    var want_images = false;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
            i += 1;
            if (i >= args.len) {
                try stderr.writeAll("Error: -o requires a path argument.\n");
                try stderr.flush();
                return error.MissingOutputPath;
            }
            output_path = args[i];
        } else if (std.mem.eql(u8, arg, "--meta")) {
            want_meta = true;
        } else if (std.mem.eql(u8, arg, "--images")) {
            want_images = true;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try stderr.writeAll(
                \\Usage: pdf-gen extract <in.pdf> [-o out.mdx] [--meta] [--images]
                \\  Reads a PDF and emits MDX (Markdown + YAML frontmatter).
                \\  If <in.pdf> is omitted, the PDF is read from stdin.
                \\  If -o is omitted, MDX is written to stdout.
                \\  --meta    also prints extraction metadata (JSON) to stderr.
                \\  --images  extract JPEG/JPEG2000 images to an images/ dir beside the output.
                \\
            );
            try stderr.flush();
            return;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            try stderr.print("Error: unrecognized extract flag '{s}'\n", .{arg});
            try stderr.flush();
            return error.UnrecognizedFlag;
        } else if (input_path == null) {
            input_path = arg;
        }
    }

    const pdf_bytes = try readInputData(allocator, input_path, stderr);
    defer allocator.free(pdf_bytes);

    const source_name = input_path orelse "";
    var result = lib.extractToMdx(allocator, pdf_bytes, .{ .source_name = source_name, .extract_images = want_images }) catch |err| {
        try stderr.print("Error: PDF extraction failed: {s}\n", .{@errorName(err)});
        try stderr.flush();
        return err;
    };
    defer result.deinit(allocator);

    if (want_images and result.images.len > 0) {
        writeImages(output_path, result.images, stderr) catch |err| {
            try stderr.print("Warning: could not write images: {s}\n", .{@errorName(err)});
            try stderr.flush();
        };
    }

    try writeOutputData(output_path, result.mdx, stdout, stderr);

    if (want_meta) {
        const meta_json = try std.json.Stringify.valueAlloc(allocator, .{
            .pages = result.meta.pages,
            .has_text_layer = result.meta.has_text_layer,
            .needs_ocr = result.meta.needs_ocr,
            .images_found = result.meta.images_found,
            .tables_found = result.meta.tables_found,
            .extraction_method = result.meta.extraction_method,
            .encrypted = result.meta.encrypted,
        }, .{ .whitespace = .indent_2 });
        defer allocator.free(meta_json);
        try stderr.print("{s}\n", .{meta_json});
        try stderr.flush();
    }
}

/// Write extracted image blobs into an `images/` directory beside the output
/// file (or in the current directory when writing MDX to stdout). The MDX refs
/// already point at `images/<name>`.
fn writeImages(output_path: ?[]const u8, images: []const lib.pdf_extract.ExtractedImage, stderr: *std.Io.Writer) !void {
    const io = global_io;
    const cwd = std.Io.Dir.cwd();

    // Resolve the images/ directory: <output dir>/images, else ./images.
    var dir_buf: [4096]u8 = undefined;
    const images_dir: []const u8 = if (output_path) |p| blk: {
        if (std.fs.path.dirname(p)) |d| {
            break :blk std.fmt.bufPrint(&dir_buf, "{s}/images", .{d}) catch "images";
        }
        break :blk "images";
    } else "images";

    cwd.createDirPath(io, images_dir) catch {};
    var count: usize = 0;
    for (images) |img| {
        var path_buf: [4352]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ images_dir, img.name }) catch continue;
        const file = cwd.createFile(io, path, .{}) catch continue;
        defer file.close(io);
        var wbuf: [8192]u8 = undefined;
        var fw = file.writer(io, &wbuf);
        fw.interface.writeAll(img.bytes) catch continue;
        fw.interface.flush() catch {};
        count += 1;
    }
    try stderr.print("Extracted {d} image(s) to {s}/\n", .{ count, images_dir });
    try stderr.flush();
}

fn printUsage(stderr: *std.Io.Writer) void {
    const usage =
        \\Zig PDF Generator CLI v1.0.0
        \\
        \\Usage:
        \\  pdf-gen [flags] [input_file [output_file]]
        \\
        \\If input_file is omitted, JSON is read from stdin.
        \\If output_file is omitted, compiled PDF bytes are written directly to stdout.
        \\
        \\Template Flags (Mutually Exclusive):
        \\  --basic              Standard invoice/receipt template (default)
        \\  --minimalist         Minimalist clean quote/invoice/handover template
        \\  --letter             Premium letter-style quote template with itemized estimation
        \\  --presentation       Freeform presentation/canvas-style template
        \\  --proposal           Structured proposal template (charts, metrics, sections)
        \\  --certificate <type> Company/legal document (see <type> list below)
        \\
        \\Certificate Types (used as: --certificate <type>):
        \\  contract               share-certificate      dividend-voucher
        \\  stock-transfer         board-resolution       director-consent
        \\  director-appointment   director-resignation   written-resolution
        \\
        \\Other Flags:
        \\  -h, --help        Show this help message and exit
        \\  -v, --version     Show version information and exit
        \\
        \\
    ;
    stderr.writeAll(usage) catch {};
    stderr.flush() catch {};
}

fn readInputData(allocator: std.mem.Allocator, input_path: ?[]const u8, stderr: *std.Io.Writer) ![]const u8 {
    const io = global_io;
    if (input_path) |path| {
        return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(50 * 1024 * 1024)) catch |err| {
            try stderr.print("Error: Cannot read input file '{s}': {s}\n", .{ path, @errorName(err) });
            return err;
        };
    } else {
        // Read from stdin (max 50MB) using streaming reader into an Allocating writer
        var read_buf: [4096]u8 = undefined;
        const stdin = std.Io.File.stdin();
        var reader = stdin.readerStreaming(io, &read_buf);
        var sink: std.Io.Writer.Allocating = .init(allocator);
        defer sink.deinit();
        
        _ = try reader.interface.streamRemaining(&sink.writer);
        const input_bytes = try sink.toOwnedSlice();
        if (input_bytes.len > 50 * 1024 * 1024) {
            allocator.free(input_bytes);
            return error.InputTooLarge;
        }
        return input_bytes;
    }
}

fn generatePdfBytes(allocator: std.mem.Allocator, mode: TemplateMode, cert_type: ?CertType, json_data: []const u8) ![]const u8 {
    switch (mode) {
        .basic => {
            const data = try lib.json.parseInvoiceJson(allocator, json_data);
            defer lib.json.freeInvoiceData(allocator, &data);
            return try lib.generateInvoice(allocator, data);
        },
        .minimalist => {
            return try lib.generateCleanQuoteFromJson(allocator, json_data);
        },
        .letter => {
            return try lib.generateLetterQuoteFromJson(allocator, json_data);
        },
        .letter_md => {
            return try lib.generateLetterFromJson(allocator, json_data);
        },
        .presentation => {
            return try lib.generatePresentationFromJson(allocator, json_data);
        },
        .proposal => {
            return try lib.generateProposalFromJson(allocator, json_data);
        },
        .crg_report => {
            // Small CrgQuote JSON (the ~28 per-lead fields) -> 20-page proposal.
            return try lib.generateCrgSolarReportFromJson(allocator, json_data);
        },
        .health_report => {
            // baton-audit SiteHealthReport JSON -> paginating branded audit PDF.
            return try lib.generateWebsiteHealthReportFromJson(allocator, json_data);
        },
        .certificate => {
            // cert_type is always set when mode == .certificate (the arg parser
            // resolves it before selecting this mode), but assert defensively.
            return switch (cert_type orelse return error.MissingCertificateType) {
                .contract => try lib.generateContractFromJson(allocator, json_data),
                .share_certificate => try lib.generateShareCertificateFromJson(allocator, json_data),
                .dividend_voucher => try lib.generateDividendVoucherFromJson(allocator, json_data),
                .stock_transfer => try lib.generateStockTransferFromJson(allocator, json_data),
                .board_resolution => try lib.generateBoardResolutionFromJson(allocator, json_data),
                .director_consent => try lib.generateDirectorConsentFromJson(allocator, json_data),
                .director_appointment => try lib.generateDirectorAppointmentFromJson(allocator, json_data),
                .director_resignation => try lib.generateDirectorResignationFromJson(allocator, json_data),
                .written_resolution => try lib.generateWrittenResolutionFromJson(allocator, json_data),
            };
        },
    }
}

/// Translate a generation error into a precise, human-readable diagnostic.
/// Strict schema-validation errors name the exact missing field and template
/// so a caller (human or LLM) can fix the payload without guessing; all other
/// errors fall through to a generic message. Always writes to stderr.
fn reportGenerationError(stderr: *std.Io.Writer, mode: TemplateMode, err: anyerror) void {
    // The schema-validation errors below are each thrown by exactly one
    // template's parser, so @tagName(mode) always names the offending template
    // (company/pages -> --letter; company_name/sections -> --minimalist or
    // --proposal, which share the ProposalData shape).
    const t = @tagName(mode);
    switch (err) {
        error.MissingCompany => stderr.print(
            "Error: Schema mismatch. Missing required field 'company' (object) for --{s} template.\n" ++
            "       A --{s} payload requires a top-level \"company\" object and a non-empty \"pages\" array.\n",
            .{ t, t },
        ) catch {},
        error.MissingPages => stderr.print(
            "Error: Schema mismatch. Missing required field 'pages' (non-empty array) for --{s} template.\n" ++
            "       A --{s} payload requires a top-level \"company\" object and a non-empty \"pages\" array.\n",
            .{ t, t },
        ) catch {},
        error.MissingCompanyName => stderr.print(
            "Error: Schema mismatch. Missing required field 'company_name' (string) for --{s} template.\n" ++
            "       A --{s} payload requires top-level \"company_name\" and a non-empty \"sections\" array.\n",
            .{ t, t },
        ) catch {},
        error.MissingSections => stderr.print(
            "Error: Schema mismatch. Missing required field 'sections' (non-empty array) for --{s} template.\n" ++
            "       A --{s} payload requires top-level \"company_name\" and a non-empty \"sections\" array.\n",
            .{ t, t },
        ) catch {},
        else => stderr.print(
            "Error: PDF generation failed for mode --{s}: {s}\n",
            .{ t, @errorName(err) },
        ) catch {},
    }
    stderr.flush() catch {};
}

fn writeOutputData(output_path: ?[]const u8, pdf_bytes: []const u8, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !void {
    const io = global_io;
    if (output_path) |path| {
        const file = std.Io.Dir.cwd().createFile(io, path, .{}) catch |err| {
            try stderr.print("Error: Cannot create output file '{s}': {s}\n", .{ path, @errorName(err) });
            return err;
        };
        defer file.close(io);

        var write_buf: [8192]u8 = undefined;
        var writer = file.writer(io, &write_buf);
        writer.interface.writeAll(pdf_bytes) catch |err| {
            try stderr.print("Error: Cannot write to output file: {s}\n", .{@errorName(err)});
            return err;
        };
        try writer.interface.flush();
        try stderr.print("Generated: {s} ({d} bytes)\n", .{ path, pdf_bytes.len });
    } else {
        // Write binary PDF stream directly to stdout
        try stdout.writeAll(pdf_bytes);
        try stdout.flush();
    }
}
