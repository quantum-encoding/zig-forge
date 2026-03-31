//! JSON Parser for Invoice Data
//!
//! Parses JSON input matching the frontend's invoiceData format:
//! ```json
//! {
//!   "document_type": "invoice",
//!   "company_name": "Acme Corp",
//!   "company_address": "123 Business St",
//!   "company_vat": "ESB12345678",
//!   "company_logo_base64": "data:image/png;base64,...",
//!   "client_name": "Client LLC",
//!   "client_address": "456 Client Ave",
//!   "client_vat": "ESB87654321",
//!   "invoice_number": "INV-2025-001",
//!   "invoice_date": "2025-11-29",
//!   "due_date": "2025-12-29",
//!   "display_mode": "itemized",
//!   "items": [
//!     {"description": "Service", "quantity": 10, "unit_price": 100, "total": 1000}
//!   ],
//!   "blackbox_description": "",
//!   "subtotal": 1000,
//!   "tax_rate": 0.21,
//!   "tax_amount": 210,
//!   "total": 1210,
//!   "verifactu_qr_base64": "data:image/png;base64,...",
//!   "notes": "Thank you",
//!   "payment_terms": "30 days",
//!   "primary_color": "#b39a7d",
//!   "secondary_color": "#2c3e50",
//!   "title_color": "#b39a7d",
//!   "company_name_color": "#1a1a1a",
//!   "font_family": "Helvetica"
//! }
//! ```

const std = @import("std");
const invoice = @import("invoice.zig");
const crypto_receipt = @import("crypto_receipt.zig");

pub const JsonError = error{
    InvalidJson,
    MissingField,
    InvalidType,
    OutOfMemory,
};

// =============================================================================
// JSON Parsing
// =============================================================================

/// Parse JSON string to InvoiceData
pub fn parseInvoiceJson(allocator: std.mem.Allocator, json_str: []const u8) !invoice.InvoiceData {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_str, .{}) catch {
        return error.InvalidJson;
    };
    defer parsed.deinit();

    return parseInvoiceFromValue(allocator, parsed.value);
}

