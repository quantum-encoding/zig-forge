//! Build script for zigqr-sys
//!
//! Handles platform-specific library linking and build configuration.

use std::env;
use std::path::PathBuf;

fn main() {
    let target_os = env::var("CARGO_CFG_TARGET_OS").unwrap_or_default();
    let target_arch = env::var("CARGO_CFG_TARGET_ARCH").unwrap_or_default();

    let manifest_dir = PathBuf::from(env::var("CARGO_MANIFEST_DIR").unwrap());
    let lib_dir = manifest_dir.join("lib");

    // Platform-specific library name
    let lib_name = match (target_os.as_str(), target_arch.as_str()) {
        ("macos", "aarch64") => "zigqr_macos-arm64",
        ("macos", "x86_64") => "zigqr_macos-x86_64",
        ("linux", "x86_64") => "zigqr_linux-x86_64",
        ("windows", "x86_64") => "zigqr_windows-x86_64",
        ("ios", "aarch64") => "zigqr_ios-arm64",
        ("android", "aarch64") => "zigqr_android-arm64",
        ("android", "arm") => "zigqr_android-arm32",
        _ => "zigqr", // Default native library
    };

    // Check for pre-built library
    let prebuilt_exists = lib_dir.join(format!("lib{}.a", lib_name)).exists()
        || lib_dir.join(format!("{}.lib", lib_name)).exists();

    if prebuilt_exists {
        println!("cargo:rustc-link-search=native={}", lib_dir.display());
        println!("cargo:rustc-link-lib=static={}", lib_name);
    } else {
        // Look in zig-out/lib for locally built libraries
        let zig_out_dir = manifest_dir
            .parent()
            .map(|p| p.join("zig-out").join("lib"))
            .unwrap_or_default();

        if zig_out_dir.exists() {
            println!("cargo:rustc-link-search=native={}", zig_out_dir.display());
            if zig_out_dir.join(format!("lib{}.a", lib_name)).exists() {
                println!("cargo:rustc-link-lib=static={}", lib_name);
            } else {
                println!("cargo:rustc-link-lib=static=zigqr");
            }
        } else {
            // Fallback: expect library in system paths
            println!("cargo:rustc-link-lib=static=zigqr");
        }
    }

    // Link system libraries
    match target_os.as_str() {
        "macos" | "ios" => {
            println!("cargo:rustc-link-lib=framework=Security");
        }
        _ => {}
    }

    println!("cargo:rerun-if-changed=lib/");
    println!("cargo:rerun-if-changed=../include/zigqr.h");
}
