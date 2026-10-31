//! What kind of prompt began a turn: one the person wrote, or one the
//! agent's harness put in the conversation for it.
//!
//! Claude Code hands its hook some prompts nobody typed: a background task's
//! end (`<task-notification>`), a subagent's hand-back (`<agent-message`),
//! and reminders it adds before the person's own words
//! (`<system-reminder>`). Shown as they are, they would put their tags and
//! ids where the turn's instruction goes. The hook judges the whole prompt
//! when the turn begins and records the kind beside a head taken from the
//! person's words; only a record from before the kind was kept is judged
//! again from its head when it is summarized. The same judgment keeps
//! these prompts out of notification bodies and tab titles.
//!
//! Codex begins some turns with no prompt at all: those its `/goal` starts
//! and continues. The provider names their kind itself (`Goal`), since no
//! text says it.

use serde::{Deserialize, Serialize};
use serde_json::Value;

/// Who wrote the prompt a turn began from.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum PromptKind {
    /// The person's own words, or nothing recognizably otherwise.
    #[default]
    Text,
    /// A background task the agent started has ended.
    BackgroundTask,
    /// A subagent handed its result back.
    SubagentMessage,
    /// Another message the harness added, with none of the person's words
    /// left to show.
    Injected,
    /// A turn the agent began on its own to work toward the goal the person
    /// set (Codex's `/goal`). The head is the goal's objective.
    Goal,
}

/// A record's `promptKind` as it was read. The kind only words the turn,
/// so a value this version does not know is kept as it came and written
/// back, rather than making the whole record read only, as an unknown value
/// elsewhere does; it reads as the person's words.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(untagged)]
pub enum RecordedPromptKind {
    Known(PromptKind),
    Unrecognized(Value),
}

impl RecordedPromptKind {
    /// The kind, `Text` for one this version does not know.
    #[must_use]
    pub fn kind(&self) -> PromptKind {
        match self {
            Self::Known(kind) => *kind,
            Self::Unrecognized(_) => PromptKind::Text,
        }
    }
}

/// Tags that open a message standing alone: the whole prompt is the
/// harness's, so nothing after the tag is the person's.
const STANDALONE_TAGS: [(&str, PromptKind); 2] = [
    ("task-notification", PromptKind::BackgroundTask),
    ("agent-message", PromptKind::SubagentMessage),
];

/// Tags the harness puts in front of a prompt, which may still be followed
/// by the person's own words once the block closes.
const LEADING_TAGS: [&str; 2] = ["system-reminder", "local-command-caveat"];

/// The kind of `prompt`, and where the person's words begin in it. The
/// words are the prompt itself unless harness blocks lead it, which are left
/// out; for any other kind they are the prompt as it came, which only that
/// kind's own wording should replace.
///
/// A block whose end is not in `prompt` (a prompt head keeps only its first
/// characters) leaves nothing of the person's to show, so it reads as
/// `Injected` rather than as the block's own text.
#[must_use]
pub fn classify_prompt(prompt: &str) -> (PromptKind, &str) {
    let mut rest = prompt.trim_start();
    loop {
        if let Some((_, kind)) = STANDALONE_TAGS.iter().find(|(tag, _)| opens(rest, tag)) {
            return (*kind, prompt);
        }
        let Some(tag) = LEADING_TAGS.iter().find(|tag| opens(rest, tag)) else {
            return (PromptKind::Text, rest);
        };
        let closing = format!("</{tag}>");
        let Some(end) = rest.find(&closing) else {
            return (PromptKind::Injected, prompt);
        };
        rest = rest[end + closing.len()..].trim_start();
        if rest.is_empty() {
            return (PromptKind::Injected, prompt);
        }
    }
}

