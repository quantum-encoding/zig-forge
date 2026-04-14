// Copyright (c) 2025 QUANTUM ENCODING LTD
// Licensed under the MIT License.
//
// zig_docx.h — C API for the zig-docx document conversion library.
//
// Embed in any language that supports C FFI: Swift, Python, Go, Rust, etc.
// Thread-safe: no global state, all functions are reentrant.
//
// Usage:
//   1. Link against libzig_docx.a (static) or libzig_docx.dylib (dynamic)
//   2. Call zig_docx_md_to_docx() / zig_docx_to_markdown()
//   3. Free results with zig_docx_free()

#ifndef ZIG_DOCX_H
#define ZIG_DOCX_H

#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// ─── Types ─────────────────────────────────────────────────────────

/// Result of a conversion: data + length, or error message.
/// Free data with zig_docx_free(result.data, result.len).
/// Free error_msg with zig_docx_free_string(result.error_msg).
typedef struct {
    uint8_t *data;          // Output bytes (DOCX or markdown). NULL on error.
    size_t len;             // Length of data in bytes.
    const char *error_msg;  // NULL on success, error description on failure.
} ZigDocxResult;

/// Options for markdown-to-DOCX conversion.
/// All fields are optional — pass NULL for defaults.
typedef struct {
    const char *title;            // Document title (null-terminated). NULL = use frontmatter.
    const char *author;           // Document author. NULL = use frontmatter.
    const char *date;             // Document date. NULL = use frontmatter.
    const char *description;      // Document description. NULL = use frontmatter.
    const uint8_t *letterhead_data;  // Letterhead image bytes. NULL = no letterhead.
    size_t letterhead_len;           // Length of letterhead_data.
    const char *letterhead_ext;      // Image extension ("png", "jpg"). NULL = "png".
} ZigDocxOptions;

/// Document metadata extracted from a DOCX file.
/// Free with zig_docx_free_info().
typedef struct {
    char *title;              // First heading text. NULL if none. Owned.
    char *author;             // Document author. NULL if none. Owned.
    uint32_t word_count;      // Total word count.
    uint32_t paragraph_count; // Total paragraph count.
    uint16_t image_count;     // Number of embedded images.
    bool has_tables;          // Whether the document contains tables.
} ZigDocxInfo;

// ─── Core Functions ────────────────────────────────────────────────

/// Convert markdown text to a DOCX file (in memory).
///
/// @param md_ptr   Pointer to UTF-8 markdown text.
/// @param md_len   Length of markdown text in bytes.
/// @param opts     Conversion options. Pass NULL for defaults.
/// @return         ZigDocxResult with DOCX bytes or error.
///
/// Example:
///   const char *md = "# Hello\n\nWorld";
///   ZigDocxResult r = zig_docx_md_to_docx(md, strlen(md), NULL);
///   if (r.data) { fwrite(r.data, 1, r.len, f); }
///   zig_docx_free(r.data, r.len);
ZigDocxResult zig_docx_md_to_docx(const uint8_t *md_ptr,
                                   size_t md_len,
                                   const ZigDocxOptions *opts);

/// Convert a DOCX file (in memory) to markdown text.
///
/// @param docx_ptr  Pointer to DOCX file bytes.
/// @param docx_len  Length of DOCX data in bytes.
/// @return          ZigDocxResult with UTF-8 markdown or error.
ZigDocxResult zig_docx_to_markdown(const uint8_t *docx_ptr,
                                    size_t docx_len);

/// Get document metadata from a DOCX file without full conversion.
///
/// @param docx_ptr  Pointer to DOCX file bytes.
/// @param docx_len  Length of DOCX data in bytes.
/// @return          ZigDocxInfo with document metadata.
ZigDocxInfo zig_docx_info(const uint8_t *docx_ptr,
                           size_t docx_len);

// ─── Memory Management ────────────────────────────────────────────

/// Free data returned by zig_docx_md_to_docx / zig_docx_to_markdown.
/// Safe to call with NULL ptr.
void zig_docx_free(uint8_t *ptr, size_t len);

/// Free a null-terminated string returned by the library.
/// Safe to call with NULL ptr.
void zig_docx_free_string(char *ptr);

/// Free all owned strings in a ZigDocxInfo struct.
void zig_docx_free_info(ZigDocxInfo *info);

// ─── Fire Risk Assessment ─────────────────────────────────────────

/// Generate a Fire Risk Assessment DOCX from JSON input.
///
/// JSON schema supports: assessor details, client/premises info,
/// checklist sections with Yes/No answers, risk ratings, action plan.
/// All PAS 79 boilerplate is built-in.
///
/// @param json_ptr  Pointer to UTF-8 JSON text.
/// @param json_len  Length of JSON text in bytes.
/// @return          ZigDocxResult with DOCX bytes or error.
ZigDocxResult zig_docx_fra_from_json(const uint8_t *json_ptr,
                                      size_t json_len);

// ─── Utility ──────────────────────────────────────────────────────

/// Returns the library version string (e.g. "1.1.0").
/// The returned string is static — do NOT free it.
const char *zig_docx_version(void);

#ifdef __cplusplus
}
#endif

#endif // ZIG_DOCX_H
