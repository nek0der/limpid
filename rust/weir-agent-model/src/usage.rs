//! A subscription usage limit the agent stopped at, and the plan usage the
//! agent last reported.

use serde::{Deserialize, Serialize};

/// The agent's plan ran out of usage, so its turn stopped until the limit
/// resets. Carried by the failure that reports it and kept on the run's
/// record while the run rests in error, so the interface can name the stop
/// and say when it ends.
///
/// Serialized in camel case like the record and the projection badge that
/// carry it.
#[derive(Clone, Debug, Default, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct UsageLimit {
    /// When the limit resets, as an ISO-8601 UTC timestamp with second
    /// precision like every other record time. `None` when the provider did
    /// not say, which the interface shows as a limit with no time.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub resets_at: Option<String>,
    /// Which limit it is, as the provider names it (Claude's `five_hour`,
    /// `seven_day`, …). Kept verbatim for the interface to word; `None` when
    /// not given.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub window: Option<String>,
}

/// How much of a subscription plan's limits an agent's account has used, as
/// the agent last reported it.
///
/// Each provider reports it its own way (Claude Code through the status line,
/// Codex through its app server); this is the one shape the interface reads.
/// Serialized in camel case like the other records.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PlanUsage {
    /// The plan's limit windows, the shortest first.
    pub windows: Vec<PlanUsageWindow>,
    /// The resets the account may spend to start its windows over, when
    /// the provider grants them (Codex). `None` when it does not say, as
    /// Claude Code's status line does not.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reset_credits: Option<PlanResetCredits>,
    /// When the provider reported these values, as an ISO-8601 UTC timestamp
    /// with second precision. The interface says how old they are, because a
    /// value read from a status line is only as fresh as the last turn.
    pub observed_at: String,
}

/// The resets an account may spend to start its limit windows over.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PlanResetCredits {
    /// How many are left to spend.
    pub available: u32,
    /// When the first of them lapses, as an ISO-8601 UTC timestamp: the one
    /// the person has to spend first. `None` when the provider did not say.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub expires_at: Option<String>,
}

/// One limit window of a plan: what share of it is used and when it resets.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PlanUsageWindow {
    /// Which window it is, in the shared vocabulary: `five_hour` and
    /// `seven_day` when the length is one of those, otherwise the provider's
    /// own name, kept for the interface to word.
    pub kind: String,
    /// The share used, from 0 to 100. Not clamped: a provider that reports
    /// past 100 is shown as at the limit, which is the interface's call.
    pub used_percent: f64,
    /// When the window resets, as an ISO-8601 UTC timestamp. `None` when the
    /// provider did not say.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub resets_at: Option<String>,
}

impl PlanUsageWindow {
    /// The shared name of the five-hour window.
    pub const FIVE_HOUR: &'static str = "five_hour";
    /// The shared name of the seven-day window.
    pub const SEVEN_DAY: &'static str = "seven_day";

    /// The shared name of a window `minutes` long, for a provider that gives
    /// its windows by length rather than by name (Codex). `None` for a length
    /// with no shared name.
    #[must_use]
    pub fn kind_for_minutes(minutes: u64) -> Option<&'static str> {
        match minutes {
            300 => Some(Self::FIVE_HOUR),
            10_080 => Some(Self::SEVEN_DAY),
            _ => None,
        }
    }
}

/// What a provider's answer to a plan usage request says.
#[derive(Clone, Debug, PartialEq)]
pub enum PlanUsageAnswer {
    /// The account's windows.
    Usage(PlanUsage),
    /// An answer, but no plan in it: an account signed in with an API key,
    /// or not signed in.
    NoPlan,
    /// No answer to read: an error response, or something that is not the
    /// provider's answer at all. Kept apart from `NoPlan` so the interface
    /// does not tell the person to sign in when the server failed.
    Unreadable,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_limit_serializes_in_camel_case_and_leaves_out_what_is_unknown() {
        let limit = UsageLimit {
            resets_at: Some("2026-10-13T06:40:00Z".to_owned()),
            window: Some("five_hour".to_owned()),
        };
        assert_eq!(
            serde_json::to_string(&limit).unwrap(),
            r#"{"resetsAt":"2026-10-13T06:40:00Z","window":"five_hour"}"#
        );
        assert_eq!(serde_json::to_string(&UsageLimit::default()).unwrap(), "{}");
        assert_eq!(
            serde_json::from_str::<UsageLimit>("{}").unwrap(),
            UsageLimit::default()
        );
    }

    #[test]
    fn plan_usage_serializes_in_camel_case_and_leaves_out_what_is_unknown() {
        let usage = PlanUsage {
            windows: vec![PlanUsageWindow {
                kind: PlanUsageWindow::FIVE_HOUR.to_owned(),
                used_percent: 42.0,
                resets_at: None,
            }],
            reset_credits: None,
            observed_at: "2026-10-29T03:00:00Z".to_owned(),
        };
        assert_eq!(
            serde_json::to_string(&usage).unwrap(),
            r#"{"windows":[{"kind":"five_hour","usedPercent":42.0}],"observedAt":"2026-10-29T03:00:00Z"}"#
        );
    }
}
