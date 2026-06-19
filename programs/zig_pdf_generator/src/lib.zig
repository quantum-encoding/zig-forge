//! Zig PDF Generator Library
//!
//! High-performance PDF generation library with C FFI for cross-platform use.
//!
//! Features:
//! - Professional invoice/quote templates
//! - Image embedding (PNG, JPEG, Base64)
//! - Color customization
//! - Multiple template styles
//! - Zero-copy where possible
//!
//! Usage (Zig):
//! ```zig
//! const invoice = @import("zigpdf").invoice;
//!
//! const data = invoice.InvoiceData{
//!     .company_name = "Acme Corp",
//!     .invoice_number = "INV-001",
//!     // ...
//! };
//!
//! const pdf_bytes = try invoice.generateInvoice(allocator, data);
//! defer allocator.free(pdf_bytes);
//! ```
//!
//! Usage (C/FFI):
//! ```c
//! #include "zigpdf.h"
//!
//! size_t len;
//! uint8_t* pdf = zigpdf_generate_invoice(json_str, &len);
//! if (pdf) {
//!     // Use pdf bytes...
//!     zigpdf_free(pdf, len);
//! }
//! ```

pub const document = @import("document.zig");
pub const invoice = @import("invoice.zig");
pub const image = @import("image.zig");
pub const json = @import("json.zig");
pub const ffi = @import("ffi.zig");
pub const crypto_receipt = @import("crypto_receipt.zig");
pub const qrcode = @import("qrcode.zig");
pub const identicon = @import("identicon.zig");
pub const contract = @import("contract.zig");
pub const share_certificate = @import("share_certificate.zig");
pub const dividend_voucher = @import("dividend_voucher.zig");
pub const stock_transfer = @import("stock_transfer.zig");
pub const board_resolution = @import("board_resolution.zig");
pub const director_consent = @import("director_consent.zig");
pub const director_appointment = @import("director_appointment.zig");
pub const director_resignation = @import("director_resignation.zig");
pub const written_resolution = @import("written_resolution.zig");
pub const presentation = @import("presentation.zig");
pub const proposal = @import("proposal.zig");
pub const clean_quote = @import("clean_quote.zig");
pub const letter_quote = @import("letter_quote.zig");
pub const markdown = @import("markdown.zig");
pub const template_card = @import("template_card.zig");
pub const order_email = @import("order_email.zig");
pub const letter = @import("letter.zig");
pub const types = @import("types.zig");
pub const CryptoPaymentBlock = types.CryptoPaymentBlock;

// Re-export key types
pub const PdfDocument = document.PdfDocument;
pub const ContentStream = document.ContentStream;
pub const Color = document.Color;
pub const Font = document.Font;
pub const PageSize = document.PageSize;
pub const Image = document.Image;

pub const InvoiceData = invoice.InvoiceData;
pub const LineItem = invoice.LineItem;
pub const InvoiceRenderer = invoice.InvoiceRenderer;
pub const generateInvoice = invoice.generateInvoice;

// Crypto receipt types
pub const CryptoReceiptData = crypto_receipt.CryptoReceiptData;
pub const CryptoReceiptRenderer = crypto_receipt.CryptoReceiptRenderer;
pub const Network = crypto_receipt.Network;
pub const DocumentType = crypto_receipt.DocumentType;
pub const generateCryptoReceipt = crypto_receipt.generateReceipt;

// QR code types
pub const QrCode = qrcode.QrCode;
pub const QrImage = qrcode.QrImage;
pub const QrConfig = qrcode.QrConfig;
pub const QrSvg = qrcode.QrSvg;
pub const SvgConfig = qrcode.SvgConfig;
pub const RenderConfig = qrcode.RenderConfig;
pub const EncodingMode = qrcode.EncodingMode;
pub const StructuredAppend = qrcode.StructuredAppend;
pub const EciMode = qrcode.EciMode;
pub const ErrorCorrectionLevel = qrcode.ErrorCorrectionLevel;
pub const encodeQr = qrcode.encode;
pub const renderQr = qrcode.render;
pub const renderQrWithConfig = qrcode.renderWithConfig;
pub const renderQrSvg = qrcode.renderSvg;
pub const encodeAndRenderQr = qrcode.encodeAndRender;
pub const encodeAndRenderQrSvg = qrcode.encodeAndRenderSvg;
pub const detectOptimalQrMode = qrcode.detectOptimalMode;

