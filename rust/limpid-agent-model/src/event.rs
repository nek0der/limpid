//! The neutral event vocabulary every provider adapter maps into.
//!
//! The set is the common subset of the agents' hook APIs. An event is only
//! promoted from `Extension` to a named variant when two providers emit it;
//! `CompactionFinished` is the recorded exception because it closes the
//! existing `Compacting` event rather than introducing a separate concept;
//! `AwaitingPrompt` is the other, because it is the one sign that work the
//! agent did outside a turn is over (see the variant).

use crate::background::BackgroundWork;
use crate::cache::CacheWindow;
use crate::prompt::PromptKind;
use crate::provider::ProviderId;
use serde::{Deserialize, Serialize};
use uuid::Uuid;

/// The identity of one hook delivery, so a turn record applies it once.
/// Built from where the delivery came from, never from a hash of its
/// payload: two deliveries with the same content (the same prompt sent
/// twice) are two events, and the same delivery retried is one.
///
/// The unit is the hook call, not each event `normalize` derives from it,
/// because the call is what the shim retries.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct EventId(String);

impl EventId {
    /// A tool hook, which the provider identifies by its tool use id:
    /// `"<provider>:tool:<tool_use_id>:<hook_event_name>"`. The hook name
    /// keeps the before and after hooks of one tool use apart.
    #[must_use]
    pub fn tool(provider: &ProviderId, tool_use_id: &str, hook_event_name: &str) -> Self {
        Self(format!(
            "{}:tool:{tool_use_id}:{hook_event_name}",
            provider.as_str()
        ))
    }

    /// A hook with no id of its own, identified by the id the shim mints for
    /// each call (`LIMPID_HOOK_INVOCATION_ID`): `"<provider>:invocation:<id>"`.
    #[must_use]
    pub fn invocation(provider: &ProviderId, invocation_id: Uuid) -> Self {
        Self(format!(
            "{}:invocation:{}",
            provider.as_str(),
            invocation_id.hyphenated().to_string().to_uppercase()
        ))
    }

    /// Identifies the end of a turn the person stopped, which no hook
    /// reports, as the app's writer applies it
    /// (`limpid_agent_hook::end_stopped_turn`):
    /// `"<provider>:stopped:<episode_token>"`. The writer ends a turn only in
    /// the episode the pass read, so a retried write is one event.
    #[must_use]
    pub fn stopped_turn(provider: &ProviderId, episode_token: &str) -> Self {
        Self(format!("{}:stopped:{episode_token}", provider.as_str()))
    }

    /// Event `index` of the call `call` identifies, for a call that yields
    /// more than one event: `"<call>#<index>"`. Each event of the call is
    /// then applied once, and a retry of the call yields the same ids.
    #[must_use]
    pub fn indexed(call: &Self, index: usize) -> Self {
        Self(format!("{}#{index}", call.0))
    }

    /// The start of a turn the runtime puts before the events of the call
    /// `call` identifies, for a turn no prompt began
    /// (`ProviderAdapter::unprompted_prompt`): `"<call>#turn"`. Apart from
    /// the call's own events, so a retry that finds the turn begun and puts
    /// nothing before them gives each the id it had.
    #[must_use]
    pub fn turn_start(call: &Self) -> Self {
        Self(format!("{}#turn", call.0))
    }

    #[must_use]
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

/// Title observations a provider can attach to an event. `None` means "no
/// observation", never "cleared": the rules keep the previous value.
#[derive(Clone, Debug, PartialEq, Eq, Default, Serialize, Deserialize)]
pub struct Titles {
    /// The name the provider keeps for the session: one the person gave it
    /// (Claude's `/rename`), or Codex's thread name, which does not say who
    /// chose it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session_title: Option<String>,
    /// A title the provider generated (Claude's `ai-title`), below the
    /// session's name.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub generated_title: Option<String>,
}

/// Where a session start came from, as the provider's `source` says it.
/// Both Claude and Codex report one of these; a payload without one, or
/// with a word this does not know, carries `None`, which the rules read as
/// "could be anything" rather than as a fresh start.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SessionSource {
    /// A session with no conversation behind it yet: the agent started anew.
    Startup,
    /// `/clear`: a new session, with nothing of the previous one.
    Clear,
    /// The session picked a conversation that exists on disk back up.
    Resume,
    /// The provider restarted the session after compaction.
    Compact,
    /// A new session branched from a conversation that exists on disk
    /// (Codex's `fork`): what it picked up was said, as for a resume.
    Fork,
}

