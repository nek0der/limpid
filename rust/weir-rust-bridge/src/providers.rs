//! The C ABI for provider translation and hook execution.
//!
//! Provider lookup is delegated to the hook runtime so all callers share one
//! registry.

use crate::transfer;
use serde_json::Value;
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::ptr;
use std::slice;
use weir_agent_hook::{
    GitSnapshots, HookEnv, HookOutcome, HookRuntime, NoSnapshots, SnapshotRunner, adapter_for,
    run_hook, run_worktree_hook,
};
use weir_agent_model::{
    ApprovalDecision, FailureWatch, MAX_HOOK_INPUT_BYTES, NormalizeError, ProviderAdapter,
    RawHookInput,
};

/// Status codes returned by the provider translation ABI functions,
/// reported as `int32_t` for the same reason as `weir_approval_result`.
#[repr(C)]
#[allow(non_camel_case_types)]
pub enum weir_provider_result {
    /// The call succeeded and the output buffer holds the result.
    WEIR_PROVIDER_OK = 0,
    /// The payload is valid but is not a permission request; the output
    /// buffer is empty.
    WEIR_PROVIDER_NOT_APPROVAL = 1,
    /// A required pointer was null.
    WEIR_PROVIDER_NULL_POINTER = 2,
    /// The provider id is not registered in this build.
    WEIR_PROVIDER_UNKNOWN_PROVIDER = 3,
    /// The input exceeded the hook payload limit.
    WEIR_PROVIDER_INPUT_TOO_LARGE = 4,
    /// The input was not UTF-8 or not the JSON shape the call expects.
    WEIR_PROVIDER_INVALID_INPUT = 5,
    /// The translation could not be serialized.
    WEIR_PROVIDER_INTERNAL = 6,
    /// Rust caught a panic at the FFI boundary.
    WEIR_PROVIDER_PANIC = 7,
}

const PROVIDER_OK: i32 = weir_provider_result::WEIR_PROVIDER_OK as i32;
const PROVIDER_NOT_APPROVAL: i32 = weir_provider_result::WEIR_PROVIDER_NOT_APPROVAL as i32;
const PROVIDER_NULL_POINTER: i32 = weir_provider_result::WEIR_PROVIDER_NULL_POINTER as i32;
const PROVIDER_UNKNOWN_PROVIDER: i32 = weir_provider_result::WEIR_PROVIDER_UNKNOWN_PROVIDER as i32;
const PROVIDER_INPUT_TOO_LARGE: i32 = weir_provider_result::WEIR_PROVIDER_INPUT_TOO_LARGE as i32;
const PROVIDER_INVALID_INPUT: i32 = weir_provider_result::WEIR_PROVIDER_INVALID_INPUT as i32;
const PROVIDER_INTERNAL: i32 = weir_provider_result::WEIR_PROVIDER_INTERNAL as i32;
const PROVIDER_PANIC: i32 = weir_provider_result::WEIR_PROVIDER_PANIC as i32;

/// The longest transcript line asked about: more than the watcher's reads can
/// hand over together with what they kept of the line before.
const MAX_TRANSCRIPT_LINE_BYTES: usize = 8 * 1024 * 1024;

/// Which hook entry point `weir_hook_run_v1` runs.
pub const WEIR_HOOK_KIND_LIFECYCLE: u32 = 0;
/// The worktree intercept the providers call on their shell tool.
pub const WEIR_HOOK_KIND_WORKTREE: u32 = 1;

