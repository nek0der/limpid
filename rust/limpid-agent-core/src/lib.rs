//! Provider-neutral state machines for Limpid agent integrations.

mod approval;
mod checks;
mod events;
mod gc;
mod lifecycle;
mod notifications;
mod projection;
mod session_lifecycle;
mod title;
mod turn_retention;
mod turn_rules;

pub use approval::{
    ApprovalBroker, ApprovalDecision, ApprovalKey, ApprovalRequest, ApprovalSnapshot,
    ApprovalState, BrokerError, Principal, RequestId, RunId, ServiceEpoch,
};
pub use checks::{CheckRun, DEFAULT_CHECK_PATTERNS, classify as classify_check};
pub use lifecycle::{
    ApplyContext, IdleOutcome, RecordWrites, STOPPED_TURN_IDLE_SECS, SideWrite, TurnSnapshotOp,
    apply, end_stopped_turn, idle_outcome, sanitize_text, sanitize_title, turn_snapshot_cwd,
};
/// Re-exported so the protocol crate can name a provider and a question
/// without depending on the model crate directly.
pub use limpid_agent_model::{ApprovalQuestion, ProviderId};
pub use projection::{DeclinedWait, project, project_with};
pub use session_lifecycle::{on_launch, on_terminate};
pub use title::{
    MAX_FIRST_PROMPT_BYTES, MAX_TITLE_BYTES, TitleCandidates, TitleError, resolve_title,
};
pub use turn_retention::turns_taken_by_change;
pub use turn_rules::{
    PROMPT_HEAD_CHARS, REPLY_HEAD_CHARS, SnapshotTaken, TurnEnd, TurnStart, TurnStep, begin_record,
    conversation_of, end_only_record, end_record, event_id_for, prompt_head, reply_head, turn_step,
};
