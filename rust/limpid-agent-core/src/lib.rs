//! Provider-neutral state machines for Limpid agent integrations.

mod approval;

pub use approval::{
    AgentProvider, ApprovalBroker, ApprovalDecision, ApprovalKey, ApprovalRequest,
    ApprovalSnapshot, ApprovalState, BrokerError, Principal, RequestId, RunId, ServiceEpoch,
};
