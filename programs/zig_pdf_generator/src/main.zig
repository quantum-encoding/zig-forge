//! Zig PDF Generator CLI
//!
//! Command-line interface for generating PDFs from JSON input.
//!
//! Usage:
//!   pdf-gen invoice.json output.pdf            Generate invoice PDF from JSON
//!   pdf-gen --stdin output.pdf                 Read JSON from stdin
//!   pdf-gen --demo output.pdf                  Generate demo invoice
//!   pdf-gen --receipt input.json out.pdf       Generate crypto receipt from JSON
//!   pdf-gen --demo-receipt output.pdf          Generate demo crypto receipt
//!   pdf-gen --contract input.json out.pdf      Generate contract/document from JSON
//!   pdf-gen --demo-contract output.pdf         Generate demo contract
//!   pdf-gen --certificate input.json out.pdf   Generate share certificate from JSON
//!   pdf-gen --demo-certificate output.pdf      Generate demo share certificate
//!   pdf-gen --dividend input.json out.pdf      Generate dividend voucher from JSON
//!   pdf-gen --demo-dividend output.pdf         Generate demo UK dividend voucher
//!   pdf-gen --demo-dividend-ie output.pdf      Generate demo Irish dividend voucher (with DWT)
//!   pdf-gen --demo-dividend-ie-exempt out.pdf  Generate demo Irish dividend (DWT exempt)
//!   pdf-gen --transfer input.json out.pdf      Generate stock transfer form from JSON
//!   pdf-gen --demo-transfer output.pdf         Generate demo stock transfer form
//!   pdf-gen --resolution input.json out.pdf    Generate board resolution from JSON
//!   pdf-gen --demo-resolution output.pdf       Generate demo board resolution
//!   pdf-gen --consent input.json out.pdf       Generate director consent from JSON
//!   pdf-gen --demo-consent output.pdf          Generate demo director consent
//!   pdf-gen --appointment input.json out.pdf   Generate director appointment from JSON
//!   pdf-gen --demo-appointment output.pdf      Generate demo director appointment
//!   pdf-gen --resignation input.json out.pdf   Generate director resignation from JSON
//!   pdf-gen --demo-resignation output.pdf      Generate demo director resignation
//!   pdf-gen --written input.json out.pdf       Generate written resolution from JSON
//!   pdf-gen --demo-ordinary output.pdf         Generate demo ordinary resolution
//!   pdf-gen --demo-special output.pdf          Generate demo special resolution
//!   pdf-gen --presentation input.json out.pdf  Generate presentation/canvas PDF from JSON
//!   pdf-gen --proposal input.json out.pdf      Generate branded proposal PDF from JSON
//!   pdf-gen --demo-proposal output.pdf         Generate demo CRG Direct solar proposal
//!   pdf-gen --help                             Show help

const std = @import("std");
const lib = @import("lib.zig");

const VERSION = "1.0.0";

