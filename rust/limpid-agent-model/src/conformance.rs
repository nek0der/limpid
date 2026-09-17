//! Fixture driver shared by every provider crate.
//!
//! A provider crate's `tests/conformance.rs` calls these functions with its
//! adapter and the fixture directories under `rust/fixtures`. The driver
//! walks `<provider>/<schema-date>/<case>/`, feeds each recorded payload to
//! `normalize` and `approval_request`, and compares the result with the
//! case's `expected.json` and `approval.expected.json`. The negative set is
//! shared by all providers: every adapter must reject oversized or
//! non-object input and pass unknown events through as one `Extension`.

use crate::{
    AgentEvent, ApprovalRequest, HookContext, MAX_HOOK_INPUT_BYTES, NormalizeError,
    ProviderAdapter, RawHookInput,
};
use std::collections::BTreeMap;
use std::fmt;
use std::fs;
use std::path::{Path, PathBuf};
use uuid::Uuid;

/// One mismatch between an adapter and a fixture.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ConformanceFailure {
    /// The case directory or negative file.
    pub case: PathBuf,
    /// The payload file within the case, when applicable.
    pub payload: Option<String>,
    pub expected: String,
    pub got: String,
}

impl fmt::Display for ConformanceFailure {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "{}", self.case.display())?;
        if let Some(payload) = &self.payload {
            write!(formatter, " / {payload}")?;
        }
        write!(
            formatter,
            "\n  expected: {}\n  got:      {}",
            self.expected, self.got
        )
    }
}

impl HookContext {
    /// The context every fixture is replayed under. Stable ids keep
    /// `expected.json` independent of the machine that runs the test.
    #[must_use]
    pub fn fixture() -> Self {
        Self {
            run_id: Uuid::from_u128(0x0000_0000_0000_4000_8000_0000_0000_0010),
            pane_id: Uuid::from_u128(0x0000_0000_0000_4000_8000_0000_0000_0020),
            tmux: None,
            pid: Some(4242),
        }
    }
}

/// Runs every case under `provider_root` through `normalize`.
///
/// # Panics
///
/// Panics when the fixture tree itself is malformed (unreadable directory or
/// `expected.json` that is not `Vec<Vec<AgentEvent>>`), because that is a
/// repository error rather than an adapter failure.
#[must_use]
pub fn run_normalize(
    adapter: &dyn ProviderAdapter,
    provider_root: &Path,
) -> Vec<ConformanceFailure> {
    let mut failures = Vec::new();
    for case in cases_under(provider_root) {
        let expected_path = case.join("expected.json");
        let expected: Vec<Vec<AgentEvent>> = read_json(&expected_path);
        let payloads = payloads_in(&case);
        if payloads.len() != expected.len() {
            failures.push(ConformanceFailure {
                case: case.clone(),
                payload: None,
                expected: format!("{} entries in expected.json", payloads.len()),
                got: format!("{} entries", expected.len()),
            });
        }
        for (index, payload) in payloads.iter().enumerate() {
            let bytes = fs::read(payload).expect("payload is readable");
            let transcript = transcript_for(payload);
            let context = HookContext::fixture();
            let actual = adapter.normalize(
                RawHookInput {
                    bytes: &bytes,
                    transcript: transcript.as_deref(),
                },
                &context,
            );
            let wanted = expected.get(index);
            let matches = matches!((&actual, wanted), (Ok(events), Some(want)) if events == want);
            if !matches {
                failures.push(ConformanceFailure {
                    case: case.clone(),
                    payload: Some(file_name(payload)),
                    expected: wanted
                        .map_or_else(|| "<missing>".to_owned(), |want| format!("{want:?}")),
                    got: format!("{actual:?}"),
                });
            }
        }
    }
    failures
}

