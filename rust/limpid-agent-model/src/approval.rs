//! Neutral approval request and decision shapes exchanged with a provider
//! adapter. The broker in `limpid-agent-core` owns the state machine; these
//! types only describe what crosses the adapter boundary.

use crate::ProviderId;
use serde::{Deserialize, Serialize};
use serde_json::Value;

/// A provider's permission request translated into Limpid's terms.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct ApprovalRequest {
    pub provider: ProviderId,
    /// Provider session identifier, for correlation and display only.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session_id: Option<String>,
    /// Provider-scoped operation identifier such as Codex's `turn_id`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub operation_id: Option<String>,
    pub tool_name: String,
    /// One line describing the operation, when the provider supplies it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub summary: Option<String>,
    /// The provider's tool input, kept whole for the approval UI.
    pub input: Value,
    /// How long the requester is willing to wait for a decision.
    pub timeout_ms: u64,
}

/// The decision handed back to the adapter. Matches the protocol's decision
/// vocabulary; `ask` is not part of it until a provider that emits it is
/// integrated, because unused decisions would expand the broker contract
/// without a provider behavior to validate them against.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "decision", rename_all = "snake_case")]
pub enum ApprovalDecision {
    AllowOnce,
    Deny {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        message: Option<String>,
    },
    /// No decision: the provider's native approval flow takes over.
    Delegate,
}

/// What the hook process writes to its standard output. `None` emits nothing,
/// which every provider treats as "no decision".
#[derive(Clone, Debug, PartialEq, Eq, Default)]
pub struct ProviderOutput {
    pub stdout: Option<Vec<u8>>,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decisions_use_the_protocol_vocabulary() {
        let allow = serde_json::to_string(&ApprovalDecision::AllowOnce).expect("ok");
        assert_eq!(allow, "{\"decision\":\"allow_once\"}");
        let deny = serde_json::to_string(&ApprovalDecision::Deny {
            message: Some("no".into()),
        })
        .expect("ok");
        assert_eq!(deny, "{\"decision\":\"deny\",\"message\":\"no\"}");
        let parsed: ApprovalDecision =
            serde_json::from_str("{\"decision\":\"delegate\"}").expect("ok");
        assert_eq!(parsed, ApprovalDecision::Delegate);
        assert!(serde_json::from_str::<ApprovalDecision>("{\"decision\":\"ask\"}").is_err());
    }

    #[test]
    fn requests_round_trip() {
        let request = ApprovalRequest {
            provider: ProviderId::new("codex").expect("valid"),
            session_id: Some("s".into()),
            operation_id: Some("t".into()),
            tool_name: "Bash".into(),
            summary: None,
            input: serde_json::json!({"command": "ls"}),
            timeout_ms: 570_000,
        };
        let json = serde_json::to_string(&request).expect("ok");
        assert!(!json.contains("summary"));
        let back: ApprovalRequest = serde_json::from_str(&json).expect("ok");
        assert_eq!(back, request);
    }
}
