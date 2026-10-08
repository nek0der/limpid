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


def claude_event(obj, transcript_path):
    name = string(obj, "hook_event_name") or "unknown"
    cwd = string(obj, "cwd")
    if name == "SessionStart":
        event = {"type": "session_started", "compact": string(obj, "source") == "compact"}
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
        argument = string(tool_input, "command") or string(tool_input, "file_path")
        detail = f"{tool}: {argument}" if argument else tool
        return {"type": "tool_started", "tool": tool, "detail": detail}
    if name == "Notification":
        if string(obj, "notification_type") == "permission_prompt":
            event = {"type": "approval_requested"}
            optional(event, "detail", string(obj, "message"))
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
        return event
    if name == "StopFailure":
        return {"type": "failed", "error": string(obj, "error") or string(obj, "error_type") or "error"}
    if name == "CwdChanged":
        new_cwd = string(obj, "new_cwd") or string(obj, "newCwd") or cwd or ""
        event = {"type": "cwd_changed", "new_cwd": new_cwd}
        optional(event, "old_cwd", string(obj, "old_cwd") or string(obj, "oldCwd") or string(obj, "previous_cwd"))
        return event
    return {"type": "extension", "name": name, "payload": obj}


def codex_event(obj, _transcript_path):
    name = string(obj, "hook_event_name") or "unknown"
    cwd = string(obj, "cwd")
    if name == "SessionStart":
        event = {"type": "session_started", "compact": False}
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
        return {"type": "tool_started", "tool": tool, "detail": tool}
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
        return {"type": "turn_finished"}
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
                    expected.append([rule(obj, transcript)])
                with open(os.path.join(case_dir, "expected.json"), "w", encoding="utf-8") as handle:
                    json.dump(expected, handle, indent=2, ensure_ascii=False, sort_keys=True)
                    handle.write("\n")
                print(f"{provider}/{date}/{case}: {len(expected)} payloads")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
