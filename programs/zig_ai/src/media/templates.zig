// Prompt templates for media generation presets
// Wraps user input with expert-crafted prompt engineering for specific use cases
// Ported from harvester_sdk-2.1.2 template system (45+ templates, 11 categories)

const std = @import("std");
const Allocator = std.mem.Allocator;

// ============================================================================
// Generic Template System (prefix + user prompt + suffix)
// ============================================================================

pub const Template = struct {
    name: []const u8,
    prefix: []const u8,
    suffix: []const u8,
    description: []const u8,
    category: Category,
};

pub const Category = enum {
    photography,
    digital_art,
    themed,
    business,
    construction,
    food,
    artistic,

    pub fn getName(self: Category) []const u8 {
        return switch (self) {
            .photography => "Photography",
            .digital_art => "Digital Art",
            .themed => "Themed",
            .business => "Business",
            .construction => "Construction",
            .food => "Food & Restaurant",
            .artistic => "Artistic",
        };
    }
};

/// Build a prompt by wrapping user input with template prefix and suffix
pub fn buildTemplatedPrompt(allocator: Allocator, template: Template, user_input: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s} {s}. {s}", .{
        template.prefix,
        user_input,
        template.suffix,
    });
}

/// Look up a template by name (case-insensitive match against the key)
pub fn findTemplate(name: []const u8) ?Template {
    for (&all_templates) |t| {
        if (std.mem.eql(u8, t.name, name)) return t;
    }
    return null;
}

