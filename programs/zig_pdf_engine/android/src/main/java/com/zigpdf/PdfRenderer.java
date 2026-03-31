package com.zigpdf;

import android.graphics.Bitmap;
import android.graphics.Bitmap.Config;
import java.nio.ByteBuffer;

/**
 * High-performance PDF renderer powered by Zig.
 *
 * Zero external dependencies, memory-mapped parsing, SIMD-accelerated where available.
 * Thread-safe: each PdfRenderer instance can be used from a single thread.
 *
 * Usage:
 *   try (PdfRenderer renderer = new PdfRenderer()) {
 *       renderer.setDpi(300);
 *       renderer.setQuality(RenderQuality.HIGH);
 *
 *       try (PdfDocument doc = renderer.openDocument("/path/to/file.pdf")) {
 *           int pageCount = doc.getPageCount();
 *
 *           try (RenderResult result = doc.renderPage(0)) {
 *               Bitmap bitmap = result.toBitmap();
 *               // Use bitmap...
 *           }
 *       }
 *   }
 */
public class PdfRenderer implements AutoCloseable {

    static {
        System.loadLibrary("pdf_renderer");
    }

    private long nativeHandle;
    private boolean closed = false;

    /**
     * Render quality settings.
     */
    public enum RenderQuality {
        DRAFT(0),    // Fast, lower quality
        NORMAL(1),   // Balanced (default)
        HIGH(2);     // Best quality, slower

        final int value;
        RenderQuality(int value) { this.value = value; }
    }

    /**
     * Create a new PDF renderer instance.
     *
     * @throws RuntimeException if native library initialization fails
     */
    public PdfRenderer() {
        nativeHandle = nativeCreate();
        if (nativeHandle == 0) {
            throw new RuntimeException("Failed to create PDF renderer");
        }
    }

    /**
     * Set rendering DPI (dots per inch).
     * Default is 150 DPI. Higher values produce larger, sharper images.
     *
     * @param dpi DPI value (typically 72-600)
     */
    public void setDpi(float dpi) {
        checkNotClosed();
        nativeSetDpi(nativeHandle, dpi);
    }

    /**
     * Set rendering quality.
     *
     * @param quality Render quality setting
     */
    public void setQuality(RenderQuality quality) {
        checkNotClosed();
        nativeSetQuality(nativeHandle, quality.value);
    }

    /**
     * Set background color for rendered pages.
     * Default is white (255, 255, 255, 255).
     *
     * @param r Red component (0-255)
     * @param g Green component (0-255)
     * @param b Blue component (0-255)
     * @param a Alpha component (0-255)
     */
    public void setBackground(int r, int g, int b, int a) {
        checkNotClosed();
        nativeSetBackground(nativeHandle, r, g, b, a);
    }

    /**
     * Set background color for rendered pages.
     *
     * @param color Android color value (ARGB)
     */
    public void setBackgroundColor(int color) {
        int a = (color >> 24) & 0xFF;
        int r = (color >> 16) & 0xFF;
        int g = (color >> 8) & 0xFF;
        int b = color & 0xFF;
        setBackground(r, g, b, a);
    }

    /**
     * Open a PDF document from file path.
     *
     * @param path Absolute path to PDF file
     * @return PdfDocument instance (must be closed when done)
     * @throws PdfException if document cannot be opened
     */
    public PdfDocument openDocument(String path) {
        checkNotClosed();
        long docHandle = nativeDocumentOpen(path);
        if (docHandle == 0) {
            throw new PdfException("Failed to open PDF: " + path);
        }
        return new PdfDocument(this, docHandle);
    }

    /**
     * Render raw PDF content stream to a bitmap.
     * This is a low-level method for rendering content streams directly.
     *
     * @param content PDF content stream bytes
     * @param pageWidth Page width in points (72 points = 1 inch)
     * @param pageHeight Page height in points
     * @return RenderResult containing the rendered bitmap
     * @throws PdfException if rendering fails
     */
    public RenderResult renderContent(byte[] content, float pageWidth, float pageHeight) {
        checkNotClosed();
        long resultHandle = nativeRenderContent(nativeHandle, content, content.length, pageWidth, pageHeight);
        if (resultHandle == 0) {
            throw new PdfException("Failed to render content");
        }
        return new RenderResult(resultHandle);
    }

    /**
     * Create an empty bitmap for custom drawing.
     *
     * @param width Bitmap width in pixels
     * @param height Bitmap height in pixels
     * @return RenderResult containing the empty bitmap
     * @throws PdfException if allocation fails
     */
    public RenderResult createBitmap(int width, int height) {
        checkNotClosed();
        long resultHandle = nativeBitmapCreate(width, height);
        if (resultHandle == 0) {
            throw new PdfException("Failed to create bitmap");
        }
        return new RenderResult(resultHandle);
    }

