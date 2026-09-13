//! Stable C ABI boundary between Limpid's Swift application and Rust core.

mod title;

use limpid_agent_core::{Principal, RunId};
use limpid_agent_protocol::{ApprovalService, ApprovalSession, ExchangeError};
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::ptr;
use std::slice;
use std::str;
use std::sync::{Arc, Mutex};
use title::{MAX_FIRST_PROMPT_BYTES, MAX_TITLE_BYTES, TitleCandidates, TitleError, resolve_title};
use uuid::Uuid;

#[derive(Clone, Copy)]
enum TitleCandidateKind {
    ProviderSession,
    ProviderGenerated,
    FirstPrompt,
}

/// Compatibility version of the ABI exposed by this library.
///
/// Additive symbols keep the current version. We increment it only when an
/// existing exported contract must change incompatibly.
pub const ABI_VERSION: u32 = 2;

/// The discrete approval exchange completed and returned one JSON response.
pub const APPROVAL_OK: i32 = 0;
/// A required pointer was null.
pub const APPROVAL_NULL_POINTER: i32 = 1;
/// A UUID argument did not have its required 16-byte representation.
pub const APPROVAL_INVALID_UUID: i32 = 2;
/// The input exceeded the protocol's bounded request size.
pub const APPROVAL_INPUT_TOO_LARGE: i32 = 3;
/// The input was not UTF-8.
pub const APPROVAL_INVALID_UTF8: i32 = 4;
/// The input was not one valid `WireRequest` JSON document.
pub const APPROVAL_INVALID_JSON: i32 = 5;
/// The response could not remain within the protocol's bounded size.
pub const APPROVAL_RESPONSE_TOO_LARGE: i32 = 6;
/// The service could not safely process the operation.
pub const APPROVAL_INTERNAL: i32 = 7;
/// Rust caught a panic at the FFI boundary.
pub const APPROVAL_PANIC: i32 = 8;

/// Opaque service handle. Multiple sessions share its approval state.
#[allow(non_camel_case_types)]
pub struct limpid_approval_service_v1 {
    service: Arc<ApprovalService>,
}

/// Opaque session handle. Its principal and hello state are host-bound.
#[allow(non_camel_case_types)]
pub struct limpid_approval_session_v1 {
    session: Mutex<ApprovalSession>,
}

/// Bytes allocated by Rust for one response. Ownership transfers to the caller
/// and must be released with `limpid_approval_bytes_free_v1`.
#[repr(C)]
pub struct limpid_approval_bytes_v1 {
    pub data: *mut u8,
    pub len: usize,
}

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

/// Creates an approval service that can be shared by independently
/// authenticated XPC connections.
#[unsafe(no_mangle)]
pub extern "C" fn limpid_approval_service_create_v1(
    maximum_records: usize,
) -> *mut limpid_approval_service_v1 {
    ffi_boundary(|| {
        Ok(Box::into_raw(Box::new(limpid_approval_service_v1 {
            service: Arc::new(ApprovalService::new(maximum_records)),
        })))
    })
    .unwrap_or(ptr::null_mut())
}

/// Releases a service handle after all sessions created from it have been
/// released. Passing null is a no-op.
///
/// # Safety
///
/// `service` must be null or a live pointer returned by the matching create
/// function and not previously freed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn limpid_approval_service_free_v1(service: *mut limpid_approval_service_v1) {
    if !service.is_null() {
        // SAFETY: The documented ABI contract requires this to be one unique,
        // live allocation returned by `limpid_approval_service_create_v1`.
        unsafe { drop(Box::from_raw(service)) };
    }
}

/// Creates a requester session whose run ID is bound by the authenticated
/// host, never taken from JSON.
///
/// # Safety
///
/// `service` must be a live service handle. `run_id` must be readable for
/// `run_id_len` bytes when non-null.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn limpid_approval_session_create_requester_v1(
    service: *const limpid_approval_service_v1,
    run_id: *const u8,
    run_id_len: usize,
) -> *mut limpid_approval_session_v1 {
    ffi_boundary(|| {
        let service = unsafe { service_ref(service) }?;
        let run_id = unsafe { decode_uuid(run_id, run_id_len) }?;
        Ok(Box::into_raw(Box::new(limpid_approval_session_v1 {
            session: Mutex::new(service.service.session(Principal::Requester {
                run_id: RunId::new(run_id),
            })),
        })))
    })
    .unwrap_or(ptr::null_mut())
}

