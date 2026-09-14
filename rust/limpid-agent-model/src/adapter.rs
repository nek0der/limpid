//! The contract a provider crate implements.

use crate::{
    AgentEvent, ApprovalDecision, ApprovalRequest, InstallRecipe, ProviderDescriptor,
    WorktreeIntent,
};
use serde_json::{Map, Value};
use uuid::Uuid;

/// Longest hook payload an adapter accepts, matching the protocol's client
/// request limit.
pub const MAX_HOOK_INPUT_BYTES: usize = 1024 * 1024;

/// One raw hook invocation as the provider delivered it.
#[derive(Clone, Copy, Debug)]
pub struct RawHookInput<'a> {
    /// The payload read from standard input.
    pub bytes: &'a [u8],
    /// The provider's transcript at the time of the call, when the provider
    /// has one and the runtime chose to read it.
    pub transcript: Option<&'a [u8]>,
}

/// Where the hook runs. Everything here comes from the environment the shim
/// set, never from the payload.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct HookContext {
    pub run_id: Uuid,
    pub pane_id: Uuid,
    pub tmux: Option<TmuxEndpoint>,
    pub pid: Option<u32>,
}

/// The tmux server and pane hosting the agent, captured from `TMUX` and
/// `TMUX_PANE`. The session is deliberately absent: membership is mutable and
/// resolved by the host's topology probe.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TmuxEndpoint {
    pub socket_path: String,
    pub pane: String,
    pub server_pid: u32,
    /// Unix epoch seconds the server started, when `ps` could report it.
    pub server_started_at: Option<u64>,
}

/// Why a payload could not be normalized.
#[derive(Debug, PartialEq, Eq, thiserror::Error)]
pub enum NormalizeError {
    #[error("input exceeds {limit} bytes")]
    TooLarge { limit: usize },
    #[error("input is not a JSON object")]
    NotAnObject,
    /// The adapter does not implement normalization yet.
    #[error("normalization is not implemented for this provider")]
    NotImplemented,
}

/// A provider is one implementation of this trait plus recorded fixtures.
pub trait ProviderAdapter: Send + Sync {
    /// Identity, capabilities, timing, and directory names.
    fn descriptor(&self) -> &ProviderDescriptor;

    /// What the platform must place so the provider's hooks reach Limpid.
    fn install_recipe(&self) -> InstallRecipe;

    /// Maps one hook payload to neutral events. Unknown event names become
    /// `AgentEvent::Extension`; unrecognized fields on known events are ignored.
    ///
    /// # Errors
    ///
    /// Returns `NormalizeError` only for input that is too large or is not a
    /// JSON object.
    fn normalize(
        &self,
        input: RawHookInput<'_>,
        context: &HookContext,
    ) -> Result<Vec<AgentEvent>, NormalizeError>;

    /// Reads a permission request out of a hook payload. `Ok(None)` means the
    /// payload is not a permission request.
    ///
    /// # Errors
    ///
    /// Returns `NormalizeError` only for input that is too large or is not a
    /// JSON object.
    fn approval_request(
        &self,
        input: RawHookInput<'_>,
    ) -> Result<Option<ApprovalRequest>, NormalizeError>;

    /// Renders a decision as the provider's hook output.
    fn approval_output(&self, decision: &ApprovalDecision) -> crate::ProviderOutput;

    /// Names the transcript the runtime should read alongside this payload,
    /// when the provider keeps one and this event's normalization uses it.
    /// Reading the transcript costs a file read per hook, so adapters answer
    /// only for the events that need it. The path comes from the payload and
    /// is opened by the runtime under its own limits.
    ///
    /// # Errors
    ///
    /// Returns `NormalizeError` only for input that is too large or is not a
    /// JSON object.
    fn transcript_path(&self, input: RawHookInput<'_>) -> Result<Option<String>, NormalizeError> {
        let _ = input;
        Ok(None)
    }

    /// Reads a `git worktree add` the agent is about to run out of a tool
    /// payload, so the hook runtime can intercept it. Reported alongside the
    /// neutral events rather than as one of them because it is a request to
    /// act before the tool runs, not an observation. Providers without a
    /// shell tool keep the default.
    ///
    /// # Errors
    ///
    /// Returns `NormalizeError` only for input that is too large or is not a
    /// JSON object.
    fn worktree_intent(
        &self,
        input: RawHookInput<'_>,
    ) -> Result<Option<WorktreeIntent>, NormalizeError> {
        let _ = input;
        Ok(None)
    }
}

/// Parses a payload as a JSON object under the shared size limit.
///
/// # Errors
///
/// Returns `TooLarge` past `limit` and `NotAnObject` for invalid JSON or a
/// non-object root.
pub fn parse_object(bytes: &[u8], limit: usize) -> Result<Map<String, Value>, NormalizeError> {
    if bytes.len() > limit {
        return Err(NormalizeError::TooLarge { limit });
    }
    match serde_json::from_slice::<Value>(bytes) {
        Ok(Value::Object(object)) => Ok(object),
        _ => Err(NormalizeError::NotAnObject),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_object_enforces_the_limit_before_parsing() {
        let payload = vec![b'{'; 8];
        assert_eq!(
            parse_object(&payload, 4),
            Err(NormalizeError::TooLarge { limit: 4 })
        );
        assert_eq!(parse_object(b"[1]", 64), Err(NormalizeError::NotAnObject));
        assert_eq!(
            parse_object(b"not json", 64),
            Err(NormalizeError::NotAnObject)
        );
        let object = parse_object(b"{\"a\":1}", 64).expect("object");
        assert_eq!(object.get("a"), Some(&Value::from(1)));
    }
}
