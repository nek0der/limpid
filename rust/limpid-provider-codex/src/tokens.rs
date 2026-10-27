//! Reads what a turn used, and the commands it ran, from Codex's rollout.
//!
//! Codex's hooks carry neither: `PostToolUse` hands back the command's output
//! as text with no exit status, and no hook reports tokens. The rollout
//! (`transcript_path` in every hook payload) records both, tagged with the
//! `turn_id` the hooks also carry:
//!
//! - `token_usage_record` lines, one per request, whose `turn_token_usage`
//!   is the turn's running total. It only grew within a turn in every
//!   rollout we read (Codex 0.153 to 0.164), so the last one is the turn's.
//!   Its `input_tokens` includes the cached and cache-written input.
//! - `event_msg` lines of `item_completed` whose item is a
//!   `CommandExecution`: the command as `[shell, "-lc" | "-c", script]`, its
//!   `exit_code`, and its `status`.
//! - An `event_msg` line of `task_started` that opens the turn, before any
//!   of its commands in every rollout we read. Its absence from the part we
//!   read means the turn began before it, and its first commands are gone.
//!
//! Codex writes every pending line before it runs the Stop hook: resolving
//! the hook's `transcript_path` persists the rollout first
//! (`Session::hook_transcript_path`, codex-rs 970111f). Neither shape is
//! documented, so a line this cannot read is left out rather than guessed
//! at, and a turn with none reads as no usage.

use crate::json::{contains, parse, string};
use limpid_agent_model::{CommandRun, TurnReading, TurnUsage};
use serde_json::{Map, Value};

/// What the turn `turn_id` used and ran, from `rollout` in one pass: its
/// usage from the last of its usage records, which is the turn's running
/// total and so whole however little of the rollout we read, and its
/// commands in order, partial when the turn's start is not among the
/// lines. Codex records its subagents in rollouts of their own, which this
/// does not read.
pub(crate) fn rollout_turn_reading(rollout: &[u8], turn_id: &str) -> TurnReading {
    let mut usage = None;
    let mut commands = Vec::new();
    let mut has_start = false;
    for line in rollout.split(|byte| *byte == b'\n') {
        // Substring checks keep the JSON parse for the lines that can
        // matter; most of a rollout is model output and tool results.
        let is_usage = contains(line, b"\"token_usage_record\"");
        let is_start = contains(line, b"\"task_started\"");
        if !is_usage && !is_start && !contains(line, b"\"CommandExecution\"") {
            continue;
        }
        let Some(record) = parse(line) else {
            continue;
        };
        let Some(payload) = record.get("payload").and_then(Value::as_object) else {
            continue;
        };
        if string(payload, "turn_id") != Some(turn_id) {
            continue;
        }
        if is_start && string(payload, "type") == Some("task_started") {
            has_start = true;
        } else if is_usage && string(&record, "type") == Some("token_usage_record") {
            usage = payload
                .get("turn_token_usage")
                .and_then(Value::as_object)
                .map(turn_usage)
                .or(usage);
        } else if string(payload, "type") == Some("item_completed")
            && let Some(item) = payload.get("item").and_then(Value::as_object)
            && string(item, "type") == Some("CommandExecution")
            && let Some(run) = command_run(item)
        {
            commands.push(run);
        }
    }
    TurnReading {
        marker: Some(turn_id.to_owned()),
        usage,
        subagent_transcripts: Vec::new(),
        commands: Some(commands),
        are_commands_partial: !has_start,
        is_awaiting_response: false,
    }
}

/// A turn's running total, with the cached and cache-written input taken
/// out of `input_tokens`, which counts them.
fn turn_usage(usage: &Map<String, Value>) -> TurnUsage {
    let count = |key: &str| usage.get(key).and_then(Value::as_u64).unwrap_or(0);
    let cached = count("cached_input_tokens");
    let written = count("cache_write_input_tokens");
    TurnUsage {
        input_tokens: count("input_tokens").saturating_sub(cached.saturating_add(written)),
        cache_write_tokens: written,
        cache_read_tokens: cached,
        output_tokens: count("output_tokens"),
        is_partial: false,
    }
}

/// The command a `CommandExecution` item ran: the script its shell was
/// handed as `[shell, "-lc" | "-c", script]`, and the exit status of a run
/// that completed or failed. A run the person declined never ran and is
/// left out; any other status is a run that did not come to an end of its
/// own, kept with no status. A command of another shape is left out rather
/// than guessed at.
fn command_run(item: &Map<String, Value>) -> Option<CommandRun> {
    let status = string(item, "status");
    if status == Some("declined") {
        return None;
    }
    let [Value::String(_), Value::String(flag), Value::String(script)] =
        item.get("command")?.as_array()?.as_slice()
    else {
        return None;
    };
    if !matches!(flag.as_str(), "-lc" | "-c") || script.trim().is_empty() {
        return None;
    }
    let exit_code = match status {
        Some("completed" | "failed") => item
            .get("exit_code")
            .and_then(Value::as_i64)
            .and_then(|code| i32::try_from(code).ok()),
        _ => None,
    };
    Some(CommandRun {
        command: script.clone(),
        exit_code,
        cwd: string(item, "cwd").and_then(file_url_path),
    })
}

