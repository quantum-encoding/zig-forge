// Copyright (c) 2025 QUANTUM ENCODING LTD
// Licensed under the MIT License.

import Foundation
import CZigPdf

// MARK: - Errors

public enum ZigPdfError: Error, LocalizedError {
    case invalidJSON(String)
    case renderFailed(String)
    case outOfMemory
    case invalidArgument
    case unknown(String)

    public var errorDescription: String? {
        switch self {
        case .invalidJSON(let m): return "Invalid JSON: \(m)"
        case .renderFailed(let m): return "Render failed: \(m)"
        case .outOfMemory: return "Out of memory"
        case .invalidArgument: return "Invalid argument"
        case .unknown(let m): return m
        }
    }
}

// MARK: - QR Image

public struct QrImage {
    public let width: Int
    public let height: Int
    /// Row-major RGB (3 bytes per pixel).
    public let pixels: Data
}

// MARK: - Main API

/// Thread-safe PDF generation powered by zig-pdf-generator.
///
/// Usage:
/// ```swift
/// let pdf = try ZigPdf.simple(title: "Report", body: "Hello")
/// let invoice = try ZigPdf.invoice(json: invoiceJson)
/// let receipt = try ZigPdf.cryptoReceipt(json: receiptJson)
/// let qr = try ZigPdf.qrCodeSVG("bitcoin:bc1q...")
/// ```
public enum ZigPdf {

    /// Generate a simple PDF with title + body.
    public static func simple(title: String, body: String) throws -> Data {
        try withPointer { lenPtr in
            title.withCString { tPtr in
                body.withCString { bPtr in
                    zigpdf_generate_simple(tPtr, bPtr, lenPtr)
                }
            }
        }
    }

    /// Generate an invoice PDF from JSON.
    public static func invoice(json: String) throws -> Data {
        try withPointer { lenPtr in
            json.withCString { jsonPtr in
                zigpdf_generate_invoice(jsonPtr, lenPtr)
            }
        }
    }

    /// Generate a cryptocurrency transaction receipt PDF from JSON.
    public static func cryptoReceipt(json: String) throws -> Data {
        try withPointer { lenPtr in
            json.withCString { jsonPtr in
                zigpdf_generate_crypto_receipt(jsonPtr, lenPtr)
            }
        }
    }

    /// Generate a QR code as raw RGB pixels.
    public static func qrCode(_ data: String, moduleSize: Int32 = 4) throws -> QrImage {
        var len: size_t = 0
        guard let ptr = data.withCString({ cstr in
            zigpdf_generate_qrcode(cstr, moduleSize, &len)
        }) else {
            throw Self.lastError()
        }
        defer { zigpdf_free(ptr, len) }

        guard len >= 8 else { throw ZigPdfError.renderFailed("QR payload too short") }
        let width = Int(ptr.withMemoryRebound(to: UInt32.self, capacity: 1) { $0.pointee })
        let height = Int((ptr + 4).withMemoryRebound(to: UInt32.self, capacity: 1) { $0.pointee })
        let pixels = Data(bytes: ptr + 8, count: len - 8)
        return QrImage(width: width, height: height, pixels: pixels)
    }

    /// Generate a QR code as SVG string.
    public static func qrCodeSVG(_ data: String) throws -> String {
        let bytes = try withPointer { lenPtr in
            data.withCString { cstr in
                zigpdf_generate_qrcode_svg(cstr, lenPtr)
            }
        }
        guard let s = String(data: bytes, encoding: .utf8) else {
            throw ZigPdfError.renderFailed("QR SVG not valid UTF-8")
        }
        return s
    }

    /// Generate an Ethereum blockie-style identicon as raw RGB pixels.
    public static func identicon(address: String, scale: Int32 = 8) throws -> QrImage {
        var len: size_t = 0
        guard let ptr = address.withCString({ cstr in
            zigpdf_generate_identicon(cstr, scale, &len)
        }) else {
            throw Self.lastError()
        }
        defer { zigpdf_free(ptr, len) }

        guard len >= 8 else { throw ZigPdfError.renderFailed("Identicon payload too short") }
        let width = Int(ptr.withMemoryRebound(to: UInt32.self, capacity: 1) { $0.pointee })
        let height = Int((ptr + 4).withMemoryRebound(to: UInt32.self, capacity: 1) { $0.pointee })
        let pixels = Data(bytes: ptr + 8, count: len - 8)
        return QrImage(width: width, height: height, pixels: pixels)
    }

    // MARK: - Corporate Documents

    /// Generate a legal contract PDF from JSON.
    public static func contract(json: String) throws -> Data {
        try withPointer { lenPtr in json.withCString { zigpdf_generate_contract($0, lenPtr) } }
    }

    /// Generate a share certificate PDF from JSON.
    public static func shareCertificate(json: String) throws -> Data {
        try withPointer { lenPtr in json.withCString { zigpdf_generate_share_certificate($0, lenPtr) } }
    }

    /// Generate a dividend voucher PDF from JSON.
    public static func dividendVoucher(json: String) throws -> Data {
        try withPointer { lenPtr in json.withCString { zigpdf_generate_dividend_voucher($0, lenPtr) } }
    }

    /// Generate a stock transfer document PDF from JSON.
    public static func stockTransfer(json: String) throws -> Data {
        try withPointer { lenPtr in json.withCString { zigpdf_generate_stock_transfer($0, lenPtr) } }
    }

