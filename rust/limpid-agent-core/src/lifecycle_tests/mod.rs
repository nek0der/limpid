//! The run-record lifecycle tests, with the events and the replay they share.

use super::*;
use limpid_agent_model::ProviderAdapter;

mod background_work;
mod outside_a_turn;
mod prompts_and_waits;
mod session_settings;

const NOW: &str = "2026-09-14T00:00:00Z";
const LATER: &str = "2026-09-14T00:00:05Z";

fn context() -> ApplyContext {
    ApplyContext {
        run_id: "6F1D6A1E-0E34-4A1A-9A8E-2F2B6C1D7F11".into(),
        pane_id: "6F1D6A1E-0E34-4A1A-9A8E-2F2B6C1D7F10".into(),
        pid: Some(4242),
        tmux: None,
        is_tmux_hosted: false,
        transcript_path: None,
        settings: SessionSettings::default(),
    }
}

fn claude() -> ProviderDescriptor {
    limpid_provider_claude::ClaudeAdapter.descriptor().clone()
}

fn codex() -> ProviderDescriptor {
    limpid_provider_codex::CodexAdapter.descriptor().clone()
}

fn started(title: Option<&str>) -> AgentEvent {
    AgentEvent::SessionStarted {
        compact: false,
        source: Some(SessionSource::Startup),
        session_id: Some("session-1".into()),
        session_title: title.map(str::to_owned),
        cwd: Some("/repo".into()),
    }
}

fn prompt(text: &str) -> AgentEvent {
    AgentEvent::PromptSubmitted {
        prompt: text.into(),
        kind: None,
        titles: None,
        cwd: Some("/repo".into()),
    }
}

/// Applies `events` in order and returns the final record plus every
/// side write and snapshot op, the way the runtime would see them.
fn run(
    descriptor: &ProviderDescriptor,
    events: &[AgentEvent],
) -> (RunRecord, Vec<SideWrite>, Vec<TurnSnapshotOp>) {
    let mut record: Option<RunRecord> = None;
    let mut sides = Vec::new();
    let mut snapshots = Vec::new();
    for event in events {
        let writes = apply(record.as_ref(), event, &context(), descriptor, NOW);
        sides.extend(writes.side);
        snapshots.extend(writes.snapshot);
        if let Some(next) = writes.run {
            record = Some(next);
        }
    }
    (
        record.expect("at least one event writes a record"),
        sides,
        snapshots,
    )
}
