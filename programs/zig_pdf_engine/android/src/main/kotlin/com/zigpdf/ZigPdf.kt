package com.zigpdf

import android.graphics.Bitmap
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.Closeable
import java.nio.ByteBuffer

/**
 * Kotlin-idiomatic PDF renderer powered by Zig.
 *
 * Uses coroutines for async rendering and provides a clean Kotlin API.
 *
 * Usage:
 * ```kotlin
 * ZigPdf.create().use { renderer ->
 *     renderer.dpi = 300f
 *     renderer.quality = RenderQuality.HIGH
 *
 *     renderer.openDocument("/path/to/file.pdf").use { doc ->
 *         val bitmap = doc.renderPageAsync(0)
 *         imageView.setImageBitmap(bitmap)
 *     }
 * }
 * ```
 */
class ZigPdf private constructor(private var handle: Long) : Closeable {

    companion object {
        init {
            System.loadLibrary("pdf_renderer")
        }

        /**
         * Create a new PDF renderer instance.
         */
        fun create(): ZigPdf {
            val handle = nativeCreate()
            if (handle == 0L) {
                throw PdfException("Failed to create PDF renderer")
            }
            return ZigPdf(handle)
        }

        /**
         * Get the native library version.
         */
        val version: String
            get() = nativeGetVersion()

        /**
         * Calculate bitmap size for a page at given DPI.
         */
        fun calculateBitmapSize(pageWidth: Float, pageHeight: Float, dpi: Float): Pair<Int, Int> {
            val result = IntArray(2)
            nativeCalculateBitmapSize(pageWidth, pageHeight, dpi, result)
            return Pair(result[0], result[1])
        }

        @JvmStatic private external fun nativeCreate(): Long
        @JvmStatic private external fun nativeGetVersion(): String
        @JvmStatic private external fun nativeCalculateBitmapSize(
            pageWidth: Float, pageHeight: Float, dpi: Float, outSize: IntArray
        )
    }

    /**
     * Rendering DPI (dots per inch). Default is 150.
     */
    var dpi: Float = 150f
        set(value) {
            checkNotClosed()
            nativeSetDpi(handle, value)
            field = value
        }

    /**
     * Render quality setting.
     */
    var quality: RenderQuality = RenderQuality.NORMAL
        set(value) {
            checkNotClosed()
            nativeSetQuality(handle, value.value)
            field = value
        }

    /**
     * Background color (ARGB).
     */
    var backgroundColor: Int = 0xFFFFFFFF.toInt()
        set(value) {
            checkNotClosed()
            val a = (value shr 24) and 0xFF
            val r = (value shr 16) and 0xFF
            val g = (value shr 8) and 0xFF
            val b = value and 0xFF
            nativeSetBackground(handle, r, g, b, a)
            field = value
        }

    private var closed = false

    /**
     * Open a PDF document.
     */
    fun openDocument(path: String): PdfDocument {
        checkNotClosed()
        val docHandle = nativeDocumentOpen(path)
        if (docHandle == 0L) {
            throw PdfException("Failed to open PDF: $path")
        }
        return PdfDocument(this, docHandle)
    }

    /**
     * Render raw PDF content stream.
     */
    fun renderContent(content: ByteArray, pageWidth: Float, pageHeight: Float): RenderResult {
        checkNotClosed()
        val resultHandle = nativeRenderContent(handle, content, content.size, pageWidth, pageHeight)
        if (resultHandle == 0L) {
            throw PdfException("Failed to render content")
        }
        return RenderResult(resultHandle)
    }

    /**
     * Create an empty bitmap.
     */
    fun createBitmap(width: Int, height: Int): RenderResult {
        checkNotClosed()
        val resultHandle = nativeBitmapCreate(width, height)
        if (resultHandle == 0L) {
            throw PdfException("Failed to create bitmap")
        }
        return RenderResult(resultHandle)
    }

    override fun close() {
        if (!closed && handle != 0L) {
            nativeDestroy(handle)
            handle = 0
            closed = true
        }
    }

    private fun checkNotClosed() {
        if (closed) throw IllegalStateException("ZigPdf has been closed")
    }

    private external fun nativeDestroy(handle: Long)
    private external fun nativeSetDpi(handle: Long, dpi: Float)
    private external fun nativeSetQuality(handle: Long, quality: Int)
    private external fun nativeSetBackground(handle: Long, r: Int, g: Int, b: Int, a: Int)
    private external fun nativeRenderContent(
        handle: Long, content: ByteArray, contentLen: Int, pageWidth: Float, pageHeight: Float
    ): Long
    private external fun nativeDocumentOpen(path: String): Long
    private external fun nativeBitmapCreate(width: Int, height: Int): Long

