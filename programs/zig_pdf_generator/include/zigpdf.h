/**
 * @file zigpdf.h
 * @brief Zig PDF Generator - C Foreign Function Interface
 * @version 1.0.0
 *
 * High-performance PDF generation library with support for:
 * - Professional invoices and quotes
 * - Cryptocurrency transaction receipts
 * - QR code generation (BIP21, EIP681, Solana Pay)
 * - Ethereum blockie-style identicons
 *
 * Memory Management:
 * - Input strings are borrowed (caller owns)
 * - Output buffers are allocated by the library
 * - Caller MUST free outputs with zigpdf_free()
 *
 * Thread Safety:
 * - All functions are thread-safe
 * - Error messages use thread-local storage
 *
 * Example:
 * @code
 * const char* json = "{\"company_name\":\"Acme Corp\", ...}";
 * size_t pdf_len = 0;
 * uint8_t* pdf = zigpdf_generate_invoice(json, &pdf_len);
 * if (pdf) {
 *     fwrite(pdf, 1, pdf_len, fopen("invoice.pdf", "wb"));
 *     zigpdf_free(pdf, pdf_len);
 * } else {
 *     fprintf(stderr, "Error: %s\n", zigpdf_get_error());
 * }
 * @endcode
 */

#ifndef ZIGPDF_H
#define ZIGPDF_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ============================================================================
 * Error Codes
 * ============================================================================ */

/**
 * @brief Error codes returned by zigpdf functions
 */
typedef enum {
    ZIGPDF_SUCCESS        =  0,  /**< Operation completed successfully */
    ZIGPDF_INVALID_JSON   = -1,  /**< JSON parsing failed */
    ZIGPDF_RENDER_FAILED  = -2,  /**< PDF rendering failed */
    ZIGPDF_OUT_OF_MEMORY  = -3,  /**< Memory allocation failed */
    ZIGPDF_INVALID_ARG    = -4,  /**< Invalid argument provided */
} ZigPdfError;

/* ============================================================================
 * Core Functions
 * ============================================================================ */

/**
 * @brief Generate an invoice PDF from JSON input
 *
 * Parses the JSON and generates a professional invoice PDF document.
 *
 * @param json_input Null-terminated JSON string containing invoice data
 * @param output_len Pointer to receive the length of the output PDF
 * @return Pointer to PDF bytes on success, NULL on error
 *
 * @note Caller must free the returned buffer with zigpdf_free()
 * @note On error, call zigpdf_get_error() for details
 *
 * JSON Schema:
 * @code{.json}
 * {
 *   "document_type": "invoice",
 *   "company_name": "Acme Corp",
 *   "company_address": "123 Business St",
 *   "company_vat": "ESB12345678",
 *   "company_logo_base64": "data:image/png;base64,...",
 *   "client_name": "Client LLC",
 *   "client_address": "456 Client Ave",
 *   "invoice_number": "INV-2025-001",
 *   "invoice_date": "2025-11-29",
 *   "due_date": "2025-12-29",
 *   "items": [
 *     {"description": "Service", "quantity": 10, "unit_price": 100, "total": 1000}
 *   ],
 *   "subtotal": 1000,
 *   "tax_rate": 0.21,
 *   "tax_amount": 210,
 *   "total": 1210,
 *   "notes": "Thank you!",
 *   "payment_terms": "Net 30",
 *   "qr_mode": "crypto",
 *   "crypto_wallet": "0x742d35Cc6634C0532925a3b844Bc9e7595f7ABCD",
 *   "crypto_network": "ethereum",
 *   "crypto_amount": 2.5,
 *   "show_crypto_identicons": true,
 *   "primary_color": "#627eea"
 * }
 * @endcode
 */
uint8_t* zigpdf_generate_invoice(const char* json_input, size_t* output_len);

/**
 * @brief Generate a simple PDF document
 *
 * Creates a basic PDF with a title and body text. Useful for testing.
 *
 * @param title Document title (null-terminated)
 * @param body Document body text (null-terminated)
 * @param output_len Pointer to receive output length
 * @return Pointer to PDF bytes on success, NULL on error
 *
 * @note Caller must free the returned buffer with zigpdf_free()
 */
