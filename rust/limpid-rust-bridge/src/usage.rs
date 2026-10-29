//! The C ABI for plan usage: a provider's status line relay
//! (`limpid_status_line_run_v1`), the status line setting the shim launches
//! the provider with (`limpid_status_line_setting_v1`), and reading a
//! provider's answer to a usage request (`limpid_plan_usage_answer_v1`).
//!
//! Each call names its provider and reaches it through the hook runtime's
//! registry (`adapter_for`), as the hook calls do, so this crate depends on
//! no provider.

use crate::frame::{FrameCodes, call_with_codes, input_bytes};
use limpid_agent_hook::{HookEnv, adapter_for, run_status_line, status_line_setting};
use limpid_agent_model::{PlanUsage, PlanUsageAnswer};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::BTreeMap;
use std::path::PathBuf;
use std::time::SystemTime;

/// Status codes returned by the plan usage ABI functions, reported as
/// `int32_t` for the same reason as `limpid_provider_result`.
#[repr(C)]
#[allow(non_camel_case_types)]
pub enum limpid_usage_result {
    /// The call ran and the output buffer holds its JSON body.
    LIMPID_USAGE_OK = 0,
    /// A required pointer was null.
    LIMPID_USAGE_NULL_POINTER = 1,
    /// The input exceeded `MAX_USAGE_REQUEST_BYTES`.
    LIMPID_USAGE_INPUT_TOO_LARGE = 2,
    /// The input was not UTF-8 or not the JSON shape the call expects.
    LIMPID_USAGE_INVALID_INPUT = 3,
    /// The provider id is not registered in this build.
    LIMPID_USAGE_UNKNOWN_PROVIDER = 4,
    /// The result could not be serialized.
    LIMPID_USAGE_INTERNAL = 5,
    /// Rust caught a panic at the FFI boundary.
    LIMPID_USAGE_PANIC = 6,
}

/// Largest request one call accepts. A status line request carries the
/// provider's input, which the Hook Helper bounds at 1 MiB, and the whole
/// process environment beside it, so the room is several times that.
const MAX_USAGE_REQUEST_BYTES: usize = 4 * 1024 * 1024;

const USAGE_INVALID_INPUT: i32 = limpid_usage_result::LIMPID_USAGE_INVALID_INPUT as i32;
const USAGE_UNKNOWN_PROVIDER: i32 = limpid_usage_result::LIMPID_USAGE_UNKNOWN_PROVIDER as i32;
const USAGE_INTERNAL: i32 = limpid_usage_result::LIMPID_USAGE_INTERNAL as i32;

const USAGE_FRAME: FrameCodes = FrameCodes {
    ok: limpid_usage_result::LIMPID_USAGE_OK as i32,
    null_pointer: limpid_usage_result::LIMPID_USAGE_NULL_POINTER as i32,
    input_too_large: limpid_usage_result::LIMPID_USAGE_INPUT_TOO_LARGE as i32,
    panic: limpid_usage_result::LIMPID_USAGE_PANIC as i32,
};

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct StatusLineRunRequest {
    provider: String,
    /// The status line input as the provider wrote it, which is JSON text.
    input: String,
    environment: BTreeMap<String, String>,
}

