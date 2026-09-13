//! Versioned wire messages and transport-neutral stream framing.

mod frame;
mod service;
mod wire;

pub use frame::{FrameError, read_frame, write_frame};
pub use service::{ApprovalService, ServeError};
pub use wire::{
    AgentProviderWire, ApprovalDecisionWire, ApprovalIndexWire, ApprovalKeyWire,
    ApprovalRequestWire, ApprovalSnapshotWire, ApprovalStateWire, ApprovalStatusWire, ErrorCode,
    RequestBody, ResponseBody, WireRequest, WireResponse,
};

/// Current major protocol version.
pub const PROTOCOL_VERSION: u16 = 1;
/// Maximum encoded request accepted from an authenticated client.
pub const MAXIMUM_REQUEST_BYTES: usize = 1024 * 1024;
/// Maximum encoded response emitted by the service.
pub const MAXIMUM_RESPONSE_BYTES: usize = 64 * 1024;
/// Maximum encoded approval body that can be echoed in one bounded response.
pub const MAXIMUM_APPROVAL_BYTES: usize = 48 * 1024;
/// Maximum encoded decision accepted from a controller.
pub const MAXIMUM_DECISION_BYTES: usize = 8 * 1024;
/// Maximum request lifetime or individual blocking wait.
pub const MAXIMUM_WAIT_MS: u64 = 10 * 60 * 1_000;
/// Maximum records held by one in-memory service epoch.
pub const MAXIMUM_RECORDS: usize = 128;
