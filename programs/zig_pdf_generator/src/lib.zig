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
pub const markdown = @import("markdown.zig");
pub const template_card = @import("template_card.zig");

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

// Markdown → PDF
pub const generateFromMarkdown = markdown.generateFromMarkdown;

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
