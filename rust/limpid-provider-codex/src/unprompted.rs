//! Reads what began a Codex turn that no prompt began, from its rollout.
//!
//! Codex starts some turns itself: `/goal` begins one to work toward the
//! goal it sets, and begins the next whenever a turn ends with the goal
//! still active (`codex-rs/ext/goal`, read on 2026-10-29 at Codex CLI
//! 0.165.0). They come from `TurnInput::ResponseItem`, not from the person's
//! input, so no `UserPromptSubmit` runs for them; the hooks inside them carry
//! the turn's `turn_id` as any turn's do. The rollout says what began each:
//! the turn's `task_started` event names it (`turn_attribution.turn_trigger`,
//! `"goal"` for these), and the `thread_goal_updated` event before it holds
//! the goal (`goal.objective`), which is the person's own words. Neither
//! shape is documented, so a turn the tail does not show begun has no words
//! and no kind, as before.

use crate::json::{contains, parse, string};
use limpid_agent_model::{PromptKind, UnpromptedPrompt};
use serde_json::{Map, Value};

/// What began the turn `turn_id`, as `rollout` says it.
pub(crate) fn unprompted_prompt(rollout: &[u8], turn_id: &str) -> UnpromptedPrompt {
    let mut objective: Option<String> = None;
    for line in rollout.split(|byte| *byte == b'\n') {
        let Some(payload) = event_payload(line) else {
            continue;
        };
        match string(&payload, "type") {
            Some("thread_goal_updated") => {
                objective = payload
                    .get("goal")
                    .and_then(Value::as_object)
                    .and_then(|goal| string(goal, "objective"))
                    .map(str::to_owned);
            }
            Some("task_started") => {
                let Some(attribution) = payload.get("turn_attribution").and_then(Value::as_object)
                else {
                    continue;
                };
                if string(attribution, "turn_id") != Some(turn_id) {
                    continue;
                }
                return match string(attribution, "turn_trigger") {
                    Some("goal") => UnpromptedPrompt {
                        prompt: objective.unwrap_or_default(),
                        kind: Some(PromptKind::Goal),
                        cwd: None,
                    },
                    // The person began it, though their prompt reached no
                    // hook (a call lost to a busy lock, Limpid started
                    // mid-turn); nothing here says what they wrote.
                    Some("user") | None => UnpromptedPrompt::default(),
                    // Something else of Codex's began it; it has no words of
                    // the person's to show.
                    Some(_) => UnpromptedPrompt {
                        prompt: String::new(),
                        kind: Some(PromptKind::Injected),
                        cwd: None,
                    },
                };
            }
            _ => {}
        }
    }
    UnpromptedPrompt::default()
}

/// The `payload` of an `event_msg` line.
fn event_payload(line: &[u8]) -> Option<Map<String, Value>> {
    // A substring check keeps the JSON parse for the event lines.
    if !contains(line, b"\"event_msg\"") {
        return None;
    }
    let mut record = parse(line)?;
    if string(&record, "type") != Some("event_msg") {
        return None;
    }
    match record.remove("payload") {
        Some(Value::Object(payload)) => Some(payload),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const GOAL_SET: &str = r#"{"type":"event_msg","payload":{"type":"thread_goal_updated","goal":{"objective":"Create a.txt, then b.txt"}}}"#;

    fn started(turn_id: &str, trigger: &str) -> String {
        format!(
            r#"{{"type":"event_msg","payload":{{"type":"task_started","turn_attribution":{{"turn_id":"{turn_id}","turn_trigger":"{trigger}"}}}}}}"#
        )
    }

    fn rollout(lines: &[&str]) -> Vec<u8> {
        lines.join("\n").into_bytes()
    }

    #[test]
    fn a_turn_the_goal_began_shows_its_objective() {
        let first = started("t1", "goal");
        let next = started("t2", "goal");
        let rollout = rollout(&[GOAL_SET, &first, &next]);
        for turn in ["t1", "t2"] {
            assert_eq!(
                unprompted_prompt(&rollout, turn),
                UnpromptedPrompt {
                    prompt: "Create a.txt, then b.txt".into(),
                    kind: Some(PromptKind::Goal),
                    cwd: None,
                },
                "{turn}"
            );
        }
    }

    #[test]
    fn the_objective_is_the_one_set_before_the_turn_began() {
        let changed = r#"{"type":"event_msg","payload":{"type":"thread_goal_updated","goal":{"objective":"Write the docs"}}}"#;
        let first = started("t1", "goal");
        let next = started("t2", "goal");
        let rollout = rollout(&[GOAL_SET, &first, changed, &next]);
        assert_eq!(
            unprompted_prompt(&rollout, "t1").prompt,
            "Create a.txt, then b.txt"
        );
        assert_eq!(unprompted_prompt(&rollout, "t2").prompt, "Write the docs");
    }

    #[test]
    fn a_goal_turn_whose_goal_the_tail_cut_off_has_no_words() {
        let first = started("t1", "goal");
        assert_eq!(
            unprompted_prompt(&rollout(&[&first]), "t1"),
            UnpromptedPrompt {
                prompt: String::new(),
                kind: Some(PromptKind::Goal),
                cwd: None,
            }
        );
    }

    #[test]
    fn another_trigger_is_codex_s_own_message() {
        let started = started("t1", "review");
        assert_eq!(
            unprompted_prompt(&rollout(&[&started]), "t1").kind,
            Some(PromptKind::Injected)
        );
    }

    #[test]
    fn a_turn_the_person_began_says_nothing_of_who_wrote_it() {
        let started = started("t1", "user");
        assert_eq!(
            unprompted_prompt(&rollout(&[GOAL_SET, &started]), "t1"),
            UnpromptedPrompt::default()
        );
    }

    #[test]
    fn a_turn_the_tail_does_not_show_begun_says_nothing() {
        let other = started("t0", "goal");
        let cut = r#"{"type":"event_msg","payload":{"type":"task_star"#;
        assert_eq!(
            unprompted_prompt(&rollout(&[GOAL_SET, &other, cut]), "t1"),
            UnpromptedPrompt::default()
        );
    }
}
