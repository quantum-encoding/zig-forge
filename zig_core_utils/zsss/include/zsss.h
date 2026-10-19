/**
 * zsss - Shamir Secret Sharing Library
 *
 * C-compatible FFI interface for:
 *   - Shamir Secret Sharing (split secrets into shares, combine to recover)
 *   - Steganography (hide data in PNG images with optional encryption)
 *   - Event Tickets (multi-layer steganographic ticketing system)
 *
 * Build: zig build (produces libzsss.a and libzsss.so)
 *
 * Usage:
 *   1. zsss_init() does nothing and is optional; it is kept for existing callers
 *   2. All returned buffers must be freed with zsss_free(), which wipes them first
 *   3. Check error_code in ZsssBuffer for success/failure
 *   4. For tickets, free ZsssTicketInfo with zsss_ticket_info_free()
 *
 * Pointers: a NULL pointer with a non-zero length is refused with
 * ZSSS_ERR_INVALID_INPUT, never dereferenced and never read as "absent". NULL is
 * accepted with length 0, and for the optional inputs documented as such
 * (passphrase, password, seat, tier) it means "none" only with length 0.
 *
 * Frames: a buffer of length-prefixed frames ([len:u32le][bytes]...) passed to
 * zsss_combine or zsss_slip39_combine must consist of whole frames exactly; a
 * length running past the end or trailing bytes shorter than a prefix is
 * ZSSS_ERR_INVALID_INPUT.
 */

#ifndef ZSSS_H
#define ZSSS_H

#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Error codes */
#define ZSSS_OK                          0
#define ZSSS_ERR_INVALID_INPUT          -1
#define ZSSS_ERR_THRESHOLD_TOO_LOW      -2
#define ZSSS_ERR_THRESHOLD_EXCEEDS_SHARES -3
#define ZSSS_ERR_TOO_MANY_SHARES        -4
#define ZSSS_ERR_EMPTY_SECRET           -5
#define ZSSS_ERR_NO_SHARES              -6
#define ZSSS_ERR_INSUFFICIENT_SHARES    -7
#define ZSSS_ERR_CHECKSUM_MISMATCH      -8
#define ZSSS_ERR_SECRET_VERIFICATION_FAILED -9
#define ZSSS_ERR_OUT_OF_MEMORY          -10
#define ZSSS_ERR_IMAGE_TOO_SMALL        -11
#define ZSSS_ERR_INVALID_PNG            -12
#define ZSSS_ERR_INVALID_MAGIC          -13
#define ZSSS_ERR_DECRYPTION_FAILED      -14
#define ZSSS_ERR_INVALID_PASSWORD       -15
#define ZSSS_ERR_TICKET_NOT_FOUND       -16
#define ZSSS_ERR_TICKET_EXPIRED         -17
#define ZSSS_ERR_TICKET_INVALID         -18
#define ZSSS_ERR_LAYER_OCCUPIED         -19
/* SLIP-0039 */
#define ZSSS_ERR_SLIP39_INVALID_MNEMONIC   -20
#define ZSSS_ERR_SLIP39_INVALID_SHARE_SET  -21
#define ZSSS_ERR_SLIP39_INVALID_DIGEST     -22
#define ZSSS_ERR_SLIP39_INVALID_CONFIG     -23
#define ZSSS_ERR_SLIP39_INVALID_PASSPHRASE -24
/* Steganography (added 2026-10-11; before, every extract failure was INVALID_MAGIC
 * and every embed failure IMAGE_TOO_SMALL). Existing values are unchanged. */
#define ZSSS_ERR_PNG_UNSUPPORTED        -25  /* not 8-bit, interlaced, or indexed on embed */
#define ZSSS_ERR_PNG_CRC_MISMATCH       -26  /* chunk CRC or zlib Adler-32 wrong */
#define ZSSS_ERR_PNG_TOO_LARGE          -27  /* over 16 Mpx or 65536 px per side */
#define ZSSS_ERR_STEGO_CORRUPTED        -28  /* hidden-data header corrupt / bad version */
#define ZSSS_ERR_RANDOM_FAILURE         -29  /* OS CSPRNG failed (embed with password, split) */
/* Native share format, version 2 (zsss_split / zsss_combine) */
#define ZSSS_ERR_UNSUPPORTED_SHARE_VERSION -30  /* a share in any format version but 2 */
#define ZSSS_ERR_SHARE_SET_MISMATCH        -31  /* shares of different splits, parameters or a repeated index */
#define ZSSS_ERR_UNKNOWN                -99