// Global IO context from init
var global_io: std.Io = undefined;
var global_allocator: std.mem.Allocator = undefined;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    // Store globals for helper functions
    global_io = init.io;
    global_allocator = allocator;

    // Collect args into a slice
    var args_list: std.ArrayListUnmanaged([]const u8) = .empty;
    defer args_list.deinit(allocator);

    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    while (args_iter.next()) |arg| {
        try args_list.append(allocator, arg);
    }
    const args = args_list.items;

    if (args.len < 2) {
        printUsage();
        return;
    }

    const cmd = args[1];

    if (std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "-h")) {
        printUsage();
        return;
    }

    if (std.mem.eql(u8, cmd, "--version") or std.mem.eql(u8, cmd, "-v")) {
        std.debug.print("zig-pdf-generator {s}\n", .{VERSION});
        return;
    }

    if (std.mem.eql(u8, cmd, "--demo")) {
        if (args.len < 3) {
            std.debug.print("Error: Missing output file path\n", .{});
            printUsage();
            return;
        }
        try generateDemo(allocator, args[2]);
        return;
    }

    if (std.mem.eql(u8, cmd, "--receipt")) {
        if (args.len < 4) {
            std.debug.print("Error: Missing input or output file path\n", .{});
            std.debug.print("Usage: pdf-gen --receipt <input.json> <output.pdf>\n", .{});
            return;
        }
        try generateReceiptFromFile(allocator, args[2], args[3]);
        return;
    }

    if (std.mem.eql(u8, cmd, "--demo-receipt")) {
        if (args.len < 3) {
            std.debug.print("Error: Missing output file path\n", .{});
            printUsage();
            return;
        }
        try generateDemoReceipt(allocator, args[2]);
        return;
    }

    if (std.mem.eql(u8, cmd, "--contract")) {
        if (args.len < 4) {
            std.debug.print("Error: Missing input or output file path\n", .{});
            std.debug.print("Usage: pdf-gen --contract <input.json> <output.pdf>\n", .{});
            return;
        }
        try generateContractFromFile(allocator, args[2], args[3]);
        return;
    }

    if (std.mem.eql(u8, cmd, "--demo-contract")) {
        if (args.len < 3) {
            std.debug.print("Error: Missing output file path\n", .{});
            printUsage();
            return;
        }
        try generateDemoContract(allocator, args[2]);
        return;
    }

    if (std.mem.eql(u8, cmd, "--certificate")) {
        if (args.len < 4) {
            std.debug.print("Error: Missing input or output file path\n", .{});
            std.debug.print("Usage: pdf-gen --certificate <input.json> <output.pdf>\n", .{});
            return;
        }
        try generateCertificateFromFile(allocator, args[2], args[3]);
        return;
    }

    if (std.mem.eql(u8, cmd, "--demo-certificate")) {
        if (args.len < 3) {
            std.debug.print("Error: Missing output file path\n", .{});
            printUsage();
            return;
        }
        try generateDemoCertificate(allocator, args[2]);
        return;
    }

    if (std.mem.eql(u8, cmd, "--dividend")) {
        if (args.len < 4) {
            std.debug.print("Error: Missing input or output file path\n", .{});
            std.debug.print("Usage: pdf-gen --dividend <input.json> <output.pdf>\n", .{});
            return;
        }
        try generateDividendFromFile(allocator, args[2], args[3]);
        return;
    }

    if (std.mem.eql(u8, cmd, "--demo-dividend")) {
        if (args.len < 3) {
            std.debug.print("Error: Missing output file path\n", .{});
            printUsage();
            return;
        }
        try generateDemoDividend(allocator, args[2]);
        return;
    }

    if (std.mem.eql(u8, cmd, "--demo-dividend-ie")) {
        if (args.len < 3) {
            std.debug.print("Error: Missing output file path\n", .{});
            printUsage();
            return;
        }
        try generateDemoIrishDividend(allocator, args[2]);
        return;
    }

    if (std.mem.eql(u8, cmd, "--demo-dividend-ie-exempt")) {
        if (args.len < 3) {
            std.debug.print("Error: Missing output file path\n", .{});
            printUsage();
            return;
        }
        try generateDemoIrishDividendExempt(allocator, args[2]);
        return;
    }

    if (std.mem.eql(u8, cmd, "--transfer")) {
        if (args.len < 4) {
            std.debug.print("Error: Missing input or output file path\n", .{});
            std.debug.print("Usage: pdf-gen --transfer <input.json> <output.pdf>\n", .{});
            return;
        }
        try generateTransferFromFile(allocator, args[2], args[3]);
        return;
    }

    if (std.mem.eql(u8, cmd, "--demo-transfer")) {
        if (args.len < 3) {
            std.debug.print("Error: Missing output file path\n", .{});
            printUsage();
            return;
        }
        try generateDemoTransfer(allocator, args[2]);
        return;
    }

    if (std.mem.eql(u8, cmd, "--resolution")) {
        if (args.len < 4) {
            std.debug.print("Error: Missing input or output file path\n", .{});
            std.debug.print("Usage: pdf-gen --resolution <input.json> <output.pdf>\n", .{});
            return;
        }
        try generateResolutionFromFile(allocator, args[2], args[3]);
        return;
    }

    if (std.mem.eql(u8, cmd, "--demo-resolution")) {
        if (args.len < 3) {
            std.debug.print("Error: Missing output file path\n", .{});
            printUsage();
            return;
        }
        try generateDemoResolution(allocator, args[2]);
        return;
    }

    if (std.mem.eql(u8, cmd, "--consent")) {
        if (args.len < 4) {
            std.debug.print("Error: Missing input JSON or output file path\n", .{});
            printUsage();
            return;
        }
        try generateConsent(allocator, args[2], args[3]);
        return;
    }

    if (std.mem.eql(u8, cmd, "--demo-consent")) {
        if (args.len < 3) {
            std.debug.print("Error: Missing output file path\n", .{});
            printUsage();
            return;
        }
        try generateDemoConsent(allocator, args[2]);
        return;
    }

    if (std.mem.eql(u8, cmd, "--appointment")) {
        if (args.len < 4) {
            std.debug.print("Error: Missing input JSON or output file path\n", .{});
            printUsage();
            return;
        }
        try generateAppointment(allocator, args[2], args[3]);
        return;
    }

    if (std.mem.eql(u8, cmd, "--demo-appointment")) {
        if (args.len < 3) {
            std.debug.print("Error: Missing output file path\n", .{});
            printUsage();
            return;
        }
        try generateDemoAppointment(allocator, args[2]);
        return;
    }

    if (std.mem.eql(u8, cmd, "--resignation")) {
        if (args.len < 4) {
            std.debug.print("Error: Missing input JSON or output file path\n", .{});
            printUsage();
            return;
        }
        try generateResignation(allocator, args[2], args[3]);
        return;
    }

    if (std.mem.eql(u8, cmd, "--demo-resignation")) {
        if (args.len < 3) {
            std.debug.print("Error: Missing output file path\n", .{});
            printUsage();
            return;
        }
        try generateDemoResignation(allocator, args[2]);
        return;
    }

    if (std.mem.eql(u8, cmd, "--written")) {
        if (args.len < 4) {
            std.debug.print("Error: Missing input JSON or output file path\n", .{});
            printUsage();
            return;
        }
        try generateWrittenResolution(allocator, args[2], args[3]);
        return;
    }

    if (std.mem.eql(u8, cmd, "--demo-ordinary")) {
        if (args.len < 3) {
            std.debug.print("Error: Missing output file path\n", .{});
            printUsage();
            return;
        }
        try generateDemoOrdinary(allocator, args[2]);
        return;
    }

    if (std.mem.eql(u8, cmd, "--demo-special")) {
        if (args.len < 3) {
            std.debug.print("Error: Missing output file path\n", .{});
            printUsage();
            return;
        }
        try generateDemoSpecial(allocator, args[2]);
        return;
    }

    if (std.mem.eql(u8, cmd, "--presentation")) {
        if (args.len < 4) {
            std.debug.print("Error: Missing input or output file path\n", .{});
            std.debug.print("Usage: pdf-gen --presentation <input.json> <output.pdf>\n", .{});
            return;
        }
        try generatePresentationFromFile(allocator, args[2], args[3]);
        return;
    }

    if (std.mem.eql(u8, cmd, "--proposal")) {
        if (args.len < 4) {
            std.debug.print("Error: Missing input or output file path\n", .{});
            std.debug.print("Usage: pdf-gen --proposal <input.json> <output.pdf>\n", .{});
            return;
        }
        try generateProposalFromFile(allocator, args[2], args[3]);
        return;
    }

    if (std.mem.eql(u8, cmd, "--demo-proposal")) {
        if (args.len < 3) {
            std.debug.print("Error: Missing output file path\n", .{});
            return;
        }
        try generateDemoProposal(allocator, args[2]);
        return;
    }

    if (std.mem.eql(u8, cmd, "--template-card")) {
        if (args.len < 4) {
            std.debug.print("Error: Missing input or output file path\n", .{});
            std.debug.print("Usage: pdf-gen --template-card <input.json> <output.pdf>\n", .{});
            return;
        }
        try generateTemplateCardFromFile(allocator, args[2], args[3]);
        return;
    }

    if (std.mem.eql(u8, cmd, "--demo-template-card")) {
        if (args.len < 3) {
            std.debug.print("Error: Missing output file path\n", .{});
            return;
        }
        try generateDemoTemplateCardCmd(allocator, args[2]);
        return;
    }

    if (std.mem.eql(u8, cmd, "--stdin")) {
        if (args.len < 3) {
            std.debug.print("Error: Missing output file path\n", .{});
            printUsage();
            return;
        }
        try generateFromStdin(allocator, args[2]);
        return;
    }

    // Default: json_file output_file
    if (args.len < 3) {
        std.debug.print("Error: Missing output file path\n", .{});
        printUsage();
        return;
    }

    try generateFromFile(allocator, args[1], args[2]);
}

