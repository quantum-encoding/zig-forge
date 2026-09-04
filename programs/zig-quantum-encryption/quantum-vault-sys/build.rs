//! Build script for quantum-vault-sys
//!
//! Locates the Zig static library for the target, links it and the platform
//! libraries it needs, and refuses to link an archive built from older source
//! than the one this crate claims to bind.
//!
//! Library search order:
//!   1. `<crate>/lib/` — a local drop-in (gitignored; not part of the repo)
//!   2. `<crate>/../zig-out/lib/` — the output of `zig build` / `zig build cross`
//!   3. the system search path (last resort; `cargo:rustc-link-lib` only)
//!
//! In each directory both the historical `quantum_vault[_<target>]` and the
//! current `quantum_crypto[_<target>]` artifact names are accepted.
//!
//! Freshness guard: `src/quantum_vault_ffi.zig` declares
//! `pub const VERSION_STRING = "quantum-vault-pqc-X.Y.Z";` and `qv_version()`
//! returns it, so every archive built from that source embeds the literal. The
//! script reads the declared string from the Zig source when it is present
//! (in-repo builds) and falls back to `EXPECTED_QV_VERSION` otherwise, scans
//! the chosen archive for it, and fails the build if it is absent. The value is
//! also exported as the `QV_EXPECTED_VERSION` env var so the crate's tests can
//! compare it with the live `qv_version()`.

use std::env;
use std::fs;
use std::path::{Path, PathBuf};

/// Must match `VERSION_STRING` in `../src/quantum_vault_ffi.zig`. When the Zig
/// source is available it is authoritative and a mismatch here is an error.
const EXPECTED_QV_VERSION: &str = "quantum-vault-pqc-1.1.0";

fn main() {
    let target_os = env::var("CARGO_CFG_TARGET_OS").unwrap_or_default();
    let target_arch = env::var("CARGO_CFG_TARGET_ARCH").unwrap_or_default();

    let manifest_dir = PathBuf::from(env::var("CARGO_MANIFEST_DIR").unwrap());
    let lib_dir = manifest_dir.join("lib");
    let zig_out_dir = manifest_dir
        .parent()
        .map(|p| p.join("zig-out").join("lib"))
        .unwrap_or_default();
    let zig_ffi_source = manifest_dir
        .parent()
        .map(|p| p.join("src").join("quantum_vault_ffi.zig"))
        .unwrap_or_default();

    println!("cargo:rerun-if-changed=build.rs");
    println!("cargo:rerun-if-changed=lib/");
    println!("cargo:rerun-if-changed=include/quantum_vault.h");
    println!("cargo:rerun-if-changed={}", zig_out_dir.display());
    println!("cargo:rerun-if-changed={}", zig_ffi_source.display());

    let expected_version = expected_version(&zig_ffi_source);
    println!("cargo:rustc-env=QV_EXPECTED_VERSION={}", expected_version);

    let target_suffix = match (target_os.as_str(), target_arch.as_str()) {
        ("macos", "aarch64") => Some("macos-arm64"),
        ("macos", "x86_64") => Some("macos-x86_64"),
        ("linux", "x86_64") => Some("linux-x86_64"),
        ("windows", "x86_64") => Some("windows-x86_64"),
        ("ios", "aarch64") => Some("ios-arm64"),
        ("android", "aarch64") => Some("android-arm64"),
        ("android", "arm") => Some("android-arm32"),
        _ => None,
    };

    // Candidate link names, most specific first.
    let mut candidates: Vec<String> = Vec::new();
    if let Some(suffix) = target_suffix {
        candidates.push(format!("quantum_vault_{}", suffix));
        candidates.push(format!("quantum_crypto_{}", suffix));
    }
    candidates.push("quantum_vault".to_string());
    candidates.push("quantum_crypto".to_string());

    let found = [lib_dir.as_path(), zig_out_dir.as_path()]
        .iter()
        .filter(|dir| dir.exists())
        .find_map(|dir| {
            candidates
                .iter()
                .find_map(|name| archive_path(dir, name).map(|path| (dir.to_path_buf(), name.clone(), path)))
        });

    match found {
        Some((dir, name, path)) => {
            check_archive_version(&path, &expected_version);
            println!("cargo:rustc-link-search=native={}", dir.display());
            println!("cargo:rustc-link-lib=static={}", name);
            println!("cargo:warning=quantum-vault-sys: linking {} ({})", path.display(), expected_version);
        }
        None => {
            // Nothing local: defer to the system search path. The version guard
            // cannot run here, so say so instead of pretending.
            println!(
                "cargo:warning=quantum-vault-sys: no static library found in {} or {}; \
                 falling back to -lquantum_vault on the system path (version not verified). \
                 Run `zig build` (or `zig build cross`) in {} first.",
                lib_dir.display(),
                zig_out_dir.display(),
                manifest_dir.parent().unwrap_or(&manifest_dir).display()
            );
            println!("cargo:rustc-link-lib=static=quantum_vault");
        }
    }

    // Platform libraries the Zig side needs.
    match target_os.as_str() {
        "macos" | "ios" => println!("cargo:rustc-link-lib=framework=Security"),
        "windows" => println!("cargo:rustc-link-lib=bcrypt"),
        _ => {} // linux/android: getrandom syscall, nothing to link
    }
}

