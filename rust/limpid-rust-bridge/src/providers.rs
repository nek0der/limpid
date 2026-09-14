//! The C ABI for provider translation and hook execution.
//!
//! Provider lookup is delegated to the hook runtime so all callers share one
//! registry.

use limpid_agent_hook::{
    GitSnapshots, HookEnv, HookOutcome, HookRuntime, NoSnapshots, SnapshotRunner, adapter_for,
    run_hook, run_worktree_hook,
};
use limpid_agent_model::{
    ApprovalDecision, MAX_HOOK_INPUT_BYTES, NormalizeError, ProviderAdapter, RawHookInput,
};
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::ptr;
use std::slice;

/// Status codes returned by the provider translation ABI functions,
/// reported as `int32_t` for the same reason as `limpid_approval_result`.
#[repr(C)]
#[allow(non_camel_case_types)]
pub enum limpid_provider_result {
    /// The call succeeded and the output buffer holds the result.
    LIMPID_PROVIDER_OK = 0,
    /// The payload is valid but is not a permission request; the output
    /// buffer is empty.
    LIMPID_PROVIDER_NOT_APPROVAL = 1,
    /// A required pointer was null.
    LIMPID_PROVIDER_NULL_POINTER = 2,
    /// The provider id is not registered in this build.
    LIMPID_PROVIDER_UNKNOWN_PROVIDER = 3,
    /// The input exceeded the hook payload limit.
    LIMPID_PROVIDER_INPUT_TOO_LARGE = 4,
    /// The input was not UTF-8 or not the JSON shape the call expects.
    LIMPID_PROVIDER_INVALID_INPUT = 5,
    /// The translation could not be serialized.
    LIMPID_PROVIDER_INTERNAL = 6,
    /// Rust caught a panic at the FFI boundary.
    LIMPID_PROVIDER_PANIC = 7,
}

const PROVIDER_OK: i32 = limpid_provider_result::LIMPID_PROVIDER_OK as i32;
const PROVIDER_NOT_APPROVAL: i32 = limpid_provider_result::LIMPID_PROVIDER_NOT_APPROVAL as i32;
const PROVIDER_NULL_POINTER: i32 = limpid_provider_result::LIMPID_PROVIDER_NULL_POINTER as i32;
const PROVIDER_UNKNOWN_PROVIDER: i32 =
    limpid_provider_result::LIMPID_PROVIDER_UNKNOWN_PROVIDER as i32;
const PROVIDER_INPUT_TOO_LARGE: i32 =
    limpid_provider_result::LIMPID_PROVIDER_INPUT_TOO_LARGE as i32;
const PROVIDER_INVALID_INPUT: i32 = limpid_provider_result::LIMPID_PROVIDER_INVALID_INPUT as i32;
const PROVIDER_INTERNAL: i32 = limpid_provider_result::LIMPID_PROVIDER_INTERNAL as i32;
const PROVIDER_PANIC: i32 = limpid_provider_result::LIMPID_PROVIDER_PANIC as i32;

/// Which hook entry point `limpid_hook_run_v1` runs.
pub const LIMPID_HOOK_KIND_LIFECYCLE: u32 = 0;
/// The worktree intercept the providers call on their shell tool.
pub const LIMPID_HOOK_KIND_WORKTREE: u32 = 1;

