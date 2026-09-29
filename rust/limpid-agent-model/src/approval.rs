//! Neutral approval request and decision shapes exchanged with a provider
//! adapter. The broker in `limpid-agent-core` owns the state machine; these
//! types only describe what crosses the adapter boundary.

use crate::ProviderId;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::BTreeMap;

/// One selectable answer to an `ApprovalQuestion`.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct ApprovalQuestionOption {
    pub label: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
}

/// A question the provider wants the user to answer instead of a permission
/// to grant. The card renders these; the adapter turns the answers back into
/// the provider's own shape.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct ApprovalQuestion {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub header: Option<String>,
    pub prompt: String,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub options: Vec<ApprovalQuestionOption>,
    #[serde(default)]
    pub multi_select: bool,
}

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
    /// Questions to answer when the request is a question rather than a
    /// permission. Empty for an ordinary permission request.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub questions: Vec<ApprovalQuestion>,
}

/// The decision handed back to the adapter. Matches the protocol's decision
/// vocabulary, including `answer` for a request that carries questions; `ask`
/// is not part of it until a provider that emits it is integrated, because
/// unused decisions would expand the broker contract without a provider
/// behavior to validate them against.
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
    /// The user's answers, keyed by the question prompt. Multi-select answers
    /// join labels with ", " because that is the provider's own convention.
    Answer {
        answers: BTreeMap<String, String>,
    },
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
    use std::collections::BTreeMap;

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
            questions: Vec::new(),
        };
        let json = serde_json::to_string(&request).expect("ok");
        assert!(!json.contains("summary"));
        let back: ApprovalRequest = serde_json::from_str(&json).expect("ok");
        assert_eq!(back, request);
    }

    #[test]
    fn answer_decision_serializes_with_sorted_answers() {
        let mut answers = BTreeMap::new();
        answers.insert("Which color?".to_owned(), "Red".to_owned());
        let answer = serde_json::to_string(&ApprovalDecision::Answer { answers }).expect("ok");
        assert_eq!(
            answer,
            "{\"decision\":\"answer\",\"answers\":{\"Which color?\":\"Red\"}}"
        );
        let parsed: ApprovalDecision =
            serde_json::from_str("{\"decision\":\"answer\",\"answers\":{}}").expect("ok");
        assert_eq!(
            parsed,
            ApprovalDecision::Answer {
                answers: BTreeMap::new()
            }
        );
    }

    #[test]
    fn questions_are_omitted_when_empty_and_round_trip_otherwise() {
        let mut request = ApprovalRequest {
            provider: ProviderId::new("claude").expect("valid"),
            session_id: None,
            operation_id: None,
            tool_name: "AskUserQuestion".into(),
            summary: None,
            input: serde_json::json!({}),
            timeout_ms: 1,
            questions: Vec::new(),
        };
        assert!(
            !serde_json::to_string(&request)
                .expect("ok")
                .contains("questions")
        );
        request.questions.push(ApprovalQuestion {
            header: Some("Color".into()),
            prompt: "Which color?".into(),
            options: vec![ApprovalQuestionOption {
                label: "Red".into(),
                description: None,
            }],
            multi_select: true,
        });
        let json = serde_json::to_string(&request).expect("ok");
        let back: ApprovalRequest = serde_json::from_str(&json).expect("ok");
        assert_eq!(back, request);
    }
}