/// All available templates
pub const all_templates = [_]Template{
    // -- Photography --
    .{
        .name = "photo",
        .prefix = "HYPER-REALISTIC PHOTOGRAPH:",
        .suffix = "Ultra-detailed, photographic quality, 8K resolution, professional photography, realistic lighting, sharp focus, high dynamic range, natural textures",
        .description = "Hyper-realistic photo",
        .category = .photography,
    },
    .{
        .name = "portrait",
        .prefix = "PROFESSIONAL PORTRAIT PHOTOGRAPHY:",
        .suffix = "Studio lighting, shallow depth of field, 85mm lens, professional headshot, crisp details, natural skin tones, professional photography",
        .description = "Studio portrait",
        .category = .photography,
    },
    .{
        .name = "landscape",
        .prefix = "LANDSCAPE PHOTOGRAPHY:",
        .suffix = "Wide-angle lens, golden hour lighting, dramatic sky, high resolution, nature photography, National Geographic style",
        .description = "Landscape photo",
        .category = .photography,
    },
    .{
        .name = "macro",
        .prefix = "MACRO PHOTOGRAPHY:",
        .suffix = "Extreme close-up, shallow depth of field, intricate details, professional macro lens, studio lighting, scientific photography quality",
        .description = "Macro close-up",
        .category = .photography,
    },
    .{
        .name = "product",
        .prefix = "PRODUCT PHOTOGRAPHY:",
        .suffix = "Clean white background, professional lighting, commercial quality, high-end product shot, e-commerce ready",
        .description = "Product shot",
        .category = .photography,
    },
    .{
        .name = "food",
        .prefix = "PROFESSIONAL FOOD PHOTOGRAPHY:",
        .suffix = "Appetizing presentation, natural lighting, food styling, commercial quality, mouth-watering, culinary artistry",
        .description = "Food photography",
        .category = .food,
    },
    .{
        .name = "architecture",
        .prefix = "ARCHITECTURAL PHOTOGRAPHY:",
        .suffix = "Professional building photography, geometric composition, structural details, clean lines, architectural digest quality",
        .description = "Architecture photo",
        .category = .photography,
    },
    .{
        .name = "fashion",
        .prefix = "FASHION PHOTOGRAPHY:",
        .suffix = "High-fashion editorial, professional styling, magazine quality, artistic composition, designer aesthetic",
        .description = "Fashion editorial",
        .category = .photography,
    },
    // -- Digital Art --
    .{
        .name = "anime",
        .prefix = "ANIME STYLE DIGITAL ART:",
        .suffix = "High-quality anime style, vibrant colors, detailed illustration, manga aesthetic",
        .description = "Anime/manga style",
        .category = .digital_art,
    },
    .{
        .name = "comic",
        .prefix = "COMIC BOOK ILLUSTRATION:",
        .suffix = "Comic book style, bold colors, dynamic composition, graphic novel aesthetic",
        .description = "Comic book style",
        .category = .digital_art,
    },
    .{
        .name = "watercolor",
        .prefix = "WATERCOLOR PAINTING:",
        .suffix = "Traditional watercolor technique, soft edges, transparent layers, artistic brushwork",
        .description = "Watercolor painting",
        .category = .digital_art,
    },
    .{
        .name = "digital-art",
        .prefix = "DIGITAL ART MASTERPIECE:",
        .suffix = "High-quality digital painting, professional artwork, detailed illustration, concept art quality",
        .description = "Digital artwork",
        .category = .digital_art,
    },
    // -- Cinematic --
    .{
        .name = "cinematic",
        .prefix = "CINEMATIC SHOT:",
        .suffix = "Movie still, dramatic lighting, film grain, anamorphic lens, Hollywood production quality, cinematic composition",
        .description = "Hollywood cinematic",
        .category = .themed,
    },
    .{
        .name = "noir",
        .prefix = "FILM NOIR STYLE:",
        .suffix = "Black and white, high contrast, dramatic shadows, vintage 1940s aesthetic, moody lighting, classic cinematography",
        .description = "Film noir B&W",
        .category = .themed,
    },
    // -- Themed --
    .{
        .name = "cyberpunk",
        .prefix = "CYBERPUNK AESTHETIC:",
        .suffix = "Neon lighting, futuristic cityscape, dark atmosphere, high-tech low-life, digital art style",
        .description = "Cyberpunk neon",
        .category = .themed,
    },
    .{
        .name = "steampunk",
        .prefix = "STEAMPUNK DESIGN:",
        .suffix = "Victorian-era technology, brass and copper, steam-powered machinery, retro-futuristic",
        .description = "Steampunk retro-tech",
        .category = .themed,
    },
    .{
        .name = "fantasy",
        .prefix = "EPIC FANTASY REALM:",
        .suffix = "Majestic castles, magical auras, crystalline structures, ethereal lighting, fantasy masterpiece",
        .description = "Epic fantasy",
        .category = .themed,
    },
    .{
        .name = "surreal",
        .prefix = "SURREAL DREAMSCAPE:",
        .suffix = "Impossible geometries, floating objects, dream logic, subconscious imagery, psychedelic reality",
        .description = "Surrealist dream",
        .category = .themed,
    },
    .{
        .name = "retro80s",
        .prefix = "1980S RETRO AESTHETIC:",
        .suffix = "Neon grids, synthwave colors, VHS static, chrome text, palm trees, sunset gradients, Miami Vice style, nostalgic 80s vibes",
        .description = "80s synthwave",
        .category = .themed,
    },
    .{
        .name = "solarpunk",
        .prefix = "SOLARPUNK CIVILIZATION:",
        .suffix = "Green buildings, solar panels, vertical gardens, wind turbines, eco-friendly technology, sustainable future, hopeful tomorrow",
        .description = "Solarpunk utopia",
        .category = .themed,
    },
    .{
        .name = "sci-fi",
        .prefix = "SCIENCE FICTION ART:",
        .suffix = "Futuristic technology, space exploration, alien worlds, concept art quality, sci-fi illustration",
        .description = "Sci-fi concept art",
        .category = .themed,
    },
    .{
        .name = "consciousness",
        .prefix = "CONSCIOUSNESS TRANSCENDENCE ART:",
        .suffix = "Sacred geometry, golden ratio, divine mathematics, spiritual awakening, transcendent digital art, cosmic awareness",
        .description = "Sacred geometry art",
        .category = .themed,
    },
    .{
        .name = "cosmic-duck",
        .prefix = "COSMIC DUCK WISDOM:",
        .suffix = "Rubber duck with top hat and monocle, sacred geometry patterns, quantum debugging wisdom, mystical digital art with purples and golds",
        .description = "Cosmic duck debugging wisdom",
        .category = .themed,
    },
    // -- Business --
    .{
        .name = "corporate",
        .prefix = "CORPORATE BUSINESS IMAGERY:",
        .suffix = "Professional environment, modern office, business atmosphere, clean composition, corporate aesthetic",
        .description = "Corporate business",
        .category = .business,
    },
    .{
        .name = "marketing",
        .prefix = "MARKETING VISUAL:",
        .suffix = "Eye-catching, commercial appeal, brand-friendly, marketing photography, engaging composition",
        .description = "Marketing visual",
        .category = .business,
    },
    .{
        .name = "social",
        .prefix = "SOCIAL MEDIA CONTENT:",
        .suffix = "Social media optimized, engaging visual, shareable content, vibrant and appealing",
        .description = "Social media post",
        .category = .business,
    },
    // -- Construction (CRG Direct) --
    .{
        .name = "painting",
        .prefix = "INTERIOR HOUSE PAINTING:",
        .suffix = "Professional interior painting, smooth finish, clean lines, proper coverage, residential quality, well-lit interior space",
        .description = "Interior painting",
        .category = .construction,
    },
    .{
        .name = "kitchen",
        .prefix = "KITCHEN RENOVATION PROJECT:",
        .suffix = "Modern kitchen remodel, updated appliances, new cabinetry, countertops, contemporary design, functional layout",
        .description = "Kitchen renovation",
        .category = .construction,
    },
    .{
        .name = "bathroom",
        .prefix = "BATHROOM RENOVATION:",
        .suffix = "Modern bathroom remodel, updated fixtures, new tiling, contemporary design, spa-like atmosphere, quality finishes",
        .description = "Bathroom renovation",
        .category = .construction,
    },
    .{
        .name = "flooring",
        .prefix = "HARDWOOD FLOOR INSTALLATION:",
        .suffix = "Professional hardwood flooring, quality installation, natural wood finish, residential improvement, elegant flooring",
        .description = "Flooring install",
        .category = .construction,
    },
    .{
        .name = "roofing",
        .prefix = "ROOF INSTALLATION PROJECT:",
        .suffix = "Professional roofing, shingle installation, weather protection, residential roofing, quality craftsmanship",
        .description = "Roof installation",
        .category = .construction,
    },
    .{
        .name = "terrace",
        .prefix = "OUTDOOR TERRACE CONSTRUCTION:",
        .suffix = "Wooden deck terrace, outdoor living space, quality construction, natural materials, landscape integration",
        .description = "Outdoor terrace",
        .category = .construction,
    },
    // -- Artistic --
    .{
        .name = "abstract",
        .prefix = "ABSTRACT ART:",
        .suffix = "Non-representational forms, bold colors and shapes, artistic expression, modern art",
        .description = "Abstract art",
        .category = .artistic,
    },
    .{
        .name = "minimalist",
        .prefix = "MINIMALIST DESIGN:",
        .suffix = "Clean composition, simple elegance, negative space, minimal elements, refined aesthetic",
        .description = "Minimalist design",
        .category = .artistic,
    },
    // -- Additional (from GPT-Image prompting guide) --
    .{
        .name = "infographic",
        .prefix = "DETAILED INFOGRAPHIC:",
        .suffix = "Structured information layout, clear typography, labeled sections, visual hierarchy, high-quality data visualization",
        .description = "Infographic layout",
        .category = .business,
    },
    .{
        .name = "ui-mockup",
        .prefix = "REALISTIC MOBILE APP UI MOCKUP:",
        .suffix = "Practical interface, clear typography, white background, subtle accent colors, iPhone frame, well-designed app",
        .description = "Mobile UI mockup",
        .category = .digital_art,
    },
    .{
        .name = "comic-strip",
        .prefix = "COMIC-STYLE VERTICAL REEL:",
        .suffix = "Equal-sized panels, sequential storytelling, clear visual beats, action-focused composition, readable pacing",
        .description = "Comic strip panels",
        .category = .digital_art,
    },
    .{
        .name = "holiday-card",
        .prefix = "PREMIUM HOLIDAY CARD:",
        .suffix = "Warm nostalgic mood, soft cinematic lighting, realistic textures, tasteful bokeh, high print quality, no trademarks",
        .description = "Holiday card design",
        .category = .themed,
    },
    .{
        .name = "collectible",
        .prefix = "COLLECTIBLE TOY IN BLISTER PACKAGING:",
        .suffix = "Premium toy photography, realistic plastic textures, studio lighting, sharp label printing, high-end retail presentation",
        .description = "Collectible toy box",
        .category = .themed,
    },
};