/// Runs one lifecycle or worktree hook call and reports the outcome as JSON:
/// `{"outcome":"applied","exit_code":0}` or, after a worktree intercept,
/// `{"outcome":"intercepted","exit_code":2,"message":"..."}`. Every other
/// outcome (`not_in_limpid`, `rejected`, `unknown_provider`) carries exit
/// code zero so the agent is never blocked. `env_json` is a JSON object of
/// the process environment; the runtime reads the shim's variables from it
/// rather than from the process so the host controls what the hook sees.
/// This call opens no approval service connection. On success, ownership
/// of `*out` transfers to the caller, which must release it with
/// `limpid_approval_bytes_free_v1`.
///
/// # Safety
///
/// Same contract as `limpid_provider_approval_request_v1`, with `env_json`
/// readable for `env_len` bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn limpid_hook_run_v1(
    provider: *const u8,
    provider_len: usize,
    kind: u32,
    input: *const u8,
    input_len: usize,
    env_json: *const u8,
    env_len: usize,
    out: *mut *mut u8,
    out_len: *mut usize,
) -> i32 {
    if out.is_null() || out_len.is_null() {
        return PROVIDER_NULL_POINTER;
    }
    // SAFETY: The caller guarantees both output pointers are writable.
    unsafe {
        ptr::write(out, ptr::null_mut());
        ptr::write(out_len, 0);
    }
    let status = provider_boundary(|| {
        let provider = unsafe { input_bytes(provider, provider_len) }?;
        let provider = std::str::from_utf8(provider).map_err(|_| PROVIDER_INVALID_INPUT)?;
        let input = unsafe { input_bytes(input, input_len) }?;
        let env_json = unsafe { input_bytes(env_json, env_len) }?;
        let variables: std::collections::BTreeMap<String, String> =
            serde_json::from_slice(env_json).map_err(|_| PROVIDER_INVALID_INPUT)?;
        let env = HookEnv::from_pairs(variables);
        let git = GitSnapshots;
        let none = NoSnapshots;
        let snapshots: &dyn SnapshotRunner = if env.turn_snapshots_disabled() {
            &none
        } else {
            &git
        };
        let runtime = HookRuntime::new(&env, snapshots);
        let outcome = match kind {
            LIMPID_HOOK_KIND_LIFECYCLE => run_hook(provider, input, &runtime),
            LIMPID_HOOK_KIND_WORKTREE => run_worktree_hook(provider, input, &runtime),
            _ => return Err(PROVIDER_INVALID_INPUT),
        };
        let body = serde_json::to_vec(&outcome_json(&outcome)).map_err(|_| PROVIDER_INTERNAL)?;
        // SAFETY: The caller guarantees both output pointers are writable, and
        // the bytes are owned by the caller until it frees them.
        unsafe { transfer(body, out, out_len) };
        Ok(PROVIDER_OK)
    });
    status.unwrap_or_else(|code| code)
}

fn outcome_json(outcome: &HookOutcome) -> serde_json::Value {
    let (name, message) = match outcome {
        HookOutcome::Applied => ("applied", None),
        HookOutcome::NotInLimpid => ("not_in_limpid", None),
        HookOutcome::Rejected(reason) => ("rejected", Some(reason.clone())),
        HookOutcome::UnknownProvider => ("unknown_provider", None),
        HookOutcome::Intercepted { message, .. } => ("intercepted", Some(message.clone())),
    };
    let mut body = serde_json::json!({
        "outcome": name,
        "exit_code": outcome.exit_code(),
    });
    if let Some(message) = message {
        body["message"] = serde_json::Value::String(message);
    }
    body
}

/// Translates a provider's `PermissionRequest` payload into the neutral
/// approval request as JSON.
///
/// Returns `LIMPID_PROVIDER_OK` with a JSON body, `LIMPID_PROVIDER_NOT_APPROVAL`
/// with an empty body when the payload is not a permission request, or an
/// error code with an empty body. On success, ownership of `*out` transfers to
/// the caller, which must release it with `limpid_approval_bytes_free_v1`.
///
/// # Safety
///
/// `out` and `out_len` must be writable. `provider` must be readable for
/// `provider_len` bytes and `input` for `input_len` bytes; either may be null
/// only when its length is zero.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn limpid_provider_approval_request_v1(
    provider: *const u8,
    provider_len: usize,
    input: *const u8,
    input_len: usize,
    out: *mut *mut u8,
    out_len: *mut usize,
) -> i32 {
    if out.is_null() || out_len.is_null() {
        return PROVIDER_NULL_POINTER;
    }
    // SAFETY: The caller guarantees both output pointers are writable.
    unsafe {
        ptr::write(out, ptr::null_mut());
        ptr::write(out_len, 0);
    }
    let status = provider_boundary(|| {
        let adapter = unsafe { resolve_adapter(provider, provider_len) }?;
        let input = unsafe { input_bytes(input, input_len) }?;
        let request = adapter
            .approval_request(RawHookInput {
                bytes: input,
                transcript: None,
            })
            .map_err(|error| normalize_status(&error))?;
        let Some(request) = request else {
            return Ok(PROVIDER_NOT_APPROVAL);
        };
        let body = serde_json::to_vec(&request).map_err(|_| PROVIDER_INTERNAL)?;
        // SAFETY: The caller guarantees both output pointers are writable, and
        // the bytes are owned by the caller until it frees them.
        unsafe { transfer(body, out, out_len) };
        Ok(PROVIDER_OK)
    });
    status.unwrap_or_else(|code| code)
}

