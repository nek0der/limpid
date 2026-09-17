//! The per-run record that state files carry.
//!
//! Version 2 is what the shell receivers write today; version 3 is what the
//! Rust hook runtime writes. Both are accepted on the way in so a run whose
//! writer changes between backends keeps one record with a monotonic
//! revision. Fields the model does not know are carried in `extra` rather
//! than dropped, because an older reader must not erase what a newer writer
//! recorded.

use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::BTreeMap;

/// Longest prompt, title, or detail text kept in a record, matching the
/// title resolver's candidate limit.
pub const MAX_RECORD_TEXT_BYTES: usize = 4_096;

/// Lifecycle state of one run, as the badge and Waiting rules read it.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum RunState {
    Idle,
    Running,
    NeedsInput,
    Compacting,
    Finished,
    Error,
    /// Also the target of any state string this version does not know, so a
    /// newer writer's record still decodes and is treated as unknown.
    #[serde(other)]
    Unknown,
}

impl RunState {
    /// Display priority used when several runs compete for one pane badge.
    #[must_use]
    pub fn priority(self) -> u8 {
        match self {
            Self::Error => 5,
            Self::NeedsInput => 4,
            Self::Finished => 3,
            Self::Running | Self::Compacting => 2,
            Self::Idle => 1,
            Self::Unknown => 0,
        }
    }
}

/// A version 3 run record. Timestamps are ISO-8601 UTC strings with second
/// precision, as the shell wrote them; ordering between writers uses
/// `revision`, not the timestamp.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RunRecord {
    pub schema_version: u32,
    pub pane_id: String,
    /// UUID of the shim invocation; the record file name. Absent only for
    /// pane-scoped records from before run ids existed.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub run_id: Option<String>,
    /// Monotonic per-run counter. Required in version 3; a version 2 record
    /// may lack it, in which case readers fall back to `updated_at`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub revision: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub state_episode_token: Option<String>,
    pub state: RunState,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub detail: Option<String>,
    /// Set on prompt submit, cleared when the turn ends. Version 2 wrote an
    /// empty string for "not running"; version 3 writes `null`.
    #[serde(default)]
    pub run_started_at: Option<String>,
    pub updated_at: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_hook_event: Option<String>,
    /// The reason the last session end gave, when it gave one. Kept because
    /// the reason says whether the agent is going or only its conversation
    /// is (`ProviderDescriptor::session_end_restart_reasons`), and a tab is
    /// closed on the answer. Cleared by every event that is not a session
    /// end, so it never outlives the end it describes.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session_end_reason: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub context_tokens: Option<u64>,
    /// Decimal process id as the shell wrote it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pid: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub is_tmux_hosted: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_prompt: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub first_prompt: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub provider_session_title: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub provider_generated_title: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session_started_at: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub turn_base_tree: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub turn_root: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub killed_by_limpid_at: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub resume_attempted_at: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tmux_socket_path: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tmux_session_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tmux_pane_id: Option<String>,
    #[serde(
        default,
        rename = "tmuxServerPID",
        skip_serializing_if = "Option::is_none"
    )]
    pub tmux_server_pid: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tmux_server_started_at: Option<String>,
    /// Fields this version does not model, preserved verbatim.
    #[serde(flatten)]
    pub extra: BTreeMap<String, Value>,
}

impl RunRecord {
    /// The schema version this crate writes.
    pub const SCHEMA_VERSION: u32 = 3;

    /// Decodes a record of any accepted schema version into the version 3
    /// shape.
    ///
    /// # Errors
    ///
    /// Returns `RecordError` when the bytes are not a JSON object, the
    /// schema version is missing or unsupported, or a known field has the
    /// wrong type.
    pub fn decode(bytes: &[u8]) -> Result<Self, RecordError> {
        let value: Value = serde_json::from_slice(bytes)?;
        let Some(object) = value.as_object() else {
            return Err(RecordError::NotAnObject);
        };
        let version = object
            .get("schemaVersion")
            .and_then(Value::as_u64)
            .ok_or(RecordError::MissingSchemaVersion)?;
        match version {
            // Version 1 records were pane-scoped but carried the same fields.
            1 | 2 => Ok(Self::from(serde_json::from_value::<RunRecordV2>(value)?)),
            3 => Ok(serde_json::from_value(value)?),
            other => Err(RecordError::UnsupportedSchemaVersion(other)),
        }
    }

