// zig_pdf_engine - Zero-copy PDF parser, renderer, and editor
//
// Design principles:
// - Memory-mapped file access (no loading entire PDFs into RAM)
// - Lazy object resolution (parse on demand)
// - SIMD-accelerated decompression where possible
// - Pure Zig rendering (no external dependencies)
// - FFI-ready for Android/iOS/Desktop integration

// =============================================================================
// Core PDF Parser
// =============================================================================
pub const lexer = @import("lexer.zig");
pub const xref = @import("xref.zig");
pub const objects = @import("objects.zig");
pub const document = @import("document.zig");
pub const filters = @import("filters.zig");
pub const page = @import("page.zig");
pub const cmap = @import("cmap.zig");

// =============================================================================
// PDF Editor
// =============================================================================
pub const editor = @import("editor.zig");

// Text extraction
pub const text_extract = @import("extract/text.zig");

// =============================================================================
// Rendering Engine
// =============================================================================
pub const render = struct {
    pub const bitmap = @import("render/bitmap.zig");
    pub const graphics_state = @import("render/graphics_state.zig");
    pub const path = @import("render/path.zig");
    pub const rasterizer = @import("render/rasterizer.zig");
    pub const operators = @import("render/operators.zig");
    pub const interpreter = @import("render/interpreter.zig");
    pub const renderer = @import("render/renderer.zig");
    pub const image = @import("render/image.zig");
    pub const ffi = @import("render/ffi.zig");

    // Font subsystem
    pub const font = struct {
        pub const truetype = @import("render/font/truetype.zig");
        pub const glyph = @import("render/font/glyph.zig");
        pub const pdf_fonts = @import("render/font/pdf_fonts.zig");
    };
};

// Alias for convenience
pub const operators = render.operators;

// =============================================================================
// Re-export Main Types - Parser
// =============================================================================
pub const Document = document.Document;
pub const DocumentInfo = document.DocumentInfo;
pub const Object = objects.Object;
pub const ObjectRef = objects.ObjectRef;
pub const XRefTable = xref.XRefTable;
pub const Token = lexer.Token;

// Page types
pub const Page = page.Page;
pub const PageTree = page.PageTree;

// Text extraction
pub const TextExtractor = text_extract.TextExtractor;
pub const Operator = operators.Operator;

// Filter types
pub const FlateDecode = filters.FlateDecode;
pub const Ascii85Decode = filters.Ascii85Decode;
pub const AsciiHexDecode = filters.AsciiHexDecode;

// CMap for font encoding
pub const CMap = cmap.CMap;

// Editor types
pub const Editor = editor.Editor;
pub const Writer = editor.Writer;

// =============================================================================
// Re-export Main Types - Renderer
// =============================================================================
pub const Bitmap = render.bitmap.Bitmap;
pub const Color = render.bitmap.Color;
pub const Matrix = render.graphics_state.Matrix;
pub const GraphicsState = render.graphics_state.GraphicsState;
pub const PathBuilder = render.path.PathBuilder;
pub const Point = render.path.Point;
pub const Rasterizer = render.rasterizer.Rasterizer;
pub const FillRule = render.rasterizer.FillRule;
pub const Interpreter = render.interpreter.Interpreter;
pub const PageRenderer = render.renderer.PageRenderer;
pub const PageSize = render.renderer.PageSize;
pub const RenderQuality = render.renderer.RenderQuality;
pub const DrawingContext = render.renderer.DrawingContext;

// Font types
pub const Font = render.font.truetype.Font;
pub const GlyphRasterizer = render.font.glyph.GlyphRasterizer;
pub const GlyphCache = render.font.glyph.GlyphCache;
pub const TextRenderer = render.font.glyph.TextRenderer;
pub const FontManager = render.font.pdf_fonts.FontManager;
pub const PdfFont = render.font.pdf_fonts.PdfFont;
pub const PdfTextRenderer = render.font.pdf_fonts.PdfTextRenderer;

// Image types
pub const ImageRenderer = render.image.ImageRenderer;
pub const DecodedImage = render.image.DecodedImage;

// =============================================================================
// FFI Exports (for shared library builds)
// Reference all FFI functions to prevent dead code elimination
// =============================================================================
comptime {
    // Volatile references to prevent linker from eliminating exported symbols
    _ = &render.ffi.pdf_renderer_create;
    _ = &render.ffi.pdf_renderer_destroy;
    _ = &render.ffi.pdf_renderer_set_dpi;
    _ = &render.ffi.pdf_renderer_set_quality;
    _ = &render.ffi.pdf_renderer_set_background;
    _ = &render.ffi.pdf_renderer_render_content;
    _ = &render.ffi.pdf_render_result_get_pixels;
    _ = &render.ffi.pdf_render_result_get_width;
    _ = &render.ffi.pdf_render_result_get_height;
    _ = &render.ffi.pdf_render_result_get_stride;
    _ = &render.ffi.pdf_render_result_get_size;
    _ = &render.ffi.pdf_render_result_free;
    _ = &render.ffi.pdf_document_open;
    _ = &render.ffi.pdf_document_close;
    _ = &render.ffi.pdf_document_get_page_count;
    _ = &render.ffi.pdf_document_get_version;
    _ = &render.ffi.pdf_document_get_file_size;
    _ = &render.ffi.pdf_document_is_encrypted;
    _ = &render.ffi.pdf_document_render_page;
    _ = &render.ffi.pdf_bitmap_create;
    _ = &render.ffi.pdf_bitmap_clear;
    _ = &render.ffi.pdf_bitmap_get_pixels_mut;
    _ = &render.ffi.pdf_bitmap_write_ppm;
    _ = &render.ffi.pdf_renderer_version;
    _ = &render.ffi.pdf_calculate_bitmap_size;
}

// Also export as Zig constants for library users
pub const pdf_renderer_create = render.ffi.pdf_renderer_create;
pub const pdf_renderer_destroy = render.ffi.pdf_renderer_destroy;
pub const pdf_renderer_set_dpi = render.ffi.pdf_renderer_set_dpi;
pub const pdf_renderer_set_quality = render.ffi.pdf_renderer_set_quality;
pub const pdf_renderer_render_content = render.ffi.pdf_renderer_render_content;
pub const pdf_render_result_get_pixels = render.ffi.pdf_render_result_get_pixels;
pub const pdf_render_result_get_width = render.ffi.pdf_render_result_get_width;
pub const pdf_render_result_get_height = render.ffi.pdf_render_result_get_height;
pub const pdf_render_result_free = render.ffi.pdf_render_result_free;
pub const pdf_document_open = render.ffi.pdf_document_open;
pub const pdf_document_close = render.ffi.pdf_document_close;
pub const pdf_document_get_page_count = render.ffi.pdf_document_get_page_count;
pub const pdf_bitmap_create = render.ffi.pdf_bitmap_create;
pub const pdf_bitmap_clear = render.ffi.pdf_bitmap_clear;
pub const pdf_renderer_version = render.ffi.pdf_renderer_version;

// =============================================================================
// Tests
// =============================================================================
test {
    const testing = @import("std").testing;
    testing.refAllDecls(@This());
    // Run render module tests
    _ = render.bitmap;
    _ = render.graphics_state;
    _ = render.path;
    _ = render.rasterizer;
    _ = render.renderer;
}