// ============================================================================
// Edit Templates (for image editing with input images)
// ============================================================================

pub const EditTemplate = struct {
    name: []const u8,
    prefix: []const u8,
    suffix: []const u8,
    description: []const u8,
};

/// Build an edit prompt by wrapping user input with edit template prefix and suffix
pub fn buildEditPrompt(allocator: Allocator, template: EditTemplate, user_input: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s} {s}. {s}", .{
        template.prefix,
        user_input,
        template.suffix,
    });
}

/// Look up an edit template by name
pub fn findEditTemplate(name: []const u8) ?EditTemplate {
    for (&edit_templates) |t| {
        if (std.mem.eql(u8, t.name, name)) return t;
    }
    return null;
}

pub const edit_templates = [_]EditTemplate{
    .{
        .name = "style-transfer",
        .prefix = "Use the same style from the input image and generate",
        .suffix = "on a white background",
        .description = "Apply source image style to new content",
    },
    .{
        .name = "try-on",
        .prefix = "Edit to dress the person using the provided clothing. Do not change face, body, pose, or identity.",
        .suffix = "Fit garments naturally with realistic fabric. Match lighting and shadows.",
        .description = "Virtual try-on (person + clothing)",
    },
    .{
        .name = "sketch-render",
        .prefix = "Turn this drawing into a photorealistic image. Preserve layout, proportions, perspective.",
        .suffix = "Realistic materials and lighting. Do not add new elements or text.",
        .description = "Sketch/drawing to photo",
    },
    .{
        .name = "bg-remove",
        .prefix = "Extract the product from the input image. Transparent background (RGBA PNG), crisp silhouette, no halos.",
        .suffix = "Preserve geometry and label legibility. Only remove background and lightly polish.",
        .description = "Remove background from product",
    },
    .{
        .name = "weather-change",
        .prefix = "Transform the lighting and weather conditions:",
        .suffix = "Preserve identity, geometry, camera angle, and object placement.",
        .description = "Change weather/lighting conditions",
    },
    .{
        .name = "object-remove",
        .prefix = "Remove the specified element from the image. Do not change anything else.",
        .suffix = "Preserve all surrounding context, lighting, and composition.",
        .description = "Remove object from image",
    },
};

