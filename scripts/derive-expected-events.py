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
