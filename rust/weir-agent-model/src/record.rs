//! The per-run record that state files carry.
//!
//! Version 2 is what earlier builds' shell receivers wrote; version 3 is what
//! the Rust hook runtime writes. Both are accepted on the way in, so a record
//! an earlier build left keeps one record with a monotonic revision once the
//! runtime writes it. Fields the model does not know are carried in `extra` rather
//! than dropped, because an older reader must not erase what a newer writer
//! recorded.

use crate::background::BackgroundWork;
use crate::cache::CacheWindow;
use crate::serde_helpers::lenient;
use crate::session_settings::PermissionMode;
use crate::usage::UsageLimit;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::BTreeMap;

/// Longest prompt, title, or detail text kept in a record, matching the
/// title resolver's candidate limit.
pub const MAX_RECORD_TEXT_BYTES: usize = 4_096;

/// What a run record's file name ends with in its provider's state directory.
/// The rest of the name is the record's storage id: its run id, or the launch
/// pane id for a record from before run ids existed.
///
/// Declared once because the hook runtime writes the file under this name and
/// the host finds, rewrites, and retires it by the same name. The host asks the
/// bridge for this value rather than keeping a copy, since a copy that drifted
/// would compile, pass its own tests, and leave every run invisible. Records
/// already on disk, some written by earlier builds' shell receivers, use
/// exactly this name, so changing it strands them.
pub const RUN_RECORD_FILE_SUFFIX: &str = ".state.json";

/// The file name of the run record stored under `storage_id`.
#[must_use]
pub fn run_record_file_name(storage_id: &str) -> String {
    format!("{storage_id}{RUN_RECORD_FILE_SUFFIX}")
}

/// Lifecycle state of one run, as the badge and attention rules read it.
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
    ///
    /// A run waiting for an answer outranks one that stopped: Weir can
    /// answer the request only until its deadline (570 s, set by the provider
    /// adapters under the provider's 600 s hook timeout), and after that the
    /// person has to answer at the agent's own prompt in the terminal. A
    /// stopped run has no such deadline. Swift's `PanePriority` holds the
    /// same order (a wait before a stop before an unread turn) for the
    /// attention items.
    #[must_use]
    pub const fn priority(self) -> u8 {
        match self {
            Self::NeedsInput => 5,
            Self::Error => 4,
            Self::Finished => 3,
            Self::Running | Self::Compacting => 2,
            Self::Idle => 1,
            Self::Unknown => 0,
        }
    }

    /// Whether the run is at work: running, compacting, or waiting on the
    /// person's answer before it goes on. The one set every rule that asks
    /// "is this run working" reads: whether a run works outside a turn, whether
    /// a retired run died mid-work, and whether a restore must wait for it.
    /// Swift's `AgentState.isMidTurn` holds the same set; the two sides check
    /// it against `rust/fixtures/contract/shared-values.json`.
    #[must_use]
    pub const fn is_at_work(self) -> bool {
        matches!(self, Self::Running | Self::NeedsInput | Self::Compacting)
    }
}

