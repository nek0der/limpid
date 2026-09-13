//! Stable C ABI boundary between Limpid's Swift application and Rust core.

/// Version of the ABI exposed by this library.
pub const ABI_VERSION: u32 = 1;

/// Returns the ABI version understood by this library.
///
/// `no_mangle` is required so Swift can link this symbol through the C header.
/// The function accepts no pointers and performs no unsafe operations.
#[unsafe(no_mangle)]
pub extern "C" fn limpid_rust_abi_version() -> u32 {
    ABI_VERSION
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn exported_abi_version_matches_constant() {
        assert_eq!(limpid_rust_abi_version(), ABI_VERSION);
    }
}