impl SessionSource {
    /// The provider's `source` word, as both Claude and Codex spell it;
    /// only Codex sends `fork`.
    #[must_use]
    pub fn parse(source: Option<&str>) -> Option<Self> {
        match source? {
            "startup" => Some(Self::Startup),
            "clear" => Some(Self::Clear),
            "resume" => Some(Self::Resume),
            "compact" => Some(Self::Compact),
            "fork" => Some(Self::Fork),
            _ => None,
        }
    }
}

/// One neutral event derived from one provider hook payload.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum AgentEvent {
    SessionStarted {
        /// True when the provider restarted the session after compaction.
        /// A compact start preserves the first prompt and existing titles but
        /// clears the last prompt.
        compact: bool,
        /// Where the start came from: whether a conversation already lies
        /// behind the session (`RunRecord::has_prompt`). Absent in an event
        /// an older build wrote.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        source: Option<SessionSource>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        session_id: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        session_title: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        cwd: Option<String>,
    },
    SessionEnded {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        reason: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        session_id: Option<String>,
    },
    PromptSubmitted {
        prompt: String,
        /// Who wrote the prompt, when the provider says so rather than its
        /// text: a Codex turn its goal began has no prompt of the person's,
        /// only the goal's objective. `None` leaves it to the text
        /// (`classify_prompt`).
        #[serde(default, skip_serializing_if = "Option::is_none")]
        kind: Option<PromptKind>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        titles: Option<Titles>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        cwd: Option<String>,
    },
    ToolStarted {
        tool: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        detail: Option<String>,
        /// The tool is a subagent's rather than the agent's own (Claude
        /// names the subagent with `agent_id`). A background subagent works
        /// on after the turn that launched it has stopped, and the stop
        /// already counted it (`background_work`), so its tools do not put
        /// the run back to work. Omitted when false.
        #[serde(default, skip_serializing_if = "is_false")]
        by_subagent: bool,
    },
    ToolFinished {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        tool: Option<String>,
        /// As on `ToolStarted`: the tool that ended is a subagent's. Omitted
        /// when false.
        #[serde(default, skip_serializing_if = "is_false")]
        by_subagent: bool,
    },
    WaitingForInput {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        detail: Option<String>,
    },
    ApprovalRequested {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        detail: Option<String>,
    },
    Compacting,
    CompactionFinished,
    /// The agent sits at its prompt with nothing running (Claude's idle
    /// `Notification`). Only Claude says so; it is named rather than left an
    /// extension because it closes what no `TurnFinished` may follow: work
    /// the run did outside a turn, or a turn that stopped without a `Stop`,
    /// including one whose question or permission prompt was declined.
    AwaitingPrompt {
        /// The provider's own record shows the tool call it last made has
        /// ended: a result or an interrupt follows it. Claude's question or
        /// permission prompt declined with Esc sends no hook at all, so this
        /// is what tells a wait that is over from one still open. `false`
        /// means not seen, which keeps the wait. It is absent from events
        /// written before the field existed.
        #[serde(default, skip_serializing_if = "is_false")]
        awaited_call_ended: bool,
    },
    TurnFinished {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        titles: Option<Titles>,
        /// The prompt cache as the turn left it. An observation about the
        /// turn that just ended rather than an event of its own: it has no
        /// moment of its own to report, and attaching it here keeps it out of
        /// the vocabulary until a second provider has the same thing to say.
        /// `None` means unknown, never "no cache".
        #[serde(default, skip_serializing_if = "Option::is_none")]
        cache: Option<CacheWindow>,
        /// The provider reports that this stop follows work another stop
        /// hook asked for (Claude's and Codex's `stop_hook_active`): the
        /// turn the previous stop ended went on, and this is its real end.
        /// Any other stop of a turn that already ended is a stop with no
        /// prompt of its own.
        #[serde(default, skip_serializing_if = "is_false")]
        continues_after_stop_hook: bool,
        /// The agent's last reply as the provider sent it with the stop
        /// (Claude's and Codex's `last_assistant_message`), whole: the core
        /// cuts what the turn keeps of it (`reply_head`). `None` when the
        /// provider sent none or it was empty.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        reply: Option<String>,
        /// What the agent left running as the turn ended (Claude's
        /// `background_tasks`). An observation about the stop like `cache`,
        /// attached here for the same reason. `None` when nothing was left
        /// running or the provider does not say.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        background_work: Option<BackgroundWork>,
    },
    Failed {
        error: String,
        /// Set when the failure is the plan's usage limit, with when
        /// it resets if the provider said. Absent from events written before
        /// the field existed and from every other failure.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        usage_limit: Option<crate::UsageLimit>,
    },
    Interrupted,
    CwdChanged {
        new_cwd: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        old_cwd: Option<String>,
    },
    WorktreeCreated {
        repo_root: String,
        worktree_path: String,
        branch: String,
    },
    /// A payload the adapter recognized as an event but the vocabulary does
    /// not name. Kept whole so a new provider feature is visible before the
    /// core understands it.
    Extension {
        name: String,
        payload: serde_json::Value,
    },
}