    /// Encodes the record as compact JSON.
    ///
    /// # Errors
    ///
    /// Returns `RecordError::Serialization` if JSON serialization fails.
    pub fn encode(&self) -> Result<Vec<u8>, RecordError> {
        Ok(serde_json::to_vec(self)?)
    }
}

/// The record shape the shell receivers write. Differences from version 3:
/// `runStartedAt` is always present and empty when not running, and
/// `revision` may be absent on very old records.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RunRecordV2 {
    pub schema_version: u32,
    pub pane_id: String,
    #[serde(default)]
    pub run_id: Option<String>,
    #[serde(default)]
    pub revision: Option<u64>,
    #[serde(default)]
    pub state_episode_token: Option<String>,
    pub state: RunState,
    #[serde(default)]
    pub detail: Option<String>,
    #[serde(default)]
    pub run_started_at: Option<String>,
    pub updated_at: String,
    #[serde(default)]
    pub last_hook_event: Option<String>,
    #[serde(default)]
    pub context_tokens: Option<u64>,
    #[serde(default)]
    pub pid: Option<String>,
    #[serde(default)]
    pub is_tmux_hosted: Option<bool>,
    #[serde(default)]
    pub last_prompt: Option<String>,
    #[serde(default)]
    pub first_prompt: Option<String>,
    #[serde(default)]
    pub session_id: Option<String>,
    #[serde(default)]
    pub provider_session_title: Option<String>,
    #[serde(default)]
    pub provider_generated_title: Option<String>,
    #[serde(default)]
    pub session_started_at: Option<String>,
    #[serde(default)]
    pub turn_base_tree: Option<String>,
    #[serde(default)]
    pub turn_root: Option<String>,
    #[serde(default)]
    pub killed_by_limpid_at: Option<String>,
    #[serde(default)]
    pub resume_attempted_at: Option<String>,
    #[serde(default)]
    pub tmux_socket_path: Option<String>,
    #[serde(default)]
    pub tmux_session_id: Option<String>,
    #[serde(default)]
    pub tmux_pane_id: Option<String>,
    #[serde(default, rename = "tmuxServerPID")]
    pub tmux_server_pid: Option<String>,
    #[serde(default)]
    pub tmux_server_started_at: Option<String>,
    #[serde(flatten)]
    pub extra: BTreeMap<String, Value>,
}

impl From<RunRecordV2> for RunRecord {
    fn from(record: RunRecordV2) -> Self {
        Self {
            schema_version: Self::SCHEMA_VERSION,
            pane_id: record.pane_id,
            run_id: record.run_id,
            revision: record.revision,
            state_episode_token: record.state_episode_token,
            state: record.state,
            detail: record.detail.filter(|value| !value.is_empty()),
            run_started_at: record.run_started_at.filter(|value| !value.is_empty()),
            updated_at: record.updated_at,
            last_hook_event: record.last_hook_event,
            // Version 2 never wrote one; a session end from such a record
            // reads as the agent having gone, as it did before.
            session_end_reason: None,
            context_tokens: record.context_tokens,
            pid: record.pid,
            is_tmux_hosted: record.is_tmux_hosted,
            last_prompt: record.last_prompt,
            first_prompt: record.first_prompt,
            session_id: record.session_id,
            provider_session_title: record.provider_session_title,
            provider_generated_title: record.provider_generated_title,
            session_started_at: record.session_started_at,
            turn_base_tree: record.turn_base_tree,
            turn_root: record.turn_root,
            killed_by_limpid_at: record.killed_by_limpid_at,
            resume_attempted_at: record.resume_attempted_at,
            tmux_socket_path: record.tmux_socket_path,
            tmux_session_id: record.tmux_session_id,
            tmux_pane_id: record.tmux_pane_id,
            tmux_server_pid: record.tmux_server_pid,
            tmux_server_started_at: record.tmux_server_started_at,
            extra: record.extra,
        }
    }
}