// Identicon types
pub const Identicon = identicon.Identicon;
pub const IdenticonConfig = identicon.IdenticonConfig;
pub const generateIdenticon = identicon.generate;

// Contract/Document types
pub const ContractData = contract.ContractData;
pub const ContractRenderer = contract.ContractRenderer;
pub const Party = contract.Party;
pub const Section = contract.Section;
pub const Signature = contract.Signature;
pub const generateContract = contract.generateContract;
pub const generateContractFromJson = contract.generateContractFromJson;
pub const generateDemoContract = contract.generateDemoContract;

// Share Certificate types
pub const ShareCertificateData = share_certificate.ShareCertificateData;
pub const ShareCertificateRenderer = share_certificate.ShareCertificateRenderer;
pub const ShareCertAddress = share_certificate.Address;
pub const ShareCertHolder = share_certificate.Holder;
pub const ShareCertShares = share_certificate.Shares;
pub const ShareCertSignatory = share_certificate.Signatory;
pub const generateShareCertificate = share_certificate.generateShareCertificate;
pub const generateShareCertificateFromJson = share_certificate.generateShareCertificateFromJson;
pub const generateDemoShareCertificate = share_certificate.generateDemoShareCertificate;
pub const numberToWords = share_certificate.numberToWords;

// Dividend Voucher types
pub const DividendVoucherData = dividend_voucher.DividendVoucherData;
pub const DividendVoucherRenderer = dividend_voucher.DividendVoucherRenderer;
pub const DividendVoucherAddress = dividend_voucher.Address;
pub const DividendVoucherCompany = dividend_voucher.Company;
pub const DividendVoucherShareholder = dividend_voucher.Shareholder;
pub const DividendVoucherDividend = dividend_voucher.Dividend;
pub const DividendVoucherPayment = dividend_voucher.Payment;
pub const DividendVoucherSignatory = dividend_voucher.Signatory;
pub const DividendVoucherJurisdiction = dividend_voucher.Jurisdiction;
pub const DwtExemptionType = dividend_voucher.DwtExemptionType;
pub const DwtExemption = dividend_voucher.DwtExemption;
pub const generateDividendVoucher = dividend_voucher.generateDividendVoucher;
pub const generateDividendVoucherFromJson = dividend_voucher.generateDividendVoucherFromJson;
pub const generateDemoDividendVoucher = dividend_voucher.generateDemoDividendVoucher;
pub const generateDemoIrishDividendVoucher = dividend_voucher.generateDemoIrishDividendVoucher;
pub const generateDemoIrishDividendVoucherExempt = dividend_voucher.generateDemoIrishDividendVoucherExempt;
pub const freeDividendVoucherData = dividend_voucher.freeDividendVoucherData;

// Stock Transfer types
pub const StockTransferData = stock_transfer.StockTransferData;
pub const StockTransferRenderer = stock_transfer.StockTransferRenderer;
pub const StockTransferAddress = stock_transfer.Address;
pub const Transferor = stock_transfer.Transferor;
pub const Transferee = stock_transfer.Transferee;
pub const generateStockTransfer = stock_transfer.generateStockTransfer;
pub const generateStockTransferFromJson = stock_transfer.generateStockTransferFromJson;
pub const generateDemoStockTransfer = stock_transfer.generateDemoStockTransfer;

// Board Resolution types
pub const BoardResolutionData = board_resolution.BoardResolutionData;
pub const BoardResolutionRenderer = board_resolution.BoardResolutionRenderer;
pub const Resolution = board_resolution.Resolution;
pub const generateBoardResolution = board_resolution.generateBoardResolution;
pub const generateBoardResolutionFromJson = board_resolution.generateBoardResolutionFromJson;
pub const generateDemoBoardResolution = board_resolution.generateDemoBoardResolution;