/**
 * Result buffer returned by zsss functions.
 * Must be freed with zsss_free() when done.
 */
typedef struct {
    uint8_t* data;      /* Pointer to data (NULL on error) */
    size_t len;         /* Length of data in bytes */
    int32_t error_code; /* ZSSS_OK on success, error code otherwise */
} ZsssBuffer;

/**
 * Does nothing: the library keeps no global state. Kept for the ABI; safe to call
 * any number of times from any thread.
 */
void zsss_init(void);

/**
 * Get library version string.
 * @return Null-terminated version string (do not free)
 */
const char* zsss_version(void);

/**
 * Free a buffer returned by zsss functions.
 * @param buf The buffer to free
 */
void zsss_free(ZsssBuffer buf);

/**
 * Get human-readable error message for an error code.
 * @param error_code Error code from ZsssBuffer.error_code
 * @return Null-terminated error message (do not free)
 */
const char* zsss_error_message(int32_t error_code);

/*
 * ============================================================================
 * Shamir Secret Sharing
 * ============================================================================
 *
 * zsss's own share format, version 2 (not interoperable; for that use SLIP-0039
 * below). Each share is
 *
 *   version(1) = 2 | threshold(1) | total(1) | index(1) | set_id(16)
 *   | data_len(4, LE) | data(data_len) | crc32(4, LE)
 *
 * set_id is random, one per split. data is the share of the payload
 * HMAC-SHA256(key = R, msg = secret)[0..4] || R(16 random bytes) || secret, so
 * data_len = secret_len + 20 and no share holds any function of the secret.
 * Combining checks the digest in constant time and that every share past the
 * threshold lies on the same polynomial. Only version 2 is read or written.
 */

/**
 * Split a secret into n shares with threshold k.
 *
 * @param secret_ptr Pointer to secret data
 * @param secret_len Length of secret in bytes
 * @param threshold Minimum shares needed to recover (k, must be >= 2)
 * @param num_shares Total shares to create (n, must be >= threshold, <= 255)
 * @return ZsssBuffer containing concatenated length-prefixed shares
 *         Format: [len1:u32le][share1][len2:u32le][share2]...
 *         Errors: ZSSS_ERR_EMPTY_SECRET, ZSSS_ERR_INVALID_INPUT (threshold or
 *         count), ZSSS_ERR_RANDOM_FAILURE, ZSSS_ERR_OUT_OF_MEMORY
 *
 * Example:
 *   ZsssBuffer result = zsss_split(secret, 32, 3, 5);
 *   if (result.error_code == ZSSS_OK) {
 *       // Use result.data, result.len
 *       zsss_free(result);
 *   }
 */
ZsssBuffer zsss_split(
    const uint8_t* secret_ptr,
    size_t secret_len,
    uint8_t threshold,
    uint8_t num_shares
);

/**
 * Combine shares to recover the original secret.
 *
 * @param shares_ptr Pointer to concatenated length-prefixed shares
 *                   (same format as zsss_split output); k or more of one split
 * @param shares_len Total length of shares data
 * @return ZsssBuffer containing recovered secret
 *         Errors: ZSSS_ERR_NO_SHARES, ZSSS_ERR_INVALID_INPUT (framing),
 *         ZSSS_ERR_UNSUPPORTED_SHARE_VERSION, ZSSS_ERR_CHECKSUM_MISMATCH (CRC or
 *         length), ZSSS_ERR_INSUFFICIENT_SHARES (fewer than k),
 *         ZSSS_ERR_SHARE_SET_MISMATCH (not one split),
 *         ZSSS_ERR_SECRET_VERIFICATION_FAILED (digest, or a share past the
 *         threshold off the polynomial), ZSSS_ERR_OUT_OF_MEMORY
 *
 * Example:
 *   ZsssBuffer secret = zsss_combine(shares_data, shares_len);
 *   if (secret.error_code == ZSSS_OK) {
 *       // Use secret.data, secret.len
 *       zsss_free(secret);
 *   }
 */
ZsssBuffer zsss_combine(
    const uint8_t* shares_ptr,
    size_t shares_len
);

