//! The C ABI for the application-side rules.
//!
//! Three calls, all the same shape: JSON in, JSON out, the caller frees the
//! body with `limpid_approval_bytes_free_v1`. The host never inspects the
//! projection state it carries between passes; it stores the bytes and hands
//! them back, which keeps the state's shape a private matter for the rules.

use limpid_agent_core::{on_launch, on_terminate, project};
use limpid_agent_model::{Command, Instants, LifecycleInput, ProjectionInput, ProjectionState};
use serde::Serialize;
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::ptr;
use std::slice;

/// Largest input one projection call accepts. Generous next to a hook payload
/// because the input carries every record at once, and bounded so a runaway
/// state directory reports a limit rather than exhausting memory.
const MAX_PROJECTION_INPUT_BYTES: usize = 16 * 1024 * 1024;

/// Status codes returned by the projection ABI functions, reported as
/// `int32_t` for the same reason as `limpid_provider_result`.
#[repr(C)]
#[allow(non_camel_case_types)]
pub enum limpid_projection_result {
    /// The call succeeded and the output buffer holds the result.
    LIMPID_PROJECTION_OK = 0,
    /// A required pointer was null.
    LIMPID_PROJECTION_NULL_POINTER = 1,
    /// The input exceeded the projection input limit.
    LIMPID_PROJECTION_INPUT_TOO_LARGE = 2,
    /// The input was not UTF-8 or not the JSON shape the call expects.
    LIMPID_PROJECTION_INVALID_INPUT = 3,
    /// The result could not be serialized.
    LIMPID_PROJECTION_INTERNAL = 4,
    /// Rust caught a panic at the FFI boundary.
    LIMPID_PROJECTION_PANIC = 5,
}

const PROJECTION_OK: i32 = limpid_projection_result::LIMPID_PROJECTION_OK as i32;
const PROJECTION_NULL_POINTER: i32 =
    limpid_projection_result::LIMPID_PROJECTION_NULL_POINTER as i32;
const PROJECTION_INPUT_TOO_LARGE: i32 =
    limpid_projection_result::LIMPID_PROJECTION_INPUT_TOO_LARGE as i32;
const PROJECTION_INVALID_INPUT: i32 =
    limpid_projection_result::LIMPID_PROJECTION_INVALID_INPUT as i32;
const PROJECTION_INTERNAL: i32 = limpid_projection_result::LIMPID_PROJECTION_INTERNAL as i32;
const PROJECTION_PANIC: i32 = limpid_projection_result::LIMPID_PROJECTION_PANIC as i32;

/// What one projection call returns: the state to hand back next time, what to
/// show, and what to do.
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ProjectOutput {
    state: ProjectionState,
    projection: limpid_agent_model::Projection,
    commands: Vec<Command>,
}

/// Reports the providers this build has, as `{ "<id>": <descriptor>, ... }`.
///
/// # Safety
///
/// The output pointers must be writable. On `LIMPID_PROJECTION_OK` the caller
/// owns the body and frees it with `limpid_approval_bytes_free_v1`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn limpid_projection_providers_v1(
    out: *mut *mut u8,
    out_len: *mut usize,
) -> i32 {
    let outcome = projection_boundary(|| {
        if out.is_null() || out_len.is_null() {
            return Err(PROJECTION_NULL_POINTER);
        }
        let registry: std::collections::BTreeMap<_, _> = limpid_agent_hook::installed_providers()
            .into_iter()
            .map(|descriptor| (descriptor.id.clone(), descriptor))
            .collect();
        let body = serde_json::to_vec(&registry).map_err(|_| PROJECTION_INTERNAL)?;
        unsafe { transfer(body, out, out_len) };
        Ok(PROJECTION_OK)
    });
    match outcome {
        Ok(code) | Err(code) => code,
    }
}