fn printUsage() void {
    std.debug.print(
        \\Zig PDF Generator v{s}
        \\
        \\Usage:
        \\  pdf-gen <input.json> <output.pdf>              Generate invoice PDF from JSON
        \\  pdf-gen --stdin <output.pdf>                   Read JSON from stdin
        \\  pdf-gen --demo <output.pdf>                    Generate demo invoice
        \\  pdf-gen --receipt <input.json> <out.pdf>       Generate crypto receipt from JSON
        \\  pdf-gen --demo-receipt <output.pdf>            Generate demo crypto receipt
        \\  pdf-gen --contract <input.json> <out.pdf>      Generate contract/document from JSON
        \\  pdf-gen --demo-contract <output.pdf>           Generate demo contract
        \\  pdf-gen --certificate <input.json> <out.pdf>   Generate share certificate from JSON
        \\  pdf-gen --demo-certificate <output.pdf>        Generate demo share certificate
        \\  pdf-gen --dividend <input.json> <out.pdf>      Generate dividend voucher from JSON
        \\  pdf-gen --demo-dividend <output.pdf>           Generate demo UK dividend voucher
        \\  pdf-gen --demo-dividend-ie <output.pdf>        Generate demo Irish dividend (with DWT)
        \\  pdf-gen --demo-dividend-ie-exempt <out.pdf>    Generate demo Irish dividend (DWT exempt)
        \\  pdf-gen --transfer <input.json> <out.pdf>      Generate stock transfer form from JSON
        \\  pdf-gen --demo-transfer <output.pdf>           Generate demo stock transfer form
        \\  pdf-gen --resolution <input.json> <out.pdf>    Generate board resolution from JSON
        \\  pdf-gen --demo-resolution <output.pdf>         Generate demo board resolution
        \\  pdf-gen --consent <input.json> <out.pdf>       Generate director consent from JSON
        \\  pdf-gen --demo-consent <output.pdf>            Generate demo director consent
        \\  pdf-gen --appointment <input.json> <out.pdf>   Generate director appointment from JSON
        \\  pdf-gen --demo-appointment <output.pdf>        Generate demo director appointment
        \\  pdf-gen --resignation <input.json> <out.pdf>   Generate director resignation from JSON
        \\  pdf-gen --demo-resignation <output.pdf>        Generate demo director resignation
        \\  pdf-gen --written <input.json> <out.pdf>       Generate written resolution from JSON
        \\  pdf-gen --demo-ordinary <output.pdf>           Generate demo ordinary resolution
        \\  pdf-gen --demo-special <output.pdf>            Generate demo special resolution
        \\  pdf-gen --presentation <input.json> <out.pdf>  Generate presentation/canvas PDF
        \\  pdf-gen --proposal <input.json> <out.pdf>      Generate branded proposal PDF
        \\  pdf-gen --demo-proposal <output.pdf>           Generate demo CRG solar proposal
        \\  pdf-gen --template-card <input.json> <out.pdf> Generate template card PDF
        \\  pdf-gen --demo-template-card <output.pdf>      Generate demo template card
        \\  pdf-gen --help                                 Show this help
        \\  pdf-gen --version                              Show version
        \\
        \\Invoice JSON Format:
        \\  {{
        \\    "document_type": "invoice",
        \\    "company_name": "Your Company",
        \\    "invoice_number": "INV-001",
        \\    "items": [{{"description": "Service", "quantity": 10, "unit_price": 100, "total": 1000}}],
        \\    "subtotal": 1000,
        \\    "tax_rate": 0.21,
        \\    "total": 1210
        \\  }}
        \\
        \\Contract JSON Format:
        \\  {{
        \\    "document_type": "document",
        \\    "title": "Contract Title",
        \\    "parties": [...],
        \\    "sections": [...],
        \\    "signatures": [...],
        \\    "variables": {{...}}
        \\  }}
        \\
        \\Crypto Receipt JSON Format:
        \\  {{
        \\    "tx_hash": "abc123...",
        \\    "from_address": "bc1q...",
        \\    "to_address": "bc1q...",
        \\    "amount": "1.23456789",
        \\    "symbol": "BTC",
        \\    "network": "bitcoin",
        \\    "confirmations": 6,
        \\    "fiat_value": 45678.90
        \\  }}
        \\
        \\Share Certificate JSON Format:
        \\  {{
        \\    "certificate": {{"number": "001", "issue_date": "2026-01-04"}},
        \\    "company": {{"name": "Company Ltd", "registration_number": "12345678"}},
        \\    "holder": {{"name": "John Smith", "address": {{...}}}},
        \\    "shares": {{"quantity": 100, "class": "Ordinary", "nominal_value": 0.01}},
        \\    "signatories": [...]
        \\  }}
        \\
        \\Dividend Voucher JSON Format:
        \\  {{
        \\    "voucher": {{"number": "DIV-2026-001", "date": "31 March 2026", "tax_year": "2025/26"}},
        \\    "company": {{"name": "Company Ltd", "registration_number": "12345678", ...}},
        \\    "shareholder": {{"name": "John Smith", "address": {{...}}}},
        \\    "dividend": {{"shares_held": 100, "rate_per_share": 0.10, "gross_amount": 10.00, ...}},
        \\    "payment": {{"method": "Bank Transfer", "date": "1 April 2026"}},
        \\    "declaration": {{"resolution_date": "25 March 2026", "payment_date": "1 April 2026"}},
        \\    "signatory": {{"role": "Director", "name": "Jane Doe", "date": "31 March 2026"}}
        \\  }}
        \\
    , .{VERSION});
}

fn generateFromFile(allocator: std.mem.Allocator, json_path: []const u8, output_path: []const u8) !void {
    // Create IO context
    const io = global_io;

    // Read JSON file
    const json_data = std.Io.Dir.cwd().readFileAlloc(io, json_path, allocator, .limited(10 * 1024 * 1024)) catch |err| {
        std.debug.print("Error: Cannot read '{s}': {s}\n", .{ json_path, @errorName(err) });
        return;
    };
    defer allocator.free(json_data);

    try generatePdfWithIo(allocator, io, json_data, output_path);
    std.debug.print("Generated: {s}\n", .{output_path});
}

fn generateFromStdin(allocator: std.mem.Allocator, output_path: []const u8) !void {
    // Create IO context
    const io = global_io;

    // Read from stdin using posix
    var buffer: std.ArrayListUnmanaged(u8) = .empty;
    defer buffer.deinit(allocator);

    var read_buf: [4096]u8 = undefined;
    while (true) {
        const bytes_read = std.posix.read(0, &read_buf) catch |err| {
            std.debug.print("Error: Cannot read stdin: {s}\n", .{@errorName(err)});
            return;
        };
        if (bytes_read == 0) break;
        try buffer.appendSlice(allocator, read_buf[0..bytes_read]);
    }

    try generatePdfWithIo(allocator, io, buffer.items, output_path);
    std.debug.print("Generated: {s}\n", .{output_path});
}

fn generatePdfWithIo(allocator: std.mem.Allocator, io: std.Io, json_data: []const u8, output_path: []const u8) !void {
    // Parse JSON
    const data = lib.json.parseInvoiceJson(allocator, json_data) catch |err| {
        std.debug.print("Error: Invalid JSON: {s}\n", .{@errorName(err)});
        return;
    };
    defer lib.json.freeInvoiceData(allocator, &data);

    // Generate PDF
    const pdf_bytes = lib.generateInvoice(allocator, data) catch |err| {
        std.debug.print("Error: PDF generation failed: {s}\n", .{@errorName(err)});
        return;
    };
    defer allocator.free(pdf_bytes);

    // Write to file
    const file = std.Io.Dir.cwd().createFile(io, output_path, .{}) catch |err| {
        std.debug.print("Error: Cannot create '{s}': {s}\n", .{ output_path, @errorName(err) });
        return;
    };
    defer file.close(io);

    var write_buf: [8192]u8 = undefined;
    var writer = file.writer(io, &write_buf);
    writer.interface.writeAll(pdf_bytes) catch |err| {
        std.debug.print("Error: Cannot write file: {s}\n", .{@errorName(err)});
        return;
    };
    try writer.interface.flush();
}