/// Runs every payload under `provider_root` through `approval_request`.
///
/// Cases with an `approval.expected.json` map payload file names to the
/// request the adapter must derive (`null` for "not an approval"). Every
/// payload not listed must yield `Ok(None)`.
///
/// # Panics
///
/// Panics when the fixture tree itself is malformed.
#[must_use]
pub fn run_approval(
    adapter: &dyn ProviderAdapter,
    provider_root: &Path,
) -> Vec<ConformanceFailure> {
    let mut failures = Vec::new();
    for case in cases_under(provider_root) {
        let expected_path = case.join("approval.expected.json");
        let expected: BTreeMap<String, Option<ApprovalRequest>> = if expected_path.exists() {
            read_json(&expected_path)
        } else {
            BTreeMap::new()
        };
        for payload in payloads_in(&case) {
            let bytes = fs::read(&payload).expect("payload is readable");
            let actual = adapter.approval_request(RawHookInput {
                bytes: &bytes,
                transcript: None,
            });
            let wanted = expected.get(&file_name(&payload)).cloned().flatten();
            let matches = matches!(&actual, Ok(request) if *request == wanted);
            if !matches {
                failures.push(ConformanceFailure {
                    case: case.clone(),
                    payload: Some(file_name(&payload)),
                    expected: format!("{wanted:?}"),
                    got: format!("{actual:?}"),
                });
            }
        }
    }
    failures
}

/// Runs the shared negative set plus a synthesized oversized payload.
///
/// Each input must produce `TooLarge`, `NotAnObject`, or exactly one
/// `Extension`; the oversized payload is generated here rather than stored,
/// so the repository does not carry a megabyte of padding.
///
/// # Panics
///
/// Panics when `negative_root` cannot be read.
#[must_use]
pub fn run_negative(
    adapter: &dyn ProviderAdapter,
    negative_root: &Path,
) -> Vec<ConformanceFailure> {
    let mut inputs: Vec<(PathBuf, Vec<u8>)> = payloads_in(negative_root)
        .into_iter()
        .map(|path| {
            let bytes = fs::read(&path).expect("negative payload is readable");
            (path, bytes)
        })
        .collect();
    let mut oversized = br#"{"hook_event_name":"Stop","padding":""#.to_vec();
    oversized.resize(MAX_HOOK_INPUT_BYTES + 1024, b'x');
    oversized.extend_from_slice(b"\"}");
    inputs.push((
        negative_root.join("<synthesized oversized payload>"),
        oversized,
    ));

    let context = HookContext::fixture();
    let mut failures = Vec::new();
    for (path, bytes) in inputs {
        let actual = adapter.normalize(
            RawHookInput {
                bytes: &bytes,
                transcript: None,
            },
            &context,
        );
        let accepted = match &actual {
            Err(NormalizeError::TooLarge { .. } | NormalizeError::NotAnObject) => true,
            Ok(events) => matches!(events.as_slice(), [AgentEvent::Extension { .. }]),
        };
        if !accepted {
            failures.push(ConformanceFailure {
                case: path,
                payload: None,
                expected: "TooLarge, NotAnObject, or one Extension".to_owned(),
                got: format!("{actual:?}"),
            });
        }
    }
    failures
}

/// Every `<schema-date>/<case>` directory under a provider's fixture root,
/// sorted so failures are reported in a stable order.
fn cases_under(provider_root: &Path) -> Vec<PathBuf> {
    let mut cases = Vec::new();
    for date in sorted_entries(provider_root) {
        if !date.is_dir() {
            continue;
        }
        for case in sorted_entries(&date) {
            if case.is_dir() {
                cases.push(case);
            }
        }
    }
    cases
}

/// Payload files in a case: `NNNN-<Event>.json`, sorted by name so the
/// recorder's sequence number orders them.
fn payloads_in(case: &Path) -> Vec<PathBuf> {
    sorted_entries(case)
        .into_iter()
        .filter(|path| {
            path.extension()
                .is_some_and(|extension| extension == "json")
                && !file_name(path).ends_with("expected.json")
        })
        .collect()
}

fn transcript_for(payload: &Path) -> Option<Vec<u8>> {
    let name = file_name(payload);
    let stem = name.strip_suffix(".json")?;
    let transcript = payload.with_file_name(format!("{stem}.transcript.jsonl"));
    fs::read(transcript).ok()
}