/// Reduces the records the host found into what to show and what to change.
///
/// `state` is the body a previous call returned, or empty on the first call.
/// `input` is the `ProjectionInput` JSON, `now` the `Instants` JSON.
///
/// # Safety
///
/// Every non-null pointer must remain valid for its declared length for the
/// duration of this call. The output pointers must be writable, and on
/// `LIMPID_PROJECTION_OK` the caller owns the body and frees it with
/// `limpid_approval_bytes_free_v1`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn limpid_projection_project_v1(
    state: *const u8,
    state_len: usize,
    input: *const u8,
    input_len: usize,
    now: *const u8,
    now_len: usize,
    out: *mut *mut u8,
    out_len: *mut usize,
) -> i32 {
    let outcome = projection_boundary(|| {
        let state_bytes = unsafe { optional_bytes(state, state_len) }?;
        let input_bytes = unsafe { required_bytes(input, input_len) }?;
        let now_bytes = unsafe { required_bytes(now, now_len) }?;
        if out.is_null() || out_len.is_null() {
            return Err(PROJECTION_NULL_POINTER);
        }

        let previous: ProjectionState = if state_bytes.is_empty() {
            ProjectionState::default()
        } else {
            decode(state_bytes)?
        };
        let input: ProjectionInput = decode(input_bytes)?;
        let now: Instants = decode(now_bytes)?;

        let (next, projection, commands) = project(&previous, &input, &now);
        let body = serde_json::to_vec(&ProjectOutput {
            state: next,
            projection,
            commands,
        })
        .map_err(|_| PROJECTION_INTERNAL)?;
        unsafe { transfer(body, out, out_len) };
        Ok(PROJECTION_OK)
    });
    match outcome {
        Ok(code) | Err(code) => code,
    }
}

/// Decides what to restore or retire before the interface exists.
///
/// # Safety
///
/// As `limpid_projection_project_v1`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn limpid_projection_on_launch_v1(
    input: *const u8,
    input_len: usize,
    now: *const u8,
    now_len: usize,
    out: *mut *mut u8,
    out_len: *mut usize,
) -> i32 {
    unsafe { lifecycle(input, input_len, now, now_len, out, out_len, on_launch) }
}

/// Records what Limpid is about to kill and what would bring it back.
///
/// # Safety
///
/// As `limpid_projection_project_v1`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn limpid_projection_on_terminate_v1(
    input: *const u8,
    input_len: usize,
    now: *const u8,
    now_len: usize,
    out: *mut *mut u8,
    out_len: *mut usize,
) -> i32 {
    unsafe { lifecycle(input, input_len, now, now_len, out, out_len, on_terminate) }
}

/// The shared body of the two lifecycle calls, which differ only in the rule
/// they run.
unsafe fn lifecycle(
    input: *const u8,
    input_len: usize,
    now: *const u8,
    now_len: usize,
    out: *mut *mut u8,
    out_len: *mut usize,
    rule: fn(&LifecycleInput, &str) -> Vec<Command>,
) -> i32 {
    let outcome = projection_boundary(|| {
        let input_bytes = unsafe { required_bytes(input, input_len) }?;
        let now_bytes = unsafe { required_bytes(now, now_len) }?;
        if out.is_null() || out_len.is_null() {
            return Err(PROJECTION_NULL_POINTER);
        }
        let input: LifecycleInput = decode(input_bytes)?;
        let now = str::from_utf8(now_bytes).map_err(|_| PROJECTION_INVALID_INPUT)?;
        let body = serde_json::to_vec(&rule(&input, now)).map_err(|_| PROJECTION_INTERNAL)?;
        unsafe { transfer(body, out, out_len) };
        Ok(PROJECTION_OK)
    });
    match outcome {
        Ok(code) | Err(code) => code,
    }
}

fn decode<T: serde::de::DeserializeOwned>(bytes: &[u8]) -> Result<T, i32> {
    serde_json::from_slice(bytes).map_err(|_| PROJECTION_INVALID_INPUT)
}

unsafe fn required_bytes<'a>(pointer: *const u8, length: usize) -> Result<&'a [u8], i32> {
    if pointer.is_null() {
        return Err(PROJECTION_NULL_POINTER);
    }
    if length > MAX_PROJECTION_INPUT_BYTES {
        return Err(PROJECTION_INPUT_TOO_LARGE);
    }
    // SAFETY: The caller guarantees the region is readable for `length`.
    Ok(unsafe { slice::from_raw_parts(pointer, length) })
}

/// A null pointer here means "no state yet", which is how the first call
/// after launch arrives.
unsafe fn optional_bytes<'a>(pointer: *const u8, length: usize) -> Result<&'a [u8], i32> {
    if pointer.is_null() || length == 0 {
        return Ok(&[]);
    }
    unsafe { required_bytes(pointer, length) }
}

unsafe fn transfer(body: Vec<u8>, out: *mut *mut u8, out_len: *mut usize) {
    let body = body.into_boxed_slice();
    let length = body.len();
    let data = Box::into_raw(body).cast::<u8>();
    // SAFETY: The caller guarantees both output pointers are writable.
    unsafe {
        ptr::write(out, data);
        ptr::write(out_len, length);
    }
}