// ============================================================================
// Logo Generation Template
// ============================================================================

pub const LogoOptions = struct {
    /// Brand description: "Field & Flour, a local bakery"
    description: []const u8,
    /// Personality/feel: "warm, simple, and timeless"
    feel: []const u8 = "clean, professional, and memorable",
    /// Background: "plain white", "transparent", "plain black"
    background: []const u8 = "plain white",
    /// Optional extra instructions
    extra: []const u8 = "",
};

/// Build an optimized logo generation prompt from user description.
/// Based on OpenAI's recommended logo prompt structure:
/// - Clear brand constraints and simplicity
/// - Clean vector-like shapes, strong silhouette, balanced negative space
/// - Scalability across sizes
/// - Flat design, no gradients unless essential
pub fn buildLogoPrompt(allocator: Allocator, opts: LogoOptions) ![]u8 {
    // Core template follows OpenAI's recommended structure for gpt-image-1/1.5
    if (opts.extra.len > 0) {
        return std.fmt.allocPrint(allocator,
            "Create an original, non-infringing logo for {s}. " ++
                "The logo should feel {s}. " ++
                "Use clean, vector-like shapes, a strong silhouette, and balanced negative space. " ++
                "Favor simplicity over detail so it reads clearly at small and large sizes. " ++
                "Flat design, minimal strokes, no gradients unless essential. " ++
                "{s} background. " ++
                "{s} " ++
                "Deliver a single centered logo with generous padding. No watermark.", .{
                opts.description,
                opts.feel,
                opts.background,
                opts.extra,
            });
    }

    return std.fmt.allocPrint(allocator,
        "Create an original, non-infringing logo for {s}. " ++
            "The logo should feel {s}. " ++
            "Use clean, vector-like shapes, a strong silhouette, and balanced negative space. " ++
            "Favor simplicity over detail so it reads clearly at small and large sizes. " ++
            "Flat design, minimal strokes, no gradients unless essential. " ++
            "{s} background. " ++
            "Deliver a single centered logo with generous padding. No watermark.", .{
            opts.description,
            opts.feel,
            opts.background,
        });
}

