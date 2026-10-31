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
//! - `event_msg` lines of `item_completed` whose item is a
//!   `SubAgentActivity`: a subagent the turn started or put to work, named
//!   by its thread (`agent_thread_id`). The subagent keeps a rollout of its
//!   own, whose usage records carry its own turn and, as `root_turn_id`,
//!   the turn that put it to work (recorded with Codex 0.165.0 in
//!   `fixtures/transcripts/codex-0.165.0-subagent-*.jsonl`).
//!
//! Codex writes every pending line before it runs the Stop hook: resolving
//! the hook's `transcript_path` persists the rollout first
//! (`Session::hook_transcript_path`, codex-rs 970111f). Neither shape is
//! documented, so a line this cannot read is left out rather than guessed
//! at, and a turn with none reads as no usage.

use crate::json::{contains, parse, string};
use serde_json::{Map, Value};
use weir_agent_model::{CommandRun, TurnReading, TurnUsage};

/// What the turn `turn_id` used and ran, from `rollout` in one pass: its
/// usage from the last of its usage records, which is the turn's running
/// total, and its commands in order. Codex records its subagents in
/// rollouts of their own, which this names by thread (`subagents`) for the
/// runtime to find (`rollouts`) and read (`subagent_rollout_usage`). When
/// the turn's start is not among the lines, its first commands are gone,
/// and the commands are partial. The usage stays whole: Codex names a
/// subagent again when it finishes, so one only the lost lines named is
/// rare, and marking every long turn short for it would say less.
pub(crate) fn rollout_turn_reading(rollout: &[u8], turn_id: &str) -> TurnReading {
    let mut usage = None;
    let mut commands = Vec::new();
    let mut subagents: Vec<String> = Vec::new();
    let mut has_start = false;
    for line in rollout.split(|byte| *byte == b'\n') {
        // Substring checks keep the JSON parse for the lines that can
        // matter; most of a rollout is model output and tool results.
        let is_usage = contains(line, b"\"token_usage_record\"");
        let is_start = contains(line, b"\"task_started\"");
        if !is_usage
            && !is_start
            && !contains(line, b"\"CommandExecution\"")
            && !contains(line, b"\"SubAgentActivity\"")
        {
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
        {
            match string(item, "type") {
                Some("CommandExecution") => commands.extend(command_run(item)),
                // A subagent the turn started, or one an earlier turn
                // started and this one put to work again.
                Some("SubAgentActivity") => {
                    if let Some(thread) = string(item, "agent_thread_id")
                        && !thread.is_empty()
                        && !subagents.iter().any(|known| known == thread)
                    {
                        subagents.push(thread.to_owned());
                    }
                }
                _ => {}
            }
        }
    }
    TurnReading {
        marker: Some(turn_id.to_owned()),
        usage,
        subagents,
        commands: Some(commands),
        are_commands_partial: !has_start,
        is_awaiting_response: false,
    }
}

/// What a subagent's rollout used for the turn `root_turn` of the thread
/// that put it to work, or the whole rollout with no turn named: the sum of
/// its requests whose records name that turn as their root (`root_turn_id`),
/// each by its own `usage`. The subagent's turns are its own, so their
/// running totals (`turn_token_usage`) start again at each one and are not
/// summed. Partial while one of those turns has started and not ended
/// (`task_complete` or `turn_aborted`): the subagent is still at work. A
/// `rollout` that is only the file's tail (`is_whole` false) holds all of
/// that turn's work when its first line for the turn is a turn's start;
/// otherwise the work began before the tail, and the sum is partial.
pub(crate) fn subagent_rollout_usage(
    rollout: &[u8],
    is_whole: bool,
    root_turn: Option<&str>,
) -> Option<TurnUsage> {
    let mut total: Option<TurnUsage> = None;
    let mut open: Vec<String> = Vec::new();
    // Whether the tail begins after the turn's work does.
    let mut is_cut = !is_whole;
    let mut is_first = true;
    for line in rollout.split(|byte| *byte == b'\n') {
        let is_usage = contains(line, b"\"token_usage_record\"");
        if !is_usage
            && !contains(line, b"\"task_started\"")
            && !contains(line, b"\"task_complete\"")
            && !contains(line, b"\"turn_aborted\"")
        {
            continue;
        }
        let Some(record) = parse(line) else {
            continue;
        };
        let Some(payload) = record.get("payload").and_then(Value::as_object) else {
            continue;
        };
        if root_turn.is_some_and(|root| string(payload, "root_turn_id") != Some(root)) {
            continue;
        }
        if is_first {
            is_first = false;
            is_cut &= string(payload, "type") != Some("task_started");
        }
        if is_usage && string(&record, "type") == Some("token_usage_record") {
            if let Some(usage) = payload.get("usage").and_then(Value::as_object) {
                let usage = turn_usage(usage);
                total = Some(total.map_or(usage, |total| total.plus(usage)));
            }
            continue;
        }
        let Some(turn) = string(payload, "turn_id") else {
            continue;
        };
        match string(payload, "type") {
            Some("task_started") => open.push(turn.to_owned()),
            Some("task_complete" | "turn_aborted") => open.retain(|started| started != turn),
            _ => {}
        }
    }
    if open.is_empty() && !is_cut {
        return total;
    }
    Some(TurnUsage {
        is_partial: true,
        ..total.unwrap_or_default()
    })
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
    fn the_turn_names_each_subagent_thread_it_ran_once() {
        let activity = |turn: &str, kind: &str, thread: &str| {
            format!(
                r#"{{"type":"event_msg","payload":{{"type":"item_completed","turn_id":"{turn}","item":{{"type":"SubAgentActivity","kind":"{kind}","agent_thread_id":"{thread}"}}}}}}"#
            )
        };
        let rollout = [
            activity("t0", "started", "earlier"),
            activity("t1", "started", "a"),
            activity("t1", "started", "b"),
            activity("t1", "completed", "a"),
            activity("t1", "started", ""),
        ]
        .join("\n");
        assert_eq!(
            rollout_turn_reading(rollout.as_bytes(), "t1").subagents,
            vec!["a".to_owned(), "b".to_owned()]
        );
    }

    #[test]
    fn a_subagent_counts_each_request_of_the_turn_that_put_it_to_work() {
        let request = |root: &str, input: u64, cached: u64, output: u64| {
            format!(
                r#"{{"type":"token_usage_record","payload":{{"turn_id":"c","root_turn_id":"{root}","usage":{{"input_tokens":{input},"cached_input_tokens":{cached},"output_tokens":{output}}},"turn_token_usage":{{"input_tokens":999}}}}}}"#
            )
        };
        let turn = |kind: &str, turn: &str, root: &str| {
            format!(
                r#"{{"type":"event_msg","payload":{{"type":"{kind}","turn_id":"{turn}","root_turn_id":"{root}"}}}}"#
            )
        };
        let usage = |input, cached, output, is_partial| TurnUsage {
            input_tokens: input,
            cache_write_tokens: 0,
            cache_read_tokens: cached,
            output_tokens: output,
            is_partial,
        };
        let rollout = [
            turn("task_started", "c0", "t0"),
            request("t0", 50, 0, 5),
            turn("task_complete", "c0", "t0"),
            turn("task_started", "c1", "t1"),
            request("t1", 100, 0, 10),
            turn("turn_aborted", "c1", "t1"),
            turn("task_started", "c2", "t1"),
            request("t1", 120, 100, 2),
            turn("task_complete", "c2", "t1"),
            // A later turn put it to work again, and it is still at it.
            turn("task_started", "c3", "t2"),
        ]
        .join("\n");
        let bytes = rollout.as_bytes();
        // Each request once, its cached input out of the fresh; a turn of
        // the subagent ended by an interrupt counts, and one still at work
        // for another turn leaves this one whole.
        assert_eq!(
            subagent_rollout_usage(bytes, true, Some("t1")),
            Some(usage(120, 100, 12, false))
        );
        assert_eq!(
            subagent_rollout_usage(bytes, true, Some("t2")),
            Some(usage(0, 0, 0, true))
        );
        // With no turn named, the whole rollout counts.
        assert_eq!(
            subagent_rollout_usage(bytes, true, None),
            Some(usage(170, 100, 17, true))
        );
        // A tail that holds the turn's start holds all its work; one that
        // begins inside the turn's work is short of it.
        assert_eq!(
            subagent_rollout_usage(bytes, false, Some("t1")),
            Some(usage(120, 100, 12, false))
        );
        let cut = [
            request("t1", 120, 100, 2),
            turn("task_complete", "c2", "t1"),
        ]
        .join("\n");
        assert_eq!(
            subagent_rollout_usage(cut.as_bytes(), false, Some("t1")),
            Some(usage(20, 100, 2, true))
        );
        // Nothing for the turn says nothing, unless the tail may have lost it.
        assert_eq!(subagent_rollout_usage(b"", true, Some("t1")), None);
        assert_eq!(
            subagent_rollout_usage(b"", false, Some("t1")),
            Some(usage(0, 0, 0, true))
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
