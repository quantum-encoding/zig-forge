const std = @import("std");

/// PDF Content Stream Operators
/// These are the commands that appear in page content streams
pub const Operator = enum {
    // === Text Objects ===
    BeginText, // BT - Begin text object
    EndText, // ET - End text object

    // === Text Positioning ===
    MoveText, // Td - Move text position (tx, ty)
    MoveTextSetLeading, // TD - Move text and set leading
    SetTextMatrix, // Tm - Set text matrix (a, b, c, d, e, f)
    MoveToNextLine, // T* - Move to start of next line

    // === Text State ===
    SetCharSpacing, // Tc - Set character spacing
    SetWordSpacing, // Tw - Set word spacing
    SetHorizScale, // Tz - Set horizontal scaling
    SetTextLeading, // TL - Set text leading
    SetFontSize, // Tf - Set font and size
    SetTextRender, // Tr - Set text rendering mode
    SetTextRise, // Ts - Set text rise

    // === Text Showing ===
    ShowText, // Tj - Show text string
    ShowTextNextLine, // ' - Move to next line and show text
    ShowTextSpacing, // " - Set spacing, move, and show text
    ShowTextArray, // TJ - Show text with positioning

    // === Graphics State ===
    SaveState, // q - Save graphics state
    RestoreState, // Q - Restore graphics state
    ConcatMatrix, // cm - Concatenate matrix

    // === Path Construction ===
    MoveTo, // m - Move to
    LineTo, // l - Line to
    CurveTo, // c - Bezier curve
    CurveToV, // v - Bezier curve (initial point replicated)
    CurveToY, // y - Bezier curve (final point replicated)
    ClosePath, // h - Close subpath
    Rectangle, // re - Append rectangle

    // === Path Painting ===
    Stroke, // S - Stroke path
    CloseStroke, // s - Close and stroke
    Fill, // f - Fill path (nonzero winding)
    FillEvenOdd, // f* - Fill path (even-odd)
    FillStroke, // B - Fill and stroke
    CloseFillStroke, // b - Close, fill, and stroke
    EndPath, // n - End path (no-op)

    // === Clipping ===
    Clip, // W - Set clipping path (nonzero)
    ClipEvenOdd, // W* - Set clipping path (even-odd)

    // === Color ===
    SetStrokeColorSpace, // CS - Set stroke color space
    SetFillColorSpace, // cs - Set fill color space
    SetStrokeColor, // SC - Set stroke color
    SetFillColor, // sc - Set fill color
    SetStrokeColorN, // SCN - Set stroke color (with name)
    SetFillColorN, // scn - Set fill color (with name)
    SetStrokeGray, // G - Set stroke gray
    SetFillGray, // g - Set fill gray
    SetStrokeRGB, // RG - Set stroke RGB
    SetFillRGB, // rg - Set fill RGB
    SetStrokeCMYK, // K - Set stroke CMYK
    SetFillCMYK, // k - Set fill CMYK

    // === XObject ===
    DoXObject, // Do - Paint XObject

    // === Inline Images ===
    BeginInlineImage, // BI - Begin inline image
    InlineImageData, // ID - Begin inline image data
    EndInlineImage, // EI - End inline image

    // === Marked Content ===
    BeginMarkedContent, // BMC - Begin marked content
    BeginMarkedContentProps, // BDC - Begin marked content with properties
    EndMarkedContent, // EMC - End marked content
    MarkPoint, // MP - Mark point
    MarkPointProps, // DP - Mark point with properties

    // === Compatibility ===
    BeginCompat, // BX - Begin compatibility section
    EndCompat, // EX - End compatibility section

    // === Unknown ===
    Unknown,

    /// Parse operator from string
    pub fn fromString(s: []const u8) Operator {
        // Text objects
        if (std.mem.eql(u8, s, "BT")) return .BeginText;
        if (std.mem.eql(u8, s, "ET")) return .EndText;

        // Text positioning
        if (std.mem.eql(u8, s, "Td")) return .MoveText;
        if (std.mem.eql(u8, s, "TD")) return .MoveTextSetLeading;
        if (std.mem.eql(u8, s, "Tm")) return .SetTextMatrix;
        if (std.mem.eql(u8, s, "T*")) return .MoveToNextLine;

        // Text state
        if (std.mem.eql(u8, s, "Tc")) return .SetCharSpacing;
        if (std.mem.eql(u8, s, "Tw")) return .SetWordSpacing;
        if (std.mem.eql(u8, s, "Tz")) return .SetHorizScale;
        if (std.mem.eql(u8, s, "TL")) return .SetTextLeading;
        if (std.mem.eql(u8, s, "Tf")) return .SetFontSize;
        if (std.mem.eql(u8, s, "Tr")) return .SetTextRender;
        if (std.mem.eql(u8, s, "Ts")) return .SetTextRise;

        // Text showing
        if (std.mem.eql(u8, s, "Tj")) return .ShowText;
        if (std.mem.eql(u8, s, "'")) return .ShowTextNextLine;
        if (std.mem.eql(u8, s, "\"")) return .ShowTextSpacing;
        if (std.mem.eql(u8, s, "TJ")) return .ShowTextArray;

        // Graphics state
        if (std.mem.eql(u8, s, "q")) return .SaveState;
        if (std.mem.eql(u8, s, "Q")) return .RestoreState;
        if (std.mem.eql(u8, s, "cm")) return .ConcatMatrix;

        // Path construction
        if (std.mem.eql(u8, s, "m")) return .MoveTo;
        if (std.mem.eql(u8, s, "l")) return .LineTo;
        if (std.mem.eql(u8, s, "c")) return .CurveTo;
        if (std.mem.eql(u8, s, "v")) return .CurveToV;
        if (std.mem.eql(u8, s, "y")) return .CurveToY;
        if (std.mem.eql(u8, s, "h")) return .ClosePath;
        if (std.mem.eql(u8, s, "re")) return .Rectangle;

        // Path painting
        if (std.mem.eql(u8, s, "S")) return .Stroke;
        if (std.mem.eql(u8, s, "s")) return .CloseStroke;
        if (std.mem.eql(u8, s, "f")) return .Fill;
        if (std.mem.eql(u8, s, "F")) return .Fill; // Alternate
        if (std.mem.eql(u8, s, "f*")) return .FillEvenOdd;
        if (std.mem.eql(u8, s, "B")) return .FillStroke;
        if (std.mem.eql(u8, s, "B*")) return .FillStroke; // Even-odd variant
        if (std.mem.eql(u8, s, "b")) return .CloseFillStroke;
        if (std.mem.eql(u8, s, "b*")) return .CloseFillStroke; // Even-odd variant
        if (std.mem.eql(u8, s, "n")) return .EndPath;

        // Clipping
        if (std.mem.eql(u8, s, "W")) return .Clip;
        if (std.mem.eql(u8, s, "W*")) return .ClipEvenOdd;

        // Color
        if (std.mem.eql(u8, s, "CS")) return .SetStrokeColorSpace;
        if (std.mem.eql(u8, s, "cs")) return .SetFillColorSpace;
        if (std.mem.eql(u8, s, "SC")) return .SetStrokeColor;
        if (std.mem.eql(u8, s, "sc")) return .SetFillColor;
        if (std.mem.eql(u8, s, "SCN")) return .SetStrokeColorN;
        if (std.mem.eql(u8, s, "scn")) return .SetFillColorN;
        if (std.mem.eql(u8, s, "G")) return .SetStrokeGray;
        if (std.mem.eql(u8, s, "g")) return .SetFillGray;
        if (std.mem.eql(u8, s, "RG")) return .SetStrokeRGB;
        if (std.mem.eql(u8, s, "rg")) return .SetFillRGB;
        if (std.mem.eql(u8, s, "K")) return .SetStrokeCMYK;
        if (std.mem.eql(u8, s, "k")) return .SetFillCMYK;

        // XObject
        if (std.mem.eql(u8, s, "Do")) return .DoXObject;

        // Inline images
        if (std.mem.eql(u8, s, "BI")) return .BeginInlineImage;
        if (std.mem.eql(u8, s, "ID")) return .InlineImageData;
        if (std.mem.eql(u8, s, "EI")) return .EndInlineImage;

        // Marked content
        if (std.mem.eql(u8, s, "BMC")) return .BeginMarkedContent;
        if (std.mem.eql(u8, s, "BDC")) return .BeginMarkedContentProps;
        if (std.mem.eql(u8, s, "EMC")) return .EndMarkedContent;
        if (std.mem.eql(u8, s, "MP")) return .MarkPoint;
        if (std.mem.eql(u8, s, "DP")) return .MarkPointProps;

        // Compatibility
        if (std.mem.eql(u8, s, "BX")) return .BeginCompat;
        if (std.mem.eql(u8, s, "EX")) return .EndCompat;

        return .Unknown;
    }

    /// Check if this operator consumes text operands
    pub fn isTextShowing(self: Operator) bool {
        return switch (self) {
            .ShowText, .ShowTextNextLine, .ShowTextSpacing, .ShowTextArray => true,
            else => false,
        };
    }

    /// Check if this is a text positioning operator
    pub fn isTextPositioning(self: Operator) bool {
        return switch (self) {
            .MoveText, .MoveTextSetLeading, .SetTextMatrix, .MoveToNextLine => true,
            else => false,
        };
    }

    /// Get expected operand count (0 = variable or none)
    pub fn operandCount(self: Operator) u8 {
        return switch (self) {
            .BeginText, .EndText, .MoveToNextLine, .SaveState, .RestoreState => 0,
            .ClosePath, .Stroke, .CloseStroke, .Fill, .FillEvenOdd => 0,
            .FillStroke, .CloseFillStroke, .EndPath, .Clip, .ClipEvenOdd => 0,
            .EndMarkedContent, .BeginCompat, .EndCompat => 0,

            .ShowText, .ShowTextNextLine, .ShowTextArray => 1,
            .SetCharSpacing, .SetWordSpacing, .SetHorizScale, .SetTextLeading => 1,
            .SetTextRender, .SetTextRise, .SetStrokeGray, .SetFillGray => 1,
            .DoXObject, .BeginMarkedContent, .MarkPoint => 1,

            .MoveText, .MoveTextSetLeading, .Tf, .LineTo, .MoveTo => 2,
            .SetFontSize => 2,

            .SetStrokeRGB, .SetFillRGB, .ShowTextSpacing => 3,

            .SetStrokeCMYK, .SetFillCMYK, .Rectangle => 4,

            .SetTextMatrix, .ConcatMatrix => 6,
            .CurveTo => 6,
            .CurveToV, .CurveToY => 4,

            else => 0, // Variable or unknown
        };
    }
};

// === Tests ===

test "operator parsing" {
    try std.testing.expectEqual(Operator.BeginText, Operator.fromString("BT"));
    try std.testing.expectEqual(Operator.EndText, Operator.fromString("ET"));
    try std.testing.expectEqual(Operator.ShowText, Operator.fromString("Tj"));
    try std.testing.expectEqual(Operator.ShowTextArray, Operator.fromString("TJ"));
    try std.testing.expectEqual(Operator.MoveText, Operator.fromString("Td"));
    try std.testing.expectEqual(Operator.Unknown, Operator.fromString("xyz"));
}

test "operator classification" {
    try std.testing.expect(Operator.ShowText.isTextShowing());
    try std.testing.expect(Operator.ShowTextArray.isTextShowing());
    try std.testing.expect(!Operator.MoveText.isTextShowing());

    try std.testing.expect(Operator.MoveText.isTextPositioning());
    try std.testing.expect(!Operator.ShowText.isTextPositioning());
}