// Director Consent types
pub const DirectorConsentData = director_consent.DirectorConsentData;
pub const DirectorConsentRenderer = director_consent.DirectorConsentRenderer;
pub const ConsentType = director_consent.ConsentType;
pub const generateDirectorConsent = director_consent.generateDirectorConsent;
pub const generateDirectorConsentFromJson = director_consent.generateDirectorConsentFromJson;
pub const generateDemoDirectorConsent = director_consent.generateDemoDirectorConsent;

// Director Appointment types
pub const DirectorAppointmentData = director_appointment.DirectorAppointmentData;
pub const DirectorAppointmentRenderer = director_appointment.DirectorAppointmentRenderer;
pub const DirectorRole = director_appointment.DirectorRole;
pub const generateDirectorAppointment = director_appointment.generateDirectorAppointment;
pub const generateDirectorAppointmentFromJson = director_appointment.generateDirectorAppointmentFromJson;
pub const generateDemoDirectorAppointment = director_appointment.generateDemoDirectorAppointment;

// Director Resignation types
pub const DirectorResignationData = director_resignation.DirectorResignationData;
pub const DirectorResignationRenderer = director_resignation.DirectorResignationRenderer;
pub const ResignationReason = director_resignation.ResignationReason;
pub const generateDirectorResignation = director_resignation.generateDirectorResignation;
pub const generateDirectorResignationFromJson = director_resignation.generateDirectorResignationFromJson;
pub const generateDemoDirectorResignation = director_resignation.generateDemoDirectorResignation;

// Written Resolution types
pub const WrittenResolutionData = written_resolution.WrittenResolutionData;
pub const WrittenResolutionRenderer = written_resolution.WrittenResolutionRenderer;
pub const ResolutionType = written_resolution.ResolutionType;
pub const ResolutionItem = written_resolution.ResolutionItem;
pub const generateWrittenResolution = written_resolution.generateWrittenResolution;
pub const generateWrittenResolutionFromJson = written_resolution.generateWrittenResolutionFromJson;
pub const generateDemoOrdinaryResolution = written_resolution.generateDemoOrdinaryResolution;
pub const generateDemoSpecialResolution = written_resolution.generateDemoSpecialResolution;

// Presentation types
pub const PresentationData = presentation.PresentationData;
pub const PresentationRenderer = presentation.PresentationRenderer;
pub const PresentationPageSize = presentation.PageSize;
pub const PresentationPage = presentation.Page;
pub const PresentationElement = presentation.Element;
pub const generatePresentationFromJson = presentation.generatePresentationFromJson;

// Proposal types
pub const ProposalData = proposal.ProposalData;
pub const ProposalRenderer = proposal.ProposalRenderer;
pub const ProposalSection = proposal.ProposalSection;
pub const generateProposalFromJson = proposal.generateProposalFromJson;
pub const generateDemoProposal = proposal.generateDemoProposal;

// Clean Quote (minimalist template sharing proposal's JSON schema)
pub const CleanQuoteRenderer = clean_quote.CleanQuoteRenderer;
pub const generateCleanQuoteFromJson = clean_quote.generateCleanQuoteFromJson;

// Letter Quote (premium Word-document-style quote with letter-spaced headings)
pub const LetterQuoteRenderer = letter_quote.LetterQuoteRenderer;
pub const LetterQuoteData = letter_quote.LetterQuoteData;
pub const generateLetterQuoteFromJson = letter_quote.generateLetterQuoteFromJson;

// Markdown → PDF
pub const generateFromMarkdown = markdown.generateFromMarkdown;

// Letter (markdown body + letterhead + background image)
pub const LetterInput = markdown.LetterInput;
pub const generateLetter = markdown.generateLetter;
pub const generateLetterFromJson = letter.generateLetterFromJson;

