#!/usr/bin/env python3
"""Writes `expected.json` for every recorded fixture case.

Usage: scripts/derive-expected-events.py [<fixtures-root>]

This is a regeneration aid, not a second source of truth: it mirrors the
fallback order the Rust adapters implement so a re-recorded case does not
have to be written out by hand. The committed `expected.json` files are the
review-approved goldens. Re-run this script after re-recording a case and
review the diff like any other change; when the script and an adapter
disagree, review decides which behavior is correct and the script is updated
to match.
"""

import json
import os
import sys


def string(obj, key):
    value = obj.get(key)
    return value if isinstance(value, str) else None


def tool_argument(tool_input, read):
    """The tool's `command` when its input has the key, read as `read` reads
    it, else its `file_path`. Like the adapters, a `command` that is there but
    empty or of another type gives no argument rather than the `file_path`."""
    key = "command" if "command" in tool_input else "file_path"
    return read(tool_input.get(key))


def text(value):
    return value if isinstance(value, str) else None


def transcript_titles(path):
    if not os.path.exists(path):
        return None
    with open(path, encoding="utf-8") as handle:
        lines = handle.read().split("\n")
    for line in reversed(lines):
        try:
            record = json.loads(line)
        except json.JSONDecodeError:
            continue
        if not isinstance(record, dict):
            continue
        if record.get("type") != "ai-title":
            continue
        titles = {}
        session = string(record, "customTitle")
        generated = string(record, "aiTitle")
        if session is not None:
            titles["session_title"] = session
        if generated is not None:
            titles["generated_title"] = generated
        return titles or None
    return None


INTERRUPT_PREFIX = "[Request interrupted by user"


def content_blocks(message):
    content = message.get("content")
    if not isinstance(content, list):
        return []
    return [block for block in content if isinstance(block, dict)]


def transcript_awaited_call_ended(path):
    """Mirrors `limpid-provider-claude`'s `awaited`: whether every tool call
    of the latest assistant message that made one has a result, or an
    interrupt line follows that message."""
    if path is None or not os.path.exists(path):
        return False
    with open(path, encoding="utf-8") as handle:
        lines = handle.read().split("\n")
    ended = set()
    is_interrupted = False
    latest = None
    has_latest = False
    for line in reversed(lines):
        if "tool_use" not in line and INTERRUPT_PREFIX not in line:
            continue
        try:
            record = json.loads(line)
        except json.JSONDecodeError:
            continue
        if not isinstance(record, dict) or record.get("isSidechain") is True:
            continue
        message = record.get("message")
        if not isinstance(message, dict):
            continue
        kind = record.get("type")
        if kind == "user":
            counts_interrupt = not has_latest
            for block in content_blocks(message):
                if block.get("type") == "tool_result" and isinstance(block.get("tool_use_id"), str):
                    ended.add(block["tool_use_id"])
                elif block.get("type") == "text" and counts_interrupt:
                    is_interrupted |= str(text(block.get("text")) or "").startswith(INTERRUPT_PREFIX)
            if counts_interrupt:
                is_interrupted |= str(text(message.get("content")) or "").startswith(INTERRUPT_PREFIX)
        elif kind == "assistant":
            calls = [block for block in content_blocks(message) if block.get("type") == "tool_use"]
            if not calls:
                continue
            message_id = string(message, "id")
            if not has_latest:
                if is_interrupted:
                    return True
                latest, has_latest = message_id, True
            elif latest != message_id:
                return True
            if any(not isinstance(call.get("id"), str) or call["id"] not in ended for call in calls):
                return False
    return has_latest


def count(source, key):
    value = source.get(key) if isinstance(source, dict) else None
    return value if isinstance(value, int) and not isinstance(value, bool) and value >= 0 else 0


def transcript_seconds(value):
    """Mirrors the adapter: whole seconds of `YYYY-MM-DDTHH:MM:SS[.fff]Z`."""
    import datetime
    import re

    if not isinstance(value, str) or not re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z", value):
        return None
    try:
        moment = datetime.datetime.strptime(value[:19], "%Y-%m-%dT%H:%M:%S")
    except ValueError:
        return None
    return moment.replace(tzinfo=datetime.timezone.utc)


def is_main_user_line(line):
    try:
        record = json.loads(line)
    except json.JSONDecodeError:
        return False
    return isinstance(record, dict) and record.get("type") == "user" and record.get("isSidechain") is not True


