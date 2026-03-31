const std = @import("std");
const Allocator = std.mem.Allocator;

// ── espeak-ng C FFI declarations ──

const AUDIO_OUTPUT_RETRIEVAL = 0x2000;
const espeakINITIALIZE_DONT_EXIT = 0x8000;
const espeakCHARS_UTF8 = 1;
const espeakPHONEMES_IPA = 0x02;
const espeakSSML = 0x10;

extern fn espeak_Initialize(output: c_int, buflength: c_int, path: ?[*:0]const u8, options: c_int) c_int;
extern fn espeak_SetVoiceByName(name: [*:0]const u8) c_int;
extern fn espeak_TextToPhonemes(textptr: *?[*:0]const u8, textmode: c_int, phonememode: c_int) ?[*:0]const u8;
extern fn espeak_Terminate() c_int;

// ── Piper phoneme ID map ──
// Piper's en-us VITS uses a fixed IPA→ID mapping with ~130 entries.
// PAD=0, BOS=1, EOS=2, BLANK=_ mapped to PAD between phonemes.

const PAD_ID: u16 = 0;
const BOS_ID: u16 = 1;
const EOS_ID: u16 = 2;

/// Phoneme-to-ID lookup table (Piper en-us medium, _phonemes.json)
/// Maps IPA code points to phoneme IDs.
fn ipaToId(cp: u21) u16 {
    return switch (cp) {
        ' ' => 3,
        '!' => 4,
        '\'' => 5,
        '(' => 6,
        ')' => 7,
        ',' => 8,
        '-' => 9,
        '.' => 10,
        ':' => 11,
        ';' => 12,
        '?' => 13,
        'a' => 14,
        'b' => 15,
        'c' => 16,
        'd' => 17,
        'e' => 18,
        'f' => 19,
        'h' => 20,
        'i' => 21,
        'j' => 22,
        'k' => 23,
        'l' => 24,
        'm' => 25,
        'n' => 26,
        'o' => 27,
        'p' => 28,
        'r' => 29,
        's' => 30,
        't' => 31,
        'u' => 32,
        'v' => 33,
        'w' => 34,
        'x' => 35,
        'z' => 36,
        0x00E6 => 37, // æ
        0x00E7 => 38, // ç
        0x00F0 => 39, // ð
        0x00F8 => 40, // ø
        0x0127 => 41, // ħ
        0x014B => 42, // ŋ
        0x0153 => 43, // œ
        0x01C0 => 44, // ǀ (click)
        0x01C3 => 45, // ǃ
        0x0250 => 46, // ɐ
        0x0251 => 47, // ɑ
        0x0252 => 48, // ɒ
        0x0254 => 49, // ɔ
        0x0259 => 50, // ə
        0x025B => 51, // ɛ
        0x025C => 52, // ɜ
        0x025F => 53, // ɟ
        0x0260 => 54, // ɠ
        0x0261 => 55, // ɡ
        0x0262 => 56, // ɢ
        0x0263 => 57, // ɣ
        0x0264 => 58, // ɤ
        0x0265 => 59, // ɥ
        0x0268 => 60, // ɨ
        0x026A => 61, // ɪ
        0x026B => 62, // ɫ
        0x026D => 63, // ɭ
        0x026E => 64, // ɮ
        0x026F => 65, // ɯ
        0x0270 => 66, // ɰ
        0x0271 => 67, // ɱ
        0x0272 => 68, // ɲ
        0x0273 => 69, // ɳ
        0x0274 => 70, // ɴ
        0x0275 => 71, // ɵ
        0x0276 => 72, // ɶ
        0x0278 => 73, // ɸ
        0x0279 => 74, // ɹ
        0x027A => 75, // ɺ
        0x027B => 76, // ɻ
        0x027D => 77, // ɽ
        0x027E => 78, // ɾ
        0x0280 => 79, // ʀ
        0x0281 => 80, // ʁ
        0x0282 => 81, // ʂ
        0x0283 => 82, // ʃ
        0x0288 => 83, // ʈ
        0x0289 => 84, // ʉ
        0x028A => 85, // ʊ
        0x028B => 86, // ʋ
        0x028C => 87, // ʌ
        0x028D => 88, // ʍ
        0x028E => 89, // ʎ
        0x028F => 90, // ʏ
        0x0290 => 91, // ʐ
        0x0291 => 92, // ʑ
        0x0292 => 93, // ʒ
        0x0294 => 94, // ʔ
        0x0295 => 95, // ʕ
        0x0298 => 96, // ʘ
        0x029D => 97, // ʝ
        0x02A1 => 98, // ʡ
        0x02A2 => 99, // ʢ
        0x02B0 => 100, // ʰ
        0x02C8 => 101, // ˈ (primary stress)
        0x02CC => 102, // ˌ (secondary stress)
        0x02D0 => 103, // ː (length)
        0x02D1 => 104, // ˑ
        0x0303 => 105, // ̃ (nasalization, combining)
        0x0306 => 106, // ̆ (extra-short, combining)
        0x030B => 107, // ̋ (combining)
        0x030F => 108, // ̏ (combining)
        0x0318 => 109, // ̘ (combining)
        0x0319 => 110, // ̙ (combining)
        0x031A => 111, // ̚ (combining)
        0x031C => 112, // ̜ (combining)
        0x031D => 113, // ̝ (combining)
        0x031E => 114, // ̞ (combining)
        0x031F => 115, // ̟ (combining)
        0x0320 => 116, // ̠ (combining)
        0x0324 => 117, // ̤ (combining)
        0x0325 => 118, // ̥ (combining)
        0x032A => 119, // ̪ (combining)
        0x0330 => 120, // ̰ (combining)
        0x0334 => 121, // ̴ (combining)
        0x033A => 122, // ̺ (combining)
        0x033B => 123, // ̻ (combining)
        0x033C => 124, // ̼ (combining)
        0x0361 => 125, // ͡ (combining tie bar)
        0x03B2 => 126, // β
        0x03B8 => 127, // θ
        0x03C7 => 128, // χ
        0x207F => 129, // ⁿ
        else => PAD_ID, // unmapped → pad
    };
}