// Template Card types
pub const TemplateCardData = template_card.TemplateCardData;
pub const TemplateCardRenderer = template_card.TemplateCardRenderer;
pub const generateTemplateCardFromJson = template_card.generateTemplateCardFromJson;
pub const generateDemoTemplateCard = template_card.generateDemoTemplateCard;

// FFI exports (for shared library)
pub const zigpdf_generate_invoice = ffi.zigpdf_generate_invoice;
pub const zigpdf_generate_simple = ffi.zigpdf_generate_simple;
pub const zigpdf_generate_invoice_to_file = ffi.zigpdf_generate_invoice_to_file;
pub const zigpdf_generate_invoice_jni = ffi.zigpdf_generate_invoice_jni;
pub const zigpdf_generate_crypto_receipt = ffi.zigpdf_generate_crypto_receipt;
pub const zigpdf_generate_crypto_receipt_to_file = ffi.zigpdf_generate_crypto_receipt_to_file;
pub const zigpdf_generate_qrcode = ffi.zigpdf_generate_qrcode;
pub const zigpdf_generate_qrcode_svg = ffi.zigpdf_generate_qrcode_svg;
pub const zigpdf_generate_identicon = ffi.zigpdf_generate_identicon;
pub const zigpdf_generate_contract = ffi.zigpdf_generate_contract;
pub const zigpdf_generate_contract_to_file = ffi.zigpdf_generate_contract_to_file;
pub const zigpdf_generate_share_certificate = ffi.zigpdf_generate_share_certificate;
pub const zigpdf_generate_share_certificate_to_file = ffi.zigpdf_generate_share_certificate_to_file;
pub const zigpdf_generate_dividend_voucher = ffi.zigpdf_generate_dividend_voucher;
pub const zigpdf_generate_dividend_voucher_to_file = ffi.zigpdf_generate_dividend_voucher_to_file;
pub const zigpdf_generate_stock_transfer = ffi.zigpdf_generate_stock_transfer;
pub const zigpdf_generate_stock_transfer_to_file = ffi.zigpdf_generate_stock_transfer_to_file;
pub const zigpdf_generate_board_resolution = ffi.zigpdf_generate_board_resolution;
pub const zigpdf_generate_board_resolution_to_file = ffi.zigpdf_generate_board_resolution_to_file;
pub const zigpdf_generate_director_consent = ffi.zigpdf_generate_director_consent;
pub const zigpdf_generate_director_consent_to_file = ffi.zigpdf_generate_director_consent_to_file;
pub const zigpdf_generate_director_appointment = ffi.zigpdf_generate_director_appointment;
pub const zigpdf_generate_director_appointment_to_file = ffi.zigpdf_generate_director_appointment_to_file;
pub const zigpdf_generate_director_resignation = ffi.zigpdf_generate_director_resignation;
pub const zigpdf_generate_director_resignation_to_file = ffi.zigpdf_generate_director_resignation_to_file;
pub const zigpdf_generate_written_resolution = ffi.zigpdf_generate_written_resolution;
pub const zigpdf_generate_written_resolution_to_file = ffi.zigpdf_generate_written_resolution_to_file;
pub const zigpdf_generate_proposal = ffi.zigpdf_generate_proposal;
pub const zigpdf_generate_proposal_to_file = ffi.zigpdf_generate_proposal_to_file;
pub const zigpdf_generate_clean_quote = ffi.zigpdf_generate_clean_quote;
pub const zigpdf_generate_clean_quote_to_file = ffi.zigpdf_generate_clean_quote_to_file;
pub const zigpdf_generate_letter_quote = ffi.zigpdf_generate_letter_quote;
pub const zigpdf_generate_letter_quote_to_file = ffi.zigpdf_generate_letter_quote_to_file;
pub const zigpdf_generate_markdown = ffi.zigpdf_generate_markdown;
pub const zigpdf_generate_markdown_to_file = ffi.zigpdf_generate_markdown_to_file;
pub const zigpdf_generate_template_card = ffi.zigpdf_generate_template_card;
pub const zigpdf_generate_template_card_to_file = ffi.zigpdf_generate_template_card_to_file;
pub const zigpdf_free = ffi.zigpdf_free;
pub const zigpdf_get_error = ffi.zigpdf_get_error;
pub const zigpdf_version = ffi.zigpdf_version;

