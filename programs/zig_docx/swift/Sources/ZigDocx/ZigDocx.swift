// Copyright (c) 2025 QUANTUM ENCODING LTD
// Licensed under the MIT License.

import Foundation
import CZigDocx

// MARK: - Options

/// Options for markdown-to-DOCX conversion.
public struct DocxOptions {
    public var title: String?
    public var author: String?
    public var date: String?
    public var description: String?
    public var letterheadData: Data?
    public var letterheadExtension: String?

    public init(
        title: String? = nil,
        author: String? = nil,
        date: String? = nil,
        description: String? = nil,
        letterheadData: Data? = nil,
        letterheadExtension: String? = nil
    ) {
        self.title = title
        self.author = author
        self.date = date
        self.description = description
        self.letterheadData = letterheadData
        self.letterheadExtension = letterheadExtension
    }
}

// MARK: - Document Info

/// Metadata extracted from a DOCX file.
public struct DocxInfo {
    public let title: String?
    public let author: String?
    public let wordCount: UInt32
    public let paragraphCount: UInt32
    public let imageCount: UInt16
    public let hasTables: Bool
}

// MARK: - Errors

public enum DocxError: Error, LocalizedError {
    case conversionFailed(String)
    case invalidInput

    public var errorDescription: String? {
        switch self {
        case .conversionFailed(let msg): return msg
        case .invalidInput: return "Invalid input data"
        }
    }
}

// MARK: - Main API

/// Thread-safe document conversion powered by zig-docx.
///
/// Usage:
/// ```swift
/// // Markdown → DOCX
/// let docxData = try ZigDocx.markdownToDocx("# Hello\n\nWorld")
///
/// // DOCX → Markdown
/// let markdown = try ZigDocx.docxToMarkdown(docxData)
///
/// // With options
/// let opts = DocxOptions(title: "Report", author: "AI")
/// let docx = try ZigDocx.markdownToDocx(markdown, options: opts)
/// ```
public enum ZigDocx {

    /// Convert markdown text to DOCX bytes.
    public static func markdownToDocx(
        _ markdown: String,
        options: DocxOptions? = nil
    ) throws -> Data {
        let mdData = Array(markdown.utf8)

        let result: ZigDocxResult = mdData.withUnsafeBufferPointer { mdBuf in
            guard let mdPtr = mdBuf.baseAddress else {
                return ZigDocxResult(data: nil, len: 0, error_msg: nil)
            }

            if let opts = options {
                return withCOptions(opts) { cOpts in
                    zig_docx_md_to_docx(mdPtr, mdBuf.count, &cOpts)
                }
            } else {
                return zig_docx_md_to_docx(mdPtr, mdBuf.count, nil)
            }
        }

        return try extractResult(result)
    }

    /// Convert DOCX bytes to markdown text.
    public static func docxToMarkdown(_ docxData: Data) throws -> String {
        let result: ZigDocxResult = docxData.withUnsafeBytes { buf in
            guard let ptr = buf.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return ZigDocxResult(data: nil, len: 0, error_msg: nil)
            }
            return zig_docx_to_markdown(ptr, buf.count)
        }

        let data = try extractResult(result)
        guard let text = String(data: data, encoding: .utf8) else {
            throw DocxError.conversionFailed("Output is not valid UTF-8")
        }
        return text
    }

    /// Get document info without full conversion.
    public static func info(from docxData: Data) -> DocxInfo {
        let cInfo: ZigDocxInfo = docxData.withUnsafeBytes { buf in
            guard let ptr = buf.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return ZigDocxInfo()
            }
            return zig_docx_info(ptr, buf.count)
        }

        let title = cInfo.title.map { String(cString: $0) }
        let author = cInfo.author.map { String(cString: $0) }

        // Free C strings after copying
        var mutableInfo = cInfo
        zig_docx_free_info(&mutableInfo)

        return DocxInfo(
            title: title,
            author: author,
            wordCount: cInfo.word_count,
            paragraphCount: cInfo.paragraph_count,
            imageCount: cInfo.image_count,
            hasTables: cInfo.has_tables
        )
    }

    // MARK: - Fire Risk Assessment

    /// Generate a Fire Risk Assessment DOCX from JSON.
    ///
    /// The JSON defines assessor details, client/premises info, checklist
    /// sections with Yes/No answers, risk ratings, and action plan items.
    /// All PAS 79 boilerplate text is built-in.
    public static func fireRiskAssessment(json: String) throws -> Data {
        let jsonData = Array(json.utf8)
        let result: ZigDocxResult = jsonData.withUnsafeBufferPointer { buf in
            guard let ptr = buf.baseAddress else {
                return ZigDocxResult(data: nil, len: 0, error_msg: nil)
            }
            return zig_docx_fra_from_json(ptr, buf.count)
        }
        return try extractResult(result)
    }

    /// Library version string.
    public static var version: String {
        String(cString: zig_docx_version())
    }

    // MARK: - Private

    private static func extractResult(_ result: ZigDocxResult) throws -> Data {
        if let errorMsg = result.error_msg {
            let msg = String(cString: errorMsg)
            zig_docx_free_string(UnsafeMutablePointer(mutating: errorMsg))
            throw DocxError.conversionFailed(msg)
        }

        guard let data = result.data else {
            throw DocxError.invalidInput
        }

        let output = Data(bytes: data, count: result.len)
        zig_docx_free(data, result.len)
        return output
    }

    private static func withCOptions<T>(
        _ opts: DocxOptions,
        body: (ZigDocxOptions) -> T
    ) -> T {
        let title = opts.title?.cString(using: .utf8)
        let author = opts.author?.cString(using: .utf8)
        let date = opts.date?.cString(using: .utf8)
        let desc = opts.description?.cString(using: .utf8)
        let ext = opts.letterheadExtension?.cString(using: .utf8)

        var cOpts = ZigDocxOptions()

        if let t = title {
            t.withUnsafeBufferPointer { cOpts.title = $0.baseAddress }
        }
        if let a = author {
            a.withUnsafeBufferPointer { cOpts.author = $0.baseAddress }
        }
        if let d = date {
            d.withUnsafeBufferPointer { cOpts.date = $0.baseAddress }
        }
        if let d = desc {
            d.withUnsafeBufferPointer { cOpts.description = $0.baseAddress }
        }
        if let e = ext {
            e.withUnsafeBufferPointer { cOpts.letterhead_ext = $0.baseAddress }
        }

        if let lhData = opts.letterheadData {
            return lhData.withUnsafeBytes { buf in
                cOpts.letterhead_data = buf.baseAddress?.assumingMemoryBound(to: UInt8.self)
                cOpts.letterhead_len = buf.count
                return body(cOpts)
            }
        }

        return body(cOpts)
    }
}
