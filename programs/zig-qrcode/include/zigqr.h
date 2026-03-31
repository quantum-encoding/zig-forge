/**
 * @file zigqr.h
 * @brief ZigQR - High-performance QR code generator
 * @version 1.0.0
 *
 * Pure Zig implementation of ISO/IEC 18004 QR codes (versions 1-40).
 * Supports numeric, alphanumeric, and byte encoding modes with
 * error correction levels L/M/Q/H.
 *
 * Output formats: raw matrix, RGB pixels, SVG, PNG.
 *
 * Memory Management:
 * - All output buffers are allocated by the library
 * - Caller MUST free outputs with zigqr_free()
 *
 * Example:
 * @code
 * size_t len;
 * uint8_t* png = zigqr_to_png("https://example.com", 19, 1, &len);
 * if (png) {
 *     fwrite(png, 1, len, fopen("qr.png", "wb"));
 *     zigqr_free(png, len);
 * }
 * @endcode
 */

#ifndef ZIGQR_H
#define ZIGQR_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ============================================================================
 * Error Correction Levels
 * ============================================================================
 *
 * ZIGQR_EC_L = 0   ~7% recovery
 * ZIGQR_EC_M = 1   ~15% recovery (default)
 * ZIGQR_EC_Q = 2   ~25% recovery
 * ZIGQR_EC_H = 3   ~30% recovery
 */
#define ZIGQR_EC_L 0
#define ZIGQR_EC_M 1
#define ZIGQR_EC_Q 2
#define ZIGQR_EC_H 3

/* ============================================================================
 * Encoding Functions
 * ============================================================================ */

/**
 * @brief Encode data into a QR code module matrix.
 *
 * Returns a flat array of size*size bytes where 0=white, 1=black.
 * The matrix can be rendered with zigqr_render_rgb/svg/png.
 *
 * @param data       Input data bytes
 * @param data_len   Length of input data
 * @param ec_level   Error correction level (ZIGQR_EC_L/M/Q/H)
 * @param size       Pointer to receive matrix dimension (size x size)
 * @return Pointer to module matrix, or NULL on error
 *
 * @note Caller must free with zigqr_free(ptr, size * size)
 */
uint8_t* zigqr_encode(const uint8_t* data, size_t data_len, int ec_level, uint32_t* size);

/* ============================================================================
 * Rendering Functions
 * ============================================================================ */

/**
 * @brief Render QR modules to RGB pixel data.
 *
 * Output format: [width_u32_le][height_u32_le][RGB pixels...]
 *
 * @param modules     Module matrix from zigqr_encode
 * @param size        Matrix dimension
 * @param module_px   Pixels per QR module (1-16, recommended 4)
 * @param quiet_zone  Border modules (recommended 4)
 * @param output_len  Pointer to receive output length
 * @return Pointer to RGB data, or NULL on error
 */
uint8_t* zigqr_render_rgb(const uint8_t* modules, uint32_t size, uint32_t module_px, uint32_t quiet_zone, size_t* output_len);

/**
 * @brief Render QR modules to SVG string.
 *
 * @param modules     Module matrix from zigqr_encode
 * @param size        Matrix dimension
 * @param module_px   Module size in SVG units
 * @param quiet_zone  Border modules
 * @param output_len  Pointer to receive SVG string length
 * @return Pointer to SVG string, or NULL on error
 */
uint8_t* zigqr_render_svg(const uint8_t* modules, uint32_t size, uint32_t module_px, uint32_t quiet_zone, size_t* output_len);

/**
 * @brief Render QR modules to PNG image.
 *
 * @param modules     Module matrix from zigqr_encode
 * @param size        Matrix dimension
 * @param module_px   Pixels per QR module
 * @param quiet_zone  Border modules
 * @param output_len  Pointer to receive PNG length
 * @return Pointer to PNG bytes, or NULL on error
 */
uint8_t* zigqr_render_png(const uint8_t* modules, uint32_t size, uint32_t module_px, uint32_t quiet_zone, size_t* output_len);

/* ============================================================================
 * One-Shot Functions
 * ============================================================================ */

/**
 * @brief Encode data and render directly to SVG.
 *
 * @param data       Input data bytes
 * @param data_len   Length of input data
 * @param ec_level   Error correction level
 * @param output_len Pointer to receive SVG string length
 * @return Pointer to SVG string, or NULL on error
 */
uint8_t* zigqr_to_svg(const uint8_t* data, size_t data_len, int ec_level, size_t* output_len);

/**
 * @brief Encode data and render directly to PNG.
 *
 * @param data       Input data bytes
 * @param data_len   Length of input data
 * @param ec_level   Error correction level
 * @param output_len Pointer to receive PNG length
 * @return Pointer to PNG bytes, or NULL on error
 */
uint8_t* zigqr_to_png(const uint8_t* data, size_t data_len, int ec_level, size_t* output_len);

/* ============================================================================
 * Memory & Utility
 * ============================================================================ */

/**
 * @brief Free a buffer allocated by zigqr functions.
 *
 * @param ptr  Pointer to free (may be NULL)
 * @param len  Length of the buffer
 */
void zigqr_free(uint8_t* ptr, size_t len);

/**
 * @brief Get library version string.
 * @return Null-terminated version string
 */
const char* zigqr_version(void);

/**
 * @brief Get last error message.
 * @return Null-terminated error string
 */
const char* zigqr_get_error(void);

#ifdef __cplusplus
}
#endif

#endif /* ZIGQR_H */