// =============================================================================
// Tests
// =============================================================================

test {
    // Run all module tests
    _ = document;
    _ = invoice;
    _ = image;
    _ = json;
    _ = ffi;
    _ = crypto_receipt;
    _ = qrcode;
    _ = identicon;
    _ = contract;
    _ = share_certificate;
    _ = dividend_voucher;
    _ = stock_transfer;
    _ = board_resolution;
    _ = director_consent;
    _ = director_appointment;
    _ = director_resignation;
    _ = written_resolution;
    _ = presentation;
    _ = proposal;
    _ = clean_quote;
    _ = letter_quote;
    _ = markdown;
    _ = template_card;
}

test "library integration" {
    const std = @import("std");
    const allocator = std.testing.allocator;

    // Create invoice data
    const items = [_]LineItem{
        .{ .description = "Consulting", .quantity = 8, .unit_price = 150, .total = 1200 },
    };

    const data = InvoiceData{
        .company_name = "Quantum Zig Labs",
        .company_address = "123 Code Street, Zig City",
        .company_vat = "US123456789",
        .client_name = "Happy Customer",
        .client_address = "456 Client Road",
        .invoice_number = "QZL-2025-001",
        .invoice_date = "2025-11-29",
        .items = &items,
        .subtotal = 1200,
        .tax_rate = 0.10,
        .tax_amount = 120,
        .total = 1320,
        .primary_color = "#3498db",
        .notes = "Generated with Zig PDF Generator",
    };

    // Generate PDF
    const pdf_bytes = try generateInvoice(allocator, data);
    defer allocator.free(pdf_bytes);

    // Verify PDF structure
    try std.testing.expect(pdf_bytes.len > 1000);
    try std.testing.expect(std.mem.startsWith(u8, pdf_bytes, "%PDF-1.4"));
    try std.testing.expect(std.mem.endsWith(u8, pdf_bytes, "%%EOF\n"));

    // Verify content includes key text
    try std.testing.expect(std.mem.indexOf(u8, pdf_bytes, "Quantum Zig Labs") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf_bytes, "QZL-2025-001") != null);
}

test "invoice table_style variants render valid PDFs" {
    const std = @import("std");
    const allocator = std.testing.allocator;
    const items = [_]LineItem{
        .{ .description = "Service A", .quantity = 1, .unit_price = 100, .total = 100 },
        .{ .description = "Service B", .quantity = 2, .unit_price = 50, .total = 100 },
    };
    for ([_]invoice.TableStyle{ .bands, .boxes, .minimal }) |style| {
        const data = InvoiceData{
            .company_name = "Styled Co",
            .client_name = "Client",
            .invoice_number = "STY-1",
            .items = &items,
            .subtotal = 200,
            .tax_amount = 42,
            .total = 242,
            .table_style = style,
        };
        const pdf = try generateInvoice(allocator, data);
        defer allocator.free(pdf);
        try std.testing.expect(std.mem.startsWith(u8, pdf, "%PDF-1.4"));
        try std.testing.expect(std.mem.endsWith(u8, pdf, "%%EOF\n"));
        try std.testing.expect(std.mem.indexOf(u8, pdf, "Styled Co") != null);
    }
}

