//! Regenerates the committed C header from the exported items in this crate.
//!
//! The header lives in the source tree because Xcode and `make rust-header`
//! both read it from there. A generation failure is a build failure: a stale
//! header would otherwise pass the drift check in CI while no longer matching
//! the exported symbols. The header itself is a rerun trigger so restoring an
//! older copy with `git checkout` regenerates it on the next build instead of
//! letting a local `make rust-header` compare an outdated file.

fn main() {
    let crate_dir =
        std::env::var("CARGO_MANIFEST_DIR").expect("CARGO_MANIFEST_DIR is set by Cargo");
    let header = std::path::Path::new(&crate_dir).join("include/limpid_rust_bridge.h");
    let bindings =
        cbindgen::generate(&crate_dir).expect("cbindgen must generate the bridge header");
    bindings.write_to_file(&header);
    println!("cargo:rerun-if-changed=src");
    println!("cargo:rerun-if-changed=cbindgen.toml");
    println!("cargo:rerun-if-changed=include/limpid_rust_bridge.h");
}