    /**
     * PDF Document wrapper.
     */
    inner class PdfDocument internal constructor(
        private val renderer: ZigPdf,
        private var handle: Long
    ) : Closeable {

        private var closed = false

        /** Number of pages in the document. */
        val pageCount: Int
            get() {
                checkNotClosed()
                return nativeDocumentGetPageCount(handle)
            }

        /** PDF version string. */
        val version: String
            get() {
                checkNotClosed()
                return nativeDocumentGetVersion(handle)
            }

        /** File size in bytes. */
        val fileSize: Long
            get() {
                checkNotClosed()
                return nativeDocumentGetFileSize(handle)
            }

        /** Whether the document is encrypted. */
        val isEncrypted: Boolean
            get() {
                checkNotClosed()
                return nativeDocumentIsEncrypted(handle)
            }

        /**
         * Render a page synchronously.
         */
        fun renderPage(pageIndex: Int): RenderResult {
            checkNotClosed()
            validatePageIndex(pageIndex)
            val resultHandle = nativeDocumentRenderPage(handle, renderer.handle, pageIndex)
            if (resultHandle == 0L) {
                throw PdfException("Failed to render page $pageIndex")
            }
            return RenderResult(resultHandle)
        }

        /**
         * Render a page asynchronously and return an Android Bitmap.
         */
        suspend fun renderPageAsync(pageIndex: Int): Bitmap = withContext(Dispatchers.Default) {
            renderPage(pageIndex).use { result ->
                result.toBitmap()
            }
        }

        /**
         * Render all pages asynchronously.
         */
        suspend fun renderAllPagesAsync(): List<Bitmap> = withContext(Dispatchers.Default) {
            (0 until pageCount).map { renderPageAsync(it) }
        }

        override fun close() {
            if (!closed && handle != 0L) {
                nativeDocumentClose(handle)
                handle = 0
                closed = true
            }
        }

        private fun checkNotClosed() {
            if (closed) throw IllegalStateException("PdfDocument has been closed")
        }

        private fun validatePageIndex(index: Int) {
            if (index < 0 || index >= pageCount) {
                throw IndexOutOfBoundsException("Page index $index out of range [0, $pageCount)")
            }
        }

        private external fun nativeDocumentGetPageCount(handle: Long): Int
        private external fun nativeDocumentGetVersion(handle: Long): String
        private external fun nativeDocumentGetFileSize(handle: Long): Long
        private external fun nativeDocumentIsEncrypted(handle: Long): Boolean
        private external fun nativeDocumentRenderPage(docHandle: Long, rendererHandle: Long, pageIndex: Int): Long
        private external fun nativeDocumentClose(handle: Long)
    }

    /**
     * Render result containing bitmap data.
     */
    class RenderResult internal constructor(private var handle: Long) : Closeable {

        private var closed = false

        val width: Int get() = checkNotClosed().let { nativeResultGetWidth(handle) }
        val height: Int get() = checkNotClosed().let { nativeResultGetHeight(handle) }
        val stride: Int get() = checkNotClosed().let { nativeResultGetStride(handle) }
        val size: Long get() = checkNotClosed().let { nativeResultGetSize(handle) }

        /**
         * Get direct ByteBuffer to pixel data (valid only while RenderResult is open).
         */
        val pixelBuffer: ByteBuffer
            get() {
                checkNotClosed()
                return nativeResultGetPixelBuffer(handle)
                    ?: throw PdfException("Failed to get pixel buffer")
            }

        /**
         * Copy pixels to a new byte array.
         */
        fun getPixels(): ByteArray {
            checkNotClosed()
            val pixels = ByteArray(size.toInt())
            nativeResultCopyPixels(handle, pixels)
            return pixels
        }

        /**
         * Convert to Android Bitmap.
         */
        fun toBitmap(): Bitmap {
            checkNotClosed()
            val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
            nativeResultCopyToBitmap(handle, bitmap)
            return bitmap
        }

        /**
         * Clear to solid color.
         */
        fun clear(r: Int, g: Int, b: Int, a: Int = 255) {
            checkNotClosed()
            nativeBitmapClear(handle, r, g, b, a)
        }

        /**
         * Clear to Android color.
         */
        fun clear(color: Int) {
            val a = (color shr 24) and 0xFF
            val r = (color shr 16) and 0xFF
            val g = (color shr 8) and 0xFF
            val b = color and 0xFF
            clear(r, g, b, a)
        }

        /**
         * Write to PPM file (debugging).
         */
        fun writePpm(path: String): Boolean {
            checkNotClosed()
            return nativeBitmapWritePpm(handle, path)
        }

        override fun close() {
            if (!closed && handle != 0L) {
                nativeResultFree(handle)
                handle = 0
                closed = true
            }
        }

        private fun checkNotClosed() {
            if (closed) throw IllegalStateException("RenderResult has been closed")
        }

        private external fun nativeResultGetWidth(handle: Long): Int
        private external fun nativeResultGetHeight(handle: Long): Int
        private external fun nativeResultGetStride(handle: Long): Int
        private external fun nativeResultGetSize(handle: Long): Long
        private external fun nativeResultGetPixelBuffer(handle: Long): ByteBuffer?
        private external fun nativeResultCopyPixels(handle: Long, dest: ByteArray)
        private external fun nativeResultCopyToBitmap(handle: Long, bitmap: Bitmap)
        private external fun nativeResultFree(handle: Long)
        private external fun nativeBitmapClear(handle: Long, r: Int, g: Int, b: Int, a: Int)
        private external fun nativeBitmapWritePpm(handle: Long, path: String): Boolean
    }

    /**
     * Render quality settings.
     */
    enum class RenderQuality(val value: Int) {
        DRAFT(0),
        NORMAL(1),
        HIGH(2)
    }

    /**
     * PDF-related exceptions.
     */
    class PdfException(message: String, cause: Throwable? = null) : RuntimeException(message, cause)
}

/**
 * Extension function for easy inline use.
 */
inline fun <T> ZigPdf.useDocument(path: String, block: (ZigPdf.PdfDocument) -> T): T {
    return openDocument(path).use(block)
}