fn generateDemo(allocator: std.mem.Allocator, output_path: []const u8) !void {
    // Create IO context
    const io = global_io;

    const items = [_]lib.LineItem{
        .{ .description = "Web Application Development", .quantity = 80, .unit_price = 125, .total = 10000 },
        .{ .description = "UI/UX Design Services", .quantity = 40, .unit_price = 100, .total = 4000 },
        .{ .description = "Server Infrastructure Setup", .quantity = 1, .unit_price = 2500, .total = 2500 },
        .{ .description = "Technical Documentation", .quantity = 16, .unit_price = 75, .total = 1200 },
        .{ .description = "Training Session (2 hours)", .quantity = 4, .unit_price = 200, .total = 800 },
    };

    const subtotal: f64 = 18500;
    const tax_rate: f64 = 0.21;
    const tax_amount: f64 = subtotal * tax_rate;
    const total: f64 = subtotal + tax_amount;

    const data = lib.InvoiceData{
        .document_type = "invoice",
        .company_name = "Quantum Code Labs",
        .company_address = "42 Innovation Drive, Tech Valley, CA 94025",
        .company_vat = "US-QCL-2025-001",
        .client_name = "Stellar Industries Inc.",
        .client_address = "789 Enterprise Blvd, Business Park, NY 10001",
        .client_vat = "US-STL-2024-555",
        .invoice_number = "QCL-2025-0001",
        .invoice_date = "2025-11-29",
        .due_date = "2025-12-29",
        .items = &items,
        .subtotal = subtotal,
        .tax_rate = tax_rate,
        .tax_amount = tax_amount,
        .total = total,
        .notes = "Thank you for choosing Quantum Code Labs! Payment can be made via bank transfer or credit card.",
        .payment_terms = "Net 30 - Payment due within 30 days of invoice date.",
        .primary_color = "#2563eb",
        .secondary_color = "#1e3a5f",
        .title_color = "#2563eb",
    };

    const pdf_bytes = try lib.generateInvoice(allocator, data);
    defer allocator.free(pdf_bytes);

    const file = try std.Io.Dir.cwd().createFile(io, output_path, .{});
    defer file.close(io);

    var write_buf: [8192]u8 = undefined;
    var writer = file.writer(io, &write_buf);
    try writer.interface.writeAll(pdf_bytes);
    try writer.interface.flush();

    std.debug.print("Generated demo invoice: {s}\n", .{output_path});
    std.debug.print("  Company: {s}\n", .{data.company_name});
    std.debug.print("  Client: {s}\n", .{data.client_name});
    std.debug.print("  Total: ${d:.2}\n", .{total});
}

// =============================================================================
// Crypto Receipt Commands
// =============================================================================

fn generateReceiptFromFile(allocator: std.mem.Allocator, json_path: []const u8, output_path: []const u8) !void {
    // Create IO context
    const io = global_io;

    // Read JSON file
    const json_data = std.Io.Dir.cwd().readFileAlloc(io, json_path, allocator, .limited(1 * 1024 * 1024)) catch |err| {
        std.debug.print("Error: Cannot read '{s}': {s}\n", .{ json_path, @errorName(err) });
        return;
    };
    defer allocator.free(json_data);

    // Parse JSON
    const data = lib.json.parseCryptoReceiptJson(allocator, json_data) catch |err| {
        std.debug.print("Error: Invalid JSON: {s}\n", .{@errorName(err)});
        return;
    };
    defer lib.json.freeCryptoReceiptData(allocator, &data);

    // Generate PDF
    const pdf_bytes = lib.generateCryptoReceipt(allocator, data) catch |err| {
        std.debug.print("Error: PDF generation failed: {s}\n", .{@errorName(err)});
        return;
    };
    defer allocator.free(pdf_bytes);

    // Write to file
    const file = std.Io.Dir.cwd().createFile(io, output_path, .{}) catch |err| {
        std.debug.print("Error: Cannot create '{s}': {s}\n", .{ output_path, @errorName(err) });
        return;
    };
    defer file.close(io);

    var write_buf: [8192]u8 = undefined;
    var writer = file.writer(io, &write_buf);
    writer.interface.writeAll(pdf_bytes) catch |err| {
        std.debug.print("Error: Cannot write file: {s}\n", .{@errorName(err)});
        return;
    };
    try writer.interface.flush();

    std.debug.print("Generated crypto receipt: {s}\n", .{output_path});
}

fn generateDemoReceipt(allocator: std.mem.Allocator, output_path: []const u8) !void {
    // Create IO context
    const io = global_io;

    const data = lib.CryptoReceiptData{
        .tx_hash = "7b5e8f4a3c2d1b9e6f0a4c8d2e1f3b5a7c9d0e2f4a6b8c0d2e4f6a8b0c2d4e6f",
        .from_address = "bc1qar0srrr7xfkvy5l643lydnw9re59gtzzwf5mdq",
        .to_address = "bc1qc7slrfxkknqcq2jevvvkdgvrt8080852dfjewde",
        .amount = "0.25000000",
        .symbol = "BTC",
        .network = .bitcoin,
        .timestamp = "2026-01-04 14:32:18 UTC",
        .confirmations = 6,
        .block_height = 876543,
        .network_fee = "0.00004521",
        .fiat_value = 25850.00,
        .fiat_symbol = "USD",
        .memo = "Payment for consulting services - Invoice #QCL-2026-001",
    };

    const pdf_bytes = try lib.generateCryptoReceipt(allocator, data);
    defer allocator.free(pdf_bytes);

    const file = try std.Io.Dir.cwd().createFile(io, output_path, .{});
    defer file.close(io);

    var write_buf: [8192]u8 = undefined;
    var writer = file.writer(io, &write_buf);
    try writer.interface.writeAll(pdf_bytes);
    try writer.interface.flush();

    std.debug.print("Generated demo crypto receipt: {s}\n", .{output_path});
    std.debug.print("  Network:  Bitcoin\n", .{});
    std.debug.print("  Amount:   {s} BTC\n", .{data.amount});
    std.debug.print("  USD:      ${d:.2}\n", .{data.fiat_value.?});
    std.debug.print("  Status:   Confirmed ({d} confirmations)\n", .{data.confirmations.?});
}

// =============================================================================
// Contract/Document Commands
// =============================================================================

fn generateContractFromFile(allocator: std.mem.Allocator, json_path: []const u8, output_path: []const u8) !void {
    // Create IO context
    const io = global_io;

    // Read JSON file
    const json_data = std.Io.Dir.cwd().readFileAlloc(io, json_path, allocator, .limited(10 * 1024 * 1024)) catch |err| {
        std.debug.print("Error: Cannot read '{s}': {s}\n", .{ json_path, @errorName(err) });
        return;
    };
    defer allocator.free(json_data);

    // Generate PDF from JSON
    const pdf_bytes = lib.generateContractFromJson(allocator, json_data) catch |err| {
        std.debug.print("Error: Contract generation failed: {s}\n", .{@errorName(err)});
        return;
    };
    defer allocator.free(pdf_bytes);

    // Write to file
    const file = std.Io.Dir.cwd().createFile(io, output_path, .{}) catch |err| {
        std.debug.print("Error: Cannot create '{s}': {s}\n", .{ output_path, @errorName(err) });
        return;
    };
    defer file.close(io);

    var write_buf: [8192]u8 = undefined;
    var writer = file.writer(io, &write_buf);
    writer.interface.writeAll(pdf_bytes) catch |err| {
        std.debug.print("Error: Cannot write file: {s}\n", .{@errorName(err)});
        return;
    };
    try writer.interface.flush();

    std.debug.print("Generated contract: {s}\n", .{output_path});
}

fn generateDemoContract(allocator: std.mem.Allocator, output_path: []const u8) !void {
    // Create IO context
    const io = global_io;

    // Generate demo contract PDF
    const pdf_bytes = try lib.generateDemoContract(allocator);
    defer allocator.free(pdf_bytes);

    const file = try std.Io.Dir.cwd().createFile(io, output_path, .{});
    defer file.close(io);

    var write_buf: [8192]u8 = undefined;
    var writer = file.writer(io, &write_buf);
    try writer.interface.writeAll(pdf_bytes);
    try writer.interface.flush();

    std.debug.print("Generated demo contract: {s}\n", .{output_path});
    std.debug.print("  Title: Kitchen Renovation Contract\n", .{});
    std.debug.print("  Parties: Contractor, Client\n", .{});
    std.debug.print("  Sections: 5 (Scope, Payment, Timeline, Warranties, Terms)\n", .{});
}

