//! Replays the recorded Claude fixtures through the adapter.

use std::path::{Path, PathBuf};
use weir_agent_model::conformance::{run_approval, run_negative, run_normalize};
use weir_provider_claude::ClaudeAdapter;

fn fixtures(segment: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("..")
        .join("fixtures")
        .join(segment)
}

fn report(failures: &[weir_agent_model::conformance::ConformanceFailure]) -> String {
    failures
        .iter()
        .map(ToString::to_string)
        .collect::<Vec<_>>()
        .join("\n")
}

#[test]
fn approval_requests_match_the_recorded_expectations() {
    let failures = run_approval(&ClaudeAdapter, &fixtures("claude"));
    assert!(failures.is_empty(), "{}", report(&failures));
}

#[test]
fn payloads_normalize_as_recorded() {
    let failures = run_normalize(&ClaudeAdapter, &fixtures("claude"));
    assert!(failures.is_empty(), "{}", report(&failures));
}

#[test]
fn negative_inputs_are_rejected_or_passed_through() {
    let failures = run_negative(&ClaudeAdapter, &fixtures("negative"));
    assert!(failures.is_empty(), "{}", report(&failures));
}
