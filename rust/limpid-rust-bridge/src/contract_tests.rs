//! The values the app defines for itself but the Rust side depends on, or
//! the other way round, checked against the one file both sides read
//! (`rust/fixtures/contract/shared-values.json`). The app's
//! `SharedValuesContractTests` check its own constants against the same file.

use crate::projection::MAX_PROJECTION_INPUT_BYTES;
use limpid_agent_hook::{PANE_ID_VARIABLE, WORKTREE_ROUTING_FILE};
use limpid_agent_model::RunState;
use limpid_agent_protocol::MAXIMUM_DECISION_BYTES;
use serde::Deserialize;
use std::path::Path;

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct SharedValues {
    maximum_decision_bytes: usize,
    maximum_projection_input_bytes: usize,
    worktree_routing_file_name: String,
    pane_identifier_variable: String,
    at_work_states: Vec<RunState>,
    not_at_work_states: Vec<RunState>,
}

fn shared_values() -> SharedValues {
    let path =
        Path::new(env!("CARGO_MANIFEST_DIR")).join("../fixtures/contract/shared-values.json");
    let bytes = std::fs::read(&path).expect("the shared values file");
    serde_json::from_slice(&bytes).expect("the shared values decode")
}

#[test]
fn the_limits_are_the_ones_the_app_checks_against() {
    let shared = shared_values();
    assert_eq!(MAXIMUM_DECISION_BYTES, shared.maximum_decision_bytes);
    assert_eq!(
        MAX_PROJECTION_INPUT_BYTES,
        shared.maximum_projection_input_bytes
    );
}

#[test]
fn the_names_are_the_ones_the_app_writes() {
    let shared = shared_values();
    assert_eq!(WORKTREE_ROUTING_FILE, shared.worktree_routing_file_name);
    assert_eq!(PANE_ID_VARIABLE, shared.pane_identifier_variable);
}

#[test]
fn the_at_work_states_are_the_ones_the_app_counts_as_mid_turn() {
    let shared = shared_values();
    // Every state this build knows is in one of the lists, so a new one has
    // to be placed in the file before either side can ship it. The match has
    // no wildcard: a new variant does not compile until it is listed here.
    let every = [
        RunState::Idle,
        RunState::Running,
        RunState::NeedsInput,
        RunState::Compacting,
        RunState::Finished,
        RunState::Error,
        RunState::Unknown,
    ];
    for state in every {
        match state {
            RunState::Idle
            | RunState::Running
            | RunState::NeedsInput
            | RunState::Compacting
            | RunState::Finished
            | RunState::Error
            | RunState::Unknown => {}
        }
        assert!(
            shared.at_work_states.contains(&state) || shared.not_at_work_states.contains(&state),
            "{state:?} is in neither list"
        );
    }
    for state in shared.at_work_states {
        assert!(state.is_at_work(), "{state:?}");
    }
    for state in shared.not_at_work_states {
        assert!(!state.is_at_work(), "{state:?}");
    }
}