impl AgentEvent {
    /// Adds titles read from outside the payload (`indexed_titles`) to an
    /// event that carries titles. A title the payload's own normalization
    /// found stays: it was read for this very call. A session start carries
    /// only the session title, which names a resumed session from its first
    /// hook. Other events carry none and are left as they are.
    pub fn add_titles(&mut self, added: &Titles) {
        if let Self::SessionStarted { session_title, .. } = self {
            if session_title.is_none() {
                session_title.clone_from(&added.session_title);
            }
            return;
        }
        let (Self::PromptSubmitted { titles, .. } | Self::TurnFinished { titles, .. }) = self
        else {
            return;
        };
        if added.session_title.is_none() && added.generated_title.is_none() {
            return;
        }
        let titles = titles.get_or_insert_with(Titles::default);
        if titles.session_title.is_none() {
            titles.session_title.clone_from(&added.session_title);
        }
        if titles.generated_title.is_none() {
            titles.generated_title.clone_from(&added.generated_title);
        }
    }
}

#[allow(clippy::trivially_copy_pass_by_ref)] // serde passes the field by reference.
fn is_false(value: &bool) -> bool {
    !*value
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_source_word_codex_and_claude_send_is_read() {
        // Codex's `SessionStartSource` has five words, Claude's the first
        // four; a word neither sends says nothing.
        for (word, source) in [
            ("startup", SessionSource::Startup),
            ("clear", SessionSource::Clear),
            ("resume", SessionSource::Resume),
            ("compact", SessionSource::Compact),
            ("fork", SessionSource::Fork),
        ] {
            assert_eq!(SessionSource::parse(Some(word)), Some(source), "{word}");
        }
        assert_eq!(SessionSource::parse(Some("other")), None);
        assert_eq!(SessionSource::parse(None), None);
    }

    #[test]
    fn events_round_trip_through_json_with_a_type_tag() {
        let events = vec![
            AgentEvent::SessionStarted {
                compact: false,
                source: Some(SessionSource::Startup),
                session_id: Some("s".into()),
                session_title: None,
                cwd: Some("/tmp".into()),
            },
            AgentEvent::Compacting,
            AgentEvent::TurnFinished {
                continues_after_stop_hook: false,
                titles: Some(Titles {
                    session_title: None,
                    generated_title: Some("t".into()),
                }),
                cache: Some(crate::cache::CacheWindow {
                    observed_at: "2026-09-14T00:00:00Z".into(),
                    ttl_seconds: 3600,
                    rewrite_tokens: Some(1_000),
                    precision: crate::cache::CachePrecision::Estimated,
                }),
                reply: Some("Done.".into()),
                background_work: None,
            },
            AgentEvent::AwaitingPrompt {
                awaited_call_ended: false,
            },
            AgentEvent::AwaitingPrompt {
                awaited_call_ended: true,
            },
            AgentEvent::Extension {
                name: "Notification".into(),
                payload: serde_json::json!({"notification_type": "auth_success"}),
            },
        ];
        let json = serde_json::to_string(&events).expect("serialize");
        assert!(json.contains("\"type\":\"session_started\""));
        assert!(json.contains("\"type\":\"compacting\""));
        let back: Vec<AgentEvent> = serde_json::from_str(&json).expect("deserialize");
        assert_eq!(back, events);
    }

    #[test]
    fn a_compacting_event_an_earlier_build_wrote_with_a_token_count_still_decodes() {
        let event: AgentEvent =
            serde_json::from_str(r#"{"type":"compacting","context_tokens":120000}"#)
                .expect("decodes");
        assert_eq!(event, AgentEvent::Compacting);
    }

    #[test]
    fn added_titles_fill_only_what_the_payload_left_empty() {
        let added = Titles {
            session_title: Some("Indexed".into()),
            generated_title: None,
        };
        let mut finished = AgentEvent::TurnFinished {
            continues_after_stop_hook: false,
            titles: Some(Titles {
                session_title: Some("From the payload".into()),
                generated_title: None,
            }),
            cache: None,
            reply: None,
            background_work: None,
        };
        finished.add_titles(&added);
        assert!(matches!(
            finished,
            AgentEvent::TurnFinished { titles: Some(Titles { ref session_title, .. }), .. }
                if session_title.as_deref() == Some("From the payload")
        ));

        let mut prompt = AgentEvent::PromptSubmitted {
            prompt: "p".into(),
            kind: None,
            titles: None,
            cwd: None,
        };
        prompt.add_titles(&added);
        assert!(matches!(
            prompt,
            AgentEvent::PromptSubmitted { titles: Some(ref titles), .. } if *titles == added
        ));
        // Nothing added leaves the event as it was, not with empty titles.
        let mut untouched = AgentEvent::PromptSubmitted {
            prompt: "p".into(),
            kind: None,
            titles: None,
            cwd: None,
        };
        untouched.add_titles(&Titles::default());
        assert!(matches!(
            untouched,
            AgentEvent::PromptSubmitted { titles: None, .. }
        ));

        let mut started = AgentEvent::SessionStarted {
            compact: false,
            source: Some(SessionSource::Resume),
            session_id: Some("s".into()),
            session_title: None,
            cwd: None,
        };
        started.add_titles(&added);
        assert!(matches!(
            started,
            AgentEvent::SessionStarted { ref session_title, .. }
                if session_title.as_deref() == Some("Indexed")
        ));

        let mut tool = AgentEvent::ToolFinished {
            tool: None,
            by_subagent: false,
        };
        tool.add_titles(&added);
        assert_eq!(
            tool,
            AgentEvent::ToolFinished {
                tool: None,
                by_subagent: false,
            }
        );
    }

    #[test]
    fn absent_optionals_are_omitted() {
        let json = serde_json::to_string(&AgentEvent::ToolFinished {
            tool: None,
            by_subagent: false,
        })
        .expect("ok");
        assert_eq!(json, "{\"type\":\"tool_finished\"}");
        let json = serde_json::to_string(&AgentEvent::TurnFinished {
            continues_after_stop_hook: false,
            titles: None,
            cache: None,
            reply: None,
            background_work: None,
        })
        .expect("ok");
        assert_eq!(json, "{\"type\":\"turn_finished\"}");
        // The idle prompt an older build wrote, and one that saw nothing
        // end, are the same event.
        let idle = AgentEvent::AwaitingPrompt {
            awaited_call_ended: false,
        };
        let json = serde_json::to_string(&idle).expect("ok");
        assert_eq!(json, "{\"type\":\"awaiting_prompt\"}");
        let back: AgentEvent = serde_json::from_str(&json).expect("ok");
        assert_eq!(back, idle);
    }
}
