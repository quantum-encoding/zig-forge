//! SLIP-39: Shamir's Secret Sharing for Mnemonic Codes
//!
//! Implements mnemonic encoding/decoding for Shamir shares according to SLIP-39.
//! Uses a 1024-word wordlist with 10 bits per word.
//!
//! Reference: https://github.com/satoshilabs/slips/blob/master/slip-0039.md

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;

/// SLIP-39 uses RS1024 checksum (3 words = 30 bits)
pub const CHECKSUM_WORDS = 3;

/// Bits per word (1024 words = 10 bits)
pub const BITS_PER_WORD = 10;

/// RS1024 Generator polynomial coefficients
const GEN: [3]u16 = .{ 0x0E5, 0x36D, 0x3C1 };

/// Customization string for RS1024
const CUSTOMIZATION_STRING = "shamir";

/// RS1024 checksum computation
/// Computes Reed-Solomon checksum over GF(1024)
pub fn rs1024Checksum(data: []const u10) u30 {
    var chk: u30 = 1;

    // Process customization string
    for (CUSTOMIZATION_STRING) |c| {
        const b = chk >> 20;
        chk = ((chk & 0xFFFFF) << 10) ^ @as(u30, c);
        for (GEN, 0..) |g, i| {
            if ((b >> @intCast(i)) & 1 != 0) {
                chk ^= @as(u30, g) << (10 * @as(u5, @intCast(2 - i)));
            }
        }
    }

    // Process data words
    for (data) |word| {
        const b = chk >> 20;
        chk = ((chk & 0xFFFFF) << 10) ^ @as(u30, word);
        for (GEN, 0..) |g, i| {
            if ((b >> @intCast(i)) & 1 != 0) {
                chk ^= @as(u30, g) << (10 * @as(u5, @intCast(2 - i)));
            }
        }
    }

    return chk ^ 1;
}

/// Verify RS1024 checksum
pub fn verifyChecksum(words: []const u10) bool {
    if (words.len < CHECKSUM_WORDS) return false;
    return rs1024Checksum(words) == 1;
}

/// Create RS1024 checksum words
pub fn createChecksum(data: []const u10) [3]u10 {
    // Append 3 zero words and compute checksum
    var extended: [256]u10 = undefined;
    @memcpy(extended[0..data.len], data);
    extended[data.len] = 0;
    extended[data.len + 1] = 0;
    extended[data.len + 2] = 0;

    const chk = rs1024Checksum(extended[0 .. data.len + 3]);

    return .{
        @truncate((chk >> 20) & 0x3FF),
        @truncate((chk >> 10) & 0x3FF),
        @truncate(chk & 0x3FF),
    };
}

/// SLIP-39 Share metadata
pub const ShareMetadata = struct {
    /// Random 15-bit identifier (same for all shares of a set)
    identifier: u15,
    /// Iteration exponent for key derivation (0-31)
    iteration_exponent: u5,
    /// Group index (0-15)
    group_index: u4,
    /// Group threshold (1-16)
    group_threshold: u4,
    /// Group count (1-16)
    group_count: u4,
    /// Member index within group (0-15)
    member_index: u4,
    /// Member threshold (1-16)
    member_threshold: u4,
    /// Share value (the actual secret share data)
    share_value: []const u8,
};