/// `lib<name>.a` on Unix-style toolchains, `<name>.lib` for MSVC-style output.
fn archive_path(dir: &Path, name: &str) -> Option<PathBuf> {
    let unix = dir.join(format!("lib{}.a", name));
    if unix.exists() {
        return Some(unix);
    }
    let msvc = dir.join(format!("{}.lib", name));
    if msvc.exists() {
        return Some(msvc);
    }
    None
}

/// The version string the source declares. Reads `VERSION_STRING` from the Zig
/// FFI source when it is present; otherwise the crate's own constant. If both
/// exist and disagree, the crate constant is stale — fail so it gets bumped.
fn expected_version(zig_ffi_source: &Path) -> String {
    let Ok(source) = fs::read_to_string(zig_ffi_source) else {
        return EXPECTED_QV_VERSION.to_string();
    };
    let declared = source
        .lines()
        .find_map(|line| {
            let line = line.trim();
            let rest = line.strip_prefix("pub const VERSION_STRING = \"")?;
            let end = rest.find('"')?;
            Some(rest[..end].to_string())
        })
        .unwrap_or_else(|| {
            panic!(
                "quantum-vault-sys: could not find `pub const VERSION_STRING = \"...\";` in {}",
                zig_ffi_source.display()
            )
        });
    if declared != EXPECTED_QV_VERSION {
        panic!(
            "quantum-vault-sys: EXPECTED_QV_VERSION in build.rs is \"{}\" but {} declares \"{}\". \
             Bump the build.rs constant (and the crate version) to match the Zig source.",
            EXPECTED_QV_VERSION,
            zig_ffi_source.display(),
            declared
        );
    }
    declared
}

/// Fail the build unless the archive embeds the expected `qv_version()` string.
/// A static library is a plain container of object files, so the NUL-terminated
/// literal `qv_version()` returns is present verbatim in its data section.
fn check_archive_version(archive: &Path, expected: &str) {
    let bytes = fs::read(archive)
        .unwrap_or_else(|e| panic!("quantum-vault-sys: cannot read {}: {}", archive.display(), e));
    let mut needle = expected.as_bytes().to_vec();
    needle.push(0);
    let present = bytes.windows(needle.len()).any(|w| w == needle.as_slice());
    if !present {
        let stale = find_embedded_version(&bytes).unwrap_or_else(|| "no qv_version string at all".to_string());
        panic!(
            "quantum-vault-sys: {} does not contain qv_version() == \"{}\" (found: {}). \
             The archive was built from different source than this crate binds. \
             Rebuild it with `zig build -Doptimize=ReleaseSafe` / `zig build cross` \
             and copy it into place (see docs/README.md, Output Libraries).",
            archive.display(),
            expected,
            stale
        );
    }
}

/// Best-effort: report whatever `quantum-vault-pqc-*` string the archive does carry.
fn find_embedded_version(bytes: &[u8]) -> Option<String> {
    let prefix = b"quantum-vault-pqc-";
    let start = bytes.windows(prefix.len()).position(|w| w == prefix)?;
    let tail = &bytes[start..];
    let end = tail.iter().position(|&b| b == 0).unwrap_or(tail.len().min(64));
    Some(format!("\"{}\"", String::from_utf8_lossy(&tail[..end])))
}