/// Why record bytes could not be decoded.
#[derive(Debug, thiserror::Error)]
pub enum RecordError {
    #[error("record is not a JSON object")]
    NotAnObject,
    #[error("record has no schemaVersion")]
    MissingSchemaVersion,
    #[error("record schema version {0} is not supported")]
    UnsupportedSchemaVersion(u64),
    #[error("record JSON: {0}")]
    Serialization(#[from] serde_json::Error),
}

#[cfg(test)]
mod tests {
    use super::*;

    const V2: &str = r#"{"schemaVersion":2,"paneId":"6F1D6A1E-0E34-4A1A-9A8E-2F2B6C1D7F10","state":"idle","detail":"","runStartedAt":"","updatedAt":"2026-09-14T00:00:00Z","lastHookEvent":"SessionStart","pid":"123","sessionId":"abc","stateEpisodeToken":"1","runId":"6F1D6A1E-0E34-4A1A-9A8E-2F2B6C1D7F11","revision":1,"futureField":{"nested":true}}"#;

    #[test]
    fn version_two_empty_run_started_at_becomes_none() {
        let record = RunRecord::decode(V2.as_bytes()).expect("decodes");
        assert_eq!(record.schema_version, 3);
        assert_eq!(record.run_started_at, None);
        assert_eq!(record.detail, None);
        assert_eq!(record.revision, Some(1));
        assert_eq!(record.state, RunState::Idle);
        assert_eq!(record.pid.as_deref(), Some("123"));
    }

    #[test]
    fn version_two_without_revision_keeps_none() {
        let json = V2.replace(",\"revision\":1", "");
        let record = RunRecord::decode(json.as_bytes()).expect("decodes");
        assert_eq!(record.revision, None);
    }

    #[test]
    fn unknown_fields_survive_a_round_trip() {
        let record = RunRecord::decode(V2.as_bytes()).expect("decodes");
        assert_eq!(
            record.extra.get("futureField"),
            Some(&serde_json::json!({"nested": true}))
        );
        let encoded = record.encode().expect("encodes");
        let again = RunRecord::decode(&encoded).expect("decodes again");
        assert_eq!(again, record);
        let text = String::from_utf8(encoded).expect("utf8");
        assert!(text.contains("\"futureField\":{\"nested\":true}"));
        assert!(text.contains("\"schemaVersion\":3"));
        let value: Value = serde_json::from_str(&text).expect("json");
        assert_eq!(value["runStartedAt"], Value::Null);
    }

    #[test]
    fn unknown_state_strings_decode_as_unknown() {
        let json = V2.replace("\"state\":\"idle\"", "\"state\":\"hibernating\"");
        let record = RunRecord::decode(json.as_bytes()).expect("decodes");
        assert_eq!(record.state, RunState::Unknown);
        assert_eq!(
            serde_json::to_string(&RunState::NeedsInput).expect("ok"),
            "\"needsInput\""
        );
    }

    #[test]
    fn rejects_missing_or_unsupported_schema_versions() {
        assert!(matches!(
            RunRecord::decode(b"{\"paneId\":\"x\"}"),
            Err(RecordError::MissingSchemaVersion)
        ));
        let json = V2.replace("\"schemaVersion\":2", "\"schemaVersion\":9");
        assert!(matches!(
            RunRecord::decode(json.as_bytes()),
            Err(RecordError::UnsupportedSchemaVersion(9))
        ));
        assert!(matches!(
            RunRecord::decode(b"[]"),
            Err(RecordError::NotAnObject)
        ));
        assert!(matches!(
            RunRecord::decode(b"{"),
            Err(RecordError::Serialization(_))
        ));
    }

    #[test]
    fn priorities_order_the_states() {
        assert!(RunState::Error.priority() > RunState::NeedsInput.priority());
        assert!(RunState::NeedsInput.priority() > RunState::Finished.priority());
        assert!(RunState::Finished.priority() > RunState::Running.priority());
        assert_eq!(
            RunState::Running.priority(),
            RunState::Compacting.priority()
        );
        assert!(RunState::Idle.priority() > RunState::Unknown.priority());
    }
}
