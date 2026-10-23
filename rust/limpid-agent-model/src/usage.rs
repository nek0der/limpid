//! A subscription usage limit the agent stopped at.

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
}