test "invoice multiple payment buttons embed clickable links" {
    const std = @import("std");
    const allocator = std.testing.allocator;
    const items = [_]LineItem{.{ .description = "Item", .quantity = 1, .unit_price = 10, .total = 10 }};
    const buttons = [_]invoice.PaymentButton{
        .{ .label = "Pay by Card", .url = "https://checkout.stripe.com/pay/cs_test_123", .color = "#635BFF" },
        .{ .label = "PayPal", .url = "https://paypal.me/example/10", .color = "#003087" },
    };
    const data = InvoiceData{
        .company_name = "Pay Co",
        .client_name = "Buyer",
        .invoice_number = "PAY-1",
        .items = &items,
        .subtotal = 10,
        .total = 10,
        .payment_buttons = &buttons,
    };
    const pdf = try generateInvoice(allocator, data);
    defer allocator.free(pdf);
    // Both checkout URLs must appear as link annotations.
    try std.testing.expect(std.mem.indexOf(u8, pdf, "checkout.stripe.com/pay/cs_test_123") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "paypal.me/example/10") != null);
}

test "invoice IRPF retention row renders when set" {
    const std = @import("std");
    const allocator = std.testing.allocator;
    const items = [_]LineItem{.{ .description = "Servicio", .quantity = 1, .unit_price = 100, .total = 100 }};
    const data = InvoiceData{
        .company_name = "Autonomo SL",
        .client_name = "Cliente",
        .invoice_number = "ES-1",
        .items = &items,
        .subtotal = 100,
        .tax_rate = 0.21,
        .tax_amount = 21,
        .irpf_rate = 0.15,
        .irpf_amount = 15,
        .total = 106,
        .show_tax = true,
    };
    const pdf = try generateInvoice(allocator, data);
    defer allocator.free(pdf);
    // PDF escapes parens in text strings (IRPF \(15%\)), so match the token.
    try std.testing.expect(std.mem.indexOf(u8, pdf, "IRPF") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "15%") != null);
}

test "invoice paginates a long item list across multiple pages" {
    const std = @import("std");
    const allocator = std.testing.allocator;
    var items: [40]LineItem = undefined;
    for (&items) |*it| it.* = .{ .description = "Line item with a moderately long description that wraps", .quantity = 1, .unit_price = 10, .total = 10 };
    const data = InvoiceData{
        .company_name = "Multi Page Co",
        .client_name = "Client",
        .invoice_number = "MP-1",
        .items = &items,
        .subtotal = 400,
        .tax_amount = 84,
        .total = 484,
    };
    const pdf = try generateInvoice(allocator, data);
    defer allocator.free(pdf);
    try std.testing.expect(std.mem.endsWith(u8, pdf, "%%EOF\n"));
    // 40 items can't fit on one page → at least two page objects.
    const p0 = std.mem.indexOf(u8, pdf, "/Type /Page /Parent").?;
    try std.testing.expect(std.mem.indexOf(u8, pdf[p0 + 1 ..], "/Type /Page /Parent") != null);
}

test "rgbaToRgb composites transparent pixels onto white" {
    const std = @import("std");
    const allocator = std.testing.allocator;
    // 3 pixels: opaque red, fully transparent, half-transparent blue.
    const rgba = [_]u8{ 255, 0, 0, 255, 0, 0, 0, 0, 0, 0, 255, 128 };
    const rgb = try image.rgbaToRgb(allocator, &rgba, 3, 1);
    defer allocator.free(rgb);
    // Opaque red stays red.
    try std.testing.expectEqual(@as(u8, 255), rgb[0]);
    try std.testing.expectEqual(@as(u8, 0), rgb[1]);
    // Fully transparent -> white (not the stray 0,0,0 underneath).
    try std.testing.expectEqual(@as(u8, 255), rgb[3]);
    try std.testing.expectEqual(@as(u8, 255), rgb[4]);
    try std.testing.expectEqual(@as(u8, 255), rgb[5]);
    // Half-transparent blue -> blended toward white on R/G, partial B.
    try std.testing.expect(rgb[6] > 120 and rgb[6] < 135); // ~127
    try std.testing.expect(rgb[8] > 250); // B = 255*128/255 + 255*127/255 ≈ 255
}