/// Runs one lifecycle or worktree hook call and reports the outcome as JSON:
/// `{"outcome":"applied","exit_code":0}` or, after a worktree intercept,
/// `{"outcome":"intercepted","exit_code":2,"message":"..."}`. Every other
/// outcome (`not_in_weir`, `rejected`, `unknown_provider`) carries exit
/// code zero so the agent is never blocked. `env_json` is a JSON object of
/// the process environment; the runtime reads the shim's variables from it
/// rather than from the process so the host controls what the hook sees.
/// The working directory, which no variable says, is read from the process:
/// the Hook Helper makes this call in the process the provider started for
/// the hook, in the directory it started it in
/// (`HookContext::hook_directory`).
/// This call opens no approval service connection. On success, ownership
/// of `*out` transfers to the caller, which must release it with
/// `weir_approval_bytes_free_v1`.
///
/// # Safety
///
/// Same contract as `weir_provider_approval_request_v1`, with `env_json`
/// readable for `env_len` bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn weir_hook_run_v1(
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
        let env = match std::env::current_dir() {
            Ok(directory) => env.in_directory(directory),
            Err(_) => env,
        };
        let git = GitSnapshots;
        let none = NoSnapshots;
        let snapshots: &dyn SnapshotRunner = if env.turn_snapshots_disabled() {
            &none
        } else {
            &git
        };
        let runtime = HookRuntime::new(&env, snapshots);
        let outcome = match kind {
            WEIR_HOOK_KIND_LIFECYCLE => run_hook(provider, input, &runtime),
            WEIR_HOOK_KIND_WORKTREE => run_worktree_hook(provider, input, &runtime),
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
        HookOutcome::NotInWeir => ("not_in_weir", None),
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
/// Returns `WEIR_PROVIDER_OK` with a JSON body, `WEIR_PROVIDER_NOT_APPROVAL`
/// with an empty body when the payload is not a permission request, or an
/// error code with an empty body. On success, ownership of `*out` transfers to
/// the caller, which must release it with `weir_approval_bytes_free_v1`.
///
/// # Safety
///
/// `out` and `out_len` must be writable. `provider` must be readable for
/// `provider_len` bytes and `input` for `input_len` bytes; either may be null
/// only when its length is zero.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn weir_provider_approval_request_v1(
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
/// An `answer` decision always delegates through this entry point, because it
/// has no request to echo; callers that need it rendered use
/// `weir_provider_approval_output_v2` with the request document.
/// Returns `WEIR_PROVIDER_OK` with the bytes to write to the hook's standard
/// output; an empty body means the provider's native flow decides. On
/// success, ownership of `*out` transfers to the caller, which must release
/// it with `weir_approval_bytes_free_v1`.
///
/// # Safety
///
/// Same contract as `weir_provider_approval_request_v1`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn weir_provider_approval_output_v1(
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
        if let Some(body) = adapter.approval_output(&decision, &Value::Null).stdout {
            // SAFETY: The caller guarantees both output pointers are writable,
            // and the bytes are owned by the caller until it frees them.
            unsafe { transfer(body, out, out_len) };
        }
        Ok(PROVIDER_OK)
    });
    status.unwrap_or_else(|code| code)
}

/// Same as `weir_provider_approval_output_v1`, with the `ApprovalRequest`
/// JSON that `weir_provider_approval_request_v1` produced. An answer needs
/// the request's `tool_name` and `input`; the other decisions ignore it.
///
/// # Safety
///
/// Same contract as `weir_provider_approval_request_v1`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn weir_provider_approval_output_v2(
    provider: *const u8,
    provider_len: usize,
    request_json: *const u8,
    request_len: usize,
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
        let request = unsafe { input_bytes(request_json, request_len) }?;
        let request: Value = serde_json::from_slice(request).map_err(|_| PROVIDER_INVALID_INPUT)?;
        let decision = unsafe { input_bytes(decision_json, decision_len) }?;
        let decision: ApprovalDecision =
            serde_json::from_slice(decision).map_err(|_| PROVIDER_INVALID_INPUT)?;
        if let Some(body) = adapter.approval_output(&decision, &request).stdout {
            // SAFETY: The caller guarantees both output pointers are writable,
            // and the bytes are owned by the caller until it frees them.
            unsafe { transfer(body, out, out_len) };
        }
        Ok(PROVIDER_OK)
    });
    status.unwrap_or_else(|code| code)
}