uint8_t* zigpdf_generate_simple(const char* title, const char* body, size_t* output_len);

/**
 * @brief Free memory allocated by zigpdf functions
 *
 * Must be called for every non-NULL return from zigpdf_generate_* functions.
 *
 * @param ptr Pointer returned by a zigpdf function (may be NULL)
 * @param len Length of the allocated buffer
 */
void zigpdf_free(uint8_t* ptr, size_t len);

/**
 * @brief Get the last error message
 *
 * Returns a description of the most recent error. The returned string is
 * valid until the next zigpdf function call on the same thread.
 *
 * @return Null-terminated error string
 */
const char* zigpdf_get_error(void);

/**
 * @brief Get library version string
 *
 * @return Null-terminated version string (e.g., "1.0.0")
 */
const char* zigpdf_version(void);

/* ============================================================================
 * File Output Functions
 * ============================================================================ */

/**
 * @brief Generate invoice and write directly to file
 *
 * Convenience function that generates a PDF and writes it to the specified path.
 *
 * @param json_input Null-terminated JSON string
 * @param output_path Null-terminated file path (absolute path recommended)
 * @return ZIGPDF_SUCCESS on success, error code on failure
 */
ZigPdfError zigpdf_generate_invoice_to_file(const char* json_input, const char* output_path);

/**
 * @brief Generate crypto receipt and write directly to file
 *
 * @param json_input Null-terminated JSON string
 * @param output_path Null-terminated file path
 * @return ZIGPDF_SUCCESS on success, error code on failure
 */
ZigPdfError zigpdf_generate_crypto_receipt_to_file(const char* json_input, const char* output_path);

/* ============================================================================
 * JNI/Android Functions
 * ============================================================================ */

/**
 * @brief JNI-friendly invoice generation
 *
 * Returns a buffer with a 4-byte big-endian length prefix for easy
 * parsing in Java/Kotlin.
 *
 * Buffer format: [4 bytes length (big endian)][PDF data]
 *
 * @param json_input Null-terminated JSON string
 * @param total_len Pointer to receive total buffer length (including header)
 * @return Pointer to buffer on success, NULL on error
 *
 * @note Caller must free the returned buffer with zigpdf_free()
 */
uint8_t* zigpdf_generate_invoice_jni(const char* json_input, size_t* total_len);

/* ============================================================================
 * Crypto Receipt Functions
 * ============================================================================ */

/**
 * @brief Generate a cryptocurrency transaction receipt PDF
 *
 * Creates a professional receipt document for cryptocurrency transactions
 * with QR codes and optional identicons.
 *
 * @param json_input Null-terminated JSON string containing receipt data
 * @param output_len Pointer to receive the length of the output PDF
 * @return Pointer to PDF bytes on success, NULL on error
 *
 * @note Caller must free the returned buffer with zigpdf_free()
 *
 * Supported Networks:
 * - bitcoin, ethereum, polygon, litecoin, solana, tron
 * - dogecoin, cardano, xrp, bnb, usdt, usdc
 * - bitcoin_cash, lightning
 *
 * JSON Schema:
 * @code{.json}
 * {
 *   "tx_hash": "abc123...",
 *   "from_address": "0x1234...",
 *   "to_address": "0x5678...",
 *   "amount": "1.23456789",
 *   "symbol": "ETH",
 *   "network": "ethereum",
 *   "timestamp": "2025-01-04T12:34:56Z",
 *   "confirmations": 12,
 *   "block_height": 19000000,
 *   "network_fee": "0.002",
 *   "fiat_value": 3500.00,
 *   "fiat_symbol": "USD",
 *   "memo": "Payment for services",
 *   "document_type": "transaction_receipt",
 *   "show_identicons": true,
 *   "primary_color": "#627eea"
 * }
 * @endcode
 */
uint8_t* zigpdf_generate_crypto_receipt(const char* json_input, size_t* output_len);