/*
 * ============================================================================
 * SLIP-0039 (interoperable mnemonic shares)
 * ============================================================================
 *
 * A different scheme from zsss_split/zsss_combine above: shares produced here
 * are standard SLIP-0039 mnemonics and interoperate with other SLIP-39
 * implementations (Trezor, Electrum, Sparrow, python-shamir-mnemonic).
 * See docs/slip-0039.md for the specification.
 */

/**
 * Split a master secret into SLIP-0039 mnemonic shares.
 *
 * @param secret_ptr         Master secret. Must be >= 16 bytes with an even
 *                           length (>= 128 bits of entropy, a whole number of
 *                           16-bit units). For a BIP-32 wallet this is the
 *                           BIP-32 master seed.
 * @param secret_len         Length of the master secret in bytes
 * @param group_threshold    Number of groups required to recover (1..group_count)
 * @param group_specs_ptr    group_count pairs of bytes, one pair per group:
 *                           (member_threshold, member_count). Both 1..16, and
 *                           member_threshold <= member_count. A group with
 *                           member_threshold 1 must have member_count 1.
 * @param group_count        Number of groups (1..16). For a plain k-of-n backup
 *                           pass group_threshold 1 and a single {k, n} pair.
 * @param passphrase_ptr     Passphrase, or NULL (with length 0) for none. Printable ASCII only
 *                           (code points 32-126).
 * @param passphrase_len     Passphrase length in bytes
 * @param iteration_exponent 0..15; total PBKDF2 iterations are 10000 << e.
 *                           Use 1 to match the reference implementation default.
 * @param extendable         Set the extendable backup flag. Pass true for new
 *                           backups; false only to match a pre-2023 share set.
 * @return ZsssBuffer holding the mnemonics as length-prefixed UTF-8 strings,
 *         [len1:u32le][mnemonic1][len2:u32le][mnemonic2]..., ordered group 0's
 *         members first. Free with zsss_free().
 *
 * Example:
 *   uint8_t groups[2] = {3, 5};  // one group, 3 of 5
 *   ZsssBuffer r = zsss_slip39_generate(seed, 32, 1, groups, 1,
 *                                       "hunter2", 7, 1, true);
 */
ZsssBuffer zsss_slip39_generate(
    const uint8_t* secret_ptr,
    size_t secret_len,
    uint8_t group_threshold,
    const uint8_t* group_specs_ptr,
    size_t group_count,
    const uint8_t* passphrase_ptr,
    size_t passphrase_len,
    uint8_t iteration_exponent,
    bool extendable
);

/**
 * Recover a master secret from SLIP-0039 mnemonics.
 *
 * @param mnemonics_ptr  Length-prefixed UTF-8 mnemonic strings, same framing as
 *                       zsss_slip39_generate output
 * @param mnemonics_len  Total length of the mnemonics buffer
 * @param passphrase_ptr Passphrase, or NULL (with length 0) for none
 * @param passphrase_len Passphrase length in bytes
 * @return ZsssBuffer holding the recovered master secret. Free with zsss_free().
 *
 * Exactly group_threshold groups must be supplied, and exactly each of those
 * groups' member_threshold shares — no more and no fewer, and no share twice:
 * a repeated share is ZSSS_ERR_SLIP39_INVALID_SHARE_SET.
 *
 * SLIP-0039 provides no way to verify the passphrase: a wrong passphrase
 * returns a DIFFERENT master secret with ZSSS_OK, it does not error. This is
 * specified behaviour (plausible deniability), not a defect.
 */
ZsssBuffer zsss_slip39_combine(
    const uint8_t* mnemonics_ptr,
    size_t mnemonics_len,
    const uint8_t* passphrase_ptr,
    size_t passphrase_len
);

/*
 * ============================================================================
 * Steganography
 * ============================================================================
 */

