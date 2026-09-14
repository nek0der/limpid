#!/usr/bin/env python3
"""Scrubs one recorded hook payload in place before it becomes a fixture.

Usage: scripts/scrub-hook-fixture.py <payload.json> <case-name>

Recorded payloads carry the developer's home directory, temporary paths, the
provider's session identifiers, and the prompt text. Fixtures are reviewed and
committed like code, so those values are replaced with stable placeholders.
Key names and event names are never changed: they are what the adapter is
tested against. The output is re-serialized with sorted keys and indentation
so a re-recording of the same case produces a readable diff.

Transcript copies (`*.transcript.jsonl`) are line-delimited JSON. The adapter
only reads the title lines (`ai-title` and `custom-title`), so those are
scrubbed with the same rules and every other line is reduced to its `type`:
the fixture still exercises "skip unrelated lines" without carrying the
conversation. Lines that are not JSON are dropped.
"""

import json
import os
import re
import sys

HOME = os.path.expanduser("~")
USER_NAME = os.path.basename(HOME)
TEMP_PATTERNS = [
    # Claude names its per-project transcript directory after the encoded cwd.
    re.compile(r"-private-var-folders-[A-Za-z0-9_-]+?-repo(?=/)"),
    re.compile(r"-private-tmp-[A-Za-z0-9_-]+?-repo(?=/)"),
    re.compile(r"/private/var/folders/[^\s\"']+"),
    re.compile(r"/var/folders/[^\s\"']+"),
    re.compile(r"/private/tmp/[^\s\"']+"),
    re.compile(r"/tmp/[^\s\"']+"),
]
UUID_PATTERN = re.compile(r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")
PLACEHOLDER_SESSION = "00000000-0000-4000-8000-000000000001"
PLACEHOLDER_UUID = "00000000-0000-4000-8000-0000000000ff"
# Keys whose string value is conversation content. Provider-authored strings
# such as a Notification `message` stay, because the adapter reads them.
PROMPT_KEYS = {"prompt", "last_assistant_message", "content", "display", "text"}
# Keys whose value identifies the provider session and must stay consistent
# across the payloads of one case.
SESSION_KEYS = {"session_id", "sessionId", "thread_id", "conversation_id"}
# Per-turn identifiers the adapters carry through unchanged (Codex's
# `turn_id` becomes the neutral operation id). A recorded value dates the
# session (Codex mints UUIDv7), so each key gets its own fixed placeholder.
CORRELATION_KEYS = {
    "prompt_id": "00000000-0000-4000-8000-000000000002",
    "turn_id": "00000000-0000-4000-8000-000000000003",
    "tool_use_id": "toolu_00000000000000000000000",
}
# Transcript line types the Claude adapter reads for titles.
TITLE_LINE_TYPES = {"ai-title", "custom-title"}


def scrub_string(value, key, case_name):
    if key in PROMPT_KEYS:
        return f"<{key} for {case_name}>"
    if key in SESSION_KEYS:
        return PLACEHOLDER_SESSION
    if key in CORRELATION_KEYS:
        return CORRELATION_KEYS[key]
    value = value.replace(HOME, "/Users/example")
    for pattern in TEMP_PATTERNS:
        value = pattern.sub(lambda match: "-tmp-example" if match.group(0).startswith("-") else "/tmp/example", value)
    # Tool output such as `ls -l` names the account without a path.
    if USER_NAME and len(USER_NAME) >= 3:
        value = value.replace(USER_NAME, "example")
    if key in ("transcript_path", "cwd", "new_cwd", "old_cwd", "newCwd", "oldCwd"):
        value = UUID_PATTERN.sub(PLACEHOLDER_UUID, value)
    return value


def scrub(value, key=None, case_name=""):
    if isinstance(value, dict):
        return {k: scrub(v, k, case_name) for k, v in value.items()}
    if isinstance(value, list):
        return [scrub(v, key, case_name) for v in value]
    if isinstance(value, str):
        return scrub_string(value, key, case_name)
    return value


def scrub_json_file(path, case_name):
    with open(path, encoding="utf-8") as handle:
        data = json.load(handle)
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(scrub(data, None, case_name), handle, indent=2, ensure_ascii=False, sort_keys=True)
        handle.write("\n")


def scrub_jsonl_file(path, case_name):
    kept = []
    with open(path, encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            try:
                record = json.loads(line)
            except json.JSONDecodeError:
                continue
            if not isinstance(record, dict):
                continue
            if record.get("type") not in TITLE_LINE_TYPES:
                record = {"type": record.get("type", "unknown")}
            kept.append(json.dumps(scrub(record, None, case_name), ensure_ascii=False, sort_keys=True))
    with open(path, "w", encoding="utf-8") as handle:
        handle.write("\n".join(kept) + ("\n" if kept else ""))


def main(argv):
    if len(argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    path, case_name = argv[1], argv[2]
    if path.endswith(".jsonl"):
        scrub_jsonl_file(path, case_name)
    else:
        scrub_json_file(path, case_name)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