/// The path a `file://` URL names, its percent escapes decoded; `None` for
/// any other URL, or one whose escapes do not decode to UTF-8.
fn file_url_path(url: &str) -> Option<String> {
    let encoded = url.strip_prefix("file://")?;
    let bytes = encoded.as_bytes();
    let mut decoded = Vec::with_capacity(bytes.len());
    let mut index = 0;
    while index < bytes.len() {
        if bytes[index] == b'%' {
            let hex = std::str::from_utf8(bytes.get(index + 1..index + 3)?).ok()?;
            decoded.push(u8::from_str_radix(hex, 16).ok()?);
            index += 3;
        } else {
            decoded.push(bytes[index]);
            index += 1;
        }
    }
    String::from_utf8(decoded)
        .ok()
        .filter(|path| path.starts_with('/'))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn record(turn: &str, input: u64, cached: u64, output: u64) -> String {
        format!(
            r#"{{"timestamp":"t","type":"token_usage_record","payload":{{"turn_id":"{turn}","usage":{{"input_tokens":1}},"turn_token_usage":{{"input_tokens":{input},"cached_input_tokens":{cached},"cache_write_input_tokens":0,"output_tokens":{output},"reasoning_output_tokens":0,"total_tokens":{}}}}}}}"#,
            input + output
        )
    }

    fn command(turn: &str, argv: &str, status: &str, exit: &str) -> String {
        format!(
            r#"{{"timestamp":"t","type":"event_msg","payload":{{"type":"item_completed","turn_id":"{turn}","item":{{"type":"CommandExecution","command":[{argv}],"cwd":"file:///Users/me/my%20repo","status":"{status}","exit_code":{exit}}}}}}}"#
        )
    }

    fn started(turn: &str) -> String {
        format!(
            r#"{{"timestamp":"t","type":"event_msg","payload":{{"type":"task_started","turn_id":"{turn}"}}}}"#
        )
    }

    fn rollout(lines: &[String]) -> Vec<u8> {
        lines.join("\n").into_bytes()
    }

    #[test]
    fn the_turn_takes_its_last_running_total_without_the_cached_input() {
        let bytes = rollout(&[
            record("a", 43_649, 0, 254),
            record("b", 10, 0, 10),
            record("a", 96_113, 94_464, 807),
            record("c", 5, 0, 5),
        ]);
        assert_eq!(
            rollout_turn_reading(&bytes, "a").usage,
            Some(TurnUsage {
                input_tokens: 1_649,
                cache_write_tokens: 0,
                cache_read_tokens: 94_464,
                output_tokens: 807,
                is_partial: false,
            })
        );
        let other = rollout_turn_reading(&bytes, "z");
        assert_eq!(other.usage, None);
        assert_eq!(other.commands, Some(Vec::new()));
    }

    #[test]
    fn the_turn_lists_its_own_commands_in_order() {
        let bytes = rollout(&[
            started("a"),
            command("a", r#""/bin/zsh","-lc","cargo test""#, "failed", "101"),
            command("b", r#""/bin/zsh","-lc","ls""#, "completed", "0"),
            command("a", r#""/bin/bash","-c","cargo test""#, "completed", "0"),
            command("a", r#""/bin/zsh","-lc","sleep 99""#, "in_progress", "null"),
            // Declined, so never run, and two shapes we do not read.
            command("a", r#""/bin/zsh","-lc","rm -rf x""#, "declined", "null"),
            command("a", r#""cargo","test""#, "completed", "0"),
            command("a", r#""/bin/zsh","-x","cargo test""#, "completed", "0"),
        ]);
        let run = |command: &str, exit_code| CommandRun {
            command: command.into(),
            exit_code,
            cwd: Some("/Users/me/my repo".into()),
        };
        let reading = rollout_turn_reading(&bytes, "a");
        assert_eq!(
            reading.commands,
            Some(vec![
                run("cargo test", Some(101)),
                run("cargo test", Some(0)),
                run("sleep 99", None),
            ])
        );
        assert!(!reading.are_commands_partial);
        assert_eq!(reading.marker.as_deref(), Some("a"));
    }

    #[test]
    fn a_turn_that_began_before_the_part_read_has_partial_commands() {
        let bytes = rollout(&[
            started("b"),
            command("a", r#""/bin/zsh","-lc","cargo test""#, "completed", "0"),
        ]);
        let reading = rollout_turn_reading(&bytes, "a");
        assert_eq!(reading.commands.map(|runs| runs.len()), Some(1));
        assert!(
            reading.are_commands_partial,
            "another turn's start is not this one's"
        );
    }

    #[test]
    fn only_a_file_url_names_a_directory() {
        assert_eq!(file_url_path("file:///a/b%E3%81%82"), Some("/a/bあ".into()));
        assert_eq!(file_url_path("/a/b"), None);
        assert_eq!(file_url_path("file:///a/%zz"), None);
        assert_eq!(file_url_path("file://host/a"), None);
    }
}
