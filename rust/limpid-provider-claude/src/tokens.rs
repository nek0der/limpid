//! Reads what a turn used from Claude Code's transcript, a request at a
//! time (`transcript`).
//!
//! The lines of a turn follow the user line that carries its prompt. Claude
//! Code tags that line, and the tool results the turn hands back, with the
//! `promptId` that `UserPromptSubmit` reports as `prompt_id`; assistant lines
//! carry none, so the turn is everything from that line on. Run with `-p`,
//! the turn's responses are in the file when Stop runs: the lines written
//! after it are `stop_hook_summary`, `last-prompt`, and `cost-state`, whose
//! total agreed with the sum read here to the token in the transcripts we
//! compared (Claude Code 2.1.310). In an interactive session the last
//! response can still be on its way to the file as Stop runs, a tenth of a
//! second behind. A main user line newer than the last response means one is
//! missing: the reading is marked partial and says it awaits the response
//! (`TurnReading::is_awaiting_response`), so the runtime can read again.
//!
//! A subagent's requests are in its own file,
//! `<session>/subagents/agent-<agentId>.jsonl`. The tool result that hands
//! its answer back names it (`toolUseResult.agentId`); the usage beside that
//! id is the subagent's last request only, so the runtime reads the file and
//! adds it through `subagent_transcript_usage`. A subagent sent to the
//! background (`toolUseResult.status` of `async_launched`) is still at work
//! when the turn ends, so its file is not yet whole and the reading is
//! partial.

use crate::awaited::INTERRUPT_PREFIX;
use crate::transcript::{contains, is_sidechain, parse, request_usage, string, user_text};
use limpid_agent_model::{TurnReading, TurnUsage};
use serde_json::{Map, Value};
use std::collections::HashMap;
use std::path::{Path, PathBuf};

/// Most subagent files one turn reads, so a turn that fanned out widely
/// does not hold the hook up reading them.
const MAX_SUBAGENTS: usize = 32;

/// What the turn `prompt_id` names used, from `transcript`, the tail of the
/// file at `transcript_path`. Empty when the tail holds no request of the
/// turn and it ran no subagent.
///
/// Without a `prompt_id` (a Claude Code that does not report one), the turn
/// is taken to begin at the last prompt: the last main user line that is not
/// a tool result. A `prompt_id` the tail does not hold means the turn began
/// before the tail, or that Claude Code tagged the line otherwise; the turn
/// is then read from the last prompt too, or from the tail's start when it
/// holds none, and the reading is partial either way. Reading the whole tail
/// would count earlier turns.
pub(crate) fn transcript_turn_reading(
    transcript: &[u8],
    prompt_id: Option<&str>,
    transcript_path: Option<&str>,
) -> TurnReading {
    let lines: Vec<&[u8]> = transcript.split(|byte| *byte == b'\n').collect();
    let tagged = prompt_id.map(|prompt_id| prompt_start(&lines, prompt_id));
    let (start, mut is_partial) = match tagged {
        Some(Some(start)) => (Some(start), false),
        Some(None) => (last_prompt_start(&lines), true),
        None => {
            let start = last_prompt_start(&lines);
            (start, start.is_none())
        }
    };
    // The prompt the reading counts from, so the runtime can tell one that
    // began at a turn it already recorded.
    let marker = start
        .and_then(|start| parse(lines[start]))
        .and_then(|record| string(&record, "promptId").map(str::to_owned));
    let mut requests = Requests::default();
    let mut agents: Vec<String> = Vec::new();
    // A typed prompt with no response yet awaits one; a local command
    // (`/model`) makes no request, so it has nothing to wait for.
    let mut is_answered = start
        .and_then(|start| parse(lines[start]))
        .is_none_or(|record| is_local_command(&record));
    for line in &lines[start.map_or(0, |start| start + 1)..] {
        // Substring checks keep the JSON parse for the lines that can
        // matter; a tool result can be a whole file.
        if !contains(line, br#""assistant""#) && !contains(line, br#""user""#) {
            continue;
        }
        let Some(record) = parse(line) else {
            continue;
        };
        if is_sidechain(&record) {
            continue;
        }
        match string(&record, "type") {
            Some("assistant") => {
                if requests.add(&record) {
                    is_answered = true;
                }
            }
            Some("user") => {
                // The next turn's prompt ends this one: a reading made late
                // must not count what came after.
                if let Some(prompt_id) = prompt_id
                    && string(&record, "promptId").is_some_and(|other| other != prompt_id)
                {
                    break;
                }
                // An interrupt ends the turn: no response is to come, for
                // it or for a tool result before it.
                is_answered =
                    user_text(&record).is_some_and(|text| text.starts_with(INTERRUPT_PREFIX));
                let result = record.get("toolUseResult").and_then(Value::as_object);
                if let Some(agent) = result
                    .and_then(|result| string(result, "agentId"))
                    .filter(|agent| is_agent_id(agent))
                {
                    is_partial |= result.and_then(|result| string(result, "status"))
                        == Some("async_launched");
                    if !agents.iter().any(|known| known == agent) {
                        agents.push(agent.to_owned());
                    }
                }
            }
            _ => {}
        }
    }
    let is_awaiting_response = !is_answered;
    if requests.is_empty() && agents.is_empty() {
        // Nothing to count yet; a prompt still awaiting its only response
        // says so, and the runtime reads again for it.
        return TurnReading {
            marker,
            is_awaiting_response,
            ..TurnReading::default()
        };
    }
    is_partial |= is_awaiting_response;
    if agents.len() > MAX_SUBAGENTS {
        agents.truncate(MAX_SUBAGENTS);
        is_partial = true;
    }
    let directory = transcript_path.and_then(subagent_directory);
    if directory.is_none() && !agents.is_empty() {
        is_partial = true;
    }
    let mut usage = requests.total();
    usage.is_partial = is_partial;
    TurnReading {
        marker,
        usage: Some(usage),
        subagent_transcripts: directory
            .map(|directory| {
                agents
                    .iter()
                    .map(|agent| directory.join(format!("agent-{agent}.jsonl")))
                    .collect()
            })
            .unwrap_or_default(),
        commands: None,
        are_commands_partial: false,
        is_awaiting_response,
    }
}

