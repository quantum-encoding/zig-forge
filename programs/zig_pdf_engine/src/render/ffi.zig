// PDF Renderer - C FFI Interface
//
// Clean C API for integration with Android (JNI), iOS, and other platforms.
// All functions are extern "C" with explicit memory management.
//
// Usage pattern:
//   1. pdf_renderer_create() - Create renderer instance
//   2. pdf_renderer_set_dpi() - Configure rendering
//   3. pdf_renderer_render_page() - Render a page
//   4. pdf_render_result_get_pixels() - Get pixel data
//   5. pdf_render_result_free() - Free result
//   6. pdf_renderer_destroy() - Destroy renderer

const std = @import("std");
const renderer_mod = @import("renderer.zig");
const bitmap_mod = @import("bitmap.zig");
const document_mod = @import("../document.zig");
const objects_mod = @import("../objects.zig");
const interpreter_mod = @import("interpreter.zig");
const lexer_mod = @import("../lexer.zig");

const Object = objects_mod.Object;
const ObjectRef = objects_mod.ObjectRef;

const PageRenderer = renderer_mod.PageRenderer;
const Bitmap = bitmap_mod.Bitmap;
const Color = bitmap_mod.Color;
const PageSize = renderer_mod.PageSize;
const RenderQuality = renderer_mod.RenderQuality;
const Document = document_mod.Document;
const ResourceProvider = interpreter_mod.ResourceProvider;
const FontInfo = interpreter_mod.FontInfo;
const XObjectInfo = interpreter_mod.XObjectInfo;
const ColorSpaceInfo = interpreter_mod.ColorSpaceInfo;
const ExtGStateInfo = interpreter_mod.ExtGStateInfo;
const Lexer = lexer_mod.Lexer;

/// Opaque renderer handle for FFI
const RendererHandle = struct {
    renderer: PageRenderer,
    allocator: std.mem.Allocator,
};

/// Opaque render result handle
const RenderResultHandle = struct {
    bitmap: Bitmap,
    allocator: std.mem.Allocator,
};

/// Opaque document handle
const DocumentHandle = struct {
    doc: Document,
    allocator: std.mem.Allocator,
};

// =============================================================================
// Page Resource Provider
// =============================================================================