/// Parse InvoiceData from parsed JSON value
fn parseInvoiceFromValue(allocator: std.mem.Allocator, root: std.json.Value) !invoice.InvoiceData {
    if (root != .object) return error.InvalidJson;

    const obj = root.object;

    var data = invoice.InvoiceData{};

    // Parse string fields (always allocate, even defaults, so freeInvoiceData works correctly)
    data.document_type = try dupeJsonString(allocator, obj, "document_type") orelse try allocator.dupe(u8, "invoice");
    data.company_name = try dupeJsonString(allocator, obj, "company_name") orelse try allocator.dupe(u8, "");
    data.company_address = try dupeJsonString(allocator, obj, "company_address") orelse try allocator.dupe(u8, "");
    data.company_vat = try dupeJsonString(allocator, obj, "company_vat") orelse try allocator.dupe(u8, "");
    data.company_logo_base64 = try dupeJsonString(allocator, obj, "company_logo_base64");
    data.client_name = try dupeJsonString(allocator, obj, "client_name") orelse try allocator.dupe(u8, "");
    data.client_address = try dupeJsonString(allocator, obj, "client_address") orelse try allocator.dupe(u8, "");
    data.client_vat = try dupeJsonString(allocator, obj, "client_vat") orelse try allocator.dupe(u8, "");
    data.invoice_number = try dupeJsonString(allocator, obj, "invoice_number") orelse try allocator.dupe(u8, "");
    data.invoice_date = try dupeJsonString(allocator, obj, "invoice_date") orelse try allocator.dupe(u8, "");
    data.due_date = try dupeJsonString(allocator, obj, "due_date") orelse try allocator.dupe(u8, "");
    data.blackbox_description = try dupeJsonString(allocator, obj, "blackbox_description") orelse try allocator.dupe(u8, "");
    data.qr_base64 = try dupeJsonString(allocator, obj, "qr_base64");
    data.verifactu_qr_base64 = try dupeJsonString(allocator, obj, "verifactu_qr_base64");
    data.notes = try dupeJsonString(allocator, obj, "notes") orelse try allocator.dupe(u8, "");
    data.payment_terms = try dupeJsonString(allocator, obj, "payment_terms") orelse try allocator.dupe(u8, "");
    data.primary_color = try dupeJsonString(allocator, obj, "primary_color") orelse try allocator.dupe(u8, "#b39a7d");
    data.secondary_color = try dupeJsonString(allocator, obj, "secondary_color") orelse try allocator.dupe(u8, "#2c3e50");
    data.title_color = try dupeJsonString(allocator, obj, "title_color") orelse try allocator.dupe(u8, "#b39a7d");
    data.company_name_color = try dupeJsonString(allocator, obj, "company_name_color") orelse try allocator.dupe(u8, "#1a1a1a");
    data.font_family = try dupeJsonString(allocator, obj, "font_family") orelse try allocator.dupe(u8, "Helvetica");

    // Parse numeric fields
    data.subtotal = getJsonFloat(obj, "subtotal") orelse 0;
    data.tax_rate = getJsonFloat(obj, "tax_rate") orelse 0.21;
    data.tax_amount = getJsonFloat(obj, "tax_amount") orelse 0;
    data.total = getJsonFloat(obj, "total") orelse 0;
    data.logo_x = @floatCast(getJsonFloat(obj, "logo_x") orelse 40);
    data.logo_y = @floatCast(getJsonFloat(obj, "logo_y") orelse 750);
    data.logo_width = @floatCast(getJsonFloat(obj, "logo_width") orelse 80);
    data.logo_height = @floatCast(getJsonFloat(obj, "logo_height") orelse 50);

    // Parse display mode
    if (getJsonString(obj, "display_mode")) |mode| {
        if (std.mem.eql(u8, mode, "blackbox")) {
            data.display_mode = .blackbox;
        } else {
            data.display_mode = .itemized;
        }
    }

    // Parse template style
    if (getJsonString(obj, "template_style")) |style| {
        if (std.mem.eql(u8, style, "modern")) {
            data.template_style = .modern;
        } else if (std.mem.eql(u8, style, "classic")) {
            data.template_style = .classic;
        } else if (std.mem.eql(u8, style, "creative")) {
            data.template_style = .creative;
        } else {
            data.template_style = .professional;
        }
    }

    // Parse QR code mode
    if (getJsonString(obj, "qr_mode")) |mode| {
        if (std.mem.eql(u8, mode, "verifactu")) {
            data.qr_mode = .verifactu;
        } else if (std.mem.eql(u8, mode, "payment_link") or std.mem.eql(u8, mode, "payment")) {
            data.qr_mode = .payment_link;
        } else if (std.mem.eql(u8, mode, "bank_details") or std.mem.eql(u8, mode, "bank")) {
            data.qr_mode = .bank_details;
        } else if (std.mem.eql(u8, mode, "verification") or std.mem.eql(u8, mode, "verify")) {
            data.qr_mode = .verification;
        } else if (std.mem.eql(u8, mode, "crypto") or std.mem.eql(u8, mode, "cryptocurrency")) {
            data.qr_mode = .crypto;
        } else {
            data.qr_mode = .none;
        }
    }

    // Parse custom QR label (overrides default label for the mode)
    data.qr_label = try dupeJsonString(allocator, obj, "qr_label");

    // Parse VeriFactu compliance fields (Spanish e-invoicing)
    data.verifactu_hash = try dupeJsonString(allocator, obj, "verifactu_hash");
    data.verifactu_series = try dupeJsonString(allocator, obj, "verifactu_series");
    data.verifactu_nif = try dupeJsonString(allocator, obj, "verifactu_nif");
    data.verifactu_timestamp = try dupeJsonString(allocator, obj, "verifactu_timestamp");

    // Parse crypto payment fields
    data.crypto_wallet = try dupeJsonString(allocator, obj, "crypto_wallet");
    data.crypto_sender_wallet = try dupeJsonString(allocator, obj, "crypto_sender_wallet");
    data.crypto_custom_symbol = try dupeJsonString(allocator, obj, "crypto_custom_symbol");
    data.crypto_amount = getJsonFloat(obj, "crypto_amount");

    // Parse crypto network
    if (getJsonString(obj, "crypto_network")) |network_str| {
        data.crypto_network = crypto_receipt.Network.fromString(network_str);
    }

    // Parse show_crypto_identicons boolean
    if (obj.get("show_crypto_identicons")) |val| {
        if (val == .bool) {
            data.show_crypto_identicons = val.bool;
        }
    }

    // Parse show_branding boolean (defaults to true)
    if (obj.get("show_branding")) |val| {
        if (val == .bool) {
            data.show_branding = val.bool;
        }
    }

    // Parse branding_url (optional custom URL)
    if (try dupeJsonString(allocator, obj, "branding_url")) |url| {
        data.branding_url = url;
    }

    // Parse payment button fields (clickable link in PDF)
    data.payment_button_url = try dupeJsonString(allocator, obj, "payment_button_url");
    data.payment_button_label = try dupeJsonString(allocator, obj, "payment_button_label") orelse try allocator.dupe(u8, "Pay Now");
    data.payment_button_color = try dupeJsonString(allocator, obj, "payment_button_color") orelse try allocator.dupe(u8, "#635BFF");
    data.payment_button_text_color = try dupeJsonString(allocator, obj, "payment_button_text_color") orelse try allocator.dupe(u8, "#FFFFFF");

    // Parse line items
    if (obj.get("items")) |items_val| {
        if (items_val == .array) {
            const items_array = items_val.array;
            var items = try allocator.alloc(invoice.LineItem, items_array.items.len);

            for (items_array.items, 0..) |item_val, i| {
                if (item_val == .object) {
                    const item_obj = item_val.object;
                    items[i] = invoice.LineItem{
                        .description = try dupeJsonString(allocator, item_obj, "description") orelse "",
                        .quantity = getJsonFloat(item_obj, "quantity") orelse 0,
                        .unit_price = getJsonFloat(item_obj, "unit_price") orelse 0,
                        .total = getJsonFloat(item_obj, "total") orelse 0,
                    };
                }
            }

            data.items = items;
        }
    }

    return data;
}

