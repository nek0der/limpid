//! What a provider observed about its server-side prompt cache when a turn
//! ended.
//!
//! An agent caches the conversation prefix on the model provider's servers.
//! The cache lives for a fixed time after the last request, and the next
//! message after it expires re-writes the whole prefix at the cache-write
//! rate. For a large session that is the most expensive message of the day,
//! and nothing in the agent's own interface says it is about to happen.
//!
//! The window is provider-neutral on purpose. Claude Code exposes no expiry,
//! so its adapter estimates one from the transcript; another provider that
//! reports the expiry directly fills the same struct with `Reported`, and the
//! record, projection, and interface code stay unchanged.

use serde::{Deserialize, Serialize};

/// How far the window can be trusted.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum CachePrecision {
    /// The provider stated the expiry.
    Reported,
    /// Derived from what the provider recorded, for example the time of the
    /// last request and the cache bucket its usage counters name. Usually a
    /// little late, because the provider counts from when the request
    /// started and we only see when its first line was logged; a response
    /// that thinks for long before writing anything can make it minutes late.
    Estimated,
}

/// One prompt cache lifetime, anchored to the request that last refreshed it.
///
/// Serialized in camel case like the record that carries it, so the record
/// and the projection badge spell it the same way.
#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CacheWindow {
    /// When the cache was last refreshed, as an ISO-8601 UTC timestamp with
    /// second precision like every other record time. Also the identity of
    /// one window: a later request moves it, which is how the interface tells
    /// a new expiry from the one the user already dismissed.
    pub observed_at: String,
    /// How long the cache lives after `observed_at`.
    pub ttl_seconds: u64,
    /// Prompt tokens the next request re-sends, which is what a cache miss
    /// re-writes. `None` when the provider gave no usage to count.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub rewrite_tokens: Option<u64>,
    pub precision: CachePrecision,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_window_serializes_in_camel_case() {
        let window = CacheWindow {
            observed_at: "2026-10-07T12:00:00Z".to_owned(),
            ttl_seconds: 3600,
            rewrite_tokens: Some(573_000),
            precision: CachePrecision::Estimated,
        };
        let json = serde_json::to_string(&window).expect("encode");
        assert_eq!(
            json,
            r#"{"observedAt":"2026-10-07T12:00:00Z","ttlSeconds":3600,"rewriteTokens":573000,"precision":"estimated"}"#
        );
        let back: CacheWindow = serde_json::from_str(&json).expect("decode");
        assert_eq!(back, window);
    }

    #[test]
    fn an_unknown_rewrite_size_is_omitted() {
        let window = CacheWindow {
            observed_at: "2026-10-07T12:00:00Z".to_owned(),
            ttl_seconds: 300,
            rewrite_tokens: None,
            precision: CachePrecision::Reported,
        };
        let json = serde_json::to_string(&window).expect("encode");
        assert!(!json.contains("rewriteTokens"));
        assert!(json.contains(r#""precision":"reported""#));
    }
}