/// Provides page resources (fonts, XObjects, etc.) to the interpreter
const PageResourceProvider = struct {
    doc: *Document,
    allocator: std.mem.Allocator,
    fonts: std.StringHashMap(FontInfo),
    xobjects: std.StringHashMap(XObjectInfo),
    resources_dict: ?[]const u8,

    const vtable = ResourceProvider.VTable{
        .getXObject = getXObject,
        .getFont = getFont,
        .getColorSpace = getColorSpace,
        .getExtGState = getExtGState,
    };

    fn init(allocator: std.mem.Allocator, doc: *Document, page_index: u32) PageResourceProvider {
        var provider = PageResourceProvider{
            .doc = doc,
            .allocator = allocator,
            .fonts = std.StringHashMap(FontInfo).init(allocator),
            .xobjects = std.StringHashMap(XObjectInfo).init(allocator),
            .resources_dict = null,
        };

        // Parse page resources
        provider.parsePageResources(page_index) catch {};

        return provider;
    }

    fn deinit(self: *PageResourceProvider) void {
        self.fonts.deinit();
        self.xobjects.deinit();
    }

    fn asResourceProvider(self: *PageResourceProvider) ResourceProvider {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    fn parsePageResources(self: *PageResourceProvider, page_index: u32) !void {
        // Get page dictionary
        const page_dict = self.doc.getPageDict(page_index) catch return;

        // Parse /Resources dictionary
        var parser = DictParser.init(page_dict);
        const resources_value = parser.get("Resources") orelse return;

        const resources_dict = switch (resources_value) {
            .reference => |ref| blk: {
                const resolved = self.doc.resolveRef(ref) catch return;
                break :blk switch (resolved) {
                    .dict => |d| d,
                    else => return,
                };
            },
            .dict => |d| d,
            else => return,
        };

        self.resources_dict = resources_dict;

        // Parse /Font subdictionary
        self.parseFonts(resources_dict);

        // Parse /XObject subdictionary
        self.parseXObjects(resources_dict);
    }

    fn parseFonts(self: *PageResourceProvider, resources_dict: []const u8) void {
        var res_parser = DictParser.init(resources_dict);
        const font_value = res_parser.get("Font") orelse return;

        const font_dict = switch (font_value) {
            .reference => |ref| blk: {
                const resolved = self.doc.resolveRef(ref) catch return;
                break :blk switch (resolved) {
                    .dict => |d| d,
                    else => return,
                };
            },
            .dict => |d| d,
            else => return,
        };

        // Parse each font entry
        var lex = Lexer.init(font_dict);
        while (lex.next()) |token| {
            if (token.tag == .name) {
                const font_name = token.nameValue();

                // Get font object
                const next = lex.next() orelse break;
                const font_obj = switch (next.tag) {
                    .number => blk: {
                        // Reference: num gen R
                        const gen = lex.next() orelse break;
                        _ = lex.next(); // R keyword
                        if (gen.tag != .number) continue;

                        const ref = ObjectRef{
                            .obj_num = @intCast(next.asInt() orelse continue),
                            .gen_num = @intCast(gen.asInt() orelse continue),
                        };
                        break :blk self.doc.resolveRef(ref) catch continue;
                    },
                    .dict_start => Object.parse(&lex) catch continue,
                    else => continue,
                };

                // Extract font info
                switch (font_obj) {
                    .dict => |fd| {
                        const info = self.parseFontInfo(fd);
                        self.fonts.put(font_name, info) catch {};
                    },
                    else => {},
                }
            }
        }
    }

    fn parseXObjects(self: *PageResourceProvider, resources_dict: []const u8) void {
        var res_parser = DictParser.init(resources_dict);
        const xobj_value = res_parser.get("XObject") orelse return;

        const xobj_dict = switch (xobj_value) {
            .reference => |ref| blk: {
                const resolved = self.doc.resolveRef(ref) catch return;
                break :blk switch (resolved) {
                    .dict => |d| d,
                    else => return,
                };
            },
            .dict => |d| d,
            else => return,
        };

        // Parse each XObject entry
        var lex = Lexer.init(xobj_dict);
        while (lex.next()) |token| {
            if (token.tag == .name) {
                const xobj_name = token.nameValue();

                // Get XObject reference
                const next = lex.next() orelse break;
                if (next.tag != .number) continue;

                const gen = lex.next() orelse break;
                if (gen.tag != .number) continue;
                _ = lex.next(); // R keyword

                const ref = ObjectRef{
                    .obj_num = @intCast(next.asInt() orelse continue),
                    .gen_num = @intCast(gen.asInt() orelse continue),
                };

                // Get the XObject stream
                if (self.parseXObjectInfo(ref)) |info| {
                    self.xobjects.put(xobj_name, info) catch {};
                }
            }
        }
    }

    fn parseXObjectInfo(self: *PageResourceProvider, ref: ObjectRef) ?XObjectInfo {
        const obj = self.doc.resolveRef(ref) catch return null;

        switch (obj) {
            .stream => |s| {
                var dict_parser = DictParser.init(s.dict);

                // Get /Subtype
                const subtype_val = dict_parser.get("Subtype") orelse return null;
                const subtype_name = switch (subtype_val) {
                    .name => |n| n,
                    else => return null,
                };

                var info = XObjectInfo{
                    .subtype = .Image,
                    .data = s.data,
                    .dict = s.dict,
                };

                if (std.mem.eql(u8, subtype_name, "Image")) {
                    info.subtype = .Image;

                    // Get Width/Height for images
                    if (dict_parser.get("Width")) |w| {
                        if (w == .integer) info.width = @intCast(w.integer);
                    }
                    if (dict_parser.get("Height")) |h| {
                        if (h == .integer) info.height = @intCast(h.integer);
                    }
                } else if (std.mem.eql(u8, subtype_name, "Form")) {
                    info.subtype = .Form;

                    // Parse Matrix if present
                    if (dict_parser.get("Matrix")) |m| {
                        if (m == .array) {
                            info.matrix = self.parseMatrixArray(m.array);
                        }
                    }

                    // Parse BBox if present
                    if (dict_parser.get("BBox")) |b| {
                        if (b == .array) {
                            info.bbox = self.parseBBoxArray(b.array);
                        }
                    }
                } else if (std.mem.eql(u8, subtype_name, "PS")) {
                    info.subtype = .PS;
                }

                return info;
            },
            else => return null,
        }
    }

    fn parseMatrixArray(self: *PageResourceProvider, array_data: []const u8) ?[6]f32 {
        _ = self;
        var result: [6]f32 = .{ 1, 0, 0, 1, 0, 0 };
        var lex = Lexer.init(array_data);
        var i: usize = 0;

        while (lex.next()) |token| {
            if (i >= 6) break;
            if (token.tag == .number) {
                result[i] = @floatCast(token.asFloat() orelse 0);
                i += 1;
            }
        }

        return if (i >= 6) result else null;
    }

    fn parseBBoxArray(self: *PageResourceProvider, array_data: []const u8) ?[4]f32 {
        _ = self;
        var result: [4]f32 = .{ 0, 0, 0, 0 };
        var lex = Lexer.init(array_data);
        var i: usize = 0;

        while (lex.next()) |token| {
            if (i >= 4) break;
            if (token.tag == .number) {
                result[i] = @floatCast(token.asFloat() orelse 0);
                i += 1;
            }
        }

        return if (i >= 4) result else null;
    }

    fn parseFontInfo(self: *PageResourceProvider, font_dict: []const u8) FontInfo {
        _ = self;
        var parser = DictParser.init(font_dict);

        var info = FontInfo{
            .subtype = "Type1",
            .base_font = null,
            .encoding = null,
            .widths = null,
            .first_char = 0,
            .font_data = null,
        };

        // Get /Subtype
        if (parser.get("Subtype")) |v| {
            if (v == .name) {
                info.subtype = v.name;
            }
        }

        // Get /BaseFont
        if (parser.get("BaseFont")) |v| {
            if (v == .name) {
                info.base_font = v.name;
            }
        }

        // Get /Encoding
        if (parser.get("Encoding")) |v| {
            if (v == .name) {
                info.encoding = v.name;
            }
        }

        // Get /FirstChar
        if (parser.get("FirstChar")) |v| {
            if (v == .integer) {
                info.first_char = @intCast(v.integer);
            }
        }

        return info;
    }

    // ResourceProvider interface implementation
    fn getXObject(ctx: *anyopaque, name: []const u8) ?XObjectInfo {
        const self: *PageResourceProvider = @ptrCast(@alignCast(ctx));
        return self.xobjects.get(name);
    }

    fn getFont(ctx: *anyopaque, name: []const u8) ?FontInfo {
        const self: *PageResourceProvider = @ptrCast(@alignCast(ctx));
        return self.fonts.get(name);
    }

    fn getColorSpace(ctx: *anyopaque, name: []const u8) ?ColorSpaceInfo {
        _ = ctx;
        _ = name;
        return null;
    }

    fn getExtGState(ctx: *anyopaque, name: []const u8) ?ExtGStateInfo {
        _ = ctx;
        _ = name;
        return null;
    }
};

/// Simple dictionary parser for resources
const DictParser = struct {
    data: []const u8,

    fn init(data: []const u8) DictParser {
        return .{ .data = data };
    }

    fn get(self: *DictParser, key: []const u8) ?Object {
        var lex = Lexer.init(self.data);

        while (lex.next()) |token| {
            if (token.tag == .name and std.mem.eql(u8, token.nameValue(), key)) {
                // Next token is the value
                return Object.parse(&lex) catch null;
            }
        }
        return null;
    }
};

// =============================================================================
// Renderer API
// =============================================================================

/// Create a new PDF renderer
/// Returns NULL on failure
pub export fn pdf_renderer_create() ?*RendererHandle {
    const allocator = std.heap.c_allocator;

    const handle = allocator.create(RendererHandle) catch return null;
    handle.* = .{
        .renderer = PageRenderer.init(allocator),
        .allocator = allocator,
    };

    return handle;
}

/// Destroy a PDF renderer
pub export fn pdf_renderer_destroy(handle: ?*RendererHandle) void {
    const h = handle orelse return;
    h.renderer.deinit();
    h.allocator.destroy(h);
}

/// Set render DPI (default: 150)
pub export fn pdf_renderer_set_dpi(handle: ?*RendererHandle, dpi: f32) void {
    const h = handle orelse return;
    h.renderer.setDPI(dpi);
}

/// Set render quality (0=Draft, 1=Normal, 2=High)
pub export fn pdf_renderer_set_quality(handle: ?*RendererHandle, quality: u32) void {
    const h = handle orelse return;
    const q: RenderQuality = switch (quality) {
        0 => .Draft,
        2 => .High,
        else => .Normal,
    };
    h.renderer.setQuality(q);
}

/// Set background color (RGBA)
pub export fn pdf_renderer_set_background(handle: ?*RendererHandle, r: u8, g: u8, b: u8, a: u8) void {
    const h = handle orelse return;
    h.renderer.setBackground(Color.rgba(r, g, b, a));
}

/// Render PDF content stream to pixels
/// content: PDF content stream data
/// content_len: Length of content
/// page_width: Page width in points (72 points = 1 inch)
/// page_height: Page height in points
/// Returns render result handle or NULL on failure
pub export fn pdf_renderer_render_content(
    handle: ?*RendererHandle,
    content: [*]const u8,
    content_len: usize,
    page_width: f32,
    page_height: f32,
) ?*RenderResultHandle {
    const h = handle orelse return null;
    const allocator = h.allocator;

    const content_slice = content[0..content_len];
    const page_size = PageSize{ .width = page_width, .height = page_height };

    var result = h.renderer.render(content_slice, page_size) catch return null;

    const result_handle = allocator.create(RenderResultHandle) catch {
        result.deinit();
        return null;
    };

    result_handle.* = .{
        .bitmap = result.bitmap,
        .allocator = allocator,
    };

    return result_handle;
}

// =============================================================================
// Render Result API
// =============================================================================

/// Get pixel data pointer (RGBA8888 format)
/// Returns pointer to pixel data or NULL
pub export fn pdf_render_result_get_pixels(handle: ?*RenderResultHandle) ?[*]const u8 {
    const h = handle orelse return null;
    return h.bitmap.getRawBytes().ptr;
}

/// Get render result width in pixels
pub export fn pdf_render_result_get_width(handle: ?*RenderResultHandle) u32 {
    const h = handle orelse return 0;
    return h.bitmap.width;
}

/// Get render result height in pixels
pub export fn pdf_render_result_get_height(handle: ?*RenderResultHandle) u32 {
    const h = handle orelse return 0;
    return h.bitmap.height;
}

/// Get render result stride (bytes per row)
pub export fn pdf_render_result_get_stride(handle: ?*RenderResultHandle) u32 {
    const h = handle orelse return 0;
    return h.bitmap.stride;
}

/// Get total pixel buffer size in bytes
pub export fn pdf_render_result_get_size(handle: ?*RenderResultHandle) usize {
    const h = handle orelse return 0;
    return h.bitmap.pixels.len * 4;
}

/// Free render result
pub export fn pdf_render_result_free(handle: ?*RenderResultHandle) void {
    const h = handle orelse return;
    h.bitmap.deinit();
    h.allocator.destroy(h);
}

// =============================================================================
// Document API
// =============================================================================

/// Open a PDF document from file path
/// Returns document handle or NULL on failure
pub export fn pdf_document_open(path: [*:0]const u8) ?*DocumentHandle {
    const allocator = std.heap.c_allocator;

    var doc = Document.open(allocator, std.mem.span(path)) catch return null;

    const handle = allocator.create(DocumentHandle) catch {
        doc.close();
        return null;
    };

    handle.* = .{
        .doc = doc,
        .allocator = allocator,
    };

    return handle;
}

/// Close a PDF document
pub export fn pdf_document_close(handle: ?*DocumentHandle) void {
    const h = handle orelse return;
    h.doc.close();
    h.allocator.destroy(h);
}

/// Get number of pages in document
pub export fn pdf_document_get_page_count(handle: ?*DocumentHandle) u32 {
    const h = handle orelse return 0;
    return h.doc.getPageCount() catch 0;
}

/// Get PDF version string
/// Returns pointer to static string
pub export fn pdf_document_get_version(handle: ?*DocumentHandle) [*:0]const u8 {
    const h = handle orelse return "unknown";
    // Version is stored in the document data, which is memory-mapped
    const version = h.doc.getVersion();
    // Return as null-terminated (assuming it's short and in valid memory)
    if (version.len > 0 and version.len < 16) {
        return @ptrCast(version.ptr);
    }
    return "1.0";
}

/// Get document file size in bytes
pub export fn pdf_document_get_file_size(handle: ?*DocumentHandle) usize {
    const h = handle orelse return 0;
    return h.doc.getFileSize();
}

/// Check if document is encrypted
pub export fn pdf_document_is_encrypted(handle: ?*DocumentHandle) bool {
    const h = handle orelse return false;
    return h.doc.isEncrypted();
}

// =============================================================================
// Page Rendering from Document
// =============================================================================

/// Render a specific page from a document
/// page_index: 0-based page index
/// Returns render result handle or NULL on failure
pub export fn pdf_document_render_page(
    doc_handle: ?*DocumentHandle,
    renderer_handle: ?*RendererHandle,
    page_index: u32,
) ?*RenderResultHandle {
    var doc = &(doc_handle orelse return null).doc;
    var renderer = &(renderer_handle orelse return null).renderer;
    const allocator = (doc_handle orelse return null).allocator;

    // Get raw page content stream (PDF operators)
    const content_stream = doc.getPageContent(page_index) catch return null;
    defer allocator.free(content_stream);

    // Get actual page dimensions from MediaBox
    const page_size = if (doc.getPageDimensions(page_index)) |dims|
        PageSize{ .width = dims.width, .height = dims.height }
    else |_|
        PageSize.letter; // Default to US Letter on error

    // Create resource provider for this page
    var res_provider = PageResourceProvider.init(allocator, doc, page_index);
    defer res_provider.deinit();

    // Render with resources
    var result = renderer.renderWithResources(
        content_stream,
        page_size,
        res_provider.asResourceProvider(),
    ) catch return null;

    const result_handle = allocator.create(RenderResultHandle) catch {
        result.deinit();
        return null;
    };

    result_handle.* = .{
        .bitmap = result.bitmap,
        .allocator = allocator,
    };

    return result_handle;
}

// =============================================================================
// Bitmap Creation API (for direct pixel manipulation)
// =============================================================================

/// Create a new empty bitmap
pub export fn pdf_bitmap_create(width: u32, height: u32) ?*RenderResultHandle {
    const allocator = std.heap.c_allocator;

    var bitmap = Bitmap.init(allocator, width, height) catch return null;

    const handle = allocator.create(RenderResultHandle) catch {
        bitmap.deinit();
        return null;
    };

    handle.* = .{
        .bitmap = bitmap,
        .allocator = allocator,
    };

    return handle;
}

/// Clear bitmap to a color
pub export fn pdf_bitmap_clear(handle: ?*RenderResultHandle, r: u8, g: u8, b: u8, a: u8) void {
    const h = handle orelse return;
    h.bitmap.clear(Color.rgba(r, g, b, a));
}

/// Get mutable pixel data pointer
pub export fn pdf_bitmap_get_pixels_mut(handle: ?*RenderResultHandle) ?[*]u8 {
    const h = handle orelse return null;
    return h.bitmap.getRawBytesMut().ptr;
}

/// Write bitmap to PPM file (for debugging)
pub export fn pdf_bitmap_write_ppm(handle: ?*RenderResultHandle, path: [*:0]const u8) bool {
    const h = handle orelse return false;
    h.bitmap.writePPM(std.mem.span(path)) catch return false;
    return true;
}

// =============================================================================
// Utility Functions
// =============================================================================

/// Get library version string
pub export fn pdf_renderer_version() [*:0]const u8 {
    return "1.0.0";
}

/// Calculate required bitmap size for a page at given DPI
pub export fn pdf_calculate_bitmap_size(
    page_width: f32,
    page_height: f32,
    dpi: f32,
    out_width: *u32,
    out_height: *u32,
) void {
    const size = (PageSize{ .width = page_width, .height = page_height }).toPixels(dpi);
    out_width.* = size.width;
    out_height.* = size.height;
}

// =============================================================================
// Tests
// =============================================================================

test "ffi renderer create/destroy" {
    const handle = pdf_renderer_create();
    try std.testing.expect(handle != null);
    pdf_renderer_destroy(handle);
}

test "ffi bitmap create/destroy" {
    const handle = pdf_bitmap_create(100, 100);
    try std.testing.expect(handle != null);

    const width = pdf_render_result_get_width(handle);
    try std.testing.expectEqual(@as(u32, 100), width);

    pdf_render_result_free(handle);
}