/// Encode share metadata and value to word indices
pub fn encodeToWords(allocator: Allocator, meta: ShareMetadata) ![]u10 {
    // Calculate padding to make share_value a multiple of 10 bits
    const share_bits = meta.share_value.len * 8;
    const padding_bits = (10 - (share_bits % 10)) % 10;
    const total_data_words = (share_bits + padding_bits) / 10;

    // Total words: ID(2) + metadata(2) + share_data + checksum(3)
    // ID: 15 bits = 2 words (20 bits, 5 padding)
    // Metadata: iteration(5) + group_idx(4) + group_thresh(4) + group_count(4) +
    //           member_idx(4) + member_thresh(4) = 25 bits = 3 words (30 bits, 5 padding)
    // Actually simpler: pack everything into 10-bit words

    // SLIP-39 format:
    // Word 0: id[14:5]
    // Word 1: id[4:0] || iteration_exponent[4:0]
    // Word 2: group_index[3:0] || group_threshold-1[3:0] || group_count-1[1:0]
    // Word 3: group_count-1[3:2] || member_index[3:0] || member_threshold-1[3:0]
    // Words 4+: share value (padded)
    // Last 3 words: RS1024 checksum

    const metadata_words = 4;
    const num_words = metadata_words + total_data_words + CHECKSUM_WORDS;

    var words = try allocator.alloc(u10, num_words);
    errdefer allocator.free(words);

    // Pack metadata into first 4 words
    words[0] = @truncate(meta.identifier >> 5);
    words[1] = @as(u10, @truncate(meta.identifier & 0x1F)) << 5 | @as(u10, meta.iteration_exponent);
    words[2] = @as(u10, meta.group_index) << 6 |
        @as(u10, meta.group_threshold -| 1) << 2 |
        @as(u10, (meta.group_count -| 1) >> 2);
    words[3] = @as(u10, (meta.group_count -| 1) & 0x3) << 8 |
        @as(u10, meta.member_index) << 4 |
        @as(u10, meta.member_threshold -| 1);

    // Pack share value into remaining words (before checksum)
    var bit_buffer: u32 = 0;
    var bits_in_buffer: u5 = 0;
    var word_idx: usize = metadata_words;

    // Add padding bits first (they go at the beginning)
    if (padding_bits > 0) {
        bit_buffer = 0; // padding is zeros
        bits_in_buffer = @intCast(padding_bits);
    }

    for (meta.share_value) |byte| {
        bit_buffer = (bit_buffer << 8) | byte;
        bits_in_buffer += 8;

        while (bits_in_buffer >= 10) {
            bits_in_buffer -= 10;
            words[word_idx] = @truncate((bit_buffer >> bits_in_buffer) & 0x3FF);
            word_idx += 1;
        }
    }

    // Flush remaining bits (should be none if padding was correct)
    if (bits_in_buffer > 0) {
        words[word_idx] = @truncate((bit_buffer << (10 - bits_in_buffer)) & 0x3FF);
        word_idx += 1;
    }

    // Compute and append checksum
    const checksum = createChecksum(words[0 .. num_words - CHECKSUM_WORDS]);
    words[num_words - 3] = checksum[0];
    words[num_words - 2] = checksum[1];
    words[num_words - 1] = checksum[2];

    return words;
}

/// Decode word indices to share metadata and value
pub fn decodeFromWords(allocator: Allocator, words: []const u10) !ShareMetadata {
    if (words.len < 7) return error.MnemonicTooShort; // 4 metadata + 3 checksum minimum

    // Verify checksum
    if (!verifyChecksum(words)) return error.InvalidChecksum;

    // Extract metadata from first 4 words
    const identifier: u15 = @truncate((@as(u15, words[0]) << 5) | (words[1] >> 5));
    const iteration_exponent: u5 = @truncate(words[1] & 0x1F);
    const group_index: u4 = @truncate(words[2] >> 6);
    const group_threshold: u4 = @truncate(((words[2] >> 2) & 0xF) + 1);
    const group_count_high: u4 = @truncate(words[2] & 0x3);
    const group_count: u4 = @as(u4, @truncate(((@as(u8, group_count_high) << 2) | @as(u8, @truncate(words[3] >> 8))))) +| 1;
    const member_index: u4 = @truncate((words[3] >> 4) & 0xF);
    const member_threshold: u4 = @truncate((words[3] & 0xF) + 1);

    // Extract share value from remaining words (excluding checksum)
    const data_words = words.len - 4 - CHECKSUM_WORDS;
    const total_bits = data_words * 10;

    // Calculate actual byte length (remove padding)
    // Padding is at most 7 bits to align to byte boundary
    const padding_bits = total_bits % 8;
    const share_bytes = (total_bits - padding_bits) / 8;

    var share_value = try allocator.alloc(u8, share_bytes);
    errdefer allocator.free(share_value);

    // Unpack bits
    var bit_buffer: u32 = 0;
    var bits_in_buffer: u5 = 0;
    var byte_idx: usize = 0;
    var skip_bits: usize = padding_bits;

    for (words[4 .. words.len - CHECKSUM_WORDS]) |word| {
        bit_buffer = (bit_buffer << 10) | word;
        bits_in_buffer += 10;

        // Skip padding bits
        if (skip_bits > 0) {
            if (bits_in_buffer >= skip_bits) {
                bits_in_buffer -= @intCast(skip_bits);
                bit_buffer &= (@as(u32, 1) << bits_in_buffer) - 1;
                skip_bits = 0;
            } else {
                skip_bits -= bits_in_buffer;
                bits_in_buffer = 0;
                bit_buffer = 0;
                continue;
            }
        }

        while (bits_in_buffer >= 8 and byte_idx < share_bytes) {
            bits_in_buffer -= 8;
            share_value[byte_idx] = @truncate((bit_buffer >> bits_in_buffer) & 0xFF);
            byte_idx += 1;
        }
    }

    return ShareMetadata{
        .identifier = identifier,
        .iteration_exponent = iteration_exponent,
        .group_index = group_index,
        .group_threshold = group_threshold,
        .group_count = group_count,
        .member_index = member_index,
        .member_threshold = member_threshold,
        .share_value = share_value,
    };
}