def transcript_cache(path):
    """Mirrors `limpid-provider-claude`'s cache estimate for the golden."""
    if not os.path.exists(path):
        return None
    with open(path, encoding="utf-8") as handle:
        lines = handle.read().split("\n")
    observations = []
    for line in reversed(lines):
        # A main-thread user line (a prompt or a tool result) newer than any
        # usage means the final response is missing, and the estimate
        # reports nothing. Checked before the usage filter, since a
        # subagent's result carries the subagent's usage.
        if not observations and '"user"' in line and is_main_user_line(line):
            return None
        if '"usage"' not in line:
            continue
        try:
            record = json.loads(line)
        except json.JSONDecodeError:
            continue
        if not isinstance(record, dict) or record.get("type") != "assistant":
            continue
        if record.get("isSidechain") is True:
            continue
        message = record.get("message")
        if not isinstance(message, dict) or not isinstance(message.get("usage"), dict):
            continue
        usage = message["usage"]
        request = string(record, "requestId") or string(message, "id")
        started = transcript_seconds(record.get("timestamp"))
        if request is None or started is None:
            continue
        creation = usage.get("cache_creation")
        ttl = 3600 if count(creation, "ephemeral_1h_input_tokens") > 0 else (
            300 if count(creation, "ephemeral_5m_input_tokens") > 0 else None
        )
        observations.append({
            "request": request,
            "started": started,
            "input": count(usage, "input_tokens"),
            "read": count(usage, "cache_read_input_tokens"),
            "creation": count(usage, "cache_creation_input_tokens"),
            "output": count(usage, "output_tokens"),
            "ttl": ttl,
        })
    if not observations:
        return None
    last = dict(observations[0])
    earlier_ttl = None
    for observation in observations[1:]:
        if observation["request"] == last["request"]:
            last["started"] = min(last["started"], observation["started"])
            for key in ("input", "read", "creation", "output"):
                last[key] = max(last[key], observation[key])
            last["ttl"] = last["ttl"] or observation["ttl"]
            continue
        if last["ttl"] is not None or last["read"] == 0:
            break
        if observation["ttl"] is not None:
            earlier_ttl = observation["ttl"]
            break
    if last["read"] == 0 and last["creation"] == 0:
        return None
    ttl = last["ttl"] or (earlier_ttl if last["read"] > 0 else None)
    if ttl is None:
        return None
    return {
        "observedAt": last["started"].strftime("%Y-%m-%dT%H:%M:%SZ"),
        "ttlSeconds": ttl,
        "rewriteTokens": last["input"] + last["read"] + last["creation"] + last["output"],
        "precision": "estimated",
    }


def optional(event, key, value):
    if value is not None:
        event[key] = value


def session_source(obj):
    """The `source` word both providers spell the same way; None for one the adapters do not know."""
    source = string(obj, "source")
    return source if source in ("startup", "clear", "resume", "compact") else None


def claude_event(obj, transcript_path):
    name = string(obj, "hook_event_name") or "unknown"
    cwd = string(obj, "cwd")
    if name == "SessionStart":
        event = {"type": "session_started", "compact": string(obj, "source") == "compact"}
        optional(event, "source", session_source(obj))
        optional(event, "session_id", string(obj, "session_id"))
        optional(event, "session_title", string(obj, "session_title"))
        optional(event, "cwd", cwd)
        return event
    if name == "SessionEnd":
        event = {"type": "session_ended"}
        optional(event, "reason", string(obj, "reason"))
        optional(event, "session_id", string(obj, "session_id"))
        return event
    if name == "UserPromptSubmit":
        event = {"type": "prompt_submitted", "prompt": string(obj, "prompt") or ""}
        optional(event, "titles", transcript_titles(transcript_path))
        optional(event, "cwd", cwd)
        return event
    if name == "PreToolUse":
        tool = string(obj, "tool_name") or ""
        tool_input = obj.get("tool_input") if isinstance(obj.get("tool_input"), dict) else {}
        if tool == "AskUserQuestion":
            questions = tool_input.get("questions")
            question = None
            if isinstance(questions, list) and questions and isinstance(questions[0], dict):
                question = string(questions[0], "question")
            if question is None:
                question = string(tool_input, "question")
            return {"type": "waiting_for_input", "detail": question or "AskUserQuestion"}
        argument = tool_argument(tool_input, text)
        detail = f"{tool}: {argument}" if argument else tool
        return {"type": "tool_started", "tool": tool, "detail": detail}
    if name == "Notification":
        if string(obj, "notification_type") == "permission_prompt":
            event = {"type": "approval_requested"}
            optional(event, "detail", string(obj, "message"))
            return event
        if string(obj, "notification_type") == "idle_prompt":
            event = {"type": "awaiting_prompt"}
            if transcript_awaited_call_ended(transcript_path):
                event["awaited_call_ended"] = True
            return event
        return {"type": "extension", "name": name, "payload": obj}
    if name == "PreCompact":
        event = {"type": "compacting"}
        tokens = obj.get("current_token_count")
        if isinstance(tokens, int) and not isinstance(tokens, bool) and tokens >= 0:
            event["context_tokens"] = tokens
        return event
    if name == "Stop":
        event = {"type": "turn_finished"}
        optional(event, "titles", transcript_titles(transcript_path))
        optional(event, "cache", transcript_cache(transcript_path))
        if obj.get("stop_hook_active") is True:
            event["continues_after_stop_hook"] = True
        return event
    if name == "StopFailure":
        return {"type": "failed", "error": string(obj, "error") or string(obj, "error_type") or "error"}
    if name == "CwdChanged":
        new_cwd = string(obj, "new_cwd") or string(obj, "newCwd") or cwd or ""
        event = {"type": "cwd_changed", "new_cwd": new_cwd}
        optional(event, "old_cwd", string(obj, "old_cwd") or string(obj, "oldCwd") or string(obj, "previous_cwd"))
        return event
    return {"type": "extension", "name": name, "payload": obj}