/// Get string value from JSON object
fn getJsonString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    if (obj.get(key)) |val| {
        if (val == .string) {
            return val.string;
        }
    }
    return null;
}

/// Get float value from JSON object
fn getJsonFloat(obj: std.json.ObjectMap, key: []const u8) ?f64 {
    if (obj.get(key)) |val| {
        switch (val) {
            .float => return val.float,
            .integer => return @floatFromInt(val.integer),
            else => return null,
        }
    }
    return null;
}

/// Duplicate a JSON string value (allocates memory)
fn dupeJsonString(allocator: std.mem.Allocator, obj: std.json.ObjectMap, key: []const u8) !?[]const u8 {
    if (getJsonString(obj, key)) |str| {
        return try allocator.dupe(u8, str);
    }
    return null;
}

/// Free InvoiceData allocated strings and items
pub fn freeInvoiceData(allocator: std.mem.Allocator, data: *const invoice.InvoiceData) void {
    // Free string fields
    if (data.document_type.len > 0) allocator.free(data.document_type);
    if (data.company_name.len > 0) allocator.free(data.company_name);
    if (data.company_address.len > 0) allocator.free(data.company_address);
    if (data.company_vat.len > 0) allocator.free(data.company_vat);
    if (data.company_logo_base64) |s| allocator.free(s);
    if (data.client_name.len > 0) allocator.free(data.client_name);
    if (data.client_address.len > 0) allocator.free(data.client_address);
    if (data.client_vat.len > 0) allocator.free(data.client_vat);
    if (data.invoice_number.len > 0) allocator.free(data.invoice_number);
    if (data.invoice_date.len > 0) allocator.free(data.invoice_date);
    if (data.due_date.len > 0) allocator.free(data.due_date);
    if (data.blackbox_description.len > 0) allocator.free(data.blackbox_description);
    if (data.qr_base64) |s| allocator.free(s);
    if (data.qr_label) |s| allocator.free(s);
    if (data.verifactu_qr_base64) |s| allocator.free(s);
    if (data.verifactu_hash) |s| allocator.free(s);
    if (data.verifactu_series) |s| allocator.free(s);
    if (data.verifactu_nif) |s| allocator.free(s);
    if (data.verifactu_timestamp) |s| allocator.free(s);

    // Free crypto payment fields
    if (data.crypto_wallet) |s| allocator.free(s);
    if (data.crypto_sender_wallet) |s| allocator.free(s);
    if (data.crypto_custom_symbol) |s| allocator.free(s);

    // Free payment button fields
    if (data.payment_button_url) |s| allocator.free(s);
    if (data.payment_button_label.len > 0) allocator.free(data.payment_button_label);
    if (data.payment_button_color.len > 0) allocator.free(data.payment_button_color);
    if (data.payment_button_text_color.len > 0) allocator.free(data.payment_button_text_color);

    if (data.notes.len > 0) allocator.free(data.notes);
    if (data.payment_terms.len > 0) allocator.free(data.payment_terms);
    if (data.primary_color.len > 0) allocator.free(data.primary_color);
    if (data.secondary_color.len > 0) allocator.free(data.secondary_color);
    if (data.title_color.len > 0) allocator.free(data.title_color);
    if (data.company_name_color.len > 0) allocator.free(data.company_name_color);
    if (data.font_family.len > 0) allocator.free(data.font_family);

    // Free items
    if (data.items.len > 0) {
        for (data.items) |item| {
            if (item.description.len > 0) allocator.free(item.description);
        }
        allocator.free(data.items);
    }
}

