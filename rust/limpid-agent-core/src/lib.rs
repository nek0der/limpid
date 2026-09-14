//! Provider-neutral state machines for Limpid agent integrations.

mod approval;
mod lifecycle;

pub use approval::{
    AgentProvider, ApprovalBroker, ApprovalDecision, ApprovalKey, ApprovalRequest,
    ApprovalSnapshot, ApprovalState, BrokerError, Principal, RequestId, RunId, ServiceEpoch,
};
pub use lifecycle::{
    ApplyContext, RecordWrites, SESSION_END_DROP_REASONS, SideWrite, TurnSnapshotOp, apply,
    sanitize_text, sanitize_title, turn_snapshot_cwd,
};