// =============================================================================
// Share Certificate Commands
// =============================================================================

fn generateCertificateFromFile(allocator: std.mem.Allocator, json_path: []const u8, output_path: []const u8) !void {
    // Create IO context
    const io = global_io;

    // Read JSON file
    const json_data = std.Io.Dir.cwd().readFileAlloc(io, json_path, allocator, .limited(10 * 1024 * 1024)) catch |err| {
        std.debug.print("Error: Cannot read '{s}': {s}\n", .{ json_path, @errorName(err) });
        return;
    };
    defer allocator.free(json_data);

    // Generate PDF from JSON
    const pdf_bytes = lib.generateShareCertificateFromJson(allocator, json_data) catch |err| {
        std.debug.print("Error: Share certificate generation failed: {s}\n", .{@errorName(err)});
        return;
    };
    defer allocator.free(pdf_bytes);

    // Write to file
    const file = std.Io.Dir.cwd().createFile(io, output_path, .{}) catch |err| {
        std.debug.print("Error: Cannot create '{s}': {s}\n", .{ output_path, @errorName(err) });
        return;
    };
    defer file.close(io);

    var write_buf: [8192]u8 = undefined;
    var writer = file.writer(io, &write_buf);
    writer.interface.writeAll(pdf_bytes) catch |err| {
        std.debug.print("Error: Cannot write file: {s}\n", .{@errorName(err)});
        return;
    };
    try writer.interface.flush();

    std.debug.print("Generated share certificate: {s}\n", .{output_path});
}

fn generateDemoCertificate(allocator: std.mem.Allocator, output_path: []const u8) !void {
    // Create IO context
    const io = global_io;

    // Generate demo share certificate PDF
    const pdf_bytes = try lib.generateDemoShareCertificate(allocator);
    defer allocator.free(pdf_bytes);

    const file = try std.Io.Dir.cwd().createFile(io, output_path, .{});
    defer file.close(io);

    var write_buf: [8192]u8 = undefined;
    var writer = file.writer(io, &write_buf);
    try writer.interface.writeAll(pdf_bytes);
    try writer.interface.flush();

    std.debug.print("Generated demo share certificate: {s}\n", .{output_path});
    std.debug.print("  Company: QUANTUM ENCODING LTD\n", .{});
    std.debug.print("  Holder: Mr Lance Shikuku\n", .{});
    std.debug.print("  Shares: 5 Ordinary @ GBP 0.01 each\n", .{});
}

// =============================================================================
// Dividend Voucher Commands
// =============================================================================

fn generateDividendFromFile(allocator: std.mem.Allocator, json_path: []const u8, output_path: []const u8) !void {
    // Create IO context
    const io = global_io;

    // Read JSON file
    const json_data = std.Io.Dir.cwd().readFileAlloc(io, json_path, allocator, .limited(10 * 1024 * 1024)) catch |err| {
        std.debug.print("Error: Cannot read '{s}': {s}\n", .{ json_path, @errorName(err) });
        return;
    };
    defer allocator.free(json_data);

    // Generate PDF from JSON
    const pdf_bytes = lib.generateDividendVoucherFromJson(allocator, json_data) catch |err| {
        std.debug.print("Error: Dividend voucher generation failed: {s}\n", .{@errorName(err)});
        return;
    };
    defer allocator.free(pdf_bytes);

    // Write to file
    const file = std.Io.Dir.cwd().createFile(io, output_path, .{}) catch |err| {
        std.debug.print("Error: Cannot create '{s}': {s}\n", .{ output_path, @errorName(err) });
        return;
    };
    defer file.close(io);

    var write_buf: [8192]u8 = undefined;
    var writer = file.writer(io, &write_buf);
    writer.interface.writeAll(pdf_bytes) catch |err| {
        std.debug.print("Error: Cannot write file: {s}\n", .{@errorName(err)});
        return;
    };
    try writer.interface.flush();

    std.debug.print("Generated dividend voucher: {s}\n", .{output_path});
}

fn generateDemoDividend(allocator: std.mem.Allocator, output_path: []const u8) !void {
    // Create IO context
    const io = global_io;

    // Generate demo dividend voucher PDF
    const pdf_bytes = try lib.generateDemoDividendVoucher(allocator);
    defer allocator.free(pdf_bytes);

    const file = try std.Io.Dir.cwd().createFile(io, output_path, .{});
    defer file.close(io);

    var write_buf: [8192]u8 = undefined;
    var writer = file.writer(io, &write_buf);
    try writer.interface.writeAll(pdf_bytes);
    try writer.interface.flush();

    std.debug.print("Generated demo dividend voucher: {s}\n", .{output_path});
    std.debug.print("  Company: QUANTUM ENCODING LTD\n", .{});
    std.debug.print("  Shareholder: Mr Lance John Pearson\n", .{});
    std.debug.print("  Dividend: GBP 5.00 (5 shares @ GBP 1.00)\n", .{});
}

fn generateDemoIrishDividend(allocator: std.mem.Allocator, output_path: []const u8) !void {
    // Create IO context
    const io = global_io;

    // Generate demo Irish dividend voucher with DWT
    const pdf_bytes = try lib.generateDemoIrishDividendVoucher(allocator);
    defer allocator.free(pdf_bytes);

    const file = try std.Io.Dir.cwd().createFile(io, output_path, .{});
    defer file.close(io);

    var write_buf: [8192]u8 = undefined;
    var writer = file.writer(io, &write_buf);
    try writer.interface.writeAll(pdf_bytes);
    try writer.interface.flush();

    std.debug.print("Generated demo Irish dividend voucher: {s}\n", .{output_path});
    std.debug.print("  Company: QUANTUM ENCODING IRELAND LIMITED\n", .{});
    std.debug.print("  Shareholder: Mr Seamus O'Connor\n", .{});
    std.debug.print("  Gross Dividend: EUR 1000.00 (100 shares @ EUR 10.00)\n", .{});
    std.debug.print("  DWT Withheld (25%%): EUR 250.00\n", .{});
    std.debug.print("  Net Payable: EUR 750.00\n", .{});
}

fn generateDemoIrishDividendExempt(allocator: std.mem.Allocator, output_path: []const u8) !void {
    // Create IO context
    const io = global_io;

    // Generate demo Irish dividend voucher with DWT exemption
    const pdf_bytes = try lib.generateDemoIrishDividendVoucherExempt(allocator);
    defer allocator.free(pdf_bytes);

    const file = try std.Io.Dir.cwd().createFile(io, output_path, .{});
    defer file.close(io);

    var write_buf: [8192]u8 = undefined;
    var writer = file.writer(io, &write_buf);
    try writer.interface.writeAll(pdf_bytes);
    try writer.interface.flush();

    std.debug.print("Generated demo Irish dividend voucher (DWT exempt): {s}\n", .{output_path});
    std.debug.print("  Company: QUANTUM ENCODING IRELAND LIMITED\n", .{});
    std.debug.print("  Shareholder: ACME HOLDINGS PLC (France)\n", .{});
    std.debug.print("  Gross Dividend: EUR 5000.00 (1000 shares @ EUR 5.00)\n", .{});
    std.debug.print("  DWT: EXEMPT (EU Parent-Subsidiary Directive)\n", .{});
    std.debug.print("  Net Payable: EUR 5000.00\n", .{});
}