// =============================================================================
// Crypto Receipt JSON Parsing
// =============================================================================

/// Parse JSON string to CryptoReceiptData
/// JSON format:
/// ```json
/// {
///   "tx_hash": "abc123...",
///   "from_address": "bc1q...",
///   "to_address": "bc1q...",
///   "amount": "1.23456789",
///   "symbol": "BTC",
///   "network": "bitcoin",
///   "timestamp": "2025-01-04T12:34:56Z",
///   "confirmations": 6,
///   "block_height": 823456,
///   "network_fee": "0.00012345",
///   "fiat_value": 45678.90,
///   "fiat_symbol": "USD",
///   "memo": "Payment for services",
///   "primary_color": "#f7931a",
///   "show_identicons": true
/// }
/// ```
pub fn parseCryptoReceiptJson(allocator: std.mem.Allocator, json_str: []const u8) !crypto_receipt.CryptoReceiptData {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_str, .{}) catch {
        return error.InvalidJson;
    };
    defer parsed.deinit();

    return parseCryptoReceiptFromValue(allocator, parsed.value);
}

/// Parse CryptoReceiptData from parsed JSON value
fn parseCryptoReceiptFromValue(allocator: std.mem.Allocator, root: std.json.Value) !crypto_receipt.CryptoReceiptData {
    if (root != .object) return error.InvalidJson;

    const obj = root.object;

    // Required fields
    const tx_hash = try dupeJsonString(allocator, obj, "tx_hash") orelse return error.MissingField;
    errdefer allocator.free(tx_hash);

    const from_address = try dupeJsonString(allocator, obj, "from_address") orelse return error.MissingField;
    errdefer allocator.free(from_address);

    const to_address = try dupeJsonString(allocator, obj, "to_address") orelse return error.MissingField;
    errdefer allocator.free(to_address);

    const amount = try dupeJsonString(allocator, obj, "amount") orelse return error.MissingField;
    errdefer allocator.free(amount);

    // Always allocate string fields so freeCryptoReceiptData can consistently free them
    const symbol = try dupeJsonString(allocator, obj, "symbol") orelse try allocator.dupe(u8, "BTC");
    errdefer allocator.free(symbol);

    const secondary_color = try dupeJsonString(allocator, obj, "secondary_color") orelse try allocator.dupe(u8, "#2c3e50");
    errdefer allocator.free(secondary_color);

    const fiat_symbol = try dupeJsonString(allocator, obj, "fiat_symbol") orelse try allocator.dupe(u8, "USD");
    errdefer allocator.free(fiat_symbol);

    var data = crypto_receipt.CryptoReceiptData{
        .tx_hash = tx_hash,
        .from_address = from_address,
        .to_address = to_address,
        .amount = amount,
        .symbol = symbol,
        .secondary_color = secondary_color,
        .fiat_symbol = fiat_symbol,
    };

    // Custom title (optional - defaults to document_type title)
    data.custom_title = try dupeJsonString(allocator, obj, "title");

    // Document type
    if (getJsonString(obj, "document_type")) |dt| {
        data.document_type = crypto_receipt.DocumentType.fromString(dt);
    }

    // Network parsing
    if (getJsonString(obj, "network")) |network_str| {
        data.network = crypto_receipt.Network.fromString(network_str);
    }

    data.timestamp = try dupeJsonString(allocator, obj, "timestamp");
    data.network_fee = try dupeJsonString(allocator, obj, "network_fee");
    data.fee_symbol = try dupeJsonString(allocator, obj, "fee_symbol");
    data.memo = try dupeJsonString(allocator, obj, "memo");
    data.qr_content = try dupeJsonString(allocator, obj, "qr_content");
    data.primary_color = try dupeJsonString(allocator, obj, "primary_color");
    data.footer_text = try dupeJsonString(allocator, obj, "footer_text");

    // Optional numeric fields
    if (getJsonInt(obj, "confirmations")) |c| {
        data.confirmations = @intCast(c);
    }

    if (getJsonInt(obj, "block_height")) |h| {
        data.block_height = @intCast(h);
    }

    data.fiat_value = getJsonFloat(obj, "fiat_value");
    data.exchange_rate = getJsonFloat(obj, "exchange_rate");

    // Boolean fields
    if (getJsonBool(obj, "show_identicons")) |b| {
        data.show_identicons = b;
    }

    return data;
}