    /// Generate a board resolution PDF from JSON.
    public static func boardResolution(json: String) throws -> Data {
        try withPointer { lenPtr in json.withCString { zigpdf_generate_board_resolution($0, lenPtr) } }
    }

    /// Generate a director consent form PDF from JSON.
    public static func directorConsent(json: String) throws -> Data {
        try withPointer { lenPtr in json.withCString { zigpdf_generate_director_consent($0, lenPtr) } }
    }

    /// Generate a director appointment letter PDF from JSON.
    public static func directorAppointment(json: String) throws -> Data {
        try withPointer { lenPtr in json.withCString { zigpdf_generate_director_appointment($0, lenPtr) } }
    }

    /// Generate a director resignation letter PDF from JSON.
    public static func directorResignation(json: String) throws -> Data {
        try withPointer { lenPtr in json.withCString { zigpdf_generate_director_resignation($0, lenPtr) } }
    }

    /// Generate a written resolution PDF from JSON.
    public static func writtenResolution(json: String) throws -> Data {
        try withPointer { lenPtr in json.withCString { zigpdf_generate_written_resolution($0, lenPtr) } }
    }

    /// Generate a business proposal PDF from JSON.
    public static func proposal(json: String) throws -> Data {
        try withPointer { lenPtr in json.withCString { zigpdf_generate_proposal($0, lenPtr) } }
    }

    /// Generate a template card PDF from JSON.
    public static func templateCard(json: String) throws -> Data {
        try withPointer { lenPtr in json.withCString { zigpdf_generate_template_card($0, lenPtr) } }
    }

    // MARK: - File Output

    /// Generate an invoice and write directly to file.
    public static func invoiceToFile(json: String, path: String) throws {
        try checkFileResult(zigpdf_generate_invoice_to_file(json, path))
    }

    /// Generate a crypto receipt and write directly to file.
    public static func cryptoReceiptToFile(json: String, path: String) throws {
        try checkFileResult(zigpdf_generate_crypto_receipt_to_file(json, path))
    }

    /// Generate a contract and write directly to file.
    public static func contractToFile(json: String, path: String) throws {
        try checkFileResult(zigpdf_generate_contract_to_file(json, path))
    }

    /// Generate a share certificate and write directly to file.
    public static func shareCertificateToFile(json: String, path: String) throws {
        try checkFileResult(zigpdf_generate_share_certificate_to_file(json, path))
    }

    /// Generate a dividend voucher and write directly to file.
    public static func dividendVoucherToFile(json: String, path: String) throws {
        try checkFileResult(zigpdf_generate_dividend_voucher_to_file(json, path))
    }

    /// Generate a stock transfer document and write directly to file.
    public static func stockTransferToFile(json: String, path: String) throws {
        try checkFileResult(zigpdf_generate_stock_transfer_to_file(json, path))
    }

    /// Generate a board resolution and write directly to file.
    public static func boardResolutionToFile(json: String, path: String) throws {
        try checkFileResult(zigpdf_generate_board_resolution_to_file(json, path))
    }

    /// Generate a director consent form and write directly to file.
    public static func directorConsentToFile(json: String, path: String) throws {
        try checkFileResult(zigpdf_generate_director_consent_to_file(json, path))
    }

    /// Generate a director appointment letter and write directly to file.
    public static func directorAppointmentToFile(json: String, path: String) throws {
        try checkFileResult(zigpdf_generate_director_appointment_to_file(json, path))
    }

    /// Generate a director resignation letter and write directly to file.
    public static func directorResignationToFile(json: String, path: String) throws {
        try checkFileResult(zigpdf_generate_director_resignation_to_file(json, path))
    }

    /// Generate a written resolution and write directly to file.
    public static func writtenResolutionToFile(json: String, path: String) throws {
        try checkFileResult(zigpdf_generate_written_resolution_to_file(json, path))
    }

    /// Generate a proposal and write directly to file.
    public static func proposalToFile(json: String, path: String) throws {
        try checkFileResult(zigpdf_generate_proposal_to_file(json, path))
    }

    /// Generate a template card and write directly to file.
    public static func templateCardToFile(json: String, path: String) throws {
        try checkFileResult(zigpdf_generate_template_card_to_file(json, path))
    }

    /// Library version string.
    public static var version: String {
        String(cString: zigpdf_version())
    }

    // MARK: - Private

    private static func withPointer(
        _ body: (UnsafeMutablePointer<size_t>) -> UnsafeMutablePointer<UInt8>?
    ) throws -> Data {
        var len: size_t = 0
        guard let ptr = body(&len) else {
            throw Self.lastError()
        }
        let out = Data(bytes: ptr, count: len)
        zigpdf_free(ptr, len)
        return out
    }

    private static func checkFileResult(_ code: CZigPdf.ZigPdfError) throws {
        if code.rawValue != 0 { throw Self.lastError() }
    }

    private static func lastError() -> ZigPdfError {
        let msg = String(cString: zigpdf_get_error())
        if msg.lowercased().contains("json") { return .invalidJSON(msg) }
        if msg.lowercased().contains("memory") { return .outOfMemory }
        if msg.lowercased().contains("argument") { return .invalidArgument }
        if msg.isEmpty { return .unknown("Unknown PDF generation failure") }
        return .renderFailed(msg)
    }
}