pub const PhonemeResult = struct {
    ids: []u16,
    n_phonemes: usize,
};

var initialized = false;

/// Initialize espeak-ng with the given voice (e.g., "en-us").
pub fn init(voice: []const u8) !void {
    if (initialized) return;

    var voice_buf: [64:0]u8 = undefined;
    const copy_len = @min(voice.len, 63);
    @memcpy(voice_buf[0..copy_len], voice[0..copy_len]);
    voice_buf[copy_len] = 0;

    const ret = espeak_Initialize(AUDIO_OUTPUT_RETRIEVAL, 0, null, espeakINITIALIZE_DONT_EXIT);
    if (ret < 0) return error.EspeakInitFailed;

    if (espeak_SetVoiceByName(&voice_buf) != 0) return error.EspeakVoiceFailed;

    initialized = true;
}

pub fn deinit() void {
    if (initialized) {
        _ = espeak_Terminate();
        initialized = false;
    }
}

/// Convert text to Piper phoneme IDs with inter-phoneme blanks.
/// Output format: [BOS, PAD, p1, PAD, p2, PAD, ..., pN, PAD, EOS]
pub fn textToPhonemeIds(allocator: Allocator, text: []const u8) !PhonemeResult {
    if (!initialized) return error.EspeakNotInitialized;

    const c_text = try allocator.dupeZ(u8, text);
    defer allocator.free(c_text);

    // espeak_TextToPhonemes advances the pointer through the text
    var text_ptr: ?[*:0]const u8 = c_text.ptr;

    // Collect all IPA output
    var ipa_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer ipa_buf.deinit(allocator);

    while (text_ptr != null) {
        const phonemes = espeak_TextToPhonemes(&text_ptr, espeakCHARS_UTF8, espeakPHONEMES_IPA);
        if (phonemes) |p| {
            const span = std.mem.span(p);
            if (span.len > 0) {
                try ipa_buf.appendSlice(allocator, span);
            }
        } else break;
    }

    if (ipa_buf.items.len == 0) {
        // Return minimal sequence
        const ids = try allocator.alloc(u16, 3);
        ids[0] = BOS_ID;
        ids[1] = PAD_ID;
        ids[2] = EOS_ID;
        return PhonemeResult{ .ids = ids, .n_phonemes = 0 };
    }

    // Convert IPA string to phoneme IDs with blanks
    // Worst case: each byte is a phoneme → 2*len + 3 (BOS + blanks + EOS)
    var ids: std.ArrayListUnmanaged(u16) = .empty;
    defer ids.deinit(allocator);

    try ids.append(allocator, BOS_ID);
    try ids.append(allocator, PAD_ID); // blank after BOS

    var phoneme_count: usize = 0;
    const ipa = ipa_buf.items;
    var i: usize = 0;
    while (i < ipa.len) {
        // Decode one UTF-8 code point
        const cp_len = std.unicode.utf8ByteSequenceLength(ipa[i]) catch {
            i += 1;
            continue;
        };
        if (i + cp_len > ipa.len) break;
        const cp = std.unicode.utf8Decode(ipa[i..][0..cp_len]) catch {
            i += cp_len;
            continue;
        };
        i += cp_len;

        const id = ipaToId(cp);
        if (id != PAD_ID) {
            try ids.append(allocator, id);
            try ids.append(allocator, PAD_ID); // inter-phoneme blank
            phoneme_count += 1;
        }
    }

    try ids.append(allocator, EOS_ID);

    const result = try allocator.alloc(u16, ids.items.len);
    @memcpy(result, ids.items);

    return PhonemeResult{
        .ids = result,
        .n_phonemes = phoneme_count,
    };
}