test "invoice right-aligns + shrink-fits long meta/amounts without error" {
    const std = @import("std");
    const allocator = std.testing.allocator;
    const items = [_]LineItem{.{ .description = "Enterprise tier", .quantity = 1, .unit_price = 1234567.89, .total = 1234567.89 }};
    const data = InvoiceData{
        .company_name = "Quantum Encoding Ltd",
        .client_name = "Client",
        // Pathologically long number + huge amounts exercise the shrink-to-fit path.
        .invoice_number = "2026-000802-RECUPERACION-DOMINIO-XL-EXTRA-LONG",
        .invoice_date = "19 September 2026 (revised, second issue)",
        .items = &items,
        .subtotal = 1234567.89,
        .tax_amount = 259259.26,
        .total = 1493827.15,
        .currency_symbol = "€",
    };
    const pdf = try generateInvoice(allocator, data);
    defer allocator.free(pdf);
    try std.testing.expect(std.mem.startsWith(u8, pdf, "%PDF-1.4"));
    try std.testing.expect(std.mem.endsWith(u8, pdf, "%%EOF\n"));
}

test "link annotations attach to their own page, not always page 0" {
    const std = @import("std");
    const allocator = std.testing.allocator;
    var doc = document.PdfDocument.init(allocator);
    defer doc.deinit();

    // Page 0 — no annotation.
    var c0 = document.ContentStream.init(allocator);
    defer c0.deinit();
    try c0.drawText("Page one", 60, 700, doc.getFontId(.helvetica), 12, document.Color.black);
    try doc.addPage(&c0);

    // Page 1 — carries the link annotation.
    var c1 = document.ContentStream.init(allocator);
    defer c1.deinit();
    try c1.drawText("Page two", 60, 700, doc.getFontId(.helvetica), 12, document.Color.black);
    doc.setAnnotationPage(1);
    try doc.addLinkAnnotation(60, 690, 200, 710, "https://example.com/pay");
    try doc.addPage(&c1);

    const pdf = try doc.build();

    // The link URL is present...
    try std.testing.expect(std.mem.indexOf(u8, pdf, "https://example.com/pay") != null);

    // ...and /Annots is on the SECOND page object, not the first.
    // "/Type /Page /Parent" is unique to page objects (excludes the /Pages tree).
    const p0 = std.mem.indexOf(u8, pdf, "/Type /Page /Parent").?;
    const p1 = std.mem.indexOf(u8, pdf[p0 + 1 ..], "/Type /Page /Parent").? + p0 + 1;
    const annots = std.mem.indexOf(u8, pdf, "/Annots").?;
    try std.testing.expect(annots > p1); // belongs to page 1's object
    try std.testing.expect(std.mem.indexOf(u8, pdf[p0..p1], "/Annots") == null); // page 0 has none
}

test "justified markdown renders without error (frontmatter justify)" {
    const std = @import("std");
    const allocator = std.testing.allocator;
    const md =
        "---\njustify: true\n---\n" ++
        "This is a paragraph long enough to wrap onto at least two lines so the " ++
        "justification logic distributes inter-word space across the first line " ++
        "while leaving the final line ragged as proper typesetting requires here.";
    const pdf = try generateFromMarkdown(allocator, md);
    defer allocator.free(pdf);
    try std.testing.expect(std.mem.startsWith(u8, pdf, "%PDF-1.4"));
    try std.testing.expect(std.mem.endsWith(u8, pdf, "%%EOF\n"));
}

test "markdown links render as clickable link annotations" {
    const std = @import("std");
    const allocator = std.testing.allocator;
    const md = "See [our pricing page](https://quantumencoding.io/pricing) for the full breakdown.";
    const pdf = try generateFromMarkdown(allocator, md);
    defer allocator.free(pdf);
    // A clickable /Link annotation with the URL must be emitted.
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/Subtype /Link") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "https://quantumencoding.io/pricing") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/Annots") != null);
}

// Pull the canonical-sample regression tests into the `zig build test` graph.
test {
    _ = @import("sample_tests.zig");
    _ = @import("order_email.zig");
    _ = @import("letter.zig");
}
