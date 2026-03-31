/**
 * JNI Bridge for Zig PDF Renderer
 *
 * Connects Java/Kotlin code to the native Zig PDF rendering library.
 * All native methods from PdfRenderer.java are implemented here.
 */

#include <jni.h>
#include <stdlib.h>
#include <string.h>
#include <android/bitmap.h>

// Forward declarations for Zig FFI functions
// These are implemented in libpdf_renderer.so

// Renderer API
extern void* pdf_renderer_create(void);
extern void pdf_renderer_destroy(void* handle);
extern void pdf_renderer_set_dpi(void* handle, float dpi);
extern void pdf_renderer_set_quality(void* handle, unsigned int quality);
extern void pdf_renderer_set_background(void* handle, unsigned char r, unsigned char g,
                                         unsigned char b, unsigned char a);
extern void* pdf_renderer_render_content(void* handle, const unsigned char* content,
                                          size_t content_len, float page_width, float page_height);

// Render result API
extern const unsigned char* pdf_render_result_get_pixels(void* handle);
extern unsigned int pdf_render_result_get_width(void* handle);
extern unsigned int pdf_render_result_get_height(void* handle);
extern unsigned int pdf_render_result_get_stride(void* handle);
extern size_t pdf_render_result_get_size(void* handle);
extern void pdf_render_result_free(void* handle);

// Document API
extern void* pdf_document_open(const char* path);
extern void pdf_document_close(void* handle);
extern unsigned int pdf_document_get_page_count(void* handle);
extern const char* pdf_document_get_version(void* handle);
extern size_t pdf_document_get_file_size(void* handle);
extern int pdf_document_is_encrypted(void* handle);
extern void* pdf_document_render_page(void* doc_handle, void* renderer_handle,
                                       unsigned int page_index);

// Bitmap API
extern void* pdf_bitmap_create(unsigned int width, unsigned int height);
extern void pdf_bitmap_clear(void* handle, unsigned char r, unsigned char g,
                              unsigned char b, unsigned char a);
extern unsigned char* pdf_bitmap_get_pixels_mut(void* handle);
extern int pdf_bitmap_write_ppm(void* handle, const char* path);

// Utility API
extern const char* pdf_renderer_version(void);
extern void pdf_calculate_bitmap_size(float page_width, float page_height, float dpi,
                                       unsigned int* out_width, unsigned int* out_height);


// =============================================================================
// PdfRenderer native methods
// =============================================================================

JNIEXPORT jlong JNICALL
Java_com_zigpdf_PdfRenderer_nativeCreate(JNIEnv* env, jclass cls) {
    return (jlong)(intptr_t)pdf_renderer_create();
}

JNIEXPORT void JNICALL
Java_com_zigpdf_PdfRenderer_nativeDestroy(JNIEnv* env, jclass cls, jlong handle) {
    pdf_renderer_destroy((void*)(intptr_t)handle);
}

JNIEXPORT void JNICALL
Java_com_zigpdf_PdfRenderer_nativeSetDpi(JNIEnv* env, jclass cls, jlong handle, jfloat dpi) {
    pdf_renderer_set_dpi((void*)(intptr_t)handle, dpi);
}

JNIEXPORT void JNICALL
Java_com_zigpdf_PdfRenderer_nativeSetQuality(JNIEnv* env, jclass cls, jlong handle, jint quality) {
    pdf_renderer_set_quality((void*)(intptr_t)handle, (unsigned int)quality);
}

JNIEXPORT void JNICALL
Java_com_zigpdf_PdfRenderer_nativeSetBackground(JNIEnv* env, jclass cls, jlong handle,
                                                  jint r, jint g, jint b, jint a) {
    pdf_renderer_set_background((void*)(intptr_t)handle,
        (unsigned char)r, (unsigned char)g, (unsigned char)b, (unsigned char)a);
}

JNIEXPORT jlong JNICALL
Java_com_zigpdf_PdfRenderer_nativeRenderContent(JNIEnv* env, jclass cls, jlong handle,
                                                  jbyteArray content, jint contentLen,
                                                  jfloat pageWidth, jfloat pageHeight) {
    jbyte* contentData = (*env)->GetByteArrayElements(env, content, NULL);
    if (contentData == NULL) {
        return 0;
    }

    void* result = pdf_renderer_render_content(
        (void*)(intptr_t)handle,
        (const unsigned char*)contentData,
        (size_t)contentLen,
        pageWidth,
        pageHeight
    );

    (*env)->ReleaseByteArrayElements(env, content, contentData, JNI_ABORT);

    return (jlong)(intptr_t)result;
}