/**
 * Embed data into a PNG image using LSB steganography.
 *
 * @param png_ptr Pointer to PNG image data
 * @param png_len Length of PNG data
 * @param data_ptr Pointer to data to embed
 * @param data_len Length of data to embed
 * @param password_ptr Password for encryption (NULL with length 0 for no encryption)
 * @param password_len Length of password (must be 0 if password_ptr is NULL)
 * @param layer_slot Layer slot for multi-layer embedding (-1 for default, 0-255 for specific layer)
 * @return ZsssBuffer containing new PNG with embedded data
 *
 * The carrier must be an 8-bit, non-interlaced PNG of colour type 0, 2, 4 or 6 (grey,
 * RGB, grey+alpha, RGBA), at most 16 megapixels. Every chunk CRC and the zlib Adler-32
 * are verified. Error codes: ZSSS_ERR_INVALID_INPUT (empty input), ZSSS_ERR_INVALID_PNG
 * (not a PNG, truncated, corrupt stream), ZSSS_ERR_PNG_UNSUPPORTED (16-bit, interlaced,
 * indexed), ZSSS_ERR_PNG_CRC_MISMATCH, ZSSS_ERR_PNG_TOO_LARGE, ZSSS_ERR_IMAGE_TOO_SMALL
 * (not enough pixels for the data), ZSSS_ERR_RANDOM_FAILURE, ZSSS_ERR_OUT_OF_MEMORY.
 *
 * Example:
 *   // Simple embed without encryption
 *   ZsssBuffer output = zsss_stego_embed(png, png_len, data, data_len, NULL, 0, -1);
 *
 *   // Embed with password encryption
 *   ZsssBuffer output = zsss_stego_embed(png, png_len, data, data_len, "password", 8, -1);
 *
 *   // Multi-layer embed (layer 0 for public, layer 1 for private)
 *   ZsssBuffer output = zsss_stego_embed(png, png_len, cert, cert_len, "public", 6, 0);
 */
ZsssBuffer zsss_stego_embed(
    const uint8_t* png_ptr,
    size_t png_len,
    const uint8_t* data_ptr,
    size_t data_len,
    const uint8_t* password_ptr,
    size_t password_len,
    int16_t layer_slot
);

/**
 * Extract data from a PNG image with embedded steganographic data.
 *
 * @param png_ptr Pointer to PNG image data
 * @param png_len Length of PNG data
 * @param password_ptr Password for decryption (NULL with length 0 if data wasn't encrypted)
 * @param password_len Length of password (must be 0 if password_ptr is NULL)
 * @param layer_slot Layer slot to extract from (-1 for default, 0-255 for specific layer)
 * @return ZsssBuffer containing extracted data
 *
 * Error codes: ZSSS_ERR_INVALID_INPUT, ZSSS_ERR_INVALID_PNG, ZSSS_ERR_PNG_UNSUPPORTED,
 * ZSSS_ERR_PNG_CRC_MISMATCH, ZSSS_ERR_PNG_TOO_LARGE (the image, as for embed);
 * ZSSS_ERR_IMAGE_TOO_SMALL (fewer pixels than a stego header needs);
 * ZSSS_ERR_INVALID_MAGIC (no hidden data at this layer/password);
 * ZSSS_ERR_STEGO_CORRUPTED (header found but its length or version is impossible);
 * ZSSS_ERR_DECRYPTION_FAILED (payload tampered or wrong key); ZSSS_ERR_OUT_OF_MEMORY.
 *
 * Example:
 *   ZsssBuffer extracted = zsss_stego_extract(png, png_len, "password", 8, -1);
 *   if (extracted.error_code == ZSSS_OK) {
 *       // Use extracted.data, extracted.len
 *       zsss_free(extracted);
 *   }
 */
ZsssBuffer zsss_stego_extract(
    const uint8_t* png_ptr,
    size_t png_len,
    const uint8_t* password_ptr,
    size_t password_len,
    int16_t layer_slot
);

/*
 * ============================================================================
 * Event Tickets
 * ============================================================================
 *
 * Multi-layer steganographic ticket system for events, conferences, concerts.
 * Each image can hold up to 256 unique tickets (one per layer).
 * Each attendee gets a unique password to extract their ticket.
 */

/**
 * Ticket information structure.
 * All string pointers must be freed with zsss_ticket_info_free().
 */
typedef struct {
    uint8_t* event_id;      /* Event identifier */
    size_t event_id_len;
    uint8_t* ticket_id;     /* Unique ticket ID (hex string) */
    size_t ticket_id_len;
    uint8_t* seat;          /* Seat assignment (optional, NULL if none) */
    size_t seat_len;
    uint8_t* tier;          /* Ticket tier (optional, NULL if none) */
    size_t tier_len;
    uint8_t layer;          /* Layer where ticket was found (0-255) */
    int64_t issued_at;      /* Unix timestamp when issued */
    int64_t expires_at;     /* Unix timestamp when expires (0 if no expiry) */
    int is_valid;           /* Non-zero if ticket is valid */
    int32_t error_code;     /* ZSSS_OK on success */
} ZsssTicketInfo;

