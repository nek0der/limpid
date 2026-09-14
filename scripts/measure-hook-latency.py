#!/usr/bin/env python3
"""Measures one hook call's wall-clock latency for each backend.

Usage: scripts/measure-hook-latency.py [--iterations N] [--provider claude|codex] [--payload FILE]

Feeds the same recorded PreToolUse payload to the legacy shell receiver, to
the Hook Helper's `hook` subcommand directly, and to the production wrapper
that chooses the Rust backend, N times each against a scratch state
directory, and prints p50 / p95 / max in milliseconds. Turn snapshots are
disabled because both backends run the same git commands for them.

The newest executable helper from a Debug build is used unless
LIMPID_HOOK_HELPER is set.
"""

import argparse
import glob
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
    args = parser.parse_args()

    repo = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    payload_path = args.payload or os.path.join(
        repo, "rust", "fixtures", args.provider, "2026-09", "session-basic", "0002-PreToolUse.json"
    )
    with open(payload_path, "rb") as handle:
        payload = handle.read()

    configured_helper = os.environ.get("LIMPID_HOOK_HELPER")
    if configured_helper:
        helper_candidates = [os.path.abspath(os.path.expanduser(configured_helper))]
    else:
        helper_candidates = glob.glob(
            os.path.expanduser(
                "~/Library/Developer/Xcode/DerivedData/Limpid-*/Build/Products/Debug/"
                "Limpid Dev.app/Contents/MacOS/AgentIntegrationHookHelper"
            )
        )
    helper_candidates = [
        path for path in helper_candidates if os.path.isfile(path) and os.access(path, os.X_OK)
    ]
    if not helper_candidates:
        source = "LIMPID_HOOK_HELPER" if configured_helper else "the Debug build"
        print(f"error: no executable Hook Helper found from {source}; run make build first", file=sys.stderr)
        return 1
    helper = max(helper_candidates, key=lambda path: (os.path.getmtime(path), path))
    shim_dir = os.path.join(repo, "Limpid", "Resources", f"{args.provider}-shim")
    legacy = os.path.join(shim_dir, "limpid-hook.legacy")
    wrapper = os.path.join(shim_dir, "limpid-hook")

    scratch = tempfile.mkdtemp(prefix="limpid-hook-latency.")
    prefix = "LIMPID" if args.provider == "claude" else "LIMPID_CODEX"
    base_env = {
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        "HOME": scratch,
        "LIMPID_PANE_ID": str(uuid.uuid4()).upper(),
        "LIMPID_AGENT_RUN_ID": str(uuid.uuid4()).upper(),
        f"{prefix}_AGENT_STATES_DIR": os.path.join(scratch, "states"),
        f"{prefix}_SESSIONS_DIR": os.path.join(scratch, "sessions"),
        "LIMPID_CWD_EVENTS_DIR": os.path.join(scratch, "cwd"),
        "LIMPID_TURN_SNAPSHOT": "0",
        "LIMPID_HOOK_HELPER": helper,
    }
    backends = {
        "shell (legacy receiver)": (["/bin/sh", legacy], {}),
        "rust (helper direct)": ([helper, "hook", args.provider], {}),
        "rust (wrapper)": (["/bin/sh", wrapper], {"LIMPID_AGENT_HOOK_BACKEND": "rust"}),
    }
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


if __name__ == "__main__":
    sys.exit(main())