// ============================================================================
// Tests
// ============================================================================

test "buildLogoPrompt basic" {
    const allocator = std.testing.allocator;
    const prompt = try buildLogoPrompt(allocator, .{
        .description = "Field & Flour, a local bakery",
        .feel = "warm, simple, and timeless",
    });
    defer allocator.free(prompt);

    try std.testing.expect(std.mem.indexOf(u8, prompt, "Field & Flour") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "warm, simple, and timeless") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "vector-like shapes") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "No watermark") != null);
}

test "buildLogoPrompt with extra" {
    const allocator = std.testing.allocator;
    const prompt = try buildLogoPrompt(allocator, .{
        .description = "TechCorp, a cloud computing startup",
        .extra = "Use blue and white color palette.",
    });
    defer allocator.free(prompt);

    try std.testing.expect(std.mem.indexOf(u8, prompt, "TechCorp") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "blue and white") != null);
}

test "buildLogoPrompt custom background" {
    const allocator = std.testing.allocator;
    const prompt = try buildLogoPrompt(allocator, .{
        .description = "NightOwl, a security firm",
        .background = "plain black",
    });
    defer allocator.free(prompt);

    try std.testing.expect(std.mem.indexOf(u8, prompt, "plain black background") != null);
}

test "findTemplate returns correct template" {
    const t = findTemplate("cyberpunk").?;
    try std.testing.expectEqualStrings("CYBERPUNK AESTHETIC:", t.prefix);
    try std.testing.expect(std.mem.indexOf(u8, t.suffix, "Neon lighting") != null);
}

test "findTemplate returns null for unknown" {
    try std.testing.expect(findTemplate("nonexistent") == null);
}

test "buildTemplatedPrompt wraps correctly" {
    const allocator = std.testing.allocator;
    const t = findTemplate("product").?;
    const prompt = try buildTemplatedPrompt(allocator, t, "a pair of running shoes");
    defer allocator.free(prompt);

    try std.testing.expect(std.mem.indexOf(u8, prompt, "PRODUCT PHOTOGRAPHY:") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "running shoes") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "e-commerce ready") != null);
}

test "all_templates has expected count" {
    try std.testing.expect(all_templates.len >= 39);
}

test "findTemplate cosmic-duck" {
    const t = findTemplate("cosmic-duck").?;
    try std.testing.expectEqualStrings("COSMIC DUCK WISDOM:", t.prefix);
    try std.testing.expect(std.mem.indexOf(u8, t.suffix, "top hat and monocle") != null);
}

test "findEditTemplate returns correct template" {
    const t = findEditTemplate("try-on").?;
    try std.testing.expect(std.mem.indexOf(u8, t.prefix, "dress the person") != null);
}

test "findEditTemplate returns null for unknown" {
    try std.testing.expect(findEditTemplate("nonexistent") == null);
}

test "buildEditPrompt wraps correctly" {
    const allocator = std.testing.allocator;
    const t = findEditTemplate("weather-change").?;
    const prompt = try buildEditPrompt(allocator, t, "make it snowy winter");
    defer allocator.free(prompt);

    try std.testing.expect(std.mem.indexOf(u8, prompt, "lighting and weather") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "snowy winter") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "Preserve identity") != null);
}

test "edit_templates has expected count" {
    try std.testing.expect(edit_templates.len >= 6);
}