/// Whether `text` begins with the opening of `tag`: `<tag` followed by its
/// end, an attribute, or nothing (the head was cut inside the tag). A longer
/// name that only starts the same (`<agent-messages>`) is another tag.
fn opens(text: &str, tag: &str) -> bool {
    let Some(after) = text
        .strip_prefix('<')
        .and_then(|rest| rest.strip_prefix(tag))
    else {
        return false;
    };
    after
        .chars()
        .next()
        .is_none_or(|next| next == '>' || next == '/' || next.is_whitespace())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_background_task_notification_reads_as_a_background_task() {
        let head =
            "<task-notification> <task-id>bmtysm2i6</task-id> <tool-use-id>toolu_01</tool-use-id>";
        assert_eq!(classify_prompt(head), (PromptKind::BackgroundTask, head));
    }

    #[test]
    fn a_subagent_message_reads_as_one_with_or_without_attributes() {
        let head = r#"<agent-message from="ade08c9a2d0c40ca0"> [Subagent hand-back]"#;
        assert_eq!(classify_prompt(head).0, PromptKind::SubagentMessage);
        assert_eq!(
            classify_prompt("<agent-message>done").0,
            PromptKind::SubagentMessage
        );
    }

    #[test]
    fn leading_whitespace_does_not_hide_the_tag() {
        assert_eq!(
            classify_prompt("  \n<task-notification>x").0,
            PromptKind::BackgroundTask
        );
    }

    #[test]
    fn a_tag_cut_off_by_the_head_still_reads_as_its_kind() {
        assert_eq!(
            classify_prompt(r#"<agent-message from="ade08c9a2d0c40"#).0,
            PromptKind::SubagentMessage
        );
        assert_eq!(
            classify_prompt("<task-notification").0,
            PromptKind::BackgroundTask
        );
    }

    #[test]
    fn a_reminder_whose_end_is_cut_off_reads_as_injected() {
        let head =
            "<system-reminder> The user opened the file foo.swift in the IDE. This may or may";
        assert_eq!(classify_prompt(head), (PromptKind::Injected, head));
    }

    #[test]
    fn a_reminder_alone_reads_as_injected() {
        let head = "<system-reminder>Plan mode is active.</system-reminder> ";
        assert_eq!(classify_prompt(head), (PromptKind::Injected, head));
    }

    #[test]
    fn the_persons_words_after_a_reminder_are_the_instruction() {
        assert_eq!(
            classify_prompt("<system-reminder>ok</system-reminder> add the tests"),
            (PromptKind::Text, "add the tests")
        );
        assert_eq!(
            classify_prompt(
                "<system-reminder>a</system-reminder><local-command-caveat>b</local-command-caveat> fix it"
            ),
            (PromptKind::Text, "fix it")
        );
    }

    #[test]
    fn a_notification_after_a_reminder_reads_as_the_notification() {
        let head = "<system-reminder>a</system-reminder> <task-notification>";
        assert_eq!(classify_prompt(head), (PromptKind::BackgroundTask, head));
    }

    #[test]
    fn plain_text_and_other_tags_are_the_persons_words() {
        assert_eq!(
            classify_prompt("add tests"),
            (PromptKind::Text, "add tests")
        );
        assert_eq!(
            classify_prompt("<div> is misaligned"),
            (PromptKind::Text, "<div> is misaligned")
        );
        assert_eq!(classify_prompt("<agent-messages> list").0, PromptKind::Text);
        assert_eq!(
            classify_prompt("explain <task-notification>").0,
            PromptKind::Text
        );
    }

    #[test]
    fn an_empty_prompt_is_text_with_nothing_in_it() {
        assert_eq!(classify_prompt(""), (PromptKind::Text, ""));
        assert_eq!(classify_prompt("  "), (PromptKind::Text, ""));
    }

    #[test]
    fn kinds_serialize_in_camel_case() {
        let words: Vec<String> = [
            PromptKind::Text,
            PromptKind::BackgroundTask,
            PromptKind::SubagentMessage,
            PromptKind::Injected,
        ]
        .iter()
        .map(|kind| serde_json::to_string(kind).expect("kind"))
        .collect();
        assert_eq!(
            words,
            [
                r#""text""#,
                r#""backgroundTask""#,
                r#""subagentMessage""#,
                r#""injected""#
            ]
        );
    }
}
