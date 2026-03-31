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
 *   1. Call zsss_init() once before using other functions
 *   2. All returned buffers must be freed with zsss_free()
 *   3. Check error_code in ZsssBuffer for success/failure
 *   4. For tickets, free ZsssTicketInfo with zsss_ticket_info_free()
 */

#ifndef ZSSS_H
#define ZSSS_H

#include <stdint.h>
#include <stddef.h>

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
 * Initialize the library. Call once before using other functions.
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
 *                   (same format as zsss_split output)
 * @param shares_len Total length of shares data
 * @return ZsssBuffer containing recovered secret
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
 * @param password_ptr Password for encryption (NULL for no encryption)
 * @param password_len Length of password (ignored if password_ptr is NULL)
 * @param layer_slot Layer slot for multi-layer embedding (-1 for default, 0-255 for specific layer)
 * @return ZsssBuffer containing new PNG with embedded data
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
 * @param password_ptr Password for decryption (NULL if data wasn't encrypted)
 * @param password_len Length of password (ignored if password_ptr is NULL)
 * @param layer_slot Layer slot to extract from (-1 for default, 0-255 for specific layer)
 * @return ZsssBuffer containing extracted data
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
 * @param bytes_per_ticket Output: max bytes per ticket layer
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
