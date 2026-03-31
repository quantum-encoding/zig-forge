# Android.mk for PDF Renderer JNI
#
# Usage with ndk-build:
#   cd android && ndk-build

LOCAL_PATH := $(call my-dir)

# =============================================================================
# Prebuilt Zig PDF Renderer library
# =============================================================================

include $(CLEAR_VARS)
LOCAL_MODULE := pdf_renderer_prebuilt

# Select correct ABI directory
ifeq ($(TARGET_ARCH_ABI),arm64-v8a)
    LOCAL_SRC_FILES := ../../../../zig-out/lib/android-arm64/libpdf_renderer.so
else ifeq ($(TARGET_ARCH_ABI),armeabi-v7a)
    LOCAL_SRC_FILES := ../../../../zig-out/lib/android-arm32/libpdf_renderer.so
else ifeq ($(TARGET_ARCH_ABI),x86_64)
    LOCAL_SRC_FILES := ../../../../zig-out/lib/android-x86_64/libpdf_renderer.so
endif

include $(PREBUILT_SHARED_LIBRARY)

# =============================================================================
# JNI Bridge library
# =============================================================================

include $(CLEAR_VARS)
LOCAL_MODULE := pdf_jni
LOCAL_SRC_FILES := pdf_jni.c
LOCAL_LDLIBS := -llog -ljnigraphics
LOCAL_SHARED_LIBRARIES := pdf_renderer_prebuilt

include $(BUILD_SHARED_LIBRARY)
