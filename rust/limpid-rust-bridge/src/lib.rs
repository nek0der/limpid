//! Stable C ABI boundary between Limpid's Swift application and Rust core.

mod title;

use std::ptr;
use std::slice;
use std::str;
use title::{MAX_FIRST_PROMPT_BYTES, MAX_TITLE_BYTES, TitleCandidates, TitleError, resolve_title};

#[derive(Clone, Copy)]
enum TitleCandidateKind {
    ProviderSession,
    ProviderGenerated,
    FirstPrompt,
}

/// Version of the ABI exposed by this library.
pub const ABI_VERSION: u32 = 2;

/// The title was written to the caller-owned output buffer.
pub const TITLE_RESOLVE_OK: i32 = 0;
/// Every candidate was absent or blank.
pub const TITLE_RESOLVE_EMPTY: i32 = 1;
/// At least one candidate was not valid UTF-8.
pub const TITLE_RESOLVE_INVALID_UTF8: i32 = 2;
/// At least one candidate exceeded the protocol limit.
pub const TITLE_RESOLVE_TOO_LONG: i32 = 3;
/// The output buffer was smaller than the selected title.
pub const TITLE_RESOLVE_BUFFER_TOO_SMALL: i32 = 4;
/// A non-empty input or output used a null pointer.
pub const TITLE_RESOLVE_NULL_POINTER: i32 = 5;

/// Returns the ABI version understood by this library.
///
/// `no_mangle` is required so Swift can link this symbol through the C header.
/// The function accepts no pointers and performs no unsafe operations.
#[unsafe(no_mangle)]
pub extern "C" fn limpid_rust_abi_version() -> u32 {
    ABI_VERSION
}

/// Resolves an automatic title into a caller-owned UTF-8 buffer.
///
/// Each optional input uses a pointer-length pair. A zero length represents an
/// absent candidate and permits a null pointer. The output is not NUL
/// terminated; `output_length` receives the number of bytes written or the
/// required capacity when the buffer is too small.
///
/// # Safety
///
/// Every non-null pointer must remain valid for its declared length for the
/// duration of this call. Input regions must be readable, and the output region
/// and `output_length` must be writable. The regions must not overlap.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn limpid_resolve_title_v1(
    provider_session_ptr: *const u8,
    provider_session_len: usize,
    provider_generated_ptr: *const u8,
    provider_generated_len: usize,
    first_prompt_ptr: *const u8,
    first_prompt_len: usize,
    output_ptr: *mut u8,
    output_capacity: usize,
    output_length: *mut usize,
) -> i32 {
    if output_length.is_null() {
        return TITLE_RESOLVE_NULL_POINTER;
    }

    // SAFETY: The caller guarantees `output_length` is writable.
    unsafe { ptr::write(output_length, 0) };

    let resolved = match unsafe {
        decode_and_resolve(
            provider_session_ptr,
            provider_session_len,
            TitleCandidateKind::ProviderSession,
        )
    } {
        Ok(Some(value)) => value,
        Ok(None) => match unsafe {
            decode_and_resolve(
                provider_generated_ptr,
                provider_generated_len,
                TitleCandidateKind::ProviderGenerated,
            )
        } {
            Ok(Some(value)) => value,
            Ok(None) => match unsafe {
                decode_and_resolve(
                    first_prompt_ptr,
                    first_prompt_len,
                    TitleCandidateKind::FirstPrompt,
                )
            } {
                Ok(Some(value)) => value,
                Ok(None) => return TITLE_RESOLVE_EMPTY,
                Err(code) => return code,
            },
            Err(code) => return code,
        },
        Err(code) => return code,
    };

    // SAFETY: The caller guarantees `output_length` is writable.
    unsafe { ptr::write(output_length, resolved.len()) };
    if resolved.len() > output_capacity {
        return TITLE_RESOLVE_BUFFER_TOO_SMALL;
    }
    if resolved.is_empty() {
        return TITLE_RESOLVE_OK;
    }
    if output_ptr.is_null() {
        return TITLE_RESOLVE_NULL_POINTER;
    }

    // SAFETY: The caller guarantees a writable, non-overlapping output region
    // of at least `output_capacity` bytes. The capacity check above proves the
    // selected bytes fit.
    unsafe { ptr::copy_nonoverlapping(resolved.as_ptr(), output_ptr, resolved.len()) };
    TITLE_RESOLVE_OK
}