JNIEXPORT jlong JNICALL
Java_com_zigpdf_PdfRenderer_nativeDocumentOpen(JNIEnv* env, jclass cls, jstring path) {
    const char* pathStr = (*env)->GetStringUTFChars(env, path, NULL);
    if (pathStr == NULL) {
        return 0;
    }

    void* handle = pdf_document_open(pathStr);

    (*env)->ReleaseStringUTFChars(env, path, pathStr);

    return (jlong)(intptr_t)handle;
}

JNIEXPORT jlong JNICALL
Java_com_zigpdf_PdfRenderer_nativeBitmapCreate(JNIEnv* env, jclass cls, jint width, jint height) {
    return (jlong)(intptr_t)pdf_bitmap_create((unsigned int)width, (unsigned int)height);
}

JNIEXPORT void JNICALL
Java_com_zigpdf_PdfRenderer_nativeCalculateBitmapSize(JNIEnv* env, jclass cls,
                                                        jfloat pageWidth, jfloat pageHeight,
                                                        jfloat dpi, jintArray outSize) {
    unsigned int width, height;
    pdf_calculate_bitmap_size(pageWidth, pageHeight, dpi, &width, &height);

    jint* out = (*env)->GetIntArrayElements(env, outSize, NULL);
    if (out != NULL) {
        out[0] = (jint)width;
        out[1] = (jint)height;
        (*env)->ReleaseIntArrayElements(env, outSize, out, 0);
    }
}

JNIEXPORT jstring JNICALL
Java_com_zigpdf_PdfRenderer_nativeGetVersion(JNIEnv* env, jclass cls) {
    const char* version = pdf_renderer_version();
    return (*env)->NewStringUTF(env, version);
}


// =============================================================================
// PdfDocument native methods
// =============================================================================

JNIEXPORT jint JNICALL
Java_com_zigpdf_PdfRenderer_00024PdfDocument_nativeDocumentGetPageCount(JNIEnv* env, jclass cls,
                                                                          jlong handle) {
    return (jint)pdf_document_get_page_count((void*)(intptr_t)handle);
}

JNIEXPORT jstring JNICALL
Java_com_zigpdf_PdfRenderer_00024PdfDocument_nativeDocumentGetVersion(JNIEnv* env, jclass cls,
                                                                        jlong handle) {
    const char* version = pdf_document_get_version((void*)(intptr_t)handle);
    return (*env)->NewStringUTF(env, version);
}

JNIEXPORT jlong JNICALL
Java_com_zigpdf_PdfRenderer_00024PdfDocument_nativeDocumentGetFileSize(JNIEnv* env, jclass cls,
                                                                         jlong handle) {
    return (jlong)pdf_document_get_file_size((void*)(intptr_t)handle);
}

JNIEXPORT jboolean JNICALL
Java_com_zigpdf_PdfRenderer_00024PdfDocument_nativeDocumentIsEncrypted(JNIEnv* env, jclass cls,
                                                                         jlong handle) {
    return pdf_document_is_encrypted((void*)(intptr_t)handle) ? JNI_TRUE : JNI_FALSE;
}

JNIEXPORT jlong JNICALL
Java_com_zigpdf_PdfRenderer_00024PdfDocument_nativeDocumentRenderPage(JNIEnv* env, jclass cls,
                                                                        jlong docHandle,
                                                                        jlong rendererHandle,
                                                                        jint pageIndex) {
    return (jlong)(intptr_t)pdf_document_render_page(
        (void*)(intptr_t)docHandle,
        (void*)(intptr_t)rendererHandle,
        (unsigned int)pageIndex
    );
}

JNIEXPORT void JNICALL
Java_com_zigpdf_PdfRenderer_00024PdfDocument_nativeDocumentClose(JNIEnv* env, jclass cls,
                                                                   jlong handle) {
    pdf_document_close((void*)(intptr_t)handle);
}


// =============================================================================
// RenderResult native methods
// =============================================================================

JNIEXPORT jint JNICALL
Java_com_zigpdf_PdfRenderer_00024RenderResult_nativeResultGetWidth(JNIEnv* env, jclass cls,
                                                                     jlong handle) {
    return (jint)pdf_render_result_get_width((void*)(intptr_t)handle);
}

JNIEXPORT jint JNICALL
Java_com_zigpdf_PdfRenderer_00024RenderResult_nativeResultGetHeight(JNIEnv* env, jclass cls,
                                                                      jlong handle) {
    return (jint)pdf_render_result_get_height((void*)(intptr_t)handle);
}

JNIEXPORT jint JNICALL
Java_com_zigpdf_PdfRenderer_00024RenderResult_nativeResultGetStride(JNIEnv* env, jclass cls,
                                                                      jlong handle) {
    return (jint)pdf_render_result_get_stride((void*)(intptr_t)handle);
}