/// Convert word indices to mnemonic string
pub fn wordsToMnemonic(allocator: Allocator, word_indices: []const u10) ![]u8 {
    var total_len: usize = 0;
    for (word_indices) |idx| {
        total_len += wordlist[idx].len + 1; // word + space
    }
    if (total_len > 0) total_len -= 1; // no trailing space

    var result = try allocator.alloc(u8, total_len);
    var pos: usize = 0;

    for (word_indices, 0..) |idx, i| {
        const word = wordlist[idx];
        @memcpy(result[pos .. pos + word.len], word);
        pos += word.len;
        if (i < word_indices.len - 1) {
            result[pos] = ' ';
            pos += 1;
        }
    }

    return result;
}

/// Parse mnemonic string to word indices
pub fn mnemonicToWords(allocator: Allocator, mnemonic: []const u8) ![]u10 {
    // Count words
    var word_count: usize = 0;
    var in_word = false;
    for (mnemonic) |c| {
        if (c == ' ' or c == '\t' or c == '\n') {
            in_word = false;
        } else if (!in_word) {
            in_word = true;
            word_count += 1;
        }
    }

    var words = try allocator.alloc(u10, word_count);
    errdefer allocator.free(words);

    // Parse each word
    var word_idx: usize = 0;
    var start: usize = 0;
    var i: usize = 0;

    while (i <= mnemonic.len) {
        const is_sep = i == mnemonic.len or mnemonic[i] == ' ' or mnemonic[i] == '\t' or mnemonic[i] == '\n';

        if (is_sep and i > start) {
            const word = mnemonic[start..i];
            words[word_idx] = try lookupWord(word);
            word_idx += 1;
            start = i + 1;
        } else if (is_sep) {
            start = i + 1;
        }

        i += 1;
    }

    return words;
}

/// Look up a word in the wordlist
fn lookupWord(word: []const u8) !u10 {
    // Convert to lowercase for comparison
    var lower: [32]u8 = undefined;
    const len = @min(word.len, 32);
    for (word[0..len], 0..) |c, i| {
        lower[i] = if (c >= 'A' and c <= 'Z') c + 32 else c;
    }

    for (wordlist, 0..) |list_word, idx| {
        if (mem.eql(u8, lower[0..len], list_word)) {
            return @intCast(idx);
        }
    }

    return error.UnknownWord;
}