    /**
     * Calculate the required bitmap size for a page at the current DPI.
     *
     * @param pageWidth Page width in points
     * @param pageHeight Page height in points
     * @param dpi Target DPI
     * @return int array with [width, height] in pixels
     */
    public static int[] calculateBitmapSize(float pageWidth, float pageHeight, float dpi) {
        int[] result = new int[2];
        nativeCalculateBitmapSize(pageWidth, pageHeight, dpi, result);
        return result;
    }

    /**
     * Get the native library version.
     *
     * @return Version string
     */
    public static String getVersion() {
        return nativeGetVersion();
    }

    @Override
    public void close() {
        if (!closed && nativeHandle != 0) {
            nativeDestroy(nativeHandle);
            nativeHandle = 0;
            closed = true;
        }
    }

    private void checkNotClosed() {
        if (closed) {
            throw new IllegalStateException("PdfRenderer has been closed");
        }
    }

    // =========================================================================
    // Native Methods
    // =========================================================================

    private static native long nativeCreate();
    private static native void nativeDestroy(long handle);
    private static native void nativeSetDpi(long handle, float dpi);
    private static native void nativeSetQuality(long handle, int quality);
    private static native void nativeSetBackground(long handle, int r, int g, int b, int a);
    private static native long nativeRenderContent(long handle, byte[] content, int contentLen,
                                                    float pageWidth, float pageHeight);
    private static native long nativeDocumentOpen(String path);
    private static native long nativeBitmapCreate(int width, int height);
    private static native void nativeCalculateBitmapSize(float pageWidth, float pageHeight,
                                                          float dpi, int[] outSize);
    private static native String nativeGetVersion();

    // =========================================================================
    // Inner Classes
    // =========================================================================

    /**
     * Represents an open PDF document.
     */
    public static class PdfDocument implements AutoCloseable {

        private final PdfRenderer renderer;
        private long nativeHandle;
        private boolean closed = false;

        PdfDocument(PdfRenderer renderer, long handle) {
            this.renderer = renderer;
            this.nativeHandle = handle;
        }

        /**
         * Get the number of pages in the document.
         *
         * @return Page count
         */
        public int getPageCount() {
            checkNotClosed();
            return nativeDocumentGetPageCount(nativeHandle);
        }

        /**
         * Get the PDF version string.
         *
         * @return Version string (e.g., "1.4", "1.7")
         */
        public String getVersion() {
            checkNotClosed();
            return nativeDocumentGetVersion(nativeHandle);
        }

        /**
         * Get the file size in bytes.
         *
         * @return File size
         */
        public long getFileSize() {
            checkNotClosed();
            return nativeDocumentGetFileSize(nativeHandle);
        }

        /**
         * Check if the document is encrypted.
         *
         * @return true if encrypted
         */
        public boolean isEncrypted() {
            checkNotClosed();
            return nativeDocumentIsEncrypted(nativeHandle);
        }

        /**
         * Render a page from the document.
         *
         * @param pageIndex Zero-based page index
         * @return RenderResult containing the rendered page
         * @throws PdfException if rendering fails
         * @throws IndexOutOfBoundsException if page index is invalid
         */
        public RenderResult renderPage(int pageIndex) {
            checkNotClosed();
            if (pageIndex < 0 || pageIndex >= getPageCount()) {
                throw new IndexOutOfBoundsException("Page index " + pageIndex +
                    " out of range [0, " + getPageCount() + ")");
            }

            long resultHandle = nativeDocumentRenderPage(nativeHandle,
                renderer.nativeHandle, pageIndex);
            if (resultHandle == 0) {
                throw new PdfException("Failed to render page " + pageIndex);
            }
            return new RenderResult(resultHandle);
        }

        @Override
        public void close() {
            if (!closed && nativeHandle != 0) {
                nativeDocumentClose(nativeHandle);
                nativeHandle = 0;
                closed = true;
            }
        }

        private void checkNotClosed() {
            if (closed) {
                throw new IllegalStateException("PdfDocument has been closed");
            }
        }

        private static native int nativeDocumentGetPageCount(long handle);
        private static native String nativeDocumentGetVersion(long handle);
        private static native long nativeDocumentGetFileSize(long handle);
        private static native boolean nativeDocumentIsEncrypted(long handle);
        private static native long nativeDocumentRenderPage(long docHandle, long rendererHandle, int pageIndex);
        private static native void nativeDocumentClose(long handle);
    }

    /**
     * Represents a rendered page or bitmap.
     */
    public static class RenderResult implements AutoCloseable {

        private long nativeHandle;
        private boolean closed = false;

        RenderResult(long handle) {
            this.nativeHandle = handle;
        }

        /**
         * Get the width in pixels.
         *
         * @return Width
         */
        public int getWidth() {
            checkNotClosed();
            return nativeResultGetWidth(nativeHandle);
        }