/* ============================================================================
 * QR Code Functions
 * ============================================================================ */

/**
 * @brief Generate a QR code image
 *
 * Encodes data as a QR code and returns raw RGB pixel data.
 *
 * @param data Null-terminated string to encode
 * @param module_size Size of each QR module in pixels (1-16, recommended 4)
 * @param output_len Pointer to receive output length
 * @return Pointer to image data on success, NULL on error
 *
 * @note Caller must free the returned buffer with zigpdf_free()
 *
 * Output Format:
 * - Bytes 0-3: Width as uint32_t little-endian
 * - Bytes 4-7: Height as uint32_t little-endian
 * - Bytes 8+: RGB pixel data (3 bytes per pixel, row-major)
 *
 * Example:
 * @code
 * size_t len;
 * uint8_t* img = zigpdf_generate_qrcode("bitcoin:bc1q...", 4, &len);
 * if (img) {
 *     uint32_t width = *(uint32_t*)img;
 *     uint32_t height = *(uint32_t*)(img + 4);
 *     uint8_t* pixels = img + 8;
 *     // Use RGB pixels...
 *     zigpdf_free(img, len);
 * }
 * @endcode
 */
uint8_t* zigpdf_generate_qrcode(const char* data, int module_size, size_t* output_len);

/**
 * @brief Generate a QR code as SVG string
 *
 * Produces a compact SVG string with path-based rendering.
 * Supports versions 1-40, auto-detects optimal encoding mode.
 *
 * @param data Null-terminated data string to encode
 * @param output_len Pointer to receive SVG string length
 * @return Pointer to SVG string on success, NULL on error.
 *         Caller must free with zigpdf_free(ptr, *output_len).
 */
uint8_t* zigpdf_generate_qrcode_svg(const char* data, size_t* output_len);

/* ============================================================================
 * Identicon Functions
 * ============================================================================ */

/**
 * @brief Generate an Ethereum blockie-style identicon
 *
 * Creates a deterministic visual identifier from an address string.
 * The same address always produces the same identicon.
 *
 * @param address Null-terminated address string (e.g., "0x1234...")
 * @param scale Scale factor (1-16, recommended 8 for 64x64 output)
 * @param output_len Pointer to receive output length
 * @return Pointer to image data on success, NULL on error
 *
 * @note Caller must free the returned buffer with zigpdf_free()
 *
 * Output Format:
 * - Bytes 0-3: Width as uint32_t little-endian
 * - Bytes 4-7: Height as uint32_t little-endian
 * - Bytes 8+: RGB pixel data (3 bytes per pixel, row-major)
 *
 * The base grid is 8x8, so output dimensions are 8*scale x 8*scale.
 * With scale=8, output is 64x64 pixels.
 */
uint8_t* zigpdf_generate_identicon(const char* address, int scale, size_t* output_len);

/* ============================================================================
 * Supported Crypto Networks
 * ============================================================================ */

/**
 * @brief Supported cryptocurrency networks for invoices and receipts
 *
 * Use these string values for the "crypto_network" and "network" JSON fields:
 *
 * | Network      | Value          | URI Scheme      | Symbol |
 * |--------------|----------------|-----------------|--------|
 * | Bitcoin      | "bitcoin"      | bitcoin:        | BTC    |
 * | Ethereum     | "ethereum"     | ethereum:       | ETH    |
 * | Polygon      | "polygon"      | ethereum:@137   | MATIC  |
 * | Litecoin     | "litecoin"     | litecoin:       | LTC    |
 * | Solana       | "solana"       | solana:         | SOL    |
 * | Tron         | "tron"         | tron:           | TRX    |
 * | Dogecoin     | "dogecoin"     | dogecoin:       | DOGE   |
 * | Cardano      | "cardano"      | web+cardano:    | ADA    |
 * | XRP          | "xrp"          | xrpl:           | XRP    |
 * | BNB          | "bnb"          | ethereum:@56    | BNB    |
 * | USDT         | "usdt"         | ethereum:?token | USDT   |
 * | USDC         | "usdc"         | ethereum:?token | USDC   |
 * | Bitcoin Cash | "bitcoin_cash" | bitcoincash:    | BCH    |
 * | Lightning    | "lightning"    | lightning:      | BTC    |
 */