/// SLIP-39 1024-word wordlist
pub const wordlist = [_][]const u8{
    "academic",
    "acid",
    "acne",
    "acquire",
    "acrobat",
    "activity",
    "actress",
    "adapt",
    "adequate",
    "adjust",
    "admit",
    "adorn",
    "adult",
    "advance",
    "advocate",
    "afraid",
    "again",
    "agency",
    "agree",
    "aide",
    "aircraft",
    "airline",
    "airport",
    "ajar",
    "alarm",
    "album",
    "alcohol",
    "alien",
    "alive",
    "alpha",
    "already",
    "alto",
    "aluminum",
    "always",
    "amazing",
    "ambition",
    "amount",
    "amuse",
    "analysis",
    "anatomy",
    "ancestor",
    "ancient",
    "angel",
    "angry",
    "animal",
    "answer",
    "antenna",
    "anxiety",
    "apart",
    "aquatic",
    "arcade",
    "arena",
    "argue",
    "armed",
    "artist",
    "artwork",
    "aspect",
    "auction",
    "august",
    "aunt",
    "average",
    "aviation",
    "avoid",
    "award",
    "away",
    "axis",
    "axle",
    "beam",
    "beard",
    "beaver",
    "become",
    "bedroom",
    "behavior",
    "being",
    "believe",
    "belong",
    "benefit",
    "best",
    "beyond",
    "bike",
    "biology",
    "birthday",
    "bishop",
    "black",
    "blanket",
    "blessing",
    "blimp",
    "blind",
    "blue",
    "body",
    "bolt",
    "boring",
    "born",
    "both",
    "boundary",
    "bracelet",
    "branch",
    "brave",
    "breathe",
    "briefing",
    "broken",
    "brother",
    "browser",
    "bucket",
    "budget",
    "building",
    "bulb",
    "bulge",
    "bumpy",
    "bundle",
    "burden",
    "burning",
    "busy",
    "buyer",
    "cage",
    "calcium",
    "camera",
    "campus",
    "canyon",
    "capacity",
    "capital",
    "capture",
    "carbon",
    "cards",
    "careful",
    "cargo",
    "carpet",
    "carve",
    "category",
    "cause",
    "ceiling",
    "center",
    "ceramic",
    "champion",
    "change",
    "charity",
    "check",
    "chemical",
    "chest",
    "chew",
    "chubby",
    "cinema",
    "civil",
    "class",
    "clay",
    "cleanup",
    "client",
    "climate",
    "clinic",
    "clock",
    "clogs",
    "closet",
    "clothes",
    "club",
    "cluster",
    "coal",
    "coastal",
    "coding",
    "column",
    "company",
    "corner",
    "costume",
    "counter",
    "course",
    "cover",
    "cowboy",
    "cradle",
    "craft",
    "crazy",
    "credit",
    "cricket",
    "criminal",
    "crisis",
    "critical",
    "crowd",
    "crucial",
    "crunch",
    "crush",
    "crystal",
    "cubic",
    "cultural",
    "curious",
    "curly",
    "custody",
    "cylinder",
    "daisy",
    "damage",
    "dance",
    "darkness",
    "database",
    "daughter",
    "deadline",
    "deal",
    "debris",
    "debut",
    "decent",
    "decision",
    "declare",
    "decorate",
    "decrease",
    "deliver",
    "demand",
    "density",
    "deny",
    "depart",
    "depend",
    "depict",
    "deploy",
    "describe",
    "desert",
    "desire",
    "desktop",
    "destroy",
    "detailed",
    "detect",
    "device",
    "devote",
    "diagnose",
    "dictate",
    "diet",
    "dilemma",
    "diminish",
    "dining",
    "diploma",
    "disaster",
    "discuss",
    "disease",
    "dish",
    "dismiss",
    "display",
    "distance",
    "dive",
    "divorce",
    "document",
    "domain",
    "domestic",
    "dominant",
    "dough",
    "downtown",
    "dragon",
    "dramatic",
    "dream",
    "dress",
    "drift",
    "drink",
    "drove",
    "drug",
    "dryer",
    "duckling",
    "duke",
    "duration",
    "dwarf",
    "dynamic",
    "early",
    "earth",
    "easel",
    "easy",
    "echo",
    "eclipse",
    "ecology",
    "edge",
    "editor",
    "educate",
    "either",
    "elbow",
    "elder",
    "election",
    "elegant",
    "element",
    "elephant",
    "elevator",
    "elite",
    "else",
    "email",
    "emerald",
    "emission",
    "emperor",
    "emphasis",
    "employer",
    "empty",
    "ending",
    "endless",
    "endorse",
    "enemy",
    "energy",
    "enforce",
    "engage",
    "enjoy",
    "enlarge",
    "entrance",
    "envelope",
    "envy",
    "epidemic",
    "episode",
    "equation",
    "equip",
    "eraser",
    "erode",
    "escape",
    "estate",
    "estimate",
    "evaluate",
    "evening",
    "evidence",
    "evil",
    "evoke",
    "exact",
    "example",
    "exceed",
    "exchange",
    "exclude",
    "excuse",
    "execute",
    "exercise",
    "exhaust",
    "exotic",
    "expand",
    "expect",
    "explain",
    "express",
    "extend",
    "extra",
    "eyebrow",
    "facility",
    "fact",
    "failure",
    "faint",
    "fake",
    "false",
    "family",
    "famous",
    "fancy",
    "fangs",
    "fantasy",
    "fatal",
    "fatigue",
    "favorite",
    "fawn",
    "fiber",
    "fiction",
    "filter",
    "finance",
    "findings",
    "finger",
    "firefly",
    "firm",
    "fiscal",
    "fishing",
    "fitness",
    "flame",
    "flash",
    "flavor",
    "flea",
    "flexible",
    "flip",
    "float",
    "floral",
    "fluff",
    "focus",
    "forbid",
    "force",
    "forecast",
    "forget",
    "formal",
    "fortune",
    "forward",
    "founder",
    "fraction",
    "fragment",
    "frequent",
    "freshman",
    "friar",
    "fridge",
    "friendly",
    "frost",
    "froth",
    "frozen",
    "fumes",
    "funding",
    "furl",
    "fused",
    "galaxy",
    "game",
    "garbage",
    "garden",
    "garlic",
    "gasoline",
    "gather",
    "general",
    "genius",
    "genre",
    "genuine",
    "geology",
    "gesture",
    "glad",
    "glance",
    "glasses",
    "glen",
    "glimpse",
    "goat",
    "golden",
    "graduate",
    "grant",
    "grasp",
    "gravity",
    "gray",
    "greatest",
    "grief",
    "grill",
    "grin",
    "grocery",
    "gross",
    "group",
    "grownup",
    "grumpy",
    "guard",
    "guest",
    "guilt",
    "guitar",
    "gums",
    "hairy",
    "hamster",
    "hand",
    "hanger",
    "harvest",
    "have",
    "havoc",
    "hawk",
    "hazard",
    "headset",
    "health",
    "hearing",
    "heat",
    "helpful",
    "herald",
    "herd",
    "hesitate",
    "hobo",
    "holiday",
    "holy",
    "home",
    "hormone",
    "hospital",
    "hour",
    "huge",
    "human",
    "humidity",
    "hunting",
    "husband",
    "hush",
    "husky",
    "hybrid",
    "idea",
    "identify",
    "idle",
    "image",
    "impact",
    "imply",
    "improve",
    "impulse",
    "include",
    "income",
    "increase",
    "index",
    "indicate",
    "industry",
    "infant",
    "inform",
    "inherit",
    "injury",
    "inmate",
    "insect",
    "inside",
    "install",
    "intend",
    "intimate",
    "invasion",
    "involve",
    "iris",
    "island",
    "isolate",
    "item",
    "ivory",
    "jacket",
    "jerky",
    "jewelry",
    "join",
    "judicial",
    "juice",
    "jump",
    "junction",
    "junior",
    "junk",
    "jury",
    "justice",
    "kernel",
    "keyboard",
    "kidney",
    "kind",
    "kitchen",
    "knife",
    "knit",
    "laden",
    "ladle",
    "ladybug",
    "lair",
    "lamp",
    "language",
    "large",
    "laser",
    "laundry",
    "lawsuit",
    "leader",
    "leaf",
    "learn",
    "leaves",
    "lecture",
    "legal",
    "legend",
    "legs",
    "lend",
    "length",
    "level",
    "liberty",
    "library",
    "license",
    "lift",
    "likely",
    "lilac",
    "lily",
    "lips",
    "liquid",
    "listen",
    "literary",
    "living",
    "lizard",
    "loan",
    "lobe",
    "location",
    "losing",
    "loud",
    "loyalty",
    "luck",
    "lunar",
    "lunch",
    "lungs",
    "luxury",
    "lying",
    "lyrics",
    "machine",
    "magazine",
    "maiden",
    "mailman",
    "main",
    "makeup",
    "making",
    "mama",
    "manager",
    "mandate",
    "mansion",
    "manual",
    "marathon",
    "march",
    "market",
    "marvel",
    "mason",
    "material",
    "math",
    "maximum",
    "mayor",
    "meaning",
    "medal",
    "medical",
    "member",
    "memory",
    "mental",
    "merchant",
    "merit",
    "method",
    "metric",
    "midst",
    "mild",
    "military",
    "mineral",
    "minister",
    "miracle",
    "mixed",
    "mixture",
    "mobile",
    "modern",
    "modify",
    "moisture",
    "moment",
    "morning",
    "mortgage",
    "mother",
    "mountain",
    "mouse",
    "move",
    "much",
    "mule",
    "multiple",
    "muscle",
    "museum",
    "music",
    "mustang",
    "nail",
    "national",
    "necklace",
    "negative",
    "nervous",
    "network",
    "news",
    "nuclear",
    "numb",
    "numerous",
    "nylon",
    "oasis",
    "obesity",
    "object",
    "observe",
    "obtain",
    "ocean",
    "often",
    "olympic",
    "omit",
    "oral",
    "orange",
    "orbit",
    "order",
    "ordinary",
    "organize",
    "ounce",
    "oven",
    "overall",
    "owner",
    "paces",
    "pacific",
    "package",
    "paid",
    "painting",
    "pajamas",
    "pancake",
    "pants",
    "papa",
    "paper",
    "parcel",
    "parking",
    "party",
    "patent",
    "patrol",
    "payment",
    "payroll",
    "peaceful",
    "peanut",
    "peasant",
    "pecan",
    "penalty",
    "pencil",
    "percent",
    "perfect",
    "permit",
    "petition",
    "phantom",
    "pharmacy",
    "photo",
    "phrase",
    "physics",
    "pickup",
    "picture",
    "piece",
    "pile",
    "pink",
    "pipeline",
    "pistol",
    "pitch",
    "plains",
    "plan",
    "plastic",
    "platform",
    "playoff",
    "pleasure",
    "plot",
    "plunge",
    "practice",
    "prayer",
    "preach",
    "predator",
    "pregnant",
    "premium",
    "prepare",
    "presence",
    "prevent",
    "priest",
    "primary",
    "priority",
    "prisoner",
    "privacy",
    "prize",
    "problem",
    "process",
    "profile",
    "program",
    "promise",
    "prospect",
    "provide",
    "prune",
    "public",
    "pulse",
    "pumps",
    "punish",
    "puny",
    "pupal",
    "purchase",
    "purple",
    "python",
    "quantity",
    "quarter",
    "quick",
    "quiet",
    "race",
    "racism",
    "radar",
    "railroad",
    "rainbow",
    "raisin",
    "random",
    "ranked",
    "rapids",
    "raspy",
    "reaction",
    "realize",
    "rebound",
    "rebuild",
    "recall",
    "receiver",
    "recover",
    "regret",
    "regular",
    "reject",
    "relate",
    "remember",
    "remind",
    "remove",
    "render",
    "repair",
    "repeat",
    "replace",
    "require",
    "rescue",
    "research",
    "resident",
    "response",
    "result",
    "retailer",
    "retreat",
    "reunion",
    "revenue",
    "review",
    "reward",
    "rhyme",
    "rhythm",
    "rich",
    "rival",
    "river",
    "robin",
    "rocky",
    "romantic",
    "romp",
    "roster",
    "round",
    "royal",
    "ruin",
    "ruler",
    "rumor",
    "sack",
    "safari",
    "salary",
    "salon",
    "salt",
    "satisfy",
    "satoshi",
    "saver",
    "says",
    "scandal",
    "scared",
    "scatter",
    "scene",
    "scholar",
    "science",
    "scout",
    "scramble",
    "screw",
    "script",
    "scroll",
    "seafood",
    "season",
    "secret",
    "security",
    "segment",
    "senior",
    "shadow",
    "shaft",
    "shame",
    "shaped",
    "sharp",
    "shelter",
    "sheriff",
    "short",
    "should",
    "shrimp",
    "sidewalk",
    "silent",
    "silver",
    "similar",
    "simple",
    "single",
    "sister",
    "skin",
    "skunk",
    "slap",
    "slavery",
    "sled",
    "slice",
    "slim",
    "slow",
    "slush",
    "smart",
    "smear",
    "smell",
    "smirk",
    "smith",
    "smoking",
    "smug",
    "snake",
    "snapshot",
    "sniff",
    "society",
    "software",
    "soldier",
    "solution",
    "soul",
    "source",
    "space",
    "spark",
    "speak",
    "species",
    "spelling",
    "spend",
    "spew",
    "spider",
    "spill",
    "spine",
    "spirit",
    "spit",
    "spray",
    "sprinkle",
    "square",
    "squeeze",
    "stadium",
    "staff",
    "standard",
    "starting",
    "station",
    "stay",
    "steady",
    "step",
    "stick",
    "stilt",
    "story",
    "strategy",
    "strike",
    "style",
    "subject",
    "submit",
    "sugar",
    "suitable",
    "sunlight",
    "superior",
    "surface",
    "surprise",
    "survive",
    "sweater",
    "swimming",
    "swing",
    "switch",
    "symbolic",
    "sympathy",
    "syndrome",
    "system",
    "tackle",
    "tactics",
    "tadpole",
    "talent",
    "task",
    "taste",
    "taught",
    "taxi",
    "teacher",
    "teammate",
    "teaspoon",
    "temple",
    "tenant",
    "tendency",
    "tension",
    "terminal",
    "testify",
    "texture",
    "thank",
    "that",
    "theater",
    "theory",
    "therapy",
    "thorn",
    "threaten",
    "thumb",
    "thunder",
    "ticket",
    "tidy",
    "timber",
    "timely",
    "ting",
    "tofu",
    "together",
    "tolerate",
    "total",
    "toxic",
    "tracks",
    "traffic",
    "training",
    "transfer",
    "trash",
    "traveler",
    "treat",
    "trend",
    "trial",
    "tricycle",
    "trip",
    "triumph",
    "trouble",
    "true",
    "trust",
    "twice",
    "twin",
    "type",
    "typical",
    "ugly",
    "ultimate",
    "umbrella",
    "uncover",
    "undergo",
    "unfair",
    "unfold",
    "unhappy",
    "union",
    "universe",
    "unkind",
    "unknown",
    "unusual",
    "unwrap",
    "upgrade",
    "upstairs",
    "username",
    "usher",
    "usual",
    "valid",
    "valuable",
    "vampire",
    "vanish",
    "various",
    "vegan",
    "velvet",
    "venture",
    "verdict",
    "verify",
    "very",
    "veteran",
    "vexed",
    "victim",
    "video",
    "view",
    "vintage",
    "violence",
    "viral",
    "visitor",
    "visual",
    "vitamins",
    "vocal",
    "voice",
    "volume",
    "voter",
    "voting",
    "walnut",
    "warmth",
    "warn",
    "watch",
    "wavy",
    "wealthy",
    "weapon",
    "webcam",
    "welcome",
    "welfare",
    "western",
    "width",
    "wildlife",
    "window",
    "wine",
    "wireless",
    "wisdom",
    "withdraw",
    "wits",
    "wolf",
    "woman",
    "work",
    "worthy",
    "wrap",
    "wrist",
    "writing",
    "wrote",
    "year",
    "yelp",
    "yield",
    "yoga",
    "zero",
};