/// Asks `provider` about one line of a transcript a watcher reads. Reports the
/// `FailureReport` as JSON when the line is a turn that failed, and `null` for
/// any other line. On success, ownership of `*out` transfers to the caller,
/// which must release it with `weir_approval_bytes_free_v1`.
///
/// # Safety
///
/// Same contract as `weir_provider_approval_request_v1`, with `line` readable
/// for `line_len` bytes, and `transcript_path` and `session_id` readable for
/// their lengths.
#[unsafe(no_mangle)]
#[allow(clippy::too_many_arguments)]
pub unsafe extern "C" fn weir_provider_turn_failure_report_v1(
    provider: *const u8,
    provider_len: usize,
    line: *const u8,
    line_len: usize,
    transcript_path: *const u8,
    transcript_path_len: usize,
    session_id: *const u8,
    session_id_len: usize,
    read_at: u64,
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
        // A line is not a hook payload: a turn's end can carry a long answer,
        // and one refused here is a failure never reported.
        if line_len > MAX_TRANSCRIPT_LINE_BYTES {
            return Err(PROVIDER_INPUT_TOO_LARGE);
        }
        if line.is_null() && line_len > 0 {
            return Err(PROVIDER_NULL_POINTER);
        }
        // SAFETY: The caller guarantees a readable line of this length.
        let line = if line_len == 0 {
            &[]
        } else {
            unsafe { slice::from_raw_parts(line, line_len) }
        };
        let text = |pointer, length| {
            let bytes = unsafe { input_bytes(pointer, length) }?;
            std::str::from_utf8(bytes).map_err(|_| PROVIDER_INVALID_INPUT)
        };
        let watch = FailureWatch {
            transcript_path: text(transcript_path, transcript_path_len)?,
            session_id: text(session_id, session_id_len)?,
            read_at,
        };
        let report = adapter.turn_failure_report(line, &watch);
        let body = serde_json::to_vec(&report).map_err(|_| PROVIDER_INTERNAL)?;
        // SAFETY: The caller guarantees both output pointers are writable, and
        // the bytes are owned by the caller until it frees them.
        unsafe { transfer(body, out, out_len) };
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
    use crate::test_support::take_bytes;

    fn request(provider: &str, payload: &[u8]) -> (i32, Option<Value>) {
        let mut out: *mut u8 = ptr::dangling_mut();
        let mut out_len: usize = 99;
        // SAFETY: Every pointer is a live local of this test.
        let status = unsafe {
            weir_provider_approval_request_v1(
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
            weir_provider_approval_output_v1(
                provider.as_ptr(),
                provider.len(),
                decision.as_ptr(),
                decision.len(),
                &raw mut out,
                &raw mut out_len,
            )
        };
        // SAFETY: The pair is what this call wrote.
        (status, unsafe { take_bytes(out, out_len) })
    }

    fn output_v2(provider: &str, request: &[u8], decision: &[u8]) -> (i32, Option<Vec<u8>>) {
        let mut out: *mut u8 = ptr::dangling_mut();
        let mut out_len: usize = 99;
        // SAFETY: Every pointer is a live local of this test.
        let status = unsafe {
            weir_provider_approval_output_v2(
                provider.as_ptr(),
                provider.len(),
                request.as_ptr(),
                request.len(),
                decision.as_ptr(),
                decision.len(),
                &raw mut out,
                &raw mut out_len,
            )
        };
        // SAFETY: The pair is what this call wrote.
        (status, unsafe { take_bytes(out, out_len) })
    }

    fn take(out: *mut u8, out_len: usize) -> Option<Value> {
        // SAFETY: The pair is what one call wrote.
        unsafe { take_bytes(out, out_len) }
            .map(|bytes| serde_json::from_slice(&bytes).expect("JSON body"))
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
                weir_provider_approval_request_v1(
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
                weir_provider_approval_request_v1(
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
                weir_provider_approval_request_v1(
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

    /// A decision comes back as the provider's hook output, and a delegated
    /// one with no body. The bytes themselves are each adapter's, tested
    /// with it (`decisions_render_the_hook_output_the_agent_reads`).
    #[test]
    fn renders_decisions_and_delegates_with_an_empty_body() {
        let (status, bytes) = output("claude", br#"{"decision":"allow_once"}"#);
        assert_eq!(status, PROVIDER_OK);
        assert!(bytes.is_some_and(|bytes| !bytes.is_empty()));
        // The message is decoded and handed to the adapter; its bytes are
        // the adapter's tests'.
        let (status, bytes) = output("codex", br#"{"decision":"deny","message":"Blocked"}"#);
        assert_eq!(status, PROVIDER_OK);
        let bytes = String::from_utf8(bytes.expect("bytes")).expect("utf8");
        assert!(bytes.contains(r#""message":"Blocked""#), "{bytes}");
        let (status, bytes) = output("codex", br#"{"decision":"delegate"}"#);
        assert_eq!((status, bytes), (PROVIDER_OK, None));
        let (status, bytes) = output("codex", br#"{"decision":"ask"}"#);
        assert_eq!((status, bytes), (PROVIDER_INVALID_INPUT, None));
        let (status, _) = output("nope", br#"{"decision":"delegate"}"#);
        assert_eq!(status, PROVIDER_UNKNOWN_PROVIDER);
    }

    #[test]
    fn answers_render_only_through_v2_with_the_request() {
        let request = br#"{"tool_name":"AskUserQuestion","input":{"questions":[{"question":"q","options":[{"label":"a"}]}]}}"#;
        let answer = br#"{"decision":"answer","answers":{"q":"a"}}"#;
        let (status, bytes) = output_v2("claude", request, answer);
        assert_eq!(status, PROVIDER_OK);
        let bytes = String::from_utf8(bytes.expect("bytes")).expect("utf8");
        assert!(bytes.contains(r#""updatedInput""#));
        let (status, bytes) = output("claude", answer);
        assert_eq!((status, bytes), (PROVIDER_OK, None));
    }

    fn hook(provider: &str, kind: u32, payload: &[u8], env: &[u8]) -> (i32, Option<Value>) {
        let mut out: *mut u8 = ptr::dangling_mut();
        let mut out_len: usize = 99;
        // SAFETY: Every pointer is a live local of this test.
        let status = unsafe {
            weir_hook_run_v1(
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
        let scratch_dir = tempfile::tempdir().expect("scratch");
        let scratch = scratch_dir.path().to_path_buf();
        let env = serde_json::json!({
            "WEIR_PANE_ID": "6F1D6A1E-0E34-4A1A-9A8E-2F2B6C1D7F10",
            "WEIR_AGENT_RUN_ID": "6F1D6A1E-0E34-4A1A-9A8E-2F2B6C1D7F11",
            "WEIR_AGENT_LAUNCH_ORDER": "18446744073709551615",
            "WEIR_AGENT_PARENT_RUN_ID": "AAAAAAAA-1111-4111-8111-AAAAAAAAAAA1",
            "WEIR_HOOK_OBSERVED_ORDER": "100",
            "WEIR_AGENT_STATES_DIR": scratch.join("states"),
            "WEIR_SESSIONS_DIR": scratch.join("sessions"),
            "WEIR_TURN_SNAPSHOT": "0",
        })
        .to_string();
        let payload = br#"{"hook_event_name":"SessionStart","source":"startup","session_id":"s","cwd":"/tmp","model":"claude-opus-5-5"}"#;
        let (status, body) = hook("claude", WEIR_HOOK_KIND_LIFECYCLE, payload, env.as_bytes());
        assert_eq!(status, PROVIDER_OK);
        let body = body.expect("body");
        assert_eq!(body["outcome"], "applied");
        assert_eq!(body["exit_code"], 0);
        let record = std::fs::read(scratch.join("states").join(
            weir_agent_model::run_record_file_name("6F1D6A1E-0E34-4A1A-9A8E-2F2B6C1D7F11"),
        ))
        .expect("record written");
        assert!(String::from_utf8_lossy(&record).contains("\"schemaVersion\":3"));
        let decoded = weir_agent_model::RunRecord::decode(&record).expect("run record");
        assert_eq!(decoded.run_launch_order, Some(u64::MAX));
        assert_eq!(
            decoded.parent_run_id.as_deref(),
            Some("AAAAAAAA-1111-4111-8111-AAAAAAAAAAA1")
        );
        assert_eq!(decoded.run_observed_order, Some(100));
        let mut subagent_env: Value = serde_json::from_str(&env).expect("environment");
        subagent_env["WEIR_HOOK_OBSERVED_ORDER"] = Value::String("200".into());
        let subagent_payload = br#"{"hook_event_name":"PreToolUse","session_id":"s","agent_id":"child","tool_name":"Bash","permission_mode":"default"}"#;
        let (status, _) = hook(
            "claude",
            WEIR_HOOK_KIND_LIFECYCLE,
            subagent_payload,
            subagent_env.to_string().as_bytes(),
        );
        assert_eq!(status, PROVIDER_OK);
        let after = std::fs::read(scratch.join("states").join(
            weir_agent_model::run_record_file_name("6F1D6A1E-0E34-4A1A-9A8E-2F2B6C1D7F11"),
        ))
        .expect("record after subagent hook");
        assert_eq!(
            weir_agent_model::RunRecord::decode(&after)
                .expect("record")
                .run_observed_order,
            Some(100)
        );

        let (status, body) = hook("claude", WEIR_HOOK_KIND_LIFECYCLE, payload, b"{}");
        assert_eq!(status, PROVIDER_OK);
        assert_eq!(body.expect("body")["outcome"], "not_in_weir");
        let (status, body) = hook(
            "claude",
            WEIR_HOOK_KIND_WORKTREE,
            br#"{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls"}}"#,
            env.as_bytes(),
        );
        assert_eq!(status, PROVIDER_OK);
        assert_eq!(body.expect("body")["outcome"], "applied");
        let (status, _) = hook("claude", 7, payload, env.as_bytes());
        assert_eq!(status, PROVIDER_INVALID_INPUT);
        let (status, _) = hook("claude", WEIR_HOOK_KIND_LIFECYCLE, payload, b"[]");
        assert_eq!(status, PROVIDER_INVALID_INPUT);
        let (status, body) = hook("nope", WEIR_HOOK_KIND_LIFECYCLE, payload, env.as_bytes());
        assert_eq!(status, PROVIDER_OK);
        assert_eq!(body.expect("body")["outcome"], "unknown_provider");
    }

    /// The thread is told by the directory the hook runs in, not by a tool's
    /// `cwd` (Codex 0.166): a tool of the person's run in Codex's memories
    /// directory is recorded, though the payload names that directory. The
    /// test runs in the crate's directory, which is not under the home.
    #[test]
    fn hook_abi_tells_the_thread_by_the_hooks_own_directory() {
        let scratch_dir = tempfile::tempdir().expect("scratch");
        let scratch = scratch_dir.path().to_path_buf();
        let home = scratch.join("codex-home");
        std::fs::create_dir_all(home.join("memories")).expect("memories directory");
        let run = "6F1D6A1E-0E34-4A1A-9A8E-2F2B6C1D7F21";
        let env = serde_json::json!({
            "WEIR_PANE_ID": "6F1D6A1E-0E34-4A1A-9A8E-2F2B6C1D7F20",
            "WEIR_AGENT_RUN_ID": run,
            "WEIR_CODEX_AGENT_STATES_DIR": scratch.join("states"),
            "WEIR_CODEX_SESSIONS_DIR": scratch.join("sessions"),
            "WEIR_TURN_SNAPSHOT": "0",
            "CODEX_HOME": home,
        })
        .to_string();
        let payload = serde_json::json!({
            "hook_event_name": "PreToolUse",
            "session_id": "s",
            "turn_id": "t",
            "cwd": home.join("memories"),
            "tool_name": "Bash",
            "tool_input": {"command": "ls"},
            "tool_use_id": "exec-1",
        })
        .to_string();
        let (status, body) = hook(
            "codex",
            WEIR_HOOK_KIND_LIFECYCLE,
            payload.as_bytes(),
            env.as_bytes(),
        );
        assert_eq!(status, PROVIDER_OK);
        assert_eq!(body.expect("body")["outcome"], "applied");
        let record = std::fs::read(
            scratch
                .join("states")
                .join(weir_agent_model::run_record_file_name(run)),
        )
        .expect("the tool's call is recorded");
        assert!(
            String::from_utf8_lossy(&record).contains(r#""lastHookEvent":"tool_started""#),
            "{}",
            String::from_utf8_lossy(&record)
        );
    }

    #[test]
    fn panics_become_a_closed_error() {
        assert_eq!(provider_boundary(|| panic!("boom")), Err(PROVIDER_PANIC));
    }
}