/// Decodes one optional ABI input without taking ownership of its bytes.
///
/// # Safety
///
/// A non-null pointer must identify a readable region of `length` bytes for the
/// returned borrow's lifetime.
unsafe fn decode_optional<'a>(
    pointer: *const u8,
    length: usize,
    maximum_bytes: usize,
) -> Result<Option<&'a str>, i32> {
    if length == 0 {
        return Ok(None);
    }
    if pointer.is_null() {
        return Err(TITLE_RESOLVE_NULL_POINTER);
    }
    if length > maximum_bytes {
        return Err(TITLE_RESOLVE_TOO_LONG);
    }
    // SAFETY: The caller upholds the pointer validity contract documented by
    // this function.
    let bytes = unsafe { slice::from_raw_parts(pointer, length) };
    str::from_utf8(bytes)
        .map(Some)
        .map_err(|_| TITLE_RESOLVE_INVALID_UTF8)
}

unsafe fn decode_and_resolve(
    pointer: *const u8,
    length: usize,
    kind: TitleCandidateKind,
) -> Result<Option<String>, i32> {
    let maximum_bytes = match kind {
        TitleCandidateKind::ProviderSession | TitleCandidateKind::ProviderGenerated => {
            MAX_TITLE_BYTES
        }
        TitleCandidateKind::FirstPrompt => MAX_FIRST_PROMPT_BYTES,
    };
    // SAFETY: The caller forwards the pointer validity contract from the
    // exported ABI function.
    let candidate = unsafe { decode_optional(pointer, length, maximum_bytes) }?;
    let candidates = match kind {
        TitleCandidateKind::ProviderSession => TitleCandidates {
            provider_session: candidate,
            ..TitleCandidates::default()
        },
        TitleCandidateKind::ProviderGenerated => TitleCandidates {
            provider_generated: candidate,
            ..TitleCandidates::default()
        },
        TitleCandidateKind::FirstPrompt => TitleCandidates {
            first_prompt: candidate,
            ..TitleCandidates::default()
        },
    };
    resolve_title(candidates).map_err(|error| match error {
        TitleError::TooLong => TITLE_RESOLVE_TOO_LONG,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn exported_abi_version_matches_constant() {
        assert_eq!(limpid_rust_abi_version(), ABI_VERSION);
    }

    #[test]
    fn abi_resolves_into_caller_owned_buffer() {
        let provider_session = "  Session title  ".as_bytes();
        let generated = "Generated".as_bytes();
        let mut output = [0_u8; 64];
        let mut output_length = 0_usize;

        // SAFETY: Every pointer references its matching live byte region.
        let result = unsafe {
            limpid_resolve_title_v1(
                provider_session.as_ptr(),
                provider_session.len(),
                generated.as_ptr(),
                generated.len(),
                ptr::null(),
                0,
                output.as_mut_ptr(),
                output.len(),
                &raw mut output_length,
            )
        };

        assert_eq!(result, TITLE_RESOLVE_OK);
        assert_eq!(&output[..output_length], b"Session title");
    }

    #[test]
    fn abi_reports_required_output_capacity() {
        let title = "Long title".as_bytes();
        let mut output = [0_u8; 2];
        let mut output_length = 0_usize;

        // SAFETY: Every pointer references its matching live byte region.
        let result = unsafe {
            limpid_resolve_title_v1(
                title.as_ptr(),
                title.len(),
                ptr::null(),
                0,
                ptr::null(),
                0,
                output.as_mut_ptr(),
                output.len(),
                &raw mut output_length,
            )
        };

        assert_eq!(result, TITLE_RESOLVE_BUFFER_TOO_SMALL);
        assert_eq!(output_length, title.len());
    }

    #[test]
    fn abi_does_not_reject_unused_oversized_fallback() {
        let title = "Formal title".as_bytes();
        let oversized = vec![b'x'; MAX_TITLE_BYTES + 1];
        let mut output = [0_u8; 64];
        let mut output_length = 0_usize;

        // SAFETY: Every pointer references its matching live byte region.
        let result = unsafe {
            limpid_resolve_title_v1(
                title.as_ptr(),
                title.len(),
                ptr::null(),
                0,
                oversized.as_ptr(),
                oversized.len(),
                output.as_mut_ptr(),
                output.len(),
                &raw mut output_length,
            )
        };

        assert_eq!(result, TITLE_RESOLVE_OK);
        assert_eq!(&output[..output_length], title);
    }
}
