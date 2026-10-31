//! The frame every JSON-in, JSON-out call of a family shares: the output
//! pointers checked and cleared before anything runs, the body handed over,
//! and a panic caught at the boundary. Each family (turns, plan usage) names
//! its own status codes for what the frame decides.

use crate::transfer;
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::ptr;
use std::slice;

/// The status codes one family of calls reports for what the shared frame
/// decides itself: success, a missing pointer, an input past the family's
/// limit, and a caught panic.
#[derive(Clone, Copy)]
pub(crate) struct FrameCodes {
    pub ok: i32,
    pub null_pointer: i32,
    pub input_too_large: i32,
    pub panic: i32,
}

/// Runs `body` in the frame, reporting `codes` for what the frame decides.
/// `body` reads and checks the input itself, so that work stays inside the
/// panic catch and after the output check: a call with nowhere to put its
/// answer starts nothing.
///
/// # Safety
///
/// `out` and `out_len` must be writable or null. On `codes.ok` the caller
/// owns the body and frees it with `weir_approval_bytes_free_v1`.
pub(crate) unsafe fn call_with_codes(
    out: *mut *mut u8,
    out_len: *mut usize,
    codes: FrameCodes,
    body: impl FnOnce() -> Result<Vec<u8>, i32>,
) -> i32 {
    if out.is_null() || out_len.is_null() {
        return codes.null_pointer;
    }
    // SAFETY: Both output pointers were checked non-null above, and the
    // caller guarantees they are writable.
    unsafe {
        ptr::write(out, ptr::null_mut());
        ptr::write(out_len, 0);
    }
    let status = catch_unwind(AssertUnwindSafe(|| {
        let bytes = body()?;
        // SAFETY: The output pointers are writable, and the bytes are owned
        // by the caller until it frees them.
        unsafe { transfer(bytes, out, out_len) };
        Ok(codes.ok)
    }));
    match status {
        Ok(Ok(code) | Err(code)) => code,
        Err(_) => codes.panic,
    }
}

/// The input region a call was handed, checked against `limit` and reported
/// in `codes`.
///
/// # Safety
///
/// The caller guarantees `pointer` is readable for `length` bytes, or null
/// with length zero.
pub(crate) unsafe fn input_bytes<'a>(
    pointer: *const u8,
    length: usize,
    limit: usize,
    codes: FrameCodes,
) -> Result<&'a [u8], i32> {
    if length == 0 {
        return Ok(&[]);
    }
    if pointer.is_null() {
        return Err(codes.null_pointer);
    }
    if length > limit {
        return Err(codes.input_too_large);
    }
    // SAFETY: The caller guarantees a readable input region of this length.
    Ok(unsafe { slice::from_raw_parts(pointer, length) })
}