/// Renders a neutral decision as the provider's hook output.
///
/// `decision_json` is an `ApprovalDecision` document such as
/// `{"decision":"allow_once"}` or `{"decision":"deny","message":"..."}`.
/// Returns `LIMPID_PROVIDER_OK` with the bytes to write to the hook's standard
/// output; an empty body means the provider's native flow decides. On
/// success, ownership of `*out` transfers to the caller, which must release
/// it with `limpid_approval_bytes_free_v1`.
///
/// # Safety
///
/// Same contract as `limpid_provider_approval_request_v1`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn limpid_provider_approval_output_v1(
    provider: *const u8,
    provider_len: usize,
    decision_json: *const u8,
    decision_len: usize,
    out: *mut *mut u8,
    out_len: *mut usize,
) -> i32 {
    if out.is_null() || out_len.is_null() {
        return PROVIDER_NULL_POINTER;
    }
    // SAFETY: The caller guarantees both output pointers are writable.
    unsafe {
        ptr::write(out, ptr::null_mut());
        ptr::write(out_len, 0);
    }
    let status = provider_boundary(|| {
        let adapter = unsafe { resolve_adapter(provider, provider_len) }?;
        let decision = unsafe { input_bytes(decision_json, decision_len) }?;
        let decision: ApprovalDecision =
            serde_json::from_slice(decision).map_err(|_| PROVIDER_INVALID_INPUT)?;
        if let Some(body) = adapter.approval_output(&decision).stdout {
            // SAFETY: The caller guarantees both output pointers are writable,
            // and the bytes are owned by the caller until it frees them.
            unsafe { transfer(body, out, out_len) };
        }
        Ok(PROVIDER_OK)
    });
    status.unwrap_or_else(|code| code)
}

unsafe fn resolve_adapter<'a>(
    provider: *const u8,
    provider_len: usize,
) -> Result<&'a dyn ProviderAdapter, i32> {
    let bytes = unsafe { input_bytes(provider, provider_len) }?;
    let id = std::str::from_utf8(bytes).map_err(|_| PROVIDER_INVALID_INPUT)?;
    adapter_for(id).ok_or(PROVIDER_UNKNOWN_PROVIDER)
}

unsafe fn input_bytes<'a>(pointer: *const u8, length: usize) -> Result<&'a [u8], i32> {
    if length == 0 {
        return Ok(&[]);
    }
    if pointer.is_null() {
        return Err(PROVIDER_NULL_POINTER);
    }
    if length > MAX_HOOK_INPUT_BYTES {
        return Err(PROVIDER_INPUT_TOO_LARGE);
    }
    // SAFETY: The caller guarantees a readable input region of this length.
    Ok(unsafe { slice::from_raw_parts(pointer, length) })
}

/// Hands a byte vector to the caller as a `Box<[u8]>` allocation, the same
/// shape `limpid_approval_bytes_free_v1` releases.
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

fn normalize_status(error: &NormalizeError) -> i32 {
    match error {
        NormalizeError::TooLarge { .. } => PROVIDER_INPUT_TOO_LARGE,
        NormalizeError::NotAnObject => PROVIDER_INVALID_INPUT,
    }
}

