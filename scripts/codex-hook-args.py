#!/usr/bin/env python3
"""Prints the LIMPID_CODEX_HOOK_ARGS value the app would hand a pane.

Usage: scripts/codex-hook-args.py <codex-shim-directory>

Mirrors `CodexHookInjection.arguments` and `CodexTrustHash.compute` so that
fixture recording outside the app runs the same hook definitions the app
installs. Codex only runs a hook whose trust hash is recorded in
~/.codex/config.toml, and only the app writes that block, so this exits with
status 1 when a required hash is missing; launching the Debug app once
refreshes the block. The config file is only read.
"""

import hashlib
import json
import os
import sys

# Label, Codex event key, timeout. Must match `CodexHookInstaller.subscribedEvents`.
SUBSCRIBED_EVENTS = [
    ("session_start", "SessionStart", 600),
    ("session_end", "SessionEnd", 1),
    ("user_prompt_submit", "UserPromptSubmit", 600),
    ("pre_tool_use", "PreToolUse", 600),
    ("post_tool_use", "PostToolUse", 600),
    ("pre_compact", "PreCompact", 600),
    ("post_compact", "PostCompact", 600),
    ("permission_request", "PermissionRequest", 600),
    ("interrupt", "Interrupt", 1),
    ("stop", "Stop", 600),
]
WORKTREE_MATCHER = "^Bash$"
SESSION_FLAGS_PATH = "/<session-flags>/config.toml"


def toml_string(value):
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def shell_quoted(path):
    return "'" + os.path.realpath(path).replace("'", "'\\''") + "'"


def trust_hash(label, command, timeout, matcher):
    identity = {
        "event_name": label,
        "hooks": [{"async": False, "command": command, "timeout": max(1, timeout), "type": "command"}],
    }
    if matcher is not None:
        identity["matcher"] = matcher
    serialized = json.dumps(identity, separators=(",", ":"), sort_keys=True, ensure_ascii=False)
    return "sha256:" + hashlib.sha256(serialized.encode("utf-8")).hexdigest()


def group(command, matcher, timeout):
    handler = '{type="command",command=%s,timeout=%d}' % (toml_string(command), timeout)
    if matcher is None:
        return "{hooks=[%s]}" % handler
    return "{matcher=%s,hooks=[%s]}" % (toml_string(matcher), handler)


def main(argv):
    if len(argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    shim_dir = argv[1]
    lifecycle = "/bin/sh " + shell_quoted(os.path.join(shim_dir, "limpid-hook"))
    worktree_script = os.path.join(shim_dir, "limpid-pretool-worktree-hook")
    worktree = "/bin/sh " + shell_quoted(worktree_script) if os.path.exists(worktree_script) else None
    helper = os.path.join(shim_dir, "..", "..", "MacOS", "AgentIntegrationHookHelper")
    approval = shell_quoted(helper) + " permission-request codex" if os.access(helper, os.X_OK) else None

    config_path = os.path.join(os.path.expanduser("~"), ".codex", "config.toml")
    try:
        with open(config_path, encoding="utf-8") as handle:
            config = handle.read()
    except OSError:
        config = ""

    arguments = []
    missing = []
    for label, key, timeout in SUBSCRIBED_EVENTS:
        command = (approval or lifecycle) if key == "PermissionRequest" else lifecycle
        groups = [(command, None)]
        if key == "PreToolUse" and worktree:
            groups.append((worktree, WORKTREE_MATCHER))
        rendered = []
        for index, (group_command, matcher) in enumerate(groups):
            rendered.append(group(group_command, matcher, timeout))
            trust_key = "%s:%s:%d:0" % (SESSION_FLAGS_PATH, label, index)
            expected = trust_hash(label, group_command, timeout, matcher)
            entry = '[hooks.state.%s]\nenabled = true\ntrusted_hash = %s' % (toml_string(trust_key), toml_string(expected))
            if entry not in config:
                missing.append(trust_key)
        arguments += ["-c", "hooks.%s=[%s]" % (key, ",".join(rendered))]
    arguments += ["-c", "tui.terminal_title=[]"]

    if missing:
        print("error: ~/.codex/config.toml does not trust these hooks for this build:", file=sys.stderr)
        for key in missing:
            print("  " + key, file=sys.stderr)
        return 1
    print("\n".join(arguments))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