# The fixture context's provider home (`HookContext::fixture_for`): Codex's
# memory agent works under it, and its hooks are not the pane's events.
CODEX_FIXTURE_HOME = "/Users/example/.codex"
CODEX_MEMORY_DIRECTORIES = ("memories", "memories_v2")
CODEX_SUBAGENT_ACTIVITY = ("PreToolUse", "PostToolUse", "PermissionRequest")


def codex_is_internal_agent(cwd):
    if cwd is None:
        return False
    parts = cwd.rstrip("/").split("/")
    home = CODEX_FIXTURE_HOME.split("/")
    return (
        len(parts) > len(home)
        and parts[: len(home)] == home
        and parts[len(home)] in CODEX_MEMORY_DIRECTORIES
    )


def codex_argument(value):
    """A tool's argument: a string, or an argv array joined with spaces."""
    if isinstance(value, str):
        return value or None
    if isinstance(value, list):
        words = [word for word in value if isinstance(word, str)]
        return " ".join(words) if words else None
    return None


def codex_event(obj, _transcript_path):
    name = string(obj, "hook_event_name") or "unknown"
    cwd = string(obj, "cwd")
    if codex_is_internal_agent(cwd):
        return None
    # A subagent's own prompt, session, and stop are not the pane's turn;
    # only its tools and permission requests are (`is_subagents_own`).
    if string(obj, "agent_id") and name not in CODEX_SUBAGENT_ACTIVITY:
        return None
    if name == "SessionStart":
        event = {"type": "session_started", "compact": False}
        optional(event, "source", session_source(obj))
        optional(event, "session_id", string(obj, "session_id"))
        optional(event, "cwd", cwd)
        return event
    if name == "SessionEnd":
        event = {"type": "session_ended"}
        optional(event, "reason", string(obj, "reason"))
        optional(event, "session_id", string(obj, "session_id"))
        return event
    if name == "UserPromptSubmit":
        event = {"type": "prompt_submitted", "prompt": string(obj, "prompt") or ""}
        optional(event, "cwd", cwd)
        return event
    if name == "PreToolUse":
        tool = string(obj, "tool_name") or ""
        tool_input = obj.get("tool_input") if isinstance(obj.get("tool_input"), dict) else {}
        argument = tool_argument(tool_input, codex_argument)
        detail = f"{tool}: {argument}" if argument else tool
        return {"type": "tool_started", "tool": tool, "detail": detail}
    if name == "PostToolUse":
        event = {"type": "tool_finished"}
        optional(event, "tool", string(obj, "tool_name"))
        return event
    if name == "PermissionRequest":
        event = {"type": "approval_requested"}
        optional(event, "detail", string(obj, "message"))
        return event
    if name == "PreCompact":
        event = {"type": "compacting"}
        tokens = obj.get("current_token_count")
        if isinstance(tokens, int) and not isinstance(tokens, bool) and tokens >= 0:
            event["context_tokens"] = tokens
        return event
    if name == "PostCompact":
        return {"type": "compaction_finished"}
    if name == "Interrupt":
        return {"type": "interrupted"}
    if name == "Stop":
        error = string(obj, "error_type")
        if error:
            return {"type": "failed", "error": error}
        event = {"type": "turn_finished"}
        if obj.get("stop_hook_active") is True:
            event["continues_after_stop_hook"] = True
        return event
    return {"type": "extension", "name": name, "payload": obj}


RULES = {"claude": claude_event, "codex": codex_event}


def main(argv):
    root = argv[1] if len(argv) > 1 else os.path.join(os.path.dirname(__file__), "..", "rust", "fixtures")
    for provider, rule in RULES.items():
        provider_root = os.path.join(root, provider)
        if not os.path.isdir(provider_root):
            continue
        for date in sorted(os.listdir(provider_root)):
            date_dir = os.path.join(provider_root, date)
            if not os.path.isdir(date_dir):
                continue
            for case in sorted(os.listdir(date_dir)):
                case_dir = os.path.join(date_dir, case)
                if not os.path.isdir(case_dir):
                    continue
                payloads = sorted(
                    name for name in os.listdir(case_dir)
                    if name.endswith(".json") and not name.endswith("expected.json")
                )
                expected = []
                for name in payloads:
                    with open(os.path.join(case_dir, name), encoding="utf-8") as handle:
                        obj = json.load(handle)
                    transcript = os.path.join(case_dir, name[: -len(".json")] + ".transcript.jsonl")
                    # `None` is a payload that yields no event at all.
                    event = rule(obj, transcript)
                    expected.append([] if event is None else [event])
                with open(os.path.join(case_dir, "expected.json"), "w", encoding="utf-8") as handle:
                    json.dump(expected, handle, indent=2, ensure_ascii=False, sort_keys=True)
                    handle.write("\n")
                print(f"{provider}/{date}/{case}: {len(expected)} payloads")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