/// Get integer value from JSON object
fn getJsonInt(obj: std.json.ObjectMap, key: []const u8) ?i64 {
    if (obj.get(key)) |val| {
        if (val == .integer) {
            return val.integer;
        }
    }
    return null;
}

/// Get boolean value from JSON object
fn getJsonBool(obj: std.json.ObjectMap, key: []const u8) ?bool {
    if (obj.get(key)) |val| {
        if (val == .bool) {
            return val.bool;
        }
    }
    return null;
}

/// Free CryptoReceiptData allocated strings
/// Note: This only works for data created by parseCryptoReceiptJson,
/// which always allocates all string fields.
pub fn freeCryptoReceiptData(allocator: std.mem.Allocator, data: *const crypto_receipt.CryptoReceiptData) void {
    // Required fields (always allocated)
    allocator.free(data.tx_hash);
    allocator.free(data.from_address);
    allocator.free(data.to_address);
    allocator.free(data.amount);

    // Fields with defaults (always allocated by parser)
    allocator.free(data.symbol);
    allocator.free(data.secondary_color);
    allocator.free(data.fiat_symbol);

    // Optional fields
    if (data.custom_title) |s| allocator.free(s);
    if (data.timestamp) |s| allocator.free(s);
    if (data.network_fee) |s| allocator.free(s);
    if (data.fee_symbol) |s| allocator.free(s);
    if (data.memo) |s| allocator.free(s);
    if (data.qr_content) |s| allocator.free(s);
    if (data.primary_color) |s| allocator.free(s);
    if (data.footer_text) |s| allocator.free(s);
}

// =============================================================================
// Tests
// =============================================================================