// =============================================================================
// Stock Transfer Commands
// =============================================================================

fn generateTransferFromFile(allocator: std.mem.Allocator, json_path: []const u8, output_path: []const u8) !void {
    // Create IO context
    const io = global_io;

    // Read JSON file
    const json_data = std.Io.Dir.cwd().readFileAlloc(io, json_path, allocator, .limited(10 * 1024 * 1024)) catch |err| {
        std.debug.print("Error: Cannot read '{s}': {s}\n", .{ json_path, @errorName(err) });
        return;
    };
    defer allocator.free(json_data);

    // Generate PDF from JSON
    const pdf_bytes = lib.generateStockTransferFromJson(allocator, json_data) catch |err| {
        std.debug.print("Error: Stock transfer form generation failed: {s}\n", .{@errorName(err)});
        return;
    };
    defer allocator.free(pdf_bytes);

    // Write to file
    const file = std.Io.Dir.cwd().createFile(io, output_path, .{}) catch |err| {
        std.debug.print("Error: Cannot create '{s}': {s}\n", .{ output_path, @errorName(err) });
        return;
    };
    defer file.close(io);

    var write_buf: [8192]u8 = undefined;
    var writer = file.writer(io, &write_buf);
    writer.interface.writeAll(pdf_bytes) catch |err| {
        std.debug.print("Error: Cannot write file: {s}\n", .{@errorName(err)});
        return;
    };
    try writer.interface.flush();

    std.debug.print("Generated stock transfer form: {s}\n", .{output_path});
}

fn generateDemoTransfer(allocator: std.mem.Allocator, output_path: []const u8) !void {
    // Create IO context
    const io = global_io;

    // Generate demo stock transfer form PDF
    const pdf_bytes = try lib.generateDemoStockTransfer(allocator);
    defer allocator.free(pdf_bytes);

    const file = try std.Io.Dir.cwd().createFile(io, output_path, .{});
    defer file.close(io);

    var write_buf: [8192]u8 = undefined;
    var writer = file.writer(io, &write_buf);
    try writer.interface.writeAll(pdf_bytes);
    try writer.interface.flush();

    std.debug.print("Generated demo stock transfer form: {s}\n", .{output_path});
    std.debug.print("  Company: QUANTUM ENCODING LTD\n", .{});
    std.debug.print("  Transferor: RICHARD ALEXANDER TUNE\n", .{});
    std.debug.print("  Transferee: LANCE JOHN PEARSON\n", .{});
    std.debug.print("  Shares: 5 Ordinary @ GBP 0.01\n", .{});
}

// =============================================================================
// Board Resolution Commands
// =============================================================================

fn generateResolutionFromFile(allocator: std.mem.Allocator, json_path: []const u8, output_path: []const u8) !void {
    // Create IO context
    const io = global_io;

    // Read JSON file
    const json_data = std.Io.Dir.cwd().readFileAlloc(io, json_path, allocator, .limited(10 * 1024 * 1024)) catch |err| {
        std.debug.print("Error: Cannot read '{s}': {s}\n", .{ json_path, @errorName(err) });
        return;
    };
    defer allocator.free(json_data);

    // Generate PDF from JSON
    const pdf_bytes = lib.generateBoardResolutionFromJson(allocator, json_data) catch |err| {
        std.debug.print("Error: Board resolution generation failed: {s}\n", .{@errorName(err)});
        return;
    };
    defer allocator.free(pdf_bytes);

    // Write to file
    const file = std.Io.Dir.cwd().createFile(io, output_path, .{}) catch |err| {
        std.debug.print("Error: Cannot create '{s}': {s}\n", .{ output_path, @errorName(err) });
        return;
    };
    defer file.close(io);

    var write_buf: [8192]u8 = undefined;
    var writer = file.writer(io, &write_buf);
    writer.interface.writeAll(pdf_bytes) catch |err| {
        std.debug.print("Error: Cannot write file: {s}\n", .{@errorName(err)});
        return;
    };
    try writer.interface.flush();

    std.debug.print("Generated board resolution: {s}\n", .{output_path});
}

fn generateDemoResolution(allocator: std.mem.Allocator, output_path: []const u8) !void {
    // Create IO context
    const io = global_io;

    // Generate demo board resolution PDF
    const pdf_bytes = try lib.generateDemoBoardResolution(allocator);
    defer allocator.free(pdf_bytes);

    const file = try std.Io.Dir.cwd().createFile(io, output_path, .{});
    defer file.close(io);

    var write_buf: [8192]u8 = undefined;
    var writer = file.writer(io, &write_buf);
    try writer.interface.writeAll(pdf_bytes);
    try writer.interface.flush();

    std.debug.print("Generated demo board resolution: {s}\n", .{output_path});
    std.debug.print("  Company: QUANTUM ENCODING LTD\n", .{});
    std.debug.print("  Type: Board Meeting\n", .{});
    std.debug.print("  Resolutions: 3 (Share Allotment, Certificate, Filing)\n", .{});
}

fn generateConsent(allocator: std.mem.Allocator, json_path: []const u8, output_path: []const u8) !void {
    // Create IO context
    const io = global_io;

    // Read JSON file
    const json_data = std.Io.Dir.cwd().readFileAlloc(io, json_path, allocator, .limited(10 * 1024 * 1024)) catch |err| {
        std.debug.print("Error: Cannot read '{s}': {s}\n", .{ json_path, @errorName(err) });
        return;
    };
    defer allocator.free(json_data);

    // Generate PDF from JSON
    const pdf_bytes = lib.generateDirectorConsentFromJson(allocator, json_data) catch |err| {
        std.debug.print("Error: Director consent generation failed: {s}\n", .{@errorName(err)});
        return;
    };
    defer allocator.free(pdf_bytes);

    // Write to file
    const file = std.Io.Dir.cwd().createFile(io, output_path, .{}) catch |err| {
        std.debug.print("Error: Cannot create '{s}': {s}\n", .{ output_path, @errorName(err) });
        return;
    };
    defer file.close(io);

    var write_buf: [8192]u8 = undefined;
    var writer = file.writer(io, &write_buf);
    writer.interface.writeAll(pdf_bytes) catch |err| {
        std.debug.print("Error: Cannot write file: {s}\n", .{@errorName(err)});
        return;
    };
    try writer.interface.flush();

    std.debug.print("Generated director consent: {s}\n", .{output_path});
    std.debug.print("  Size: {d} bytes\n", .{pdf_bytes.len});
}