/**
 * Embed a single ticket into a PNG image.
 *
 * @param png_ptr Pointer to PNG image data
 * @param png_len Length of PNG data
 * @param event_id_ptr Event identifier string
 * @param event_id_len Length of event_id
 * @param password_ptr Password for this ticket (attendee's access key)
 * @param password_len Length of password
 * @param layer Layer slot (0-255) to embed ticket in
 * @param seat_ptr Seat assignment (NULL if none)
 * @param seat_len Length of seat string
 * @param tier_ptr Ticket tier like "VIP", "General" (NULL if none)
 * @param tier_len Length of tier string
 * @return ZsssBuffer containing new PNG with embedded ticket
 *
 * Example:
 *   // Create VIP ticket at layer 0
 *   ZsssBuffer result = zsss_ticket_embed(
 *       png, png_len,
 *       "CONCERT-2026", 12,
 *       "SecretPass1", 11,
 *       0,                    // layer 0
 *       "A-1", 3,            // seat
 *       "VIP", 3             // tier
 *   );
 *   if (result.error_code == ZSSS_OK) {
 *       // Save result.data as new PNG
 *       zsss_free(result);
 *   }
 */
ZsssBuffer zsss_ticket_embed(
    const uint8_t* png_ptr,
    size_t png_len,
    const uint8_t* event_id_ptr,
    size_t event_id_len,
    const uint8_t* password_ptr,
    size_t password_len,
    uint8_t layer,
    const uint8_t* seat_ptr,
    size_t seat_len,
    const uint8_t* tier_ptr,
    size_t tier_len
);

/**
 * Extract raw ticket data from a PNG image.
 *
 * Searches all 256 layers to find a ticket matching the password.
 *
 * @param png_ptr Pointer to PNG image data
 * @param png_len Length of PNG data
 * @param password_ptr Password to try
 * @param password_len Length of password
 * @return ZsssBuffer containing raw ticket data bytes
 */
ZsssBuffer zsss_ticket_extract(
    const uint8_t* png_ptr,
    size_t png_len,
    const uint8_t* password_ptr,
    size_t password_len
);

/**
 * Get structured ticket information from a PNG image.
 *
 * Searches all 256 layers to find a ticket matching the password.
 *
 * @param png_ptr Pointer to PNG image data
 * @param png_len Length of PNG data
 * @param password_ptr Password to try
 * @param password_len Length of password
 * @param out_info Pointer to ZsssTicketInfo struct to fill
 * @return ZSSS_OK on success, error code otherwise
 *
 * Example:
 *   ZsssTicketInfo info;
 *   int32_t err = zsss_ticket_info(png, png_len, "MyPass", 6, &info);
 *   if (err == ZSSS_OK) {
 *       printf("Event: %.*s\n", (int)info.event_id_len, info.event_id);
 *       printf("Seat: %.*s\n", (int)info.seat_len, info.seat);
 *       zsss_ticket_info_free(&info);
 *   }
 */
int32_t zsss_ticket_info(
    const uint8_t* png_ptr,
    size_t png_len,
    const uint8_t* password_ptr,
    size_t password_len,
    ZsssTicketInfo* out_info
);

/**
 * Free memory allocated in a ZsssTicketInfo struct.
 *
 * @param info Pointer to ZsssTicketInfo to free
 */
void zsss_ticket_info_free(ZsssTicketInfo* info);

/**
 * Get image ticket capacity.
 *
 * @param png_ptr Pointer to PNG image data
 * @param png_len Length of PNG data
 * @param bytes_per_ticket Output: max bytes per ticket layer (may be NULL)
 * @return Number of ticket layers (max 256)
 *
 * Example:
 *   size_t bytes_per_ticket;
 *   int32_t layers = zsss_ticket_capacity(png, png_len, &bytes_per_ticket);
 *   printf("Can hold %d tickets, %zu bytes each\n", layers, bytes_per_ticket);
 */
int32_t zsss_ticket_capacity(
    const uint8_t* png_ptr,
    size_t png_len,
    size_t* bytes_per_ticket
);

#ifdef __cplusplus
}
#endif

#endif /* ZSSS_H */