fn sorted_entries(directory: &Path) -> Vec<PathBuf> {
    let mut entries: Vec<PathBuf> = fs::read_dir(directory)
        .unwrap_or_else(|error| panic!("read {}: {error}", directory.display()))
        .map(|entry| entry.expect("directory entry").path())
        .collect();
    entries.sort();
    entries
}

fn file_name(path: &Path) -> String {
    path.file_name()
        .map(|name| name.to_string_lossy().into_owned())
        .unwrap_or_default()
}

fn read_json<T: serde::de::DeserializeOwned>(path: &Path) -> T {
    let bytes = fs::read(path).unwrap_or_else(|error| panic!("read {}: {error}", path.display()));
    serde_json::from_slice(&bytes)
        .unwrap_or_else(|error| panic!("parse {}: {error}", path.display()))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{
        ApprovalDecision, Capability, InstallRecipe, ProviderDescriptor, ProviderId,
        ProviderOutput, parse_object,
    };
    use std::collections::BTreeSet;

    /// Turns every object into one `Extension` named after its event, and
    /// treats a `PermissionRequest` as an approval for `tool_name`.
    struct PassThrough {
        descriptor: ProviderDescriptor,
    }

    impl PassThrough {
        fn new() -> Self {
            let id = ProviderId::new("fake").expect("valid");
            Self {
                descriptor: ProviderDescriptor {
                    state_directory: ProviderDescriptor::default_state_directory(&id),
                    session_directory: ProviderDescriptor::default_session_directory(&id),
                    cwd_events_directory: None,
                    id,
                    display_name: "Fake".into(),
                    capabilities: BTreeSet::from([Capability::ApprovalHook]),
                    pid_sweep_interval_ms: 1000,
                    process_names: vec!["fake".into()],
                    session_end_drop_reasons: Vec::new(),
                    session_end_restart_reasons: Vec::new(),
                },
            }
        }
    }

    impl ProviderAdapter for PassThrough {
        fn descriptor(&self) -> &ProviderDescriptor {
            &self.descriptor
        }

        fn install_recipe(&self) -> InstallRecipe {
            InstallRecipe::default()
        }

        fn normalize(
            &self,
            input: RawHookInput<'_>,
            _context: &HookContext,
        ) -> Result<Vec<AgentEvent>, NormalizeError> {
            let object = parse_object(input.bytes, MAX_HOOK_INPUT_BYTES)?;
            let name = object
                .get("hook_event_name")
                .and_then(serde_json::Value::as_str)
                .unwrap_or("unknown")
                .to_owned();
            Ok(vec![AgentEvent::Extension {
                name,
                payload: serde_json::Value::Object(object),
            }])
        }

        fn approval_request(
            &self,
            input: RawHookInput<'_>,
        ) -> Result<Option<ApprovalRequest>, NormalizeError> {
            let object = parse_object(input.bytes, MAX_HOOK_INPUT_BYTES)?;
            if object
                .get("hook_event_name")
                .and_then(serde_json::Value::as_str)
                != Some("PermissionRequest")
            {
                return Ok(None);
            }
            Ok(Some(ApprovalRequest {
                provider: self.descriptor.id.clone(),
                session_id: None,
                operation_id: None,
                tool_name: object
                    .get("tool_name")
                    .and_then(serde_json::Value::as_str)
                    .unwrap_or_default()
                    .to_owned(),
                summary: None,
                input: serde_json::Value::Null,
                timeout_ms: 1,
            }))
        }

        fn approval_output(&self, _decision: &ApprovalDecision) -> ProviderOutput {
            ProviderOutput::default()
        }
    }

    /// Produces no events at all, which the negative set must reject.
    struct Empty(PassThrough);
    impl ProviderAdapter for Empty {
        fn descriptor(&self) -> &ProviderDescriptor {
            self.0.descriptor()
        }
        fn install_recipe(&self) -> InstallRecipe {
            InstallRecipe::default()
        }
        fn normalize(
            &self,
            _input: RawHookInput<'_>,
            _context: &HookContext,
        ) -> Result<Vec<AgentEvent>, NormalizeError> {
            Ok(Vec::new())
        }
        fn approval_request(
            &self,
            _input: RawHookInput<'_>,
        ) -> Result<Option<ApprovalRequest>, NormalizeError> {
            Ok(None)
        }
        fn approval_output(&self, _decision: &ApprovalDecision) -> ProviderOutput {
            ProviderOutput::default()
        }
    }

    /// A scratch fixture tree that removes itself.
    struct Tree(PathBuf);

    impl Tree {
        fn new(name: &str) -> Self {
            let root =
                std::env::temp_dir().join(format!("limpid-conformance-{name}-{}", Uuid::new_v4()));
            fs::create_dir_all(&root).expect("create scratch tree");
            Self(root)
        }

        fn write(&self, relative: &str, contents: &str) {
            let path = self.0.join(relative);
            fs::create_dir_all(path.parent().expect("parent")).expect("create case");
            fs::write(path, contents).expect("write fixture");
        }
    }

    impl Drop for Tree {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    fn matching_expectations_report_no_failures() {
        let tree = Tree::new("ok");
        tree.write(
            "2026-09/basic/0000-Stop.json",
            r#"{"hook_event_name":"Stop","x":1}"#,
        );
        tree.write(
            "2026-09/basic/expected.json",
            r#"[[{"type":"extension","name":"Stop","payload":{"hook_event_name":"Stop","x":1}}]]"#,
        );
        assert_eq!(run_normalize(&PassThrough::new(), &tree.0), Vec::new());
        assert_eq!(run_approval(&PassThrough::new(), &tree.0), Vec::new());
    }

    #[test]
    fn mismatches_and_missing_expectations_are_reported_per_payload() {
        let tree = Tree::new("mismatch");
        tree.write(
            "2026-09/basic/0000-Stop.json",
            r#"{"hook_event_name":"Stop"}"#,
        );
        tree.write(
            "2026-09/basic/0001-Stop.json",
            r#"{"hook_event_name":"Stop"}"#,
        );
        tree.write(
            "2026-09/basic/expected.json",
            r#"[[{"type":"compacting"}]]"#,
        );
        let failures = run_normalize(&PassThrough::new(), &tree.0);
        let payloads: Vec<Option<String>> = failures
            .iter()
            .map(|failure| failure.payload.clone())
            .collect();
        assert_eq!(
            payloads,
            vec![
                None,
                Some("0000-Stop.json".into()),
                Some("0001-Stop.json".into())
            ]
        );
        assert!(failures[2].expected.contains("<missing>"));
    }

    #[test]
    fn approval_expectations_cover_listed_and_unlisted_payloads() {
        let tree = Tree::new("approval");
        tree.write(
            "2026-09/ask/0000-PermissionRequest.json",
            r#"{"hook_event_name":"PermissionRequest","tool_name":"Bash"}"#,
        );
        tree.write(
            "2026-09/ask/0001-Stop.json",
            r#"{"hook_event_name":"Stop"}"#,
        );
        tree.write("2026-09/ask/expected.json", "[[],[]]");
        tree.write(
            "2026-09/ask/approval.expected.json",
            r#"{"0000-PermissionRequest.json":{"provider":"fake","tool_name":"Bash","input":null,"timeout_ms":1}}"#,
        );
        assert_eq!(run_approval(&PassThrough::new(), &tree.0), Vec::new());

        tree.write(
            "2026-09/ask/approval.expected.json",
            r#"{"0000-PermissionRequest.json":null}"#,
        );
        let failures = run_approval(&PassThrough::new(), &tree.0);
        assert_eq!(failures.len(), 1);
        assert_eq!(
            failures[0].payload.as_deref(),
            Some("0000-PermissionRequest.json")
        );
    }

    #[test]
    fn negative_set_accepts_errors_and_single_extensions_only() {
        let tree = Tree::new("negative");
        tree.write("truncated.json", "{\"hook_event_name\":");
        tree.write("array-root.json", "[1]");
        tree.write("unknown.json", r#"{"hook_event_name":"Whatever"}"#);
        assert_eq!(run_negative(&PassThrough::new(), &tree.0), Vec::new());

        let failures = run_negative(&Empty(PassThrough::new()), &tree.0);
        // Three files plus the synthesized oversized payload all fail.
        assert_eq!(failures.len(), 4);
    }
}