fn provider_boundary(operation: impl FnOnce() -> Result<i32, i32>) -> Result<i32, i32> {
    match catch_unwind(AssertUnwindSafe(operation)) {
        Ok(result) => result,
        Err(_) => Err(PROVIDER_PANIC),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::limpid_approval_bytes_free_v1;
    use serde_json::Value;

    fn request(provider: &str, payload: &[u8]) -> (i32, Option<Value>) {
        let mut out: *mut u8 = ptr::dangling_mut();
        let mut out_len: usize = 99;
        // SAFETY: Every pointer is a live local of this test.
        let status = unsafe {
            limpid_provider_approval_request_v1(
                provider.as_ptr(),
                provider.len(),
                payload.as_ptr(),
                payload.len(),
                &raw mut out,
                &raw mut out_len,
            )
        };
        (status, take(out, out_len))
    }

    fn output(provider: &str, decision: &[u8]) -> (i32, Option<Vec<u8>>) {
        let mut out: *mut u8 = ptr::dangling_mut();
        let mut out_len: usize = 99;
        // SAFETY: Every pointer is a live local of this test.
        let status = unsafe {
            limpid_provider_approval_output_v1(
                provider.as_ptr(),
                provider.len(),
                decision.as_ptr(),
                decision.len(),
                &raw mut out,
                &raw mut out_len,
            )
        };
        if out.is_null() {
            assert_eq!(out_len, 0);
            return (status, None);
        }
        // SAFETY: A non-null output is the exact owned pair the call produced.
        let bytes = unsafe { slice::from_raw_parts(out, out_len) }.to_vec();
        unsafe { limpid_approval_bytes_free_v1(out, out_len) };
        (status, Some(bytes))
    }

    fn take(out: *mut u8, out_len: usize) -> Option<Value> {
        if out.is_null() {
            assert_eq!(out_len, 0);
            return None;
        }
        // SAFETY: A non-null output is the exact owned pair the call produced.
        let bytes = unsafe { slice::from_raw_parts(out, out_len) }.to_vec();
        unsafe { limpid_approval_bytes_free_v1(out, out_len) };
        Some(serde_json::from_slice(&bytes).expect("JSON body"))
    }

    const CODEX_PERMISSION: &[u8] = br#"{"hook_event_name":"PermissionRequest","session_id":"s","turn_id":"t","tool_name":"Bash","tool_input":{"command":"ls"}}"#;

    #[test]
    fn translates_a_permission_request_for_each_registered_provider() {
        let (status, body) = request("codex", CODEX_PERMISSION);
        assert_eq!(status, PROVIDER_OK);
        let body = body.expect("body");
        assert_eq!(body["provider"], "codex");
        assert_eq!(body["operation_id"], "t");
        assert_eq!(body["summary"], "ls");
        assert_eq!(body["timeout_ms"], 570_000);

        let (status, body) = request("claude", CODEX_PERMISSION);
        assert_eq!(status, PROVIDER_OK);
        assert_eq!(body.expect("body").get("operation_id"), None);
    }

    #[test]
    fn non_approval_payloads_return_an_empty_body() {
        let (status, body) = request("claude", br#"{"hook_event_name":"Stop"}"#);
        assert_eq!(status, PROVIDER_NOT_APPROVAL);
        assert_eq!(body, None);
    }

    #[test]
    fn rejects_null_pointers_unknown_providers_and_bad_input() {
        let (status, body) = request("gemini", CODEX_PERMISSION);
        assert_eq!((status, body), (PROVIDER_UNKNOWN_PROVIDER, None));
        let (status, _) = request("", CODEX_PERMISSION);
        assert_eq!(status, PROVIDER_UNKNOWN_PROVIDER);
        let (status, _) = request("claude", b"[1,2]");
        assert_eq!(status, PROVIDER_INVALID_INPUT);
        let (status, _) = request("claude", b"");
        assert_eq!(status, PROVIDER_INVALID_INPUT);
        let oversized = vec![b'{'; MAX_HOOK_INPUT_BYTES + 1];
        let (status, _) = request("claude", &oversized);
        assert_eq!(status, PROVIDER_INPUT_TOO_LARGE);

        let mut out: *mut u8 = ptr::null_mut();
        let mut out_len: usize = 0;
        // SAFETY: The non-null pointers are live locals of this test.
        unsafe {
            assert_eq!(
                limpid_provider_approval_request_v1(
                    ptr::null(),
                    6,
                    CODEX_PERMISSION.as_ptr(),
                    CODEX_PERMISSION.len(),
                    &raw mut out,
                    &raw mut out_len,
                ),
                PROVIDER_NULL_POINTER
            );
            assert_eq!(
                limpid_provider_approval_request_v1(
                    b"codex".as_ptr(),
                    5,
                    ptr::null(),
                    4,
                    &raw mut out,
                    &raw mut out_len,
                ),
                PROVIDER_NULL_POINTER
            );
            assert_eq!(
                limpid_provider_approval_request_v1(
                    b"codex".as_ptr(),
                    5,
                    CODEX_PERMISSION.as_ptr(),
                    CODEX_PERMISSION.len(),
                    ptr::null_mut(),
                    &raw mut out_len,
                ),
                PROVIDER_NULL_POINTER
            );
        }
        assert!(out.is_null());
    }

    #[test]
    fn renders_decisions_and_delegates_with_an_empty_body() {
        let (status, bytes) = output("claude", br#"{"decision":"allow_once"}"#);
        assert_eq!(status, PROVIDER_OK);
        assert_eq!(
            bytes.as_deref(),
            Some(&br#"{"hookSpecificOutput":{"decision":{"behavior":"allow"},"hookEventName":"PermissionRequest"}}"#[..])
        );
        let (status, bytes) = output("codex", br#"{"decision":"deny","message":"Blocked"}"#);
        assert_eq!(status, PROVIDER_OK);
        assert!(
            bytes
                .expect("bytes")
                .ends_with(br#""message":"Blocked"},"hookEventName":"PermissionRequest"}}"#)
        );
        let (status, bytes) = output("codex", br#"{"decision":"delegate"}"#);
        assert_eq!((status, bytes), (PROVIDER_OK, None));
        let (status, bytes) = output("codex", br#"{"decision":"ask"}"#);
        assert_eq!((status, bytes), (PROVIDER_INVALID_INPUT, None));
        let (status, _) = output("nope", br#"{"decision":"delegate"}"#);
        assert_eq!(status, PROVIDER_UNKNOWN_PROVIDER);
    }

    fn hook(provider: &str, kind: u32, payload: &[u8], env: &[u8]) -> (i32, Option<Value>) {
        let mut out: *mut u8 = ptr::dangling_mut();
        let mut out_len: usize = 99;
        // SAFETY: Every pointer is a live local of this test.
        let status = unsafe {
            limpid_hook_run_v1(
                provider.as_ptr(),
                provider.len(),
                kind,
                payload.as_ptr(),
                payload.len(),
                env.as_ptr(),
                env.len(),
                &raw mut out,
                &raw mut out_len,
            )
        };
        (status, take(out, out_len))
    }

    #[test]
    fn hook_abi_reports_outcomes_and_writes_records() {
        let scratch =
            std::env::temp_dir().join(format!("limpid-bridge-hook-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&scratch).expect("scratch");
        let env = serde_json::json!({
            "LIMPID_PANE_ID": "6F1D6A1E-0E34-4A1A-9A8E-2F2B6C1D7F10",
            "LIMPID_AGENT_RUN_ID": "6F1D6A1E-0E34-4A1A-9A8E-2F2B6C1D7F11",
            "LIMPID_AGENT_STATES_DIR": scratch.join("states"),
            "LIMPID_SESSIONS_DIR": scratch.join("sessions"),
            "LIMPID_TURN_SNAPSHOT": "0",
        })
        .to_string();
        let payload = br#"{"hook_event_name":"SessionStart","source":"startup","session_id":"s","cwd":"/tmp"}"#;
        let (status, body) = hook(
            "claude",
            LIMPID_HOOK_KIND_LIFECYCLE,
            payload,
            env.as_bytes(),
        );
        assert_eq!(status, PROVIDER_OK);
        let body = body.expect("body");
        assert_eq!(body["outcome"], "applied");
        assert_eq!(body["exit_code"], 0);
        let record = std::fs::read(
            scratch
                .join("states")
                .join("6F1D6A1E-0E34-4A1A-9A8E-2F2B6C1D7F11.state.json"),
        )
        .expect("record written");
        assert!(String::from_utf8_lossy(&record).contains("\"schemaVersion\":3"));

        let (status, body) = hook("claude", LIMPID_HOOK_KIND_LIFECYCLE, payload, b"{}");
        assert_eq!(status, PROVIDER_OK);
        assert_eq!(body.expect("body")["outcome"], "not_in_limpid");
        let (status, body) = hook(
            "claude",
            LIMPID_HOOK_KIND_WORKTREE,
            br#"{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls"}}"#,
            env.as_bytes(),
        );
        assert_eq!(status, PROVIDER_OK);
        assert_eq!(body.expect("body")["outcome"], "applied");
        let (status, _) = hook("claude", 7, payload, env.as_bytes());
        assert_eq!(status, PROVIDER_INVALID_INPUT);
        let (status, _) = hook("claude", LIMPID_HOOK_KIND_LIFECYCLE, payload, b"[]");
        assert_eq!(status, PROVIDER_INVALID_INPUT);
        let (status, body) = hook("nope", LIMPID_HOOK_KIND_LIFECYCLE, payload, env.as_bytes());
        assert_eq!(status, PROVIDER_OK);
        assert_eq!(body.expect("body")["outcome"], "unknown_provider");
        let _ = std::fs::remove_dir_all(&scratch);
    }

    #[test]
    fn panics_become_a_closed_error() {
        assert_eq!(provider_boundary(|| panic!("boom")), Err(PROVIDER_PANIC));
    }
}