JNIEXPORT jlong JNICALL
Java_com_zigpdf_PdfRenderer_00024RenderResult_nativeResultGetSize(JNIEnv* env, jclass cls,
                                                                    jlong handle) {
    return (jlong)pdf_render_result_get_size((void*)(intptr_t)handle);
}

JNIEXPORT jobject JNICALL
Java_com_zigpdf_PdfRenderer_00024RenderResult_nativeResultGetPixelBuffer(JNIEnv* env, jclass cls,
                                                                           jlong handle) {
    const unsigned char* pixels = pdf_render_result_get_pixels((void*)(intptr_t)handle);
    size_t size = pdf_render_result_get_size((void*)(intptr_t)handle);

    if (pixels == NULL || size == 0) {
        return NULL;
    }

    // Create a direct ByteBuffer pointing to the native pixel data
    return (*env)->NewDirectByteBuffer(env, (void*)pixels, (jlong)size);
}

JNIEXPORT void JNICALL
Java_com_zigpdf_PdfRenderer_00024RenderResult_nativeResultCopyPixels(JNIEnv* env, jclass cls,
                                                                       jlong handle,
                                                                       jbyteArray dest) {
    const unsigned char* pixels = pdf_render_result_get_pixels((void*)(intptr_t)handle);
    size_t size = pdf_render_result_get_size((void*)(intptr_t)handle);

    if (pixels == NULL || size == 0) {
        return;
    }

    jsize destLen = (*env)->GetArrayLength(env, dest);
    size_t copySize = (size_t)destLen < size ? (size_t)destLen : size;

    (*env)->SetByteArrayRegion(env, dest, 0, (jsize)copySize, (const jbyte*)pixels);
}

JNIEXPORT void JNICALL
Java_com_zigpdf_PdfRenderer_00024RenderResult_nativeResultCopyToBitmap(JNIEnv* env, jclass cls,
                                                                         jlong handle,
                                                                         jobject bitmap) {
    const unsigned char* pixels = pdf_render_result_get_pixels((void*)(intptr_t)handle);
    unsigned int width = pdf_render_result_get_width((void*)(intptr_t)handle);
    unsigned int height = pdf_render_result_get_height((void*)(intptr_t)handle);

    if (pixels == NULL) {
        return;
    }

    // Lock the bitmap for writing
    void* bitmapPixels;
    int ret = AndroidBitmap_lockPixels(env, bitmap, &bitmapPixels);
    if (ret != ANDROID_BITMAP_RESULT_SUCCESS) {
        return;
    }

    // Get bitmap info
    AndroidBitmapInfo info;
    AndroidBitmap_getInfo(env, bitmap, &info);

    // Copy with RGBA -> ARGB swizzle
    // Native format: RGBA (R at byte 0)
    // Android ARGB_8888 format: ARGB (stored as BGRA in memory on little-endian)
    unsigned int* dest = (unsigned int*)bitmapPixels;
    size_t pixelCount = (size_t)width * height;

    for (size_t i = 0; i < pixelCount; i++) {
        unsigned char r = pixels[i * 4 + 0];
        unsigned char g = pixels[i * 4 + 1];
        unsigned char b = pixels[i * 4 + 2];
        unsigned char a = pixels[i * 4 + 3];
        // Android stores as ARGB in big-endian order, which is BGRA in memory (little-endian)
        // We need: 0xAARRGGBB
        dest[i] = ((unsigned int)a << 24) | ((unsigned int)r << 16) |
                  ((unsigned int)g << 8) | (unsigned int)b;
    }

    AndroidBitmap_unlockPixels(env, bitmap);
}

JNIEXPORT void JNICALL
Java_com_zigpdf_PdfRenderer_00024RenderResult_nativeResultFree(JNIEnv* env, jclass cls,
                                                                 jlong handle) {
    pdf_render_result_free((void*)(intptr_t)handle);
}

JNIEXPORT void JNICALL
Java_com_zigpdf_PdfRenderer_00024RenderResult_nativeBitmapClear(JNIEnv* env, jclass cls,
                                                                  jlong handle,
                                                                  jint r, jint g, jint b, jint a) {
    pdf_bitmap_clear((void*)(intptr_t)handle,
        (unsigned char)r, (unsigned char)g, (unsigned char)b, (unsigned char)a);
}

JNIEXPORT jboolean JNICALL
Java_com_zigpdf_PdfRenderer_00024RenderResult_nativeBitmapWritePpm(JNIEnv* env, jclass cls,
                                                                     jlong handle, jstring path) {
    const char* pathStr = (*env)->GetStringUTFChars(env, path, NULL);
    if (pathStr == NULL) {
        return JNI_FALSE;
    }

    int result = pdf_bitmap_write_ppm((void*)(intptr_t)handle, pathStr);

    (*env)->ReleaseStringUTFChars(env, path, pathStr);

    return result ? JNI_TRUE : JNI_FALSE;
}