/* ============================================================================
 * Corporate Document Functions
 * ============================================================================
 *
 * All corporate document functions follow the same pattern:
 *   Buffer output: zigpdf_generate_<type>(json, &len) → PDF bytes or NULL
 *   File output:   zigpdf_generate_<type>_to_file(json, path) → error code
 *
 * Free buffer results with zigpdf_free(). On error, call zigpdf_get_error().
 */

/** @brief Generate a legal contract PDF */
uint8_t* zigpdf_generate_contract(const char* json_input, size_t* output_len);
ZigPdfError zigpdf_generate_contract_to_file(const char* json_input, const char* output_path);

/** @brief Generate a share certificate PDF */
uint8_t* zigpdf_generate_share_certificate(const char* json_input, size_t* output_len);
ZigPdfError zigpdf_generate_share_certificate_to_file(const char* json_input, const char* output_path);

/** @brief Generate a dividend voucher PDF */
uint8_t* zigpdf_generate_dividend_voucher(const char* json_input, size_t* output_len);
ZigPdfError zigpdf_generate_dividend_voucher_to_file(const char* json_input, const char* output_path);

/** @brief Generate a stock transfer document PDF */
uint8_t* zigpdf_generate_stock_transfer(const char* json_input, size_t* output_len);
ZigPdfError zigpdf_generate_stock_transfer_to_file(const char* json_input, const char* output_path);

/** @brief Generate a board resolution PDF */
uint8_t* zigpdf_generate_board_resolution(const char* json_input, size_t* output_len);
ZigPdfError zigpdf_generate_board_resolution_to_file(const char* json_input, const char* output_path);

/** @brief Generate a director consent form PDF */
uint8_t* zigpdf_generate_director_consent(const char* json_input, size_t* output_len);
ZigPdfError zigpdf_generate_director_consent_to_file(const char* json_input, const char* output_path);

/** @brief Generate a director appointment letter PDF */
uint8_t* zigpdf_generate_director_appointment(const char* json_input, size_t* output_len);
ZigPdfError zigpdf_generate_director_appointment_to_file(const char* json_input, const char* output_path);

/** @brief Generate a director resignation letter PDF */
uint8_t* zigpdf_generate_director_resignation(const char* json_input, size_t* output_len);
ZigPdfError zigpdf_generate_director_resignation_to_file(const char* json_input, const char* output_path);

/** @brief Generate a written resolution PDF */
uint8_t* zigpdf_generate_written_resolution(const char* json_input, size_t* output_len);
ZigPdfError zigpdf_generate_written_resolution_to_file(const char* json_input, const char* output_path);

/** @brief Generate a business proposal PDF */
uint8_t* zigpdf_generate_proposal(const char* json_input, size_t* output_len);
ZigPdfError zigpdf_generate_proposal_to_file(const char* json_input, const char* output_path);

/** @brief Generate a template card PDF */
uint8_t* zigpdf_generate_template_card(const char* json_input, size_t* output_len);
ZigPdfError zigpdf_generate_template_card_to_file(const char* json_input, const char* output_path);

/* ============================================================================
 * QR Code Modes for Invoices
 * ============================================================================ */

/**
 * @brief Supported QR code modes for invoices
 *
 * Use these string values for the "qr_mode" JSON field:
 *
 * | Mode         | Value          | Description                      |
 * |--------------|----------------|----------------------------------|
 * | None         | "none"         | No QR code displayed             |
 * | VeriFactu    | "verifactu"    | Spanish e-invoicing compliance   |
 * | Payment Link | "payment_link" | Stripe/PayPal payment URL        |
 * | Bank Details | "bank_details" | UK Faster Payments format        |
 * | Verification | "verification" | Invoice verification URL         |
 * | Crypto       | "crypto"       | Cryptocurrency payment address   |
 */

#ifdef __cplusplus
}
#endif

#endif /* ZIGPDF_H */
