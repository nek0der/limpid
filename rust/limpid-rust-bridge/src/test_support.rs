//! This module holds what the bridge's ABI tests share for taking a body the
//! bridge handed over.

use crate::limpid_approval_bytes_free_v1;
use std::slice;

/// Copies a body an ABI call handed over and frees it once, and returns
/// `None` when the call handed over nothing. A null body must come with a
/// zero length, so a call that clears the pointer but leaves the length fails
/// here. The status and the body's shape stay with each caller: some expect a
/// body, and some read an undecodable one as none.
///
/// # Safety
///
/// `out` and `len` must be exactly what one call wrote, not yet freed.
pub(crate) unsafe fn take_bytes(out: *mut u8, len: usize) -> Option<Vec<u8>> {
    if out.is_null() {
        assert_eq!(len, 0, "a null body has no length");
        return None;
    }
    // SAFETY: A non-null output is the exact owned pair the call produced.
    let bytes = unsafe { slice::from_raw_parts(out, len) }.to_vec();
    // SAFETY: The body came from this bridge and is freed once, here.
    unsafe { limpid_approval_bytes_free_v1(out, len) };
    Some(bytes)
}
