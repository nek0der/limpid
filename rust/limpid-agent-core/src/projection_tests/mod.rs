//! The projection tests, with the records and inputs they share.

use super::*;
use limpid_agent_model::{Focus, PaneLocation, ProjectionState, ProviderAdapter, TabPanes};

mod reported_waits;
mod run_records;
mod sight;
mod stopped_turns;
mod turn_records;

const PANE: &str = "11111111-1111-4111-8111-111111111111";
const RUN: &str = "AAAAAAAA-1111-4111-8111-AAAAAAAAAAA1";

fn claude() -> ProviderId {
    ProviderId::new("claude").expect("provider id")
}

fn record(revision: Option<u64>, updated_at: &str, state: &str) -> String {
    let revision = revision.map_or("null".to_owned(), |it| it.to_string());
    format!(
        r#"{{"schemaVersion":3,"paneId":"{PANE}","runId":"{RUN}","revision":{revision},
           "state":"{state}","updatedAt":"{updated_at}"}}"#
    )
}

fn file(content: Option<String>) -> RecordFile {
    RecordFile {
        provider: claude(),
        name: RUN.to_owned(),
        content,
    }
}

/// One finished run in one pane, with `seen_panes` the panes the person can
/// see.
fn finished_input(seen_panes: Vec<Uuid>) -> ProjectionInput {
    ProjectionInput {
        providers: [(claude(), descriptor())].into_iter().collect(),
        records: vec![file(Some(record(
            Some(4),
            "2026-09-14T12:03:00Z",
            "finished",
        )))],
        tabs: vec![TabPanes {
            id: Uuid::new_v4(),
            panes: vec![PANE.parse().expect("pane")],
        }],
        seen_panes,
        ..ProjectionInput::default()
    }
}

fn descriptor() -> ProviderDescriptor {
    ProviderDescriptor::fixture("claude", [])
}

fn now() -> Instants {
    Instants {
        wall: "2026-10-12T00:01:00Z".to_owned(),
        monotonic_ms: 0,
    }
}

/// The run the turns belong to, still running.
fn running() -> Vec<RecordFile> {
    vec![file(Some(record(
        Some(4),
        "2026-10-12T00:00:30Z",
        "running",
    )))]
}

fn codex() -> ProviderId {
    ProviderId::new("codex").expect("provider id")
}

/// Returns `input` with Claude's descriptor naming its OSC 7501 app
/// (`claude-code`) and holding `capabilities`, and the run's pane last
/// reporting `status` (a state and, for a block, its kind) at `at`.
fn reported_status(
    mut input: ProjectionInput,
    capabilities: &[Capability],
    app: &str,
    status: (ProgramState, Option<BlockedKind>),
    at: &str,
) -> ProjectionInput {
    let mut descriptor = ProviderDescriptor::fixture("claude", []);
    descriptor.capabilities = capabilities.iter().copied().collect();
    descriptor.program_status_app = Some("claude-code".to_owned());
    input.providers.insert(claude(), descriptor);
    input.program_status.insert(
        PANE.parse().expect("pane"),
        ProgramStatus {
            app: app.to_owned(),
            state: status.0,
            kind: status.1,
            observed_at: at.to_owned(),
        },
    );
    input
}