// =============================================================================
// Tests
// =============================================================================

test "wordlist size" {
    try std.testing.expectEqual(@as(usize, 1024), wordlist.len);
}

test "word lookup" {
    try std.testing.expectEqual(@as(u10, 0), try lookupWord("academic"));
    try std.testing.expectEqual(@as(u10, 1), try lookupWord("acid"));
    try std.testing.expectEqual(@as(u10, 1023), try lookupWord("zero"));
    try std.testing.expectEqual(@as(u10, 856), try lookupWord("satoshi"));
}

test "RS1024 checksum basic" {
    // Test with simple data
    var data = [_]u10{ 0, 1, 2, 3, 4 };
    const checksum = createChecksum(&data);

    // Verify appending checksum validates
    var full = [_]u10{ 0, 1, 2, 3, 4, checksum[0], checksum[1], checksum[2] };
    try std.testing.expect(verifyChecksum(&full));
}

test "mnemonic roundtrip" {
    const allocator = std.testing.allocator;

    const original_words = [_]u10{ 0, 100, 200, 300, 400, 500, 600, 700, 800, 900 };
    const mnemonic = try wordsToMnemonic(allocator, &original_words);
    defer allocator.free(mnemonic);

    const parsed = try mnemonicToWords(allocator, mnemonic);
    defer allocator.free(parsed);

    try std.testing.expectEqualSlices(u10, &original_words, parsed);
}
