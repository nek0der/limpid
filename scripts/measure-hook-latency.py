#!/usr/bin/env python3
"""Measures one hook call's wall-clock latency, direct and through the wrapper.

Usage: scripts/measure-hook-latency.py [--iterations N] [--provider claude|codex] [--payload FILE]
                                      [--turn-repo DIR]

Feeds the same recorded PreToolUse payload to the Hook Helper's `hook`
subcommand directly and to the production wrapper that execs it, N times
each against a scratch state directory, and prints p50 / p95 / max in
milliseconds. Turn snapshots are disabled because both run the same git
commands for them.

With --turn-repo, it instead times the two calls that record a turn, the
prompt submit and the stop, through the production wrapper with snapshots
on, against the repository at DIR. Each pair writes a turn and pins two
refs there; the script removes the refs and the scratch index files it made
before it exits.

The newest executable helper from a Debug build is used unless
WEIR_HOOK_HELPER is set.
"""

import argparse
import glob
import json
import os
import shutil
import statistics
import subprocess
import sys
import tempfile
import time
import uuid


def percentile(samples, fraction):
    ordered = sorted(samples)
    index = min(len(ordered) - 1, max(0, round(fraction * (len(ordered) - 1))))
    return ordered[index]


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--iterations", type=int, default=200)
    parser.add_argument("--provider", choices=["claude", "codex"], default="claude")
    parser.add_argument("--payload")
    parser.add_argument("--turn-repo")
    args = parser.parse_args()

    repo = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    payload_path = args.payload or os.path.join(
        repo, "rust", "fixtures", args.provider, "2026-09", "session-basic", "0002-PreToolUse.json"
    )
    with open(payload_path, "rb") as handle:
        payload = handle.read()

    configured_helper = os.environ.get("WEIR_HOOK_HELPER")
    if configured_helper:
        helper_candidates = [os.path.abspath(os.path.expanduser(configured_helper))]
    else:
        helper_candidates = glob.glob(
            os.path.expanduser(
                "~/Library/Developer/Xcode/DerivedData/Weir-*/Build/Products/Debug/"
                "Weir Dev.app/Contents/MacOS/AgentIntegrationHookHelper"
            )
        )
    helper_candidates = [
        path for path in helper_candidates if os.path.isfile(path) and os.access(path, os.X_OK)
    ]
    if not helper_candidates:
        source = "WEIR_HOOK_HELPER" if configured_helper else "the Debug build"
        print(f"error: no executable Hook Helper found from {source}; run make build first", file=sys.stderr)
        return 1
    helper = max(helper_candidates, key=lambda path: (os.path.getmtime(path), path))
    shim_dir = os.path.join(repo, "Weir", "Resources", f"{args.provider}-shim")
    wrapper = os.path.join(shim_dir, "weir-hook")

    scratch = tempfile.mkdtemp(prefix="weir-hook-latency.")
    prefix = "WEIR" if args.provider == "claude" else "WEIR_CODEX"
    base_env = {
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        "HOME": scratch,
        "WEIR_PANE_ID": str(uuid.uuid4()).upper(),
        "WEIR_AGENT_RUN_ID": str(uuid.uuid4()).upper(),
        f"{prefix}_AGENT_STATES_DIR": os.path.join(scratch, "states"),
        f"{prefix}_SESSIONS_DIR": os.path.join(scratch, "sessions"),
        "WEIR_CWD_EVENTS_DIR": os.path.join(scratch, "cwd"),
        "WEIR_TURN_SNAPSHOT": "0",
        "WEIR_HOOK_HELPER": helper,
    }
    backends = {
        "rust (helper direct)": ([helper, "hook", args.provider], {}),
        "rust (wrapper)": (["/bin/sh", wrapper], {}),
    }
    if args.turn_repo:
        if args.provider != "claude":
            # The prompt and stop payloads below are Claude's.
            print("error: --turn-repo measures the claude hooks only", file=sys.stderr)
            return 1
        try:
            return measure_turns(args, base_env, wrapper, scratch)
        finally:
            shutil.rmtree(scratch, ignore_errors=True)
    try:
        results = {}
        for name, (command, extra) in backends.items():
            env = dict(base_env, **extra)
            samples = []
            for _ in range(args.iterations):
                started = time.perf_counter()
                subprocess.run(command, input=payload, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
                samples.append((time.perf_counter() - started) * 1000)
            results[name] = samples
        print(f"iterations: {args.iterations}, payload: {os.path.relpath(payload_path, repo)}")
        print(f"{'backend':<26}{'p50 ms':>10}{'p95 ms':>10}{'max ms':>10}{'mean ms':>10}")
        for name, samples in results.items():
            print(
                f"{name:<26}{percentile(samples, 0.50):>10.1f}{percentile(samples, 0.95):>10.1f}"
                f"{max(samples):>10.1f}{statistics.fmean(samples):>10.1f}"
            )
    finally:
        shutil.rmtree(scratch, ignore_errors=True)
    return 0


def git(repo, *arguments):
    return subprocess.run(
        ["git", "-C", repo, *arguments], capture_output=True, text=True, check=False
    ).stdout.strip()


def measure_turns(args, base_env, wrapper, scratch):
    """Times prompt submit and stop with snapshots on, then removes the refs."""
    repo = os.path.abspath(os.path.expanduser(args.turn_repo))
    env = dict(base_env)
    del env["WEIR_TURN_SNAPSHOT"]
    prompt = (
        '{"hook_event_name":"UserPromptSubmit","session_id":"latency","prompt":"measure","cwd":%s}'
        % json.dumps(repo)
    ).encode()
    stop = b'{"hook_event_name":"Stop","session_id":"latency"}'
    session = b'{"hook_event_name":"SessionStart","session_id":"latency","source":"startup"}'
    subprocess.run(["/bin/sh", wrapper], input=session, env=env, cwd=repo, check=False)
    begins, ends = [], []
    try:
        for _ in range(args.iterations):
            for payload, samples in ((prompt, begins), (stop, ends)):
                started = time.perf_counter()
                subprocess.run(
                    ["/bin/sh", wrapper], input=payload, env=env, cwd=repo,
                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False,
                )
                samples.append((time.perf_counter() - started) * 1000)
    finally:
        turns = os.path.join(env["WEIR_AGENT_STATES_DIR"], "turns")
        for name in os.listdir(turns) if os.path.isdir(turns) else []:
            if name.endswith(".turn.json"):
                turn_id = name[: -len(".turn.json")]
                for side in ("begin", "end"):
                    git(repo, "update-ref", "-d", f"refs/weir/turns/{turn_id}/{side}")
        key = env["WEIR_PANE_ID"].lower()
        git(repo, "update-ref", "-d", f"refs/weir/turn/{key}")
        git_dir = git(repo, "rev-parse", "--absolute-git-dir")
        for suffix in ("index", "end.index"):
            path = os.path.join(git_dir, "weir", f"turn-{key}.{suffix}")
            if os.path.exists(path):
                os.remove(path)
    files = len(git(repo, "ls-files").splitlines())
    print(f"iterations: {args.iterations}, repository: {repo} ({files} tracked files)")
    print(f"{'call':<26}{'p50 ms':>10}{'p95 ms':>10}{'max ms':>10}{'mean ms':>10}")
    for name, samples in (("prompt submit (begin)", begins), ("stop (end)", ends)):
        print(
            f"{name:<26}{percentile(samples, 0.50):>10.1f}{percentile(samples, 0.95):>10.1f}"
            f"{max(samples):>10.1f}{statistics.fmean(samples):>10.1f}"
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