/// Creates a controller session for a host-authenticated controller principal.
///
/// # Safety
///
/// `service` must be a live service handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn limpid_approval_session_create_controller_v1(
    service: *const limpid_approval_service_v1,
) -> *mut limpid_approval_session_v1 {
    ffi_boundary(|| {
        let service = unsafe { service_ref(service) }?;
        Ok(Box::into_raw(Box::new(limpid_approval_session_v1 {
            session: Mutex::new(service.service.session(Principal::Controller)),
        })))
    })
    .unwrap_or(ptr::null_mut())
}

/// Releases a session handle. Passing null is a no-op.
///
/// # Safety
///
/// `session` must be null or a live pointer returned by a matching session
/// constructor and not previously freed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn limpid_approval_session_free_v1(session: *mut limpid_approval_session_v1) {
    if !session.is_null() {
        // SAFETY: The documented ABI contract requires unique ownership.
        unsafe { drop(Box::from_raw(session)) };
    }
}

/// Exchanges exactly one complete `WireRequest` JSON document for exactly one
/// `WireResponse` JSON document. It deliberately does not add stream framing.
///
/// # Safety
///
/// `session` and `output` must be live writable pointers. `input` may be null
/// only when `input_len` is zero; otherwise it must be readable for its length.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn limpid_approval_session_exchange_v1(
    session: *mut limpid_approval_session_v1,
    input: *const u8,
    input_len: usize,
    output: *mut limpid_approval_bytes_v1,
) -> i32 {
    if output.is_null() {
        return APPROVAL_NULL_POINTER;
    }
    // SAFETY: The caller guarantees `output` is writable.
    unsafe {
        ptr::write(
            output,
            limpid_approval_bytes_v1 {
                data: ptr::null_mut(),
                len: 0,
            },
        );
    };
    ffi_boundary(|| {
        let session = unsafe { session_ref(session) }?;
        let input = unsafe { input_bytes(input, input_len) }?;
        let mut session = session.session.lock().map_err(|_| APPROVAL_INTERNAL)?;
        let response = session
            .exchange_json(input)
            .map_err(|error| exchange_status(&error))?;
        let response = response.into_boxed_slice();
        let length = response.len();
        let data = Box::into_raw(response).cast::<u8>();
        // SAFETY: The caller guarantees `output` is writable, and these bytes
        // are now owned by the caller until it invokes the matching free.
        unsafe { ptr::write(output, limpid_approval_bytes_v1 { data, len: length }) };
        Ok(APPROVAL_OK)
    })
    .unwrap_or_else(|status| status)
}

/// Releases response bytes returned by `limpid_approval_session_exchange_v1`.
/// Passing null with a zero length is a no-op.
///
/// # Safety
///
/// The pair must be null/zero or exactly the pair returned by a successful
/// exchange and not previously freed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn limpid_approval_bytes_free_v1(data: *mut u8, len: usize) {
    if !data.is_null() {
        // SAFETY: The bytes originate from `Box<[u8]>` with this exact length.
        unsafe { drop(Box::from_raw(ptr::slice_from_raw_parts_mut(data, len))) };
    }
}

unsafe fn service_ref<'a>(
    service: *const limpid_approval_service_v1,
) -> Result<&'a limpid_approval_service_v1, i32> {
    if service.is_null() {
        return Err(APPROVAL_NULL_POINTER);
    }
    // SAFETY: The caller of the exported ABI function guarantees this is a
    // live handle for the duration of its call.
    Ok(unsafe { &*service })
}

unsafe fn session_ref<'a>(
    session: *mut limpid_approval_session_v1,
) -> Result<&'a limpid_approval_session_v1, i32> {
    if session.is_null() {
        return Err(APPROVAL_NULL_POINTER);
    }
    // SAFETY: The caller of the exported ABI function guarantees this is a
    // live handle for the duration of its call.
    Ok(unsafe { &*session })
}

unsafe fn decode_uuid(pointer: *const u8, length: usize) -> Result<Uuid, i32> {
    if length != 16 {
        return Err(APPROVAL_INVALID_UUID);
    }
    if pointer.is_null() {
        return Err(APPROVAL_NULL_POINTER);
    }
    // SAFETY: The caller guarantees a readable UUID-sized input region.
    let bytes = unsafe { slice::from_raw_parts(pointer, length) };
    let bytes: [u8; 16] = bytes.try_into().map_err(|_| APPROVAL_INVALID_UUID)?;
    Ok(Uuid::from_bytes(bytes))
}