test "parse simple invoice JSON" {
    const allocator = std.testing.allocator;

    const json =
        \\{
        \\  "document_type": "invoice",
        \\  "company_name": "Test Corp",
        \\  "company_vat": "ESB12345678",
        \\  "client_name": "Client Inc",
        \\  "invoice_number": "INV-001",
        \\  "invoice_date": "2025-11-29",
        \\  "items": [
        \\    {"description": "Service A", "quantity": 5, "unit_price": 100, "total": 500}
        \\  ],
        \\  "subtotal": 500,
        \\  "tax_rate": 0.21,
        \\  "tax_amount": 105,
        \\  "total": 605
        \\}
    ;

    const data = try parseInvoiceJson(allocator, json);
    defer freeInvoiceData(allocator, &data);

    try std.testing.expectEqualStrings("invoice", data.document_type);
    try std.testing.expectEqualStrings("Test Corp", data.company_name);
    try std.testing.expectEqualStrings("Client Inc", data.client_name);
    try std.testing.expectEqual(@as(usize, 1), data.items.len);
    try std.testing.expectEqualStrings("Service A", data.items[0].description);
    try std.testing.expectApproxEqAbs(@as(f64, 500), data.subtotal, 0.01);
    try std.testing.expectApproxEqAbs(@as(f64, 605), data.total, 0.01);
}

test "parse invoice with colors" {
    const allocator = std.testing.allocator;

    const json =
        \\{
        \\  "company_name": "Acme",
        \\  "primary_color": "#ff0000",
        \\  "secondary_color": "#00ff00",
        \\  "display_mode": "blackbox",
        \\  "blackbox_description": "Professional services"
        \\}
    ;

    const data = try parseInvoiceJson(allocator, json);
    defer freeInvoiceData(allocator, &data);

    try std.testing.expectEqualStrings("#ff0000", data.primary_color);
    try std.testing.expectEqualStrings("#00ff00", data.secondary_color);
    try std.testing.expectEqual(invoice.DisplayMode.blackbox, data.display_mode);
    try std.testing.expectEqualStrings("Professional services", data.blackbox_description);
}

test "parse crypto receipt JSON" {
    const allocator = std.testing.allocator;

    const json =
        \\{
        \\  "tx_hash": "abc123def456789012345678901234567890",
        \\  "from_address": "bc1qar0srrr7xfkvy5l643lydnw9re59gtzzwf5mdq",
        \\  "to_address": "bc1qc7slrfxkknqcq2jevvvkdgvrt8080852dfjewde",
        \\  "amount": "0.12345678",
        \\  "symbol": "BTC",
        \\  "network": "bitcoin",
        \\  "timestamp": "2025-01-04 12:34:56 UTC",
        \\  "confirmations": 6,
        \\  "block_height": 823456,
        \\  "network_fee": "0.00001234",
        \\  "fiat_value": 5432.10,
        \\  "memo": "Payment for services"
        \\}
    ;

    const data = try parseCryptoReceiptJson(allocator, json);
    defer freeCryptoReceiptData(allocator, &data);

    try std.testing.expectEqualStrings("abc123def456789012345678901234567890", data.tx_hash);
    try std.testing.expectEqualStrings("bc1qar0srrr7xfkvy5l643lydnw9re59gtzzwf5mdq", data.from_address);
    try std.testing.expectEqualStrings("0.12345678", data.amount);
    try std.testing.expectEqual(crypto_receipt.Network.bitcoin, data.network);
    try std.testing.expectEqual(@as(?u32, 6), data.confirmations);
    try std.testing.expectEqual(@as(?u64, 823456), data.block_height);
    try std.testing.expectEqualStrings("Payment for services", data.memo.?);
}

test "parse crypto receipt missing required field" {
    const allocator = std.testing.allocator;

    const json =
        \\{
        \\  "from_address": "bc1q...",
        \\  "to_address": "bc1q...",
        \\  "amount": "1.0"
        \\}
    ;

    const result = parseCryptoReceiptJson(allocator, json);
    try std.testing.expectError(error.MissingField, result);
}