fn generateDemoConsent(allocator: std.mem.Allocator, output_path: []const u8) !void {
    // Create IO context
    const io = global_io;

    // Generate demo director consent PDF
    const pdf_bytes = try lib.generateDemoDirectorConsent(allocator);
    defer allocator.free(pdf_bytes);

    const file = try std.Io.Dir.cwd().createFile(io, output_path, .{});
    defer file.close(io);

    var write_buf: [8192]u8 = undefined;
    var writer = file.writer(io, &write_buf);
    try writer.interface.writeAll(pdf_bytes);
    try writer.interface.flush();

    std.debug.print("Generated demo director consent: {s}\n", .{output_path});
    std.debug.print("  Director: Mr James Alexander Smith\n", .{});
    std.debug.print("  Company: QUANTUM ENCODING LTD\n", .{});
    std.debug.print("  Type: New Appointment\n", .{});
}

fn generateAppointment(allocator: std.mem.Allocator, json_path: []const u8, output_path: []const u8) !void {
    // Create IO context
    const io = global_io;

    // Read JSON file
    const json_data = std.Io.Dir.cwd().readFileAlloc(io, json_path, allocator, .limited(10 * 1024 * 1024)) catch |err| {
        std.debug.print("Error: Cannot read '{s}': {s}\n", .{ json_path, @errorName(err) });
        return;
    };
    defer allocator.free(json_data);

    // Generate PDF from JSON
    const pdf_bytes = lib.generateDirectorAppointmentFromJson(allocator, json_data) catch |err| {
        std.debug.print("Error: Director appointment generation failed: {s}\n", .{@errorName(err)});
        return;
    };
    defer allocator.free(pdf_bytes);

    // Write to file
    const file = std.Io.Dir.cwd().createFile(io, output_path, .{}) catch |err| {
        std.debug.print("Error: Cannot create '{s}': {s}\n", .{ output_path, @errorName(err) });
        return;
    };
    defer file.close(io);

    var write_buf: [8192]u8 = undefined;
    var writer = file.writer(io, &write_buf);
    writer.interface.writeAll(pdf_bytes) catch |err| {
        std.debug.print("Error: Cannot write file: {s}\n", .{@errorName(err)});
        return;
    };
    try writer.interface.flush();

    std.debug.print("Generated director appointment: {s}\n", .{output_path});
    std.debug.print("  Size: {d} bytes\n", .{pdf_bytes.len});
}

fn generateDemoAppointment(allocator: std.mem.Allocator, output_path: []const u8) !void {
    // Create IO context
    const io = global_io;

    // Generate demo director appointment PDF
    const pdf_bytes = try lib.generateDemoDirectorAppointment(allocator);
    defer allocator.free(pdf_bytes);

    const file = try std.Io.Dir.cwd().createFile(io, output_path, .{});
    defer file.close(io);

    var write_buf: [8192]u8 = undefined;
    var writer = file.writer(io, &write_buf);
    try writer.interface.writeAll(pdf_bytes);
    try writer.interface.flush();

    std.debug.print("Generated demo director appointment: {s}\n", .{output_path});
    std.debug.print("  Director: Mr James Alexander Smith\n", .{});
    std.debug.print("  Company: QUANTUM ENCODING LTD\n", .{});
    std.debug.print("  Role: Non-Executive Director\n", .{});
}

fn generateResignation(allocator: std.mem.Allocator, json_path: []const u8, output_path: []const u8) !void {
    // Create IO context
    const io = global_io;

    // Read JSON file
    const json_data = std.Io.Dir.cwd().readFileAlloc(io, json_path, allocator, .limited(10 * 1024 * 1024)) catch |err| {
        std.debug.print("Error: Cannot read '{s}': {s}\n", .{ json_path, @errorName(err) });
        return;
    };
    defer allocator.free(json_data);

    // Generate PDF from JSON
    const pdf_bytes = lib.generateDirectorResignationFromJson(allocator, json_data) catch |err| {
        std.debug.print("Error: Director resignation generation failed: {s}\n", .{@errorName(err)});
        return;
    };
    defer allocator.free(pdf_bytes);

    // Write to file
    const file = std.Io.Dir.cwd().createFile(io, output_path, .{}) catch |err| {
        std.debug.print("Error: Cannot create '{s}': {s}\n", .{ output_path, @errorName(err) });
        return;
    };
    defer file.close(io);

    var write_buf: [8192]u8 = undefined;
    var writer = file.writer(io, &write_buf);
    writer.interface.writeAll(pdf_bytes) catch |err| {
        std.debug.print("Error: Cannot write file: {s}\n", .{@errorName(err)});
        return;
    };
    try writer.interface.flush();

    std.debug.print("Generated director resignation: {s}\n", .{output_path});
    std.debug.print("  Size: {d} bytes\n", .{pdf_bytes.len});
}

fn generateDemoResignation(allocator: std.mem.Allocator, output_path: []const u8) !void {
    // Create IO context
    const io = global_io;

    // Generate demo director resignation PDF
    const pdf_bytes = try lib.generateDemoDirectorResignation(allocator);
    defer allocator.free(pdf_bytes);

    const file = try std.Io.Dir.cwd().createFile(io, output_path, .{});
    defer file.close(io);

    var write_buf: [8192]u8 = undefined;
    var writer = file.writer(io, &write_buf);
    try writer.interface.writeAll(pdf_bytes);
    try writer.interface.flush();

    std.debug.print("Generated demo director resignation: {s}\n", .{output_path});
    std.debug.print("  Director: Mr James Alexander Smith\n", .{});
    std.debug.print("  Company: QUANTUM ENCODING LTD\n", .{});
    std.debug.print("  Effective Date: 31 March 2026\n", .{});
}

fn generateWrittenResolution(allocator: std.mem.Allocator, json_path: []const u8, output_path: []const u8) !void {
    // Create IO context
    const io = global_io;

    // Read JSON file
    const json_data = std.Io.Dir.cwd().readFileAlloc(io, json_path, allocator, .limited(10 * 1024 * 1024)) catch |err| {
        std.debug.print("Error: Cannot read '{s}': {s}\n", .{ json_path, @errorName(err) });
        return;
    };
    defer allocator.free(json_data);

    // Generate PDF from JSON
    const pdf_bytes = lib.generateWrittenResolutionFromJson(allocator, json_data) catch |err| {
        std.debug.print("Error: Written resolution generation failed: {s}\n", .{@errorName(err)});
        return;
    };
    defer allocator.free(pdf_bytes);

    // Write to file
    const file = std.Io.Dir.cwd().createFile(io, output_path, .{}) catch |err| {
        std.debug.print("Error: Cannot create '{s}': {s}\n", .{ output_path, @errorName(err) });
        return;
    };
    defer file.close(io);

    var write_buf: [8192]u8 = undefined;
    var writer = file.writer(io, &write_buf);
    writer.interface.writeAll(pdf_bytes) catch |err| {
        std.debug.print("Error: Cannot write file: {s}\n", .{@errorName(err)});
        return;
    };
    try writer.interface.flush();

    std.debug.print("Generated written resolution: {s}\n", .{output_path});
    std.debug.print("  Size: {d} bytes\n", .{pdf_bytes.len});
}

fn generateDemoOrdinary(allocator: std.mem.Allocator, output_path: []const u8) !void {
    // Create IO context
    const io = global_io;

    // Generate demo ordinary resolution PDF
    const pdf_bytes = try lib.generateDemoOrdinaryResolution(allocator);
    defer allocator.free(pdf_bytes);

    const file = try std.Io.Dir.cwd().createFile(io, output_path, .{});
    defer file.close(io);

    var write_buf: [8192]u8 = undefined;
    var writer = file.writer(io, &write_buf);
    try writer.interface.writeAll(pdf_bytes);
    try writer.interface.flush();

    std.debug.print("Generated demo ordinary resolution: {s}\n", .{output_path});
    std.debug.print("  Company: QUANTUM ENCODING LTD\n", .{});
    std.debug.print("  Type: Ordinary (Simple Majority)\n", .{});
    std.debug.print("  Resolutions: 2 (Annual Accounts, Auditor Re-appointment)\n", .{});
}

