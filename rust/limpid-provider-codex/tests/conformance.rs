//! Replays the recorded Codex fixtures through the adapter.

use limpid_agent_model::conformance::{run_approval, run_negative, run_normalize};
use limpid_provider_codex::CodexAdapter;
use std::path::{Path, PathBuf};

fn fixtures(segment: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("..")
        .join("fixtures")
        .join(segment)
}

fn report(failures: &[limpid_agent_model::conformance::ConformanceFailure]) -> String {
    failures
        .iter()
        .map(ToString::to_string)
        .collect::<Vec<_>>()
        .join("\n")
}

#[test]
fn approval_requests_match_the_recorded_expectations() {
    let failures = run_approval(&CodexAdapter, &fixtures("codex"));
    assert!(failures.is_empty(), "{}", report(&failures));
}

#[test]
fn payloads_normalize_as_recorded() {
    let failures = run_normalize(&CodexAdapter, &fixtures("codex"));
    assert!(failures.is_empty(), "{}", report(&failures));
}

#[test]
fn negative_inputs_are_rejected_or_passed_through() {
    let failures = run_negative(&CodexAdapter, &fixtures("negative"));
    assert!(failures.is_empty(), "{}", report(&failures));
}
