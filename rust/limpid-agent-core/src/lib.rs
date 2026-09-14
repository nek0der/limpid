//! Provider-neutral state machines for Limpid agent integrations.

mod approval;
mod events;
mod gc;
mod lifecycle;
mod notifications;
mod projection;
mod session_lifecycle;
mod title;

pub use approval::{
    AgentProvider, ApprovalBroker, ApprovalDecision, ApprovalKey, ApprovalRequest,
    ApprovalSnapshot, ApprovalState, BrokerError, Principal, RequestId, RunId, ServiceEpoch,
};
pub use lifecycle::{
    ApplyContext, RecordWrites, SESSION_END_DROP_REASONS, SideWrite, TurnSnapshotOp, apply,
    sanitize_text, sanitize_title, turn_snapshot_cwd,
};
pub use projection::project;
pub use session_lifecycle::{on_launch, on_terminate};
pub use title::{
    MAX_FIRST_PROMPT_BYTES, MAX_TITLE_BYTES, TitleCandidates, TitleError, resolve_title,
};