/// What a subagent's whole transcript used. Its lines are all the
/// subagent's own, sidechain or not. Partial when its last line is not a
/// response: the subagent was still at work when the turn ended.
pub(crate) fn subagent_transcript_usage(transcript: &[u8]) -> Option<TurnUsage> {
    let mut requests = Requests::default();
    let mut is_answered = true;
    for line in transcript.split(|byte| *byte == b'\n') {
        let Some(record) = parse(line) else {
            continue;
        };
        match string(&record, "type") {
            Some("assistant") => {
                if requests.add(&record) {
                    is_answered = true;
                }
            }
            Some("user") => is_answered = false,
            _ => {}
        }
    }
    if requests.is_empty() {
        return None;
    }
    let mut usage = requests.total();
    usage.is_partial = !is_answered;
    Some(usage)
}

/// Whether a user line is a local command (`/model`, `/clear`) or text the
/// harness wrote, which no request answers.
fn is_local_command(record: &Map<String, Value>) -> bool {
    record.get("isMeta").and_then(Value::as_bool) == Some(true)
        || user_text(record).is_some_and(|text| {
            let text = text.trim_start();
            text.starts_with("<command-name>") || text.starts_with("<local-command")
        })
}

/// The index of the main user line tagged `prompt_id`, where the turn it
/// names begins.
fn prompt_start(lines: &[&[u8]], prompt_id: &str) -> Option<usize> {
    let needle = format!(r#""promptId":"{prompt_id}""#);
    lines.iter().position(|line| {
        contains(line, needle.as_bytes())
            && parse(line).is_some_and(|record| {
                string(&record, "type") == Some("user")
                    && !is_sidechain(&record)
                    && string(&record, "promptId") == Some(prompt_id)
            })
    })
}

/// The index of the last prompt: the last main user line that is neither a
/// tool result nor the line an interrupt leaves.
fn last_prompt_start(lines: &[&[u8]]) -> Option<usize> {
    lines.iter().rposition(|line| {
        contains(line, br#""user""#)
            && parse(line).is_some_and(|record| {
                string(&record, "type") == Some("user")
                    && !is_sidechain(&record)
                    && !is_tool_result(&record)
                    && !user_text(&record).is_some_and(|text| text.starts_with(INTERRUPT_PREFIX))
            })
    })
}

/// The requests read so far, each the larger value of every counter over
/// its lines.
#[derive(Default)]
struct Requests {
    by_id: HashMap<String, TurnUsage>,
}

impl Requests {
    /// Adds the line's usage to its request; false for a line that carries
    /// none.
    fn add(&mut self, record: &Map<String, Value>) -> bool {
        let Some((request, line)) = request_usage(record) else {
            return false;
        };
        let known = self.by_id.entry(request.to_owned()).or_default();
        *known = known.fuller(line);
        true
    }

    fn is_empty(&self) -> bool {
        self.by_id.is_empty()
    }

    fn total(&self) -> TurnUsage {
        self.by_id
            .values()
            .fold(TurnUsage::default(), |total, request| total.plus(*request))
    }
}

/// The folder Claude Code keeps a session's subagent transcripts in, beside
/// the session's own file.
fn subagent_directory(transcript_path: &str) -> Option<PathBuf> {
    let path = Path::new(transcript_path);
    let stem = path.file_stem()?;
    Some(path.parent()?.join(stem).join("subagents"))
}

/// Whether `agent` can name a file in the subagents folder. Claude Code's
/// agent ids are hex; we take letters, digits, `-`, and `_`, so nothing
/// joined into the path can leave the folder (`/`, `..`).
fn is_agent_id(agent: &str) -> bool {
    !agent.is_empty()
        && agent.len() <= 64
        && agent
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-' || byte == b'_')
}

fn is_tool_result(record: &Map<String, Value>) -> bool {
    record
        .get("message")
        .and_then(|message| message.get("content"))
        .and_then(Value::as_array)
        .is_some_and(|content| {
            content
                .iter()
                .any(|part| part.get("type").and_then(Value::as_str) == Some("tool_result"))
        })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn prompt(id: &str, text: &str) -> String {
        format!(
            r#"{{"type":"user","isSidechain":false,"promptId":"{id}","message":{{"role":"user","content":"{text}"}}}}"#
        )
    }

    fn tool_result(id: &str, extra: &str) -> String {
        format!(
            r#"{{"type":"user","isSidechain":false,"promptId":"{id}","message":{{"role":"user","content":[{{"type":"tool_result","tool_use_id":"t"}}]}}{extra}}}"#
        )
    }

    fn reply(request: &str, input: u64, write: u64, read: u64, output: u64) -> String {
        format!(
            r#"{{"type":"assistant","isSidechain":false,"requestId":"{request}","message":{{"id":"msg_{request}","role":"assistant","usage":{{"input_tokens":{input},"cache_creation_input_tokens":{write},"cache_read_input_tokens":{read},"output_tokens":{output}}}}}}}"#
        )
    }

    fn transcript(lines: &[String]) -> Vec<u8> {
        let mut bytes = lines.join("\n").into_bytes();
        bytes.push(b'\n');
        bytes
    }

    fn usage(input: u64, write: u64, read: u64, output: u64) -> TurnUsage {
        TurnUsage {
            input_tokens: input,
            cache_write_tokens: write,
            cache_read_tokens: read,
            output_tokens: output,
            is_partial: false,
        }
    }

    #[test]
    fn a_turn_sums_its_requests_once_each_from_its_prompt_on() {
        let bytes = transcript(&[
            prompt("p1", "earlier"),
            reply("req_0", 9, 9, 9, 9),
            prompt("p2", "add tests"),
            // One request streamed over two lines, the output growing.
            reply("req_1", 2, 14_846, 11_558, 120),
            reply("req_1", 2, 14_846, 11_558, 254),
            tool_result("p2", ""),
            reply("req_2", 2, 284, 26_404, 72),
            r#"{"type":"system","subtype":"stop_hook_summary"}"#.to_owned(),
        ]);
        let reading = transcript_turn_reading(&bytes, Some("p2"), None);
        assert_eq!(reading.usage, Some(usage(4, 15_130, 37_962, 326)));
        assert!(reading.subagent_transcripts.is_empty());
        assert_eq!(reading.marker.as_deref(), Some("p2"));
    }

    #[test]
    fn without_a_prompt_id_the_turn_begins_at_the_last_prompt() {
        let bytes = transcript(&[
            prompt("p1", "earlier"),
            reply("req_0", 9, 9, 9, 9),
            prompt("p2", "add tests"),
            reply("req_1", 1, 2, 3, 4),
            tool_result("p2", ""),
            reply("req_2", 1, 2, 3, 4),
        ]);
        let reading = transcript_turn_reading(&bytes, None, None);
        assert_eq!(reading.usage, Some(usage(2, 4, 6, 8)));
        assert_eq!(
            reading.marker.as_deref(),
            Some("p2"),
            "the prompt it counted from"
        );
    }

    #[test]
    fn a_turn_that_began_before_the_tail_reads_the_whole_tail_as_partial() {
        let bytes = transcript(&[
            r#"t":"cut in half"}"#.to_owned(),
            reply("req_1", 1, 2, 3, 4),
        ]);
        let reading = transcript_turn_reading(&bytes, Some("p9"), None);
        assert_eq!(
            reading.usage,
            Some(TurnUsage {
                is_partial: true,
                ..usage(1, 2, 3, 4)
            })
        );
    }

    #[test]
    fn a_prompt_id_the_tail_does_not_hold_reads_from_the_last_prompt_as_partial() {
        let bytes = transcript(&[
            prompt("p1", "earlier"),
            reply("req_0", 9, 9, 9, 9),
            prompt("p2", "tagged otherwise"),
            reply("req_1", 1, 2, 3, 4),
        ]);
        let reading = transcript_turn_reading(&bytes, Some("p9"), None);
        assert_eq!(
            reading.usage,
            Some(TurnUsage {
                is_partial: true,
                ..usage(1, 2, 3, 4)
            })
        );
    }

    #[test]
    fn a_turn_still_waiting_for_its_last_response_is_partial() {
        let bytes = transcript(&[
            prompt("p1", "go"),
            reply("req_1", 1, 2, 3, 4),
            tool_result("p1", ""),
        ]);
        let reading = transcript_turn_reading(&bytes, Some("p1"), None);
        assert!(reading.usage.expect("usage").is_partial);
    }

    #[test]
    fn sidechain_lines_and_a_local_command_count_nothing() {
        let bytes = transcript(&[
            prompt("p1", "<command-name>/model</command-name>"),
            r#"{"type":"assistant","isSidechain":true,"requestId":"s","message":{"usage":{"output_tokens":50}}}"#.to_owned(),
        ]);
        assert_eq!(
            transcript_turn_reading(&bytes, Some("p1"), None),
            TurnReading {
                marker: Some("p1".into()),
                ..TurnReading::default()
            }
        );
    }

    #[test]
    fn a_prompt_with_no_response_yet_awaits_its_only_one() {
        let bytes = transcript(&[prompt("p1", "what is 2 + 2?")]);
        let reading = transcript_turn_reading(&bytes, Some("p1"), None);
        assert_eq!(reading.usage, None);
        assert!(reading.is_awaiting_response);
    }

    #[test]
    fn an_interrupt_ends_the_turn_with_nothing_to_await() {
        let bytes = transcript(&[
            prompt("p1", "go"),
            reply("req_1", 1, 2, 3, 4),
            tool_result("p1", ""),
            r#"{"type":"user","isSidechain":false,"message":{"content":[{"type":"text","text":"[Request interrupted by user for tool use]"}]}}"#.to_owned(),
        ]);
        let reading = transcript_turn_reading(&bytes, Some("p1"), None);
        assert!(!reading.is_awaiting_response);
        assert_eq!(
            reading.usage,
            Some(usage(1, 2, 3, 4)),
            "whole: nothing more was asked"
        );
        let interrupted = transcript(&[
            prompt("p1", "go"),
            reply("req_1", 1, 2, 3, 4),
            r#"{"type":"user","isSidechain":false,"message":{"content":"[Request interrupted by user]"}}"#.to_owned(),
        ]);
        let reading = transcript_turn_reading(&interrupted, None, None);
        assert_eq!(
            reading.marker.as_deref(),
            Some("p1"),
            "an interrupt is no prompt"
        );
        assert_eq!(reading.usage, Some(usage(1, 2, 3, 4)));
        assert!(!reading.is_awaiting_response);
    }

    #[test]
    fn the_next_prompt_ends_the_turn() {
        let bytes = transcript(&[
            prompt("p1", "go"),
            reply("req_1", 1, 2, 3, 4),
            prompt("p2", "and then"),
            reply("req_2", 9, 9, 9, 9),
        ]);
        let reading = transcript_turn_reading(&bytes, Some("p1"), None);
        assert_eq!(reading.usage, Some(usage(1, 2, 3, 4)));
        assert!(!reading.is_awaiting_response);
    }

    #[test]
    fn a_subagent_the_turn_ran_is_named_by_its_file() {
        let bytes = transcript(&[
            prompt("p1", "explore"),
            reply("req_1", 1, 2, 3, 4),
            tool_result(
                "p1",
                r#","toolUseResult":{"status":"completed","agentId":"a00264d9d662df6cd"}"#,
            ),
            tool_result("p1", r#","toolUseResult":{"agentId":"../../etc"}"#),
            reply("req_2", 1, 2, 3, 4),
        ]);
        let reading = transcript_turn_reading(
            &bytes,
            Some("p1"),
            Some("/home/me/.claude/projects/-repo/7526eefe.jsonl"),
        );
        assert_eq!(
            reading.subagent_transcripts,
            vec![PathBuf::from(
                "/home/me/.claude/projects/-repo/7526eefe/subagents/agent-a00264d9d662df6cd.jsonl"
            )]
        );
        assert!(!reading.usage.expect("usage").is_partial);
    }

    #[test]
    fn a_subagent_sent_to_the_background_leaves_the_reading_partial() {
        let bytes = transcript(&[
            prompt("p1", "explore"),
            tool_result(
                "p1",
                r#","toolUseResult":{"status":"async_launched","agentId":"abc"}"#,
            ),
            reply("req_1", 1, 2, 3, 4),
        ]);
        let reading = transcript_turn_reading(&bytes, Some("p1"), Some("/p/s.jsonl"));
        assert!(reading.usage.expect("usage").is_partial);
        assert_eq!(
            reading.subagent_transcripts,
            vec![PathBuf::from("/p/s/subagents/agent-abc.jsonl")]
        );
    }

    #[test]
    fn a_turn_past_the_most_subagents_reads_them_partial() {
        let mut lines = vec![prompt("p1", "fan out"), reply("req_1", 1, 2, 3, 4)];
        for index in 0..=MAX_SUBAGENTS {
            lines.push(tool_result(
                "p1",
                &format!(r#","toolUseResult":{{"status":"completed","agentId":"a{index}"}}"#),
            ));
        }
        lines.push(reply("req_2", 1, 2, 3, 4));
        let reading = transcript_turn_reading(&transcript(&lines), Some("p1"), Some("/p/s.jsonl"));
        assert_eq!(reading.subagent_transcripts.len(), MAX_SUBAGENTS);
        assert!(reading.usage.expect("usage").is_partial);
    }

    #[test]
    fn a_subagent_without_a_transcript_path_leaves_the_reading_partial() {
        let bytes = transcript(&[
            prompt("p1", "explore"),
            tool_result("p1", r#","toolUseResult":{"agentId":"abc"}"#),
            reply("req_1", 1, 2, 3, 4),
        ]);
        let reading = transcript_turn_reading(&bytes, Some("p1"), None);
        assert!(reading.usage.expect("usage").is_partial);
        assert!(reading.subagent_transcripts.is_empty());
    }

    #[test]
    fn a_subagent_transcript_sums_every_request_and_is_partial_while_it_runs() {
        let finished = transcript(&[
            r#"{"type":"user","isSidechain":true,"message":{"content":"look"}}"#.to_owned(),
            reply("req_a", 2, 16_170, 0, 398),
            reply("req_b", 2, 1_581, 16_170, 120),
            reply("req_c", 2, 156, 17_751, 266),
        ]);
        assert_eq!(
            subagent_transcript_usage(&finished),
            Some(usage(6, 17_907, 33_921, 784))
        );
        let running = transcript(&[
            reply("req_a", 1, 1, 1, 1),
            r#"{"type":"user","isSidechain":true,"message":{"content":[{"type":"tool_result"}]}}"#
                .to_owned(),
        ]);
        assert!(
            subagent_transcript_usage(&running)
                .expect("usage")
                .is_partial
        );
        assert_eq!(subagent_transcript_usage(b""), None);
    }
}