        /**
         * Get the height in pixels.
         *
         * @return Height
         */
        public int getHeight() {
            checkNotClosed();
            return nativeResultGetHeight(nativeHandle);
        }

        /**
         * Get the stride (bytes per row).
         *
         * @return Stride
         */
        public int getStride() {
            checkNotClosed();
            return nativeResultGetStride(nativeHandle);
        }

        /**
         * Get the total pixel buffer size in bytes.
         *
         * @return Buffer size
         */
        public long getSize() {
            checkNotClosed();
            return nativeResultGetSize(nativeHandle);
        }

        /**
         * Get raw pixel data as a direct ByteBuffer.
         * The buffer is RGBA8888 format (4 bytes per pixel).
         *
         * WARNING: The returned buffer is only valid while this RenderResult is open.
         * Do not use it after calling close().
         *
         * @return Direct ByteBuffer pointing to pixel data
         */
        public ByteBuffer getPixelBuffer() {
            checkNotClosed();
            return nativeResultGetPixelBuffer(nativeHandle);
        }

        /**
         * Copy pixels to a byte array.
         * The array will be RGBA8888 format.
         *
         * @return New byte array containing pixel data
         */
        public byte[] getPixels() {
            checkNotClosed();
            int size = (int) getSize();
            byte[] pixels = new byte[size];
            nativeResultCopyPixels(nativeHandle, pixels);
            return pixels;
        }

        /**
         * Convert to an Android Bitmap.
         * This creates a new Bitmap and copies the pixel data.
         *
         * @return New Bitmap instance
         */
        public Bitmap toBitmap() {
            checkNotClosed();
            int width = getWidth();
            int height = getHeight();

            Bitmap bitmap = Bitmap.createBitmap(width, height, Config.ARGB_8888);
            ByteBuffer buffer = getPixelBuffer();

            // The native format is RGBA, but Android Bitmap uses ARGB
            // We need to swizzle the bytes
            int[] pixels = new int[width * height];
            for (int i = 0; i < pixels.length; i++) {
                int r = buffer.get() & 0xFF;
                int g = buffer.get() & 0xFF;
                int b = buffer.get() & 0xFF;
                int a = buffer.get() & 0xFF;
                pixels[i] = (a << 24) | (r << 16) | (g << 8) | b;
            }
            bitmap.setPixels(pixels, 0, width, 0, 0, width, height);

            return bitmap;
        }

        /**
         * Convert to an Android Bitmap efficiently (if native format matches).
         * Uses copyPixelsFromBuffer for better performance when possible.
         *
         * @return New Bitmap instance
         */
        public Bitmap toBitmapFast() {
            checkNotClosed();
            int width = getWidth();
            int height = getHeight();

            Bitmap bitmap = Bitmap.createBitmap(width, height, Config.ARGB_8888);

            // Copy with swizzle in native code for better performance
            nativeResultCopyToBitmap(nativeHandle, bitmap);

            return bitmap;
        }

        /**
         * Clear the bitmap to a solid color.
         *
         * @param r Red component (0-255)
         * @param g Green component (0-255)
         * @param b Blue component (0-255)
         * @param a Alpha component (0-255)
         */
        public void clear(int r, int g, int b, int a) {
            checkNotClosed();
            nativeBitmapClear(nativeHandle, r, g, b, a);
        }

        /**
         * Write bitmap to a PPM file (for debugging).
         *
         * @param path Output file path
         * @return true if successful
         */
        public boolean writePpm(String path) {
            checkNotClosed();
            return nativeBitmapWritePpm(nativeHandle, path);
        }

        @Override
        public void close() {
            if (!closed && nativeHandle != 0) {
                nativeResultFree(nativeHandle);
                nativeHandle = 0;
                closed = true;
            }
        }

        private void checkNotClosed() {
            if (closed) {
                throw new IllegalStateException("RenderResult has been closed");
            }
        }

        private static native int nativeResultGetWidth(long handle);
        private static native int nativeResultGetHeight(long handle);
        private static native int nativeResultGetStride(long handle);
        private static native long nativeResultGetSize(long handle);
        private static native ByteBuffer nativeResultGetPixelBuffer(long handle);
        private static native void nativeResultCopyPixels(long handle, byte[] dest);
        private static native void nativeResultCopyToBitmap(long handle, Bitmap bitmap);
        private static native void nativeResultFree(long handle);
        private static native void nativeBitmapClear(long handle, int r, int g, int b, int a);
        private static native boolean nativeBitmapWritePpm(long handle, String path);
    }

    /**
     * Exception thrown for PDF-related errors.
     */
    public static class PdfException extends RuntimeException {
        public PdfException(String message) {
            super(message);
        }

        public PdfException(String message, Throwable cause) {
            super(message, cause);
        }
    }
}