fn projection_boundary(operation: impl FnOnce() -> Result<i32, i32>) -> Result<i32, i32> {
    match catch_unwind(AssertUnwindSafe(operation)) {
        Ok(result) => result,
        Err(_) => Err(PROJECTION_PANIC),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::limpid_approval_bytes_free_v1;
    use serde_json::Value;

    const NOW: &str = r#"{"wall":"2026-09-14T12:00:00Z","monotonicMs":0}"#;

    fn call_project(state: &[u8], input: &str) -> (i32, Option<Value>) {
        let mut out: *mut u8 = ptr::null_mut();
        let mut out_len: usize = 0;
        let status = unsafe {
            limpid_projection_project_v1(
                state.as_ptr(),
                state.len(),
                input.as_ptr(),
                input.len(),
                NOW.as_ptr(),
                NOW.len(),
                &raw mut out,
                &raw mut out_len,
            )
        };
        if out.is_null() {
            return (status, None);
        }
        let body = unsafe { slice::from_raw_parts(out, out_len) }.to_vec();
        unsafe { limpid_approval_bytes_free_v1(out, out_len) };
        (status, serde_json::from_slice(&body).ok())
    }

    #[test]
    fn an_empty_state_is_how_the_first_pass_arrives() {
        let (status, body) = call_project(b"", "{}");
        assert_eq!(status, PROJECTION_OK);
        let body = body.expect("body");
        assert!(body.get("state").is_some());
        assert!(body.get("projection").is_some());
        assert_eq!(body["commands"], Value::Array(vec![]));
    }

    #[test]
    fn the_state_a_call_returns_is_accepted_by_the_next() {
        // The host stores this without reading it, so the only contract that
        // matters is that it round-trips.
        let (_, first) = call_project(b"", "{}");
        let state = serde_json::to_vec(&first.expect("body")["state"]).expect("encode");
        let (status, body) = call_project(&state, "{}");
        assert_eq!(status, PROJECTION_OK);
        assert!(body.is_some());
    }

    #[test]
    fn bad_input_is_reported_rather_than_guessed_at() {
        assert_eq!(call_project(b"", "not json").0, PROJECTION_INVALID_INPUT);
        assert_eq!(call_project(b"{ broken", "{}").0, PROJECTION_INVALID_INPUT);

        let mut out: *mut u8 = ptr::null_mut();
        let mut out_len: usize = 0;
        let status = unsafe {
            limpid_projection_project_v1(
                ptr::null(),
                0,
                ptr::null(),
                0,
                NOW.as_ptr(),
                NOW.len(),
                &raw mut out,
                &raw mut out_len,
            )
        };
        assert_eq!(status, PROJECTION_NULL_POINTER);
        assert!(out.is_null());
    }

    #[test]
    fn an_oversized_input_reports_a_limit_rather_than_reading_it() {
        let mut out: *mut u8 = ptr::null_mut();
        let mut out_len: usize = 0;
        let probe = b"{}";
        let status = unsafe {
            limpid_projection_project_v1(
                b"".as_ptr(),
                0,
                probe.as_ptr(),
                MAX_PROJECTION_INPUT_BYTES + 1,
                NOW.as_ptr(),
                NOW.len(),
                &raw mut out,
                &raw mut out_len,
            )
        };
        assert_eq!(status, PROJECTION_INPUT_TOO_LARGE);
    }

    #[test]
    fn the_lifecycle_calls_return_a_command_list() {
        for call in [
            limpid_projection_on_launch_v1 as unsafe extern "C" fn(_, _, _, _, _, _) -> i32,
            limpid_projection_on_terminate_v1,
        ] {
            let input = b"{}";
            let now = b"2026-09-14T12:00:00Z";
            let mut out: *mut u8 = ptr::null_mut();
            let mut out_len: usize = 0;
            let status = unsafe {
                call(
                    input.as_ptr(),
                    input.len(),
                    now.as_ptr(),
                    now.len(),
                    &raw mut out,
                    &raw mut out_len,
                )
            };
            assert_eq!(status, PROJECTION_OK);
            let body = unsafe { slice::from_raw_parts(out, out_len) }.to_vec();
            unsafe { limpid_approval_bytes_free_v1(out, out_len) };
            let commands: Value = serde_json::from_slice(&body).expect("decode");
            assert_eq!(commands, Value::Array(vec![]));
        }
    }

    #[test]
    fn a_panic_never_crosses_the_boundary() {
        let status = projection_boundary(|| panic!("inside the rules"));
        assert_eq!(status, Err(PROJECTION_PANIC));
    }
}