#[derive(Serialize)]
struct StatusLineRunAnswer {
    command: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct StatusLineSettingRequest {
    provider: String,
    environment: BTreeMap<String, String>,
    working_directory: PathBuf,
    relay_command: String,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct StatusLineSettingAnswer {
    status_line: Option<Value>,
}

#[derive(Deserialize)]
struct PlanUsageAnswerRequest {
    provider: String,
    /// The provider's answer as it wrote it, which is JSON text.
    answer: String,
}

/// `PlanUsageAnswer` on the wire: `{"outcome":"usage","usage":{...}}`,
/// `{"outcome":"noPlan"}`, or `{"outcome":"unreadable"}`.
#[derive(Serialize)]
#[serde(tag = "outcome", rename_all = "camelCase")]
enum PlanUsageAnswerBody {
    Usage { usage: PlanUsage },
    NoPlan,
    Unreadable,
}

/// Runs the status line relay on one input: keeps the plan usage it reports
/// and names the person's own status line command. The request is
/// `{"provider","input","environment"}`; the body is `{"command":...}`, null
/// when there is nothing to run.
///
/// Reads and writes small files, so it does touch the disk.
///
/// # Safety
///
/// The input pointer must be readable for its length (or null with length
/// zero), and the output pointers must be writable. On `LIMPID_USAGE_OK` the
/// caller owns the body and frees it with `limpid_approval_bytes_free_v1`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn limpid_status_line_run_v1(
    request: *const u8,
    request_len: usize,
    out: *mut *mut u8,
    out_len: *mut usize,
) -> i32 {
    let body = || {
        // SAFETY: The caller guarantees the input region is readable.
        let request =
            unsafe { input_bytes(request, request_len, MAX_USAGE_REQUEST_BYTES, USAGE_FRAME) }?;
        let request: StatusLineRunRequest =
            serde_json::from_slice(request).map_err(|_| USAGE_INVALID_INPUT)?;
        known(&request.provider)?;
        let command = run_status_line(
            &request.provider,
            request.input.as_bytes(),
            &HookEnv::from_pairs(request.environment),
            SystemTime::now(),
        );
        serde_json::to_vec(&StatusLineRunAnswer { command }).map_err(|_| USAGE_INTERNAL)
    };
    // SAFETY: We pass the pointers on under the caller's guarantees.
    unsafe { call_with_codes(out, out_len, USAGE_FRAME, body) }
}

/// The status line setting the shim launches the provider with. The request
/// is `{"provider","environment","workingDirectory","relayCommand"}`; the
/// body is `{"statusLine":{...}}`, null when the person has no status line of
/// their own and the slot stays empty.
///
/// # Safety
///
/// Same contract as `limpid_status_line_run_v1`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn limpid_status_line_setting_v1(
    request: *const u8,
    request_len: usize,
    out: *mut *mut u8,
    out_len: *mut usize,
) -> i32 {
    let body = || {
        // SAFETY: The caller guarantees the input region is readable.
        let request =
            unsafe { input_bytes(request, request_len, MAX_USAGE_REQUEST_BYTES, USAGE_FRAME) }?;
        let request: StatusLineSettingRequest =
            serde_json::from_slice(request).map_err(|_| USAGE_INVALID_INPUT)?;
        known(&request.provider)?;
        if request.relay_command.trim().is_empty() {
            return Err(USAGE_INVALID_INPUT);
        }
        let status_line = status_line_setting(
            &request.provider,
            &HookEnv::from_pairs(request.environment),
            &request.working_directory,
            &request.relay_command,
        );
        serde_json::to_vec(&StatusLineSettingAnswer { status_line }).map_err(|_| USAGE_INTERNAL)
    };
    // SAFETY: We pass the pointers on under the caller's guarantees.
    unsafe { call_with_codes(out, out_len, USAGE_FRAME, body) }
}

/// Reads a provider's answer to a plan usage request (Codex's
/// `account/rateLimits/read`). The request is `{"provider","answer"}`; the
/// body is the answer's outcome (`PlanUsageAnswerBody`).
///
/// # Safety
///
/// Same contract as `limpid_status_line_run_v1`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn limpid_plan_usage_answer_v1(
    request: *const u8,
    request_len: usize,
    out: *mut *mut u8,
    out_len: *mut usize,
) -> i32 {
    let body = || {
        // SAFETY: The caller guarantees the input region is readable.
        let request =
            unsafe { input_bytes(request, request_len, MAX_USAGE_REQUEST_BYTES, USAGE_FRAME) }?;
        let request: PlanUsageAnswerRequest =
            serde_json::from_slice(request).map_err(|_| USAGE_INVALID_INPUT)?;
        let adapter = known(&request.provider)?;
        let body = match adapter.plan_usage_answer(request.answer.as_bytes(), SystemTime::now()) {
            PlanUsageAnswer::Usage(usage) => PlanUsageAnswerBody::Usage { usage },
            PlanUsageAnswer::NoPlan => PlanUsageAnswerBody::NoPlan,
            PlanUsageAnswer::Unreadable => PlanUsageAnswerBody::Unreadable,
        };
        serde_json::to_vec(&body).map_err(|_| USAGE_INTERNAL)
    };
    // SAFETY: We pass the pointers on under the caller's guarantees.
    unsafe { call_with_codes(out, out_len, USAGE_FRAME, body) }
}

fn known(provider: &str) -> Result<&'static dyn limpid_agent_model::ProviderAdapter, i32> {
    adapter_for(provider).ok_or(USAGE_UNKNOWN_PROVIDER)
}
