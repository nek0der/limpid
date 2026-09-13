use limpid_agent_core::{
    AgentProvider, ApprovalDecision, ApprovalKey, ApprovalRequest, ApprovalSnapshot, ApprovalState,
    RequestId, RunId,
};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use uuid::Uuid;

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct WireRequest {
    pub version: u16,
    pub message_id: Uuid,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub service_epoch: Option<Uuid>,
    #[serde(flatten)]
    pub body: RequestBody,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(tag = "type", content = "body")]
pub enum RequestBody {
    #[serde(rename = "hello")]
    Hello { client_version: String },
    #[serde(rename = "approval.submit")]
    ApprovalSubmit(ApprovalRequestWire),
    #[serde(rename = "approval.get")]
    ApprovalGet(ApprovalKeyWire),
    #[serde(rename = "approval.wait")]
    ApprovalWait {
        #[serde(flatten)]
        key: ApprovalKeyWire,
        maximum_wait_ms: u64,
    },
    #[serde(rename = "approval.cancel")]
    ApprovalCancel(ApprovalKeyWire),
    #[serde(rename = "approval.resolve")]
    ApprovalResolve {
        #[serde(flatten)]
        key: ApprovalKeyWire,
        decision: ApprovalDecisionWire,
    },
    #[serde(rename = "approval.snapshot")]
    ApprovalSnapshot,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct WireResponse {
    pub version: u16,
    pub message_id: Uuid,
    pub in_reply_to: Uuid,
    pub service_epoch: Uuid,
    #[serde(flatten)]
    pub body: ResponseBody,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(tag = "type", content = "body")]
pub enum ResponseBody {
    #[serde(rename = "hello.result")]
    HelloResult { capabilities: Vec<String> },
    #[serde(rename = "approval.result")]
    ApprovalResult(ApprovalSnapshotWire),
    #[serde(rename = "approval.snapshot.result")]
    ApprovalSnapshotResult {
        sequence: u64,
        requests: Vec<ApprovalIndexWire>,
    },
    #[serde(rename = "error")]
    Error { code: ErrorCode, message: String },
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum ErrorCode {
    UnsupportedVersion,
    HelloRequired,
    AlreadyInitialized,
    EpochMismatch,
    Unauthorized,
    InvalidRequest,
    InvalidTimeout,
    CapacityExceeded,
    NotFound,
    RequestConflict,
    AlreadyTerminal,
    Internal,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct ApprovalKeyWire {
    pub run_id: Uuid,
    pub request_id: Uuid,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct ApprovalRequestWire {
    pub run_id: Uuid,
    pub request_id: Uuid,
    pub provider: AgentProviderWire,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub operation_id: Option<String>,
    pub tool_name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub summary: Option<String>,
    pub input: Value,
    pub timeout_ms: u64,
}

#[derive(Clone, Copy, Debug, Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum AgentProviderWire {
    Claude,
    Codex,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(tag = "decision", rename_all = "snake_case")]
pub enum ApprovalDecisionWire {
    AllowOnce,
    Deny {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        message: Option<String>,
    },
    Delegate,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct ApprovalSnapshotWire {
    pub request: ApprovalRequestWire,
    pub state: ApprovalStateWire,
    pub created_at_ms: u64,
    pub deadline_ms: u64,
    pub sequence: u64,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(tag = "status", rename_all = "snake_case")]
pub enum ApprovalStateWire {
    Pending,
    Resolved { result: ApprovalDecisionWire },
    Canceled,
    Expired,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct ApprovalIndexWire {
    pub run_id: Uuid,
    pub request_id: Uuid,
    pub provider: AgentProviderWire,
    pub status: ApprovalStatusWire,
    pub deadline_ms: u64,
    pub sequence: u64,
}

#[derive(Clone, Copy, Debug, Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum ApprovalStatusWire {
    Pending,
    Resolved,
    Canceled,
    Expired,
}

impl ApprovalKeyWire {
    #[must_use]
    pub fn into_domain(self) -> ApprovalKey {
        ApprovalKey {
            run_id: RunId::new(self.run_id),
            request_id: RequestId::new(self.request_id),
        }
    }
}

impl ApprovalRequestWire {
    /// Converts validated wire fields into the provider-neutral request.
    ///
    /// # Errors
    ///
    /// Returns an encoding error if the JSON input cannot be canonicalized.
    pub fn into_domain(self) -> Result<ApprovalRequest, serde_json::Error> {
        Ok(ApprovalRequest {
            key: ApprovalKey {
                run_id: RunId::new(self.run_id),
                request_id: RequestId::new(self.request_id),
            },
            provider: match self.provider {
                AgentProviderWire::Claude => AgentProvider::Claude,
                AgentProviderWire::Codex => AgentProvider::Codex,
            },
            session_id: self.session_id,
            operation_id: self.operation_id,
            tool_name: self.tool_name,
            summary: self.summary,
            input_json: serde_json::to_string(&self.input)?,
            timeout_ms: self.timeout_ms,
        })
    }
}

impl From<ApprovalDecisionWire> for ApprovalDecision {
    fn from(value: ApprovalDecisionWire) -> Self {
        match value {
            ApprovalDecisionWire::AllowOnce => Self::AllowOnce,
            ApprovalDecisionWire::Deny { message } => Self::Deny { message },
            ApprovalDecisionWire::Delegate => Self::Delegate,
        }
    }
}

impl ApprovalSnapshotWire {
    pub(crate) fn from_domain(value: ApprovalSnapshot) -> Result<Self, serde_json::Error> {
        let input = serde_json::from_str(&value.request.input_json)?;
        Ok(Self {
            request: ApprovalRequestWire {
                run_id: value.request.key.run_id.value(),
                request_id: value.request.key.request_id.value(),
                provider: match value.request.provider {
                    AgentProvider::Claude => AgentProviderWire::Claude,
                    AgentProvider::Codex => AgentProviderWire::Codex,
                },
                session_id: value.request.session_id,
                operation_id: value.request.operation_id,
                tool_name: value.request.tool_name,
                summary: value.request.summary,
                input,
                timeout_ms: value.request.timeout_ms,
            },
            state: match value.state {
                ApprovalState::Pending => ApprovalStateWire::Pending,
                ApprovalState::Resolved(decision) => ApprovalStateWire::Resolved {
                    result: match decision {
                        ApprovalDecision::AllowOnce => ApprovalDecisionWire::AllowOnce,
                        ApprovalDecision::Deny { message } => {
                            ApprovalDecisionWire::Deny { message }
                        }
                        ApprovalDecision::Delegate => ApprovalDecisionWire::Delegate,
                    },
                },
                ApprovalState::Canceled => ApprovalStateWire::Canceled,
                ApprovalState::Expired => ApprovalStateWire::Expired,
            },
            created_at_ms: value.created_at_ms,
            deadline_ms: value.deadline_ms,
            sequence: value.sequence,
        })
    }
}

impl From<ApprovalSnapshot> for ApprovalIndexWire {
    fn from(value: ApprovalSnapshot) -> Self {
        Self {
            run_id: value.request.key.run_id.value(),
            request_id: value.request.key.request_id.value(),
            provider: match value.request.provider {
                AgentProvider::Claude => AgentProviderWire::Claude,
                AgentProvider::Codex => AgentProviderWire::Codex,
            },
            status: match value.state {
                ApprovalState::Pending => ApprovalStatusWire::Pending,
                ApprovalState::Resolved(_) => ApprovalStatusWire::Resolved,
                ApprovalState::Canceled => ApprovalStatusWire::Canceled,
                ApprovalState::Expired => ApprovalStatusWire::Expired,
            },
            deadline_ms: value.deadline_ms,
            sequence: value.sequence,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::PROTOCOL_VERSION;
    use serde_json::json;

    #[test]
    fn hello_cannot_claim_a_controller_role() {
        let value = json!({
            "version": 1,
            "message_id": Uuid::new_v4(),
            "type": "hello",
            "body": {"client_version": "test"},
            "role": "controller"
        });

        assert!(serde_json::from_value::<WireRequest>(value).is_err());
    }

    #[test]
    fn unknown_decision_is_rejected() {
        let value = json!({"decision": "allow_always"});

        assert!(serde_json::from_value::<ApprovalDecisionWire>(value).is_err());
    }

    #[test]
    fn documented_handshake_and_wait_shapes_are_stable() {
        let message_id = Uuid::from_u128(1);
        let epoch = Uuid::from_u128(2);
        let run_id = Uuid::from_u128(3);
        let request_id = Uuid::from_u128(4);

        let hello = WireRequest {
            version: PROTOCOL_VERSION,
            message_id,
            service_epoch: None,
            body: RequestBody::Hello {
                client_version: "0.1.5".into(),
            },
        };
        assert_eq!(
            serde_json::to_value(hello).unwrap(),
            json!({
                "version": 1,
                "message_id": message_id,
                "type": "hello",
                "body": {"client_version": "0.1.5"}
            })
        );

        let wait = WireRequest {
            version: PROTOCOL_VERSION,
            message_id,
            service_epoch: Some(epoch),
            body: RequestBody::ApprovalWait {
                key: ApprovalKeyWire { run_id, request_id },
                maximum_wait_ms: 1_000,
            },
        };
        assert_eq!(
            serde_json::to_value(wait).unwrap(),
            json!({
                "version": 1,
                "message_id": message_id,
                "service_epoch": epoch,
                "type": "approval.wait",
                "body": {
                    "run_id": run_id,
                    "request_id": request_id,
                    "maximum_wait_ms": 1_000
                }
            })
        );
    }
}
