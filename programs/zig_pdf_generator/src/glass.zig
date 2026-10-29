//! Liquid Glass materials, shared by the templates that offer a glass theme
//! (invoice.zig's `theme: glass`, clean_quote.zig's `theme: glass`).
//!
//! Both draw into a page's background layer, which the caller composites
//! beneath the page's own content stream. A panel can therefore be emitted
//! after the text it sits behind (a table container closed once its rows are
//! laid down) and still never cover that text.

const document = @import("document.zig");

/// Linear blend from `a` to `b` by `t` in [0,1] (t=0 → a, t=1 → b).
pub fn mix(a: document.Color, b: document.Color, t: f32) document.Color {
    return .{
        .r = a.r + (b.r - a.r) * t,
        .g = a.g + (b.g - a.g) * t,
        .b = a.b + (b.b - a.b) * t,
    };
}

/// The page "environment": a soft vertical wash from a ~10% tint of `primary`
/// at the top fading to white by the lower third.
pub fn drawWash(
    doc: *document.PdfDocument,
    bg: *document.ContentStream,
    page_width: f32,
    page_height: f32,
    primary: document.Color,
) !void {
    const wash_top = mix(document.Color.white, primary, 0.10);
    const fade_y = page_height * 0.34;
    const sh = doc.getAxialShadingId(wash_top, document.Color.white, 0, page_height, 0, fade_y);
    try bg.saveState();
    try bg.clipRect(0, 0, page_width, page_height);
    try bg.paintShading(sh);
    try bg.restoreState();
}

/// One glass panel: a translucent rounded fill over the wash, a bright
/// top-edge sheen (an axial gradient clipped to the panel), and an optional
/// hairline border.
pub fn drawPanel(
    doc: *document.PdfDocument,
    bg: *document.ContentStream,
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    radius: f32,
    base: document.Color,
    base_alpha: f32,
    sheen_end: document.Color,
    sheen_alpha: f32,
    border: ?document.Color,
    border_w: f32,
) !void {
    // Translucent base fill: the wash shows through.
    try bg.saveState();
    try bg.setExtGState(doc.getOpacityExtGStateId(base_alpha));
    try bg.drawRoundedRectEx(x, y, w, h, radius, base, null, 1.0);
    try bg.restoreState();

    // Top-edge sheen: white at the very top fading to `sheen_end`, clipped to
    // the panel silhouette. The fade runs the full panel height, so there is
    // no seam: the gradient's end is the panel's bottom border.
    if (h > 1.0) {
        const sh = doc.getAxialShadingId(document.Color.white, sheen_end, x, y + h, x, y);
        try bg.saveState();
        try bg.setExtGState(doc.getOpacityExtGStateId(sheen_alpha));
        try bg.clipRoundedRect(x, y, w, h, radius);
        try bg.paintShading(sh);
        try bg.restoreState();
    }

    // Hairline border, opaque and drawn last so the edge stays crisp.
    if (border) |bc| {
        try bg.drawRoundedRectEx(x, y, w, h, radius, null, bc, border_w);
    }
}
