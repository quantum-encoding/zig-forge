use std::env;
use std::path::PathBuf;

fn main() {
    let manifest_dir = PathBuf::from(env::var("CARGO_MANIFEST_DIR").unwrap());
    let zig_lens_root = manifest_dir.join("..").join("..");

    // Link the zig-lens static library
    // User must build with `zig build lib` first
    let lib_dir = zig_lens_root.join("zig-out").join("lib");
    println!("cargo:rustc-link-search=native={}", lib_dir.display());
    println!("cargo:rustc-link-lib=static=zig_lens");

    // Also link libc (required by the Zig library)
    println!("cargo:rustc-link-lib=c");

    // Rebuild if header changes
    let header = zig_lens_root.join("include").join("zig_lens.h");
    println!("cargo:rerun-if-changed={}", header.display());

    // Generate Rust bindings from the C header
    let bindings = bindgen::Builder::default()
        .header(header.to_str().unwrap())
        .parse_callbacks(Box::new(bindgen::CargoCallbacks::new()))
        .allowlist_function("zig_lens_.*")
        .allowlist_type("ZigLensProgressCallback")
        .allowlist_var("ZIG_LENS_.*")
        .generate()
        .expect("Unable to generate bindings");

    let out_path = PathBuf::from(env::var("OUT_DIR").unwrap());
    bindings
        .write_to_file(out_path.join("bindings.rs"))
        .expect("Couldn't write bindings");
}
