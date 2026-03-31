# CMakeLists.txt for PDF Renderer JNI
#
# Modern CMake build for Android (recommended with AGP 4.0+)
#
# In app/build.gradle.kts:
#   android {
#       externalNativeBuild {
#           cmake {
#               path = file("src/main/cpp/CMakeLists.txt")
#           }
#       }
#   }

cmake_minimum_required(VERSION 3.18)
project(pdf_renderer_jni)

# Import prebuilt Zig PDF renderer library
add_library(pdf_renderer SHARED IMPORTED)

# Set library path based on ABI
if(${ANDROID_ABI} STREQUAL "arm64-v8a")
    set(ZIG_LIB_DIR "${CMAKE_SOURCE_DIR}/../../../../../zig-out/lib/android-arm64")
elseif(${ANDROID_ABI} STREQUAL "armeabi-v7a")
    set(ZIG_LIB_DIR "${CMAKE_SOURCE_DIR}/../../../../../zig-out/lib/android-arm32")
elseif(${ANDROID_ABI} STREQUAL "x86_64")
    set(ZIG_LIB_DIR "${CMAKE_SOURCE_DIR}/../../../../../zig-out/lib/android-x86_64")
else()
    message(FATAL_ERROR "Unsupported ABI: ${ANDROID_ABI}")
endif()

set_target_properties(pdf_renderer PROPERTIES
    IMPORTED_LOCATION "${ZIG_LIB_DIR}/libpdf_renderer.so"
)

# Build JNI bridge library
add_library(pdf_jni SHARED
    ../jni/pdf_jni.c
)

# Link dependencies
target_link_libraries(pdf_jni
    pdf_renderer
    log
    jnigraphics
)

# Include headers (if any)
target_include_directories(pdf_jni PRIVATE
    ${CMAKE_SOURCE_DIR}/../jni
)