unsafe fn input_bytes<'a>(pointer: *const u8, length: usize) -> Result<&'a [u8], i32> {
    if length == 0 {
        return Ok(&[]);
    }
    if pointer.is_null() {
        return Err(APPROVAL_NULL_POINTER);
    }
    // SAFETY: The caller guarantees a readable input region.
    Ok(unsafe { slice::from_raw_parts(pointer, length) })
}

fn exchange_status(error: &ExchangeError) -> i32 {
    match error {
        ExchangeError::InputTooLarge => APPROVAL_INPUT_TOO_LARGE,
        ExchangeError::InvalidUtf8 => APPROVAL_INVALID_UTF8,
        ExchangeError::InvalidJson => APPROVAL_INVALID_JSON,
        ExchangeError::ResponseTooLarge => APPROVAL_RESPONSE_TOO_LARGE,
        ExchangeError::Service(_) => APPROVAL_INTERNAL,
    }
}

fn ffi_boundary<T>(operation: impl FnOnce() -> Result<T, i32>) -> Result<T, i32> {
    match catch_unwind(AssertUnwindSafe(operation)) {
        Ok(result) => result,
        Err(_) => Err(APPROVAL_PANIC),
    }
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
    use serde_json::{Value, json};

    #[allow(clippy::needless_pass_by_value)]
    fn exchange(session: *mut limpid_approval_session_v1, request: Value) -> Value {
        let request = serde_json::to_vec(&request).unwrap();
        let mut output = limpid_approval_bytes_v1 {
            data: ptr::null_mut(),
            len: 0,
        };
        // SAFETY: The handle and output pointers originate from this test, and
        // the request vector remains live for the call.
        let status = unsafe {
            limpid_approval_session_exchange_v1(
                session,
                request.as_ptr(),
                request.len(),
                &raw mut output,
            )
        };
        assert_eq!(status, APPROVAL_OK);
        // SAFETY: A successful exchange returns this exact owned byte pair.
        let response = unsafe { slice::from_raw_parts(output.data, output.len) }.to_vec();
        // SAFETY: This releases the exact allocation from the successful call.
        unsafe { limpid_approval_bytes_free_v1(output.data, output.len) };
        serde_json::from_slice(&response).unwrap()
    }

    fn hello(session: *mut limpid_approval_session_v1) -> Uuid {
        let response = exchange(
            session,
            json!({
                "version": 1,
                "message_id": Uuid::new_v4(),
                "type": "hello",
                "body": {"client_version": "test"}
            }),
        );
        assert_eq!(response["type"], "hello.result");
        serde_json::from_value(response["service_epoch"].clone()).unwrap()
    }

    fn requester(
        service: *mut limpid_approval_service_v1,
        run_id: Uuid,
    ) -> *mut limpid_approval_session_v1 {
        // SAFETY: `service` is live and `run_id` supplies its exact 16 bytes.
        unsafe {
            limpid_approval_session_create_requester_v1(service, run_id.as_bytes().as_ptr(), 16)
        }
    }

    fn approval_submit(epoch: Uuid, run_id: Uuid, request_id: Uuid) -> Value {
        json!({
            "version": 1,
            "message_id": Uuid::new_v4(),
            "service_epoch": epoch,
            "type": "approval.submit",
            "body": {
                "run_id": run_id,
                "request_id": request_id,
                "provider": "codex",
                "tool_name": "shell",
                "input": {"command": "pwd"},
                "timeout_ms": 10_000
            }
        })
    }

    #[test]
    fn approval_abi_round_trips_submit_resolve_and_wait() {
        // SAFETY: Each handle is released exactly once before the test returns.
        unsafe {
            let service = limpid_approval_service_create_v1(8);
            let run_id = Uuid::new_v4();
            let request_id = Uuid::new_v4();
            let requester = requester(service, run_id);
            let controller = limpid_approval_session_create_controller_v1(service);
            assert!(!service.is_null() && !requester.is_null() && !controller.is_null());
            let epoch = hello(requester);
            assert_eq!(hello(controller), epoch);

            let submitted = exchange(requester, approval_submit(epoch, run_id, request_id));
            assert_eq!(submitted["body"]["state"]["status"], "pending");
            let resolved = exchange(
                controller,
                json!({
                    "version": 1,
                    "message_id": Uuid::new_v4(),
                    "service_epoch": epoch,
                    "type": "approval.resolve",
                    "body": {
                        "run_id": run_id,
                        "request_id": request_id,
                        "decision": {"decision": "allow_once"}
                    }
                }),
            );
            assert_eq!(resolved["body"]["state"]["status"], "resolved");
            let waited = exchange(
                requester,
                json!({
                    "version": 1,
                    "message_id": Uuid::new_v4(),
                    "service_epoch": epoch,
                    "type": "approval.wait",
                    "body": {"run_id": run_id, "request_id": request_id, "maximum_wait_ms": 0}
                }),
            );
            assert_eq!(waited["body"]["state"]["status"], "resolved");

            limpid_approval_session_free_v1(requester);
            limpid_approval_session_free_v1(controller);
            limpid_approval_service_free_v1(service);
        }
    }

    #[test]
    fn requester_cannot_resolve_its_own_or_another_run() {
        // SAFETY: Each handle is released exactly once before the test returns.
        unsafe {
            let service = limpid_approval_service_create_v1(8);
            let own_run = Uuid::new_v4();
            let requester = requester(service, own_run);
            let epoch = hello(requester);
            for run_id in [own_run, Uuid::new_v4()] {
                let response = exchange(
                    requester,
                    json!({
                        "version": 1,
                        "message_id": Uuid::new_v4(),
                        "service_epoch": epoch,
                        "type": "approval.resolve",
                        "body": {
                            "run_id": run_id,
                            "request_id": Uuid::new_v4(),
                            "decision": {"decision": "deny"}
                        }
                    }),
                );
                assert_eq!(response["type"], "error");
                assert_eq!(response["body"]["code"], "unauthorized");
            }
            limpid_approval_session_free_v1(requester);
            limpid_approval_service_free_v1(service);
        }
    }

    #[test]
    fn approval_abi_rejects_stale_epoch() {
        // SAFETY: Each handle is released exactly once before the test returns.
        unsafe {
            let service = limpid_approval_service_create_v1(8);
            let requester = requester(service, Uuid::new_v4());
            hello(requester);
            let response = exchange(
                requester,
                json!({
                    "version": 1,
                    "message_id": Uuid::new_v4(),
                    "service_epoch": Uuid::new_v4(),
                    "type": "approval.snapshot",
                    "body": null
                }),
            );
            assert_eq!(response["type"], "error");
            assert_eq!(response["body"]["code"], "epoch_mismatch");
            limpid_approval_session_free_v1(requester);
            limpid_approval_service_free_v1(service);
        }
    }

    #[test]
    fn approval_abi_fails_closed_for_invalid_and_oversized_inputs() {
        // SAFETY: Each handle is released exactly once before the test returns.
        unsafe {
            let service = limpid_approval_service_create_v1(8);
            assert!(
                limpid_approval_session_create_requester_v1(service, ptr::null(), 16).is_null()
            );
            let requester = requester(service, Uuid::new_v4());
            let mut output = limpid_approval_bytes_v1 {
                data: ptr::dangling_mut(),
                len: 9,
            };
            assert_eq!(
                limpid_approval_session_exchange_v1(requester, ptr::null(), 1, &raw mut output),
                APPROVAL_NULL_POINTER
            );
            assert!(output.data.is_null() && output.len == 0);
            let invalid_utf8 = [0xff_u8];
            assert_eq!(
                limpid_approval_session_exchange_v1(
                    requester,
                    invalid_utf8.as_ptr(),
                    invalid_utf8.len(),
                    &raw mut output,
                ),
                APPROVAL_INVALID_UTF8
            );
            let oversized = vec![b' '; limpid_agent_protocol::MAXIMUM_REQUEST_BYTES + 1];
            assert_eq!(
                limpid_approval_session_exchange_v1(
                    requester,
                    oversized.as_ptr(),
                    oversized.len(),
                    &raw mut output,
                ),
                APPROVAL_INPUT_TOO_LARGE
            );
            assert_eq!(
                limpid_approval_session_exchange_v1(
                    ptr::null_mut(),
                    b"{}".as_ptr(),
                    2,
                    &raw mut output
                ),
                APPROVAL_NULL_POINTER
            );
            limpid_approval_session_free_v1(requester);
            limpid_approval_service_free_v1(service);
        }
    }

    #[test]
    fn ffi_boundary_converts_panics_to_a_closed_error() {
        assert_eq!(
            ffi_boundary::<()>(|| panic!("test panic")),
            Err(APPROVAL_PANIC)
        );
    }

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