/// What a run waiting in `NeedsInput` waits on, as the event that put it
/// there said: the provider's permission request, or its own question tool.
/// The interface words the wait from this rather than from `detail`, which
/// is text for people and can be a question that happens to read like a
/// tool's request.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum WaitKind {
    Approval,
    Question,
    /// The agent cannot go on until the person signs in again. No hook says
    /// so; only the agent's own status report does (`ProgramStatus`), so no
    /// record carries it, only a badge.
    SignIn,
    /// A kind a newer writer added, read as no kind at all.
    #[serde(other)]
    Unknown,
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
    /// Immutable monotonic-clock stamp minted by the launching shim. We
    /// compare it only within one boot's terminal endpoint, never as a date.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub run_launch_order: Option<u64>,
    /// The enclosing shim invocation, when this run was launched by an agent.
    #[serde(
        default,
        rename = "parentRunID",
        skip_serializing_if = "Option::is_none"
    )]
    pub parent_run_id: Option<String>,
    /// Monotonic stamp of the latest hook reporting this run's own model or
    /// permission mode.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub run_observed_order: Option<u64>,
    /// Monotonic per-run counter. Required in version 3; a version 2 record
    /// may lack it, in which case readers fall back to `updated_at`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub revision: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub state_episode_token: Option<String>,
    pub state: RunState,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub detail: Option<String>,
    /// The tool `detail` is about, as the provider named it (`Bash`,
    /// `Write`, `apply_patch`). Written with `detail` by a tool event and
    /// kept with it by the permission request that follows, so a reader
    /// need not take the name back out of the text. Absent in records
    /// written before the field existed.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tool: Option<String>,
    /// What the run waits on while it is in `NeedsInput`; absent in any
    /// other state and in records written before the field existed. It is
    /// read leniently like the cache window: a shape this build cannot read
    /// is no kind, and the interface falls back to reading `detail`.
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        deserialize_with = "lenient"
    )]
    pub wait_kind: Option<WaitKind>,
    /// This is the provider's transcript of the conversation, as the prompt
    /// that began the run's turn or the event that put it in `NeedsInput`
    /// named it. It is absent outside a turn unless the run waits, for a
    /// provider that keeps no transcript, and in records written before the
    /// field existed. Claude sends no hook when the person declines its
    /// question or permission prompt with Esc, so the transcript is the only
    /// place that says the wait is over, and the app reads it from here
    /// while the run waits (the projection's declined wait). Nor does it
    /// send one when the person stops its work, so the app reads what a
    /// turn it ends that way used from here too (`end_stopped_turn`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub transcript_path: Option<String>,
    /// Set on prompt submit, cleared when the turn ends. Version 2 wrote an
    /// empty string for "not running"; version 3 writes `null`.
    #[serde(default)]
    pub run_started_at: Option<String>,
    pub updated_at: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_hook_event: Option<String>,
    /// Decimal process id as the shell wrote it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pid: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub is_tmux_hosted: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_prompt: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub first_prompt: Option<String>,
    /// Whether the session holds a conversation at all: a prompt was given
    /// in this run, or the session resumed one that exists on disk. `false`
    /// is a session started anew that never received a prompt, which has no
    /// transcript to resume, so a relaunch retires it quietly instead of
    /// typing a resume that cannot succeed. Absent in a record from
    /// before the field, which is read as "could be either".
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub has_prompt: Option<bool>,
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
    /// The worktree the run's latest prompt was given in, whether or not its
    /// snapshot was taken (`turn_root` is set only when it was). A restore
    /// of that worktree refuses while the run is at work.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub worktree_root: Option<String>,
    /// The run's latest turn record (`turns/<id>.turn.json`). Set only after
    /// that record is written, so a reader that follows it finds the file;
    /// a turn the next prompt overtook stays on disk without it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub current_turn_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub killed_by_weir_at: Option<String>,
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
    /// The prompt cache as the last finished turn left it. Set by the event
    /// that ends a turn and cleared by everything that starts or ends work,
    /// so a value here always describes the turn the run is resting after.
    /// Absent in every record written before the field existed, which reads
    /// as unknown.
    ///
    /// It is read leniently, so the field never vetoes the record. The window
    /// is an estimate behind the interface's cache clock; a newer writer that
    /// adds a precision this build does not know, or a value of the wrong
    /// shape, must cost that estimate and nothing else, never the run's
    /// badge. So an older build that rewrites the record drops a window a
    /// newer build wrote and it could not read, and the clock is gone until
    /// the next turn leaves one. That is acceptable for an estimate: a
    /// missing clock misleads no one, while keeping a value this build cannot
    /// check would.
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        deserialize_with = "lenient"
    )]
    pub cache_window: Option<CacheWindow>,
    /// The usage limit the run's last failure hit, set by every failure and
    /// consulted only while the run rests in error. Absent in records
    /// written before the field existed, and read leniently like the cache
    /// window: a shape this build cannot read costs the limit's time, never
    /// the record.
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        deserialize_with = "lenient"
    )]
    pub usage_limit: Option<UsageLimit>,
    /// Where a run working outside a turn returns when the agent is idle
    /// again: `idle` for work that began at the prompt after a session
    /// start, `finished` for work after a turn ended. Set by the tool event
    /// that begins that work and kept only while it lasts, so a record with
    /// it set always shows work no turn holds. Absent in records written
    /// before the field existed, which return to `finished`, and read
    /// leniently like the cache window.
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        deserialize_with = "lenient"
    )]
    pub outside_turn_rest: Option<RunState>,
    /// What the agent left running when its last turn ended, as that turn's
    /// stop reported it. Set by the stop and cleared by the next prompt,
    /// failure, interrupt, or session start or end, so a value here describes
    /// the turn the run last came to rest after, kept through work outside
    /// that turn; the badge reads it only while the run rests finished.
    /// Absent in records written before the field existed, and read
    /// leniently like the cache window.
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        deserialize_with = "lenient"
    )]
    pub background_work: Option<BackgroundWork>,
    /// The model the session runs, as the adapter names it for a person to
    /// read (`SessionSettings`). Kept from the last call that said, since
    /// most calls do not. Absent until one does, and in records written
    /// before the field existed. Read leniently like the cache window, as is
    /// the mode below: a value this build cannot read costs the header that
    /// value, never the record.
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        deserialize_with = "lenient"
    )]
    pub model: Option<String>,
    /// How hard the session's model reasons, kept as `model` is.
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        deserialize_with = "lenient"
    )]
    pub effort: Option<String>,
    /// How freely the session may act without asking, kept as `model` is.
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        deserialize_with = "lenient"
    )]
    pub permission_mode: Option<PermissionMode>,
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

