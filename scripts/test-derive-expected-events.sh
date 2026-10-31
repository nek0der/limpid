#!/usr/bin/env bash
# Weir — self-test for `derive-expected-events.py`.
#
# The script derives the fixture goldens by mirroring the Rust adapters, and
# the recorded cases only cover the inputs that happened to be recorded. This
# feeds it the payloads where its rules once differed from the adapters' and
# asserts the event the adapter gives (pinned on the Rust side by each
# provider crate's `tests/conformance.rs`), so a re-recorded case does not
# derive a golden the adapter disagrees with.
#
# Run from the repo root:
#   scripts/test-derive-expected-events.sh
#
# Exits 0 on success, 1 on any failing case.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"

python3 -I - "${REPO_ROOT}/scripts/derive-expected-events.py" <<'PYTHON'
import importlib.util
import sys

spec = importlib.util.spec_from_file_location("derive", sys.argv[1])
derive = importlib.util.module_from_spec(spec)
spec.loader.exec_module(derive)

failures = 0


def expect(name, actual, wanted):
    global failures
    if actual == wanted:
        print(f"✓ {name}")
    else:
        print(f"✗ {name}: got {actual!r}, wanted {wanted!r}")
        failures += 1


def tool_start(event, tool, tool_input):
    payload = {"hook_event_name": "PreToolUse", "tool_name": tool, "tool_input": tool_input}
    return event(payload, None)


for provider, event, tool in [
    ("claude", derive.claude_event, "Edit"),
    ("codex", derive.codex_event, "apply_patch"),
]:
    # A `command` that is there but empty gives the bare tool, not the
    # `file_path`: the adapters read `file_path` only without a `command`.
    expect(
        f"{provider}: an empty command names the tool",
        tool_start(event, tool, {"command": "", "file_path": "/a.txt"}),
        {"type": "tool_started", "tool": tool, "detail": tool},
    )
    expect(
        f"{provider}: a command of another type names the tool",
        tool_start(event, tool, {"command": 7, "file_path": "/a.txt"}),
        {"type": "tool_started", "tool": tool, "detail": tool},
    )
    expect(
        f"{provider}: no command reads the file path",
        tool_start(event, tool, {"file_path": "/a.txt"}),
        {"type": "tool_started", "tool": tool, "detail": f"{tool}: /a.txt"},
    )

expect(
    "codex: an argv command is joined",
    tool_start(derive.codex_event, "shell", {"command": ["git", "status"], "file_path": "/a.txt"}),
    {"type": "tool_started", "tool": "shell", "detail": "shell: git status"},
)

subagent = {"agent_id": "019a0000-0000-7000-8000-000000000001", "agent_type": "explorer"}
expect(
    "codex: a subagent's prompt is no turn",
    derive.codex_event({"hook_event_name": "UserPromptSubmit", "prompt": "look", **subagent}, None),
    None,
)
expect(
    "codex: a subagent's tool is the pane's work",
    derive.codex_event(
        {"hook_event_name": "PreToolUse", "tool_name": "Bash", "tool_input": {"command": "ls"}, **subagent},
        None,
    ),
    {"type": "tool_started", "tool": "Bash", "detail": "Bash: ls"},
)

for name in ["PostToolUse", "PostToolUseFailure"]:
    expect(
        f"claude: a subagent's {name} of its question is marked",
        derive.claude_event({"hook_event_name": name, "tool_name": "AskUserQuestion", **subagent}, None),
        {"type": "tool_finished", "tool": "AskUserQuestion", "by_subagent": True},
    )
    expect(
        f"claude: the agent's own {name} of its question is not",
        derive.claude_event({"hook_event_name": name, "tool_name": "AskUserQuestion"}, None),
        {"type": "tool_finished", "tool": "AskUserQuestion"},
    )

sys.exit(1 if failures else 0)
PYTHON