fn generateDemoSpecial(allocator: std.mem.Allocator, output_path: []const u8) !void {
    // Create IO context
    const io = global_io;

    // Generate demo special resolution PDF
    const pdf_bytes = try lib.generateDemoSpecialResolution(allocator);
    defer allocator.free(pdf_bytes);

    const file = try std.Io.Dir.cwd().createFile(io, output_path, .{});
    defer file.close(io);

    var write_buf: [8192]u8 = undefined;
    var writer = file.writer(io, &write_buf);
    try writer.interface.writeAll(pdf_bytes);
    try writer.interface.flush();

    std.debug.print("Generated demo special resolution: {s}\n", .{output_path});
    std.debug.print("  Company: QUANTUM ENCODING LTD\n", .{});
    std.debug.print("  Type: Special (75%% Majority)\n", .{});
    std.debug.print("  Resolutions: 2 (Name Change, Articles Amendment)\n", .{});
}

// =============================================================================
// Presentation Commands
// =============================================================================

fn generatePresentationFromFile(allocator: std.mem.Allocator, json_path: []const u8, output_path: []const u8) !void {
    // Create IO context
    const io = global_io;

    // Read JSON file
    const json_data = std.Io.Dir.cwd().readFileAlloc(io, json_path, allocator, .limited(50 * 1024 * 1024)) catch |err| {
        std.debug.print("Error: Cannot read '{s}': {s}\n", .{ json_path, @errorName(err) });
        return;
    };
    defer allocator.free(json_data);

    // Generate PDF from JSON
    const pdf_bytes = lib.generatePresentationFromJson(allocator, json_data) catch |err| {
        std.debug.print("Error: Presentation generation failed: {s}\n", .{@errorName(err)});
        return;
    };
    defer allocator.free(pdf_bytes);

    // Write to file
    const file = std.Io.Dir.cwd().createFile(io, output_path, .{}) catch |err| {
        std.debug.print("Error: Cannot create '{s}': {s}\n", .{ output_path, @errorName(err) });
        return;
    };
    defer file.close(io);

    var write_buf: [8192]u8 = undefined;
    var writer = file.writer(io, &write_buf);
    writer.interface.writeAll(pdf_bytes) catch |err| {
        std.debug.print("Error: Cannot write file: {s}\n", .{@errorName(err)});
        return;
    };
    try writer.interface.flush();

    std.debug.print("Generated presentation: {s}\n", .{output_path});
    std.debug.print("  Size: {d} bytes\n", .{pdf_bytes.len});
}

// =============================================================================
// Proposal Commands
// =============================================================================

fn generateProposalFromFile(allocator: std.mem.Allocator, json_path: []const u8, output_path: []const u8) !void {
    const io = global_io;

    const json_data = std.Io.Dir.cwd().readFileAlloc(io, json_path, allocator, .limited(10 * 1024 * 1024)) catch |err| {
        std.debug.print("Error: Cannot read '{s}': {s}\n", .{ json_path, @errorName(err) });
        return;
    };
    defer allocator.free(json_data);

    const pdf_bytes = lib.generateProposalFromJson(allocator, json_data) catch |err| {
        std.debug.print("Error: Proposal generation failed: {s}\n", .{@errorName(err)});
        return;
    };
    defer allocator.free(pdf_bytes);

    const file = std.Io.Dir.cwd().createFile(io, output_path, .{}) catch |err| {
        std.debug.print("Error: Cannot create '{s}': {s}\n", .{ output_path, @errorName(err) });
        return;
    };
    defer file.close(io);

    var write_buf: [8192]u8 = undefined;
    var writer = file.writer(io, &write_buf);
    writer.interface.writeAll(pdf_bytes) catch |err| {
        std.debug.print("Error: Cannot write file: {s}\n", .{@errorName(err)});
        return;
    };
    try writer.interface.flush();

    std.debug.print("Generated proposal: {s}\n", .{output_path});
}

fn generateDemoProposal(allocator: std.mem.Allocator, output_path: []const u8) !void {
    const io = global_io;

    const pdf_bytes = try lib.proposal.generateDemoProposal(allocator);
    defer allocator.free(pdf_bytes);

    const file = try std.Io.Dir.cwd().createFile(io, output_path, .{});
    defer file.close(io);

    var write_buf: [8192]u8 = undefined;
    var writer = file.writer(io, &write_buf);
    writer.interface.writeAll(pdf_bytes) catch |err| {
        std.debug.print("Error: Cannot write file: {s}\n", .{@errorName(err)});
        return;
    };
    try writer.interface.flush();

    std.debug.print("Generated demo proposal: {s}\n", .{output_path});
}

// =============================================================================
// Template Card Commands
// =============================================================================

fn generateTemplateCardFromFile(allocator: std.mem.Allocator, json_path: []const u8, output_path: []const u8) !void {
    const io = global_io;

    const json_data = std.Io.Dir.cwd().readFileAlloc(io, json_path, allocator, .limited(10 * 1024 * 1024)) catch |err| {
        std.debug.print("Error: Cannot read '{s}': {s}\n", .{ json_path, @errorName(err) });
        return;
    };
    defer allocator.free(json_data);

    const pdf_bytes = lib.template_card.generateTemplateCardFromJson(allocator, json_data) catch |err| {
        std.debug.print("Error: Template card generation failed: {s}\n", .{@errorName(err)});
        return;
    };
    defer allocator.free(pdf_bytes);

    const file = std.Io.Dir.cwd().createFile(io, output_path, .{}) catch |err| {
        std.debug.print("Error: Cannot create '{s}': {s}\n", .{ output_path, @errorName(err) });
        return;
    };
    defer file.close(io);

    var write_buf: [8192]u8 = undefined;
    var writer = file.writer(io, &write_buf);
    writer.interface.writeAll(pdf_bytes) catch |err| {
        std.debug.print("Error: Cannot write file: {s}\n", .{@errorName(err)});
        return;
    };
    try writer.interface.flush();

    std.debug.print("Generated template card: {s}\n", .{output_path});
}

fn generateDemoTemplateCardCmd(allocator: std.mem.Allocator, output_path: []const u8) !void {
    const io = global_io;

    const pdf_bytes = try lib.template_card.generateDemoTemplateCard(allocator);
    defer allocator.free(pdf_bytes);

    const file = try std.Io.Dir.cwd().createFile(io, output_path, .{});
    defer file.close(io);

    var write_buf: [8192]u8 = undefined;
    var writer = file.writer(io, &write_buf);
    writer.interface.writeAll(pdf_bytes) catch |err| {
        std.debug.print("Error: Cannot write file: {s}\n", .{@errorName(err)});
        return;
    };
    try writer.interface.flush();

    std.debug.print("Generated demo template card: {s}\n", .{output_path});
    std.debug.print("  Template: Cosmic Duck\n", .{});
    std.debug.print("  Format: QE-TPL-V1\n", .{});
}