/// The record shape earlier builds' shell receivers wrote. Differences from
/// version 3:
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
    pub killed_by_weir_at: Option<String>,
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
            // The shell receivers recorded neither.
            tool: None,
            wait_kind: None,
            transcript_path: None,
            run_started_at: record.run_started_at.filter(|value| !value.is_empty()),
            updated_at: record.updated_at,
            last_hook_event: record.last_hook_event,
            pid: record.pid,
            is_tmux_hosted: record.is_tmux_hosted,
            last_prompt: record.last_prompt,
            first_prompt: record.first_prompt,
            // The shell receivers did not record where a session came from.
            has_prompt: None,
            session_id: record.session_id,
            provider_session_title: record.provider_session_title,
            provider_generated_title: record.provider_generated_title,
            session_started_at: record.session_started_at,
            run_launch_order: None,
            parent_run_id: None,
            run_observed_order: None,
            turn_base_tree: record.turn_base_tree,
            turn_root: record.turn_root,
            worktree_root: None,
            // The shell receivers wrote no turn records.
            current_turn_id: None,
            killed_by_weir_at: record.killed_by_weir_at,
            resume_attempted_at: record.resume_attempted_at,
            tmux_socket_path: record.tmux_socket_path,
            tmux_session_id: record.tmux_session_id,
            tmux_pane_id: record.tmux_pane_id,
            tmux_server_pid: record.tmux_server_pid,
            tmux_server_started_at: record.tmux_server_started_at,
            // The shell receivers never estimated the cache.
            cache_window: None,
            usage_limit: None,
            outside_turn_rest: None,
            background_work: None,
            // The shell receivers recorded neither.
            model: None,
            effort: None,
            permission_mode: None,
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
    fn the_record_file_name_matches_what_is_already_on_disk() {
        // Existing records, earlier builds' among them, use this name; a change
        // here must come with a migration, not slip through as a rename.
        assert_eq!(
            run_record_file_name("6F1D6A1E-0E34-4A1A-9A8E-2F2B6C1D7F11"),
            "6F1D6A1E-0E34-4A1A-9A8E-2F2B6C1D7F11.state.json"
        );
    }

    #[test]
    fn launch_order_is_optional_and_preserves_all_integer_bits() {
        for json in [
            V2.to_owned(),
            V2.replace("\"schemaVersion\":2", "\"schemaVersion\":3"),
        ] {
            let record = RunRecord::decode(json.as_bytes()).expect("older record");
            assert_eq!(record.run_launch_order, None);
            assert!(
                !String::from_utf8(record.encode().expect("encodes"))
                    .expect("text")
                    .contains("runLaunchOrder")
            );
            let ordered = RunRecord {
                run_launch_order: Some(u64::MAX),
                parent_run_id: Some("6F1D6A1E-0E34-4A1A-9A8E-2F2B6C1D7F10".into()),
                run_observed_order: Some(u64::MAX),
                ..record
            };
            let again = RunRecord::decode(&ordered.encode().expect("encodes")).expect("decodes");
            assert_eq!(again.run_launch_order, Some(u64::MAX));
            assert_eq!(again.parent_run_id, ordered.parent_run_id);
            assert_eq!(again.run_observed_order, Some(u64::MAX));
        }
    }

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

    /// Earlier builds wrote `contextTokens`, from a field no agent sends;
    /// one still on disk is carried as any unknown field is.
    #[test]
    fn a_record_with_the_retired_token_count_still_decodes() {
        let json = V2.replace("\"pid\":\"123\"", "\"pid\":\"123\",\"contextTokens\":42");
        let record = RunRecord::decode(json.as_bytes()).expect("decodes");
        assert_eq!(
            record.extra.get("contextTokens"),
            Some(&serde_json::json!(42))
        );
    }

    #[test]
    fn the_cache_window_round_trips_and_its_absence_still_decodes() {
        let json = V2.replace("\"schemaVersion\":2", "\"schemaVersion\":3");
        let record = RunRecord::decode(json.as_bytes()).expect("decodes without the field");
        assert_eq!(record.cache_window, None);
        let text = String::from_utf8(record.encode().expect("encodes")).expect("utf8");
        assert!(!text.contains("cacheWindow"), "absent stays absent");

        let window = CacheWindow {
            observed_at: "2026-09-14T00:00:00Z".to_owned(),
            ttl_seconds: 3600,
            rewrite_tokens: Some(573_000),
            precision: crate::cache::CachePrecision::Estimated,
        };
        let with_window = RunRecord {
            cache_window: Some(window.clone()),
            ..record
        };
        let encoded = with_window.encode().expect("encodes");
        let text = String::from_utf8(encoded.clone()).expect("utf8");
        assert!(text.contains(r#""cacheWindow":{"observedAt":"2026-09-14T00:00:00Z","#));
        let again = RunRecord::decode(&encoded).expect("decodes again");
        assert_eq!(again.cache_window, Some(window));
        assert!(!again.extra.contains_key("cacheWindow"));
    }

    #[test]
    fn the_wait_kind_round_trips_and_a_kind_this_build_does_not_know_is_unknown() {
        let json = V2.replace("\"schemaVersion\":2", "\"schemaVersion\":3");
        let record = RunRecord::decode(json.as_bytes()).expect("decodes without the fields");
        assert_eq!(record.wait_kind, None);
        assert_eq!(record.tool, None);
        let encoded = RunRecord {
            wait_kind: Some(WaitKind::Question),
            tool: Some("AskUserQuestion".to_owned()),
            ..record
        }
        .encode()
        .expect("encodes");
        let text = String::from_utf8(encoded.clone()).expect("utf8");
        assert!(text.contains(r#""tool":"AskUserQuestion","waitKind":"question""#));
        let again = RunRecord::decode(&encoded).expect("decodes again");
        assert_eq!(again.wait_kind, Some(WaitKind::Question));
        assert!(!again.extra.contains_key("waitKind"));

        let newer = json.replace("\"revision\":1", r#""revision":1,"waitKind":"plan""#);
        let record = RunRecord::decode(newer.as_bytes()).expect("the record survives");
        assert_eq!(record.wait_kind, Some(WaitKind::Unknown));
        let unreadable = json.replace("\"revision\":1", r#""revision":1,"waitKind":7"#);
        let record = RunRecord::decode(unreadable.as_bytes()).expect("the record survives");
        assert_eq!(record.wait_kind, None);
    }

    #[test]
    fn the_transcript_path_round_trips_and_its_absence_still_decodes() {
        let json = V2.replace("\"schemaVersion\":2", "\"schemaVersion\":3");
        let record = RunRecord::decode(json.as_bytes()).expect("decodes without the field");
        assert_eq!(record.transcript_path, None);
        let text = String::from_utf8(record.encode().expect("encodes")).expect("utf8");
        assert!(!text.contains("transcriptPath"), "absent stays absent");
        let encoded = RunRecord {
            transcript_path: Some("/t/session.jsonl".to_owned()),
            ..record
        }
        .encode()
        .expect("encodes");
        let text = String::from_utf8(encoded.clone()).expect("utf8");
        assert!(text.contains(r#""transcriptPath":"/t/session.jsonl""#));
        let again = RunRecord::decode(&encoded).expect("decodes again");
        assert_eq!(again.transcript_path.as_deref(), Some("/t/session.jsonl"));
        assert!(!again.extra.contains_key("transcriptPath"));
    }

    #[test]
    fn the_usage_limit_round_trips_and_a_shape_this_build_cannot_read_costs_only_the_limit() {
        let json = V2.replace("\"schemaVersion\":2", "\"schemaVersion\":3");
        let record = RunRecord::decode(json.as_bytes()).expect("decodes without the field");
        assert_eq!(record.usage_limit, None);
        let limit = UsageLimit {
            resets_at: Some("2026-09-14T05:00:00Z".to_owned()),
            window: Some("five_hour".to_owned()),
        };
        let encoded = RunRecord {
            usage_limit: Some(limit.clone()),
            ..record
        }
        .encode()
        .expect("encodes");
        let again = RunRecord::decode(&encoded).expect("decodes again");
        assert_eq!(again.usage_limit, Some(limit));

        let unreadable = V2
            .replace("\"schemaVersion\":2", "\"schemaVersion\":3")
            .replace(
                "\"revision\":1",
                r#""revision":1,"usageLimit":{"resetsAt":7}"#,
            );
        let record = RunRecord::decode(unreadable.as_bytes()).expect("the record survives");
        assert_eq!(record.usage_limit, None);
    }

    #[test]
    fn a_cache_window_this_build_cannot_read_costs_only_the_window() {
        let json = V2.replace("\"schemaVersion\":2", "\"schemaVersion\":3").replace(
            "\"revision\":1",
            r#""revision":1,"cacheWindow":{"observedAt":"2026-09-14T00:00:00Z","ttlSeconds":3600,"precision":"measured"}"#,
        );
        let record = RunRecord::decode(json.as_bytes()).expect("the record still decodes");
        assert_eq!(record.cache_window, None);
        assert_eq!(record.revision, Some(1));
        let json = V2
            .replace("\"schemaVersion\":2", "\"schemaVersion\":3")
            .replace("\"revision\":1", r#""revision":1,"cacheWindow":"soon""#);
        let record = RunRecord::decode(json.as_bytes()).expect("the record still decodes");
        assert_eq!(record.cache_window, None);
    }

    #[test]
    fn background_work_round_trips_and_a_shape_this_build_cannot_read_costs_only_it() {
        let json = V2.replace("\"schemaVersion\":2", "\"schemaVersion\":3");
        let record = RunRecord::decode(json.as_bytes()).expect("decodes without the field");
        assert_eq!(record.background_work, None);
        let text = String::from_utf8(record.encode().expect("encodes")).expect("utf8");
        assert!(!text.contains("backgroundWork"), "absent stays absent");

        let work = BackgroundWork {
            shells: 2,
            subagents: 0,
            others: 1,
        };
        let with_work = RunRecord {
            background_work: Some(work),
            ..record
        };
        let encoded = with_work.encode().expect("encodes");
        let text = String::from_utf8(encoded.clone()).expect("utf8");
        assert!(text.contains(r#""backgroundWork":{"shells":2,"others":1}"#));
        let again = RunRecord::decode(&encoded).expect("decodes again");
        assert_eq!(again.background_work, Some(work));
        assert!(!again.extra.contains_key("backgroundWork"));

        for shape in [r#""two shells""#, r#"{"shells":"2"}"#, r#"{"shells":-1}"#] {
            let json = V2
                .replace("\"schemaVersion\":2", "\"schemaVersion\":3")
                .replace(
                    "\"revision\":1",
                    &format!(r#""revision":1,"backgroundWork":{shape}"#),
                );
            let record = RunRecord::decode(json.as_bytes()).expect("the record still decodes");
            assert_eq!(record.background_work, None, "{shape}");
            assert_eq!(record.revision, Some(1));
        }
    }

    #[test]
    fn session_settings_round_trip_and_a_mode_this_build_cannot_read_costs_only_it() {
        let json = V2.replace("\"schemaVersion\":2", "\"schemaVersion\":3");
        let record = RunRecord::decode(json.as_bytes()).expect("decodes without the fields");
        assert_eq!(
            (record.model.as_deref(), record.permission_mode),
            (None, None)
        );

        let with_settings = RunRecord {
            model: Some("Opus 5.5".to_owned()),
            effort: Some("xhigh".to_owned()),
            permission_mode: Some(PermissionMode::BypassPermissions),
            ..record
        };
        let encoded = with_settings.encode().expect("encodes");
        let text = String::from_utf8(encoded.clone()).expect("utf8");
        assert!(text.contains(r#""model":"Opus 5.5""#));
        assert!(text.contains(r#""effort":"xhigh""#));
        assert!(text.contains(r#""permissionMode":"bypassPermissions""#));
        assert_eq!(
            RunRecord::decode(&encoded).expect("decodes again"),
            with_settings
        );

        let json = V2
            .replace("\"schemaVersion\":2", "\"schemaVersion\":3")
            .replace("\"revision\":1", r#""revision":1,"permissionMode":"yolo""#);
        let record = RunRecord::decode(json.as_bytes()).expect("the record still decodes");
        assert_eq!(record.permission_mode, None);
        assert_eq!(record.revision, Some(1));
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
        assert!(RunState::NeedsInput.priority() > RunState::Error.priority());
        assert!(RunState::Error.priority() > RunState::Finished.priority());
        assert!(RunState::Finished.priority() > RunState::Running.priority());
        assert_eq!(
            RunState::Running.priority(),
            RunState::Compacting.priority()
        );
        assert!(RunState::Idle.priority() > RunState::Unknown.priority());
    }

    #[test]
    fn a_run_is_at_work_while_its_turn_goes_on() {
        for state in [
            RunState::Running,
            RunState::NeedsInput,
            RunState::Compacting,
        ] {
            assert!(state.is_at_work(), "{state:?}");
        }
        for state in [
            RunState::Idle,
            RunState::Finished,
            RunState::Error,
            RunState::Unknown,
        ] {
            assert!(!state.is_at_work(), "{state:?}");
        }
    }
}
