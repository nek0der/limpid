#!/usr/bin/env python3
"""Record a bulk %output stream: real tmux escaping of a large colored payload.

Usage: ./record_bulk.py [output-directory]

Without an argument the recording goes to a new temporary directory, whose
path is printed. The payload `cat` reads is written to a separate temporary
directory and removed afterwards, so it can never end up in the fixtures.

control.raw keeps the stream up to the last whole line within TRIM_BYTES,
which keeps the repository small. The manifest records the counts an
independent decoder (below) gives for the kept lines; the tests compare the
Swift decoder against those rather than against numbers pinned in code,
because how tmux splits the stream into %output lines differs from run to run.
"""
import json
import os
import re
import select
import shutil
import subprocess
import sys
import tempfile
import time

SOCK = "limpid-fixture-bulk"
TRIM_BYTES = 1_200_000
OUT = sys.argv[1] if len(sys.argv) > 1 else tempfile.mkdtemp(prefix="limpid-tmux-bulk-output-")
os.makedirs(OUT, exist_ok=True)


def tmux(*a):
    return subprocess.run(["tmux", "-L", SOCK, "-f", "/dev/null", *a], capture_output=True, text=True).stdout.strip()


def kill(socket_path=None):
    """Stop the private server. tmux leaves its socket file behind, so the
    path read while the server ran is removed as well."""
    subprocess.run(["tmux", "-L", SOCK, "-f", "/dev/null", "kill-server"], capture_output=True)
    if socket_path:
        try:
            os.remove(socket_path)
        except FileNotFoundError:
            pass


def trim(raw, limit):
    """The longest prefix of whole lines that fits in `limit` bytes."""
    if len(raw) <= limit:
        return raw
    end = raw.rfind(b"\n", 0, limit)
    return raw[: end + 1] if end >= 0 else b""


OCTAL_ESCAPE = re.compile(rb"\\[0-7]{3}")


def decoded_counts(raw):
    """(%output lines, unescaped payload bytes). tmux writes a byte below
    0x20 and the backslash as \\ooo; everything else is literal."""
    lines = 0
    size = 0
    for line in raw.split(b"\n"):
        if not line.startswith(b"%output "):
            continue
        parts = line.split(b" ", 2)
        payload = parts[2] if len(parts) == 3 else b""
        lines += 1
        size += len(OCTAL_ESCAPE.sub(b"x", payload))
    return lines, size


kill()
socket_path = None
scratch = tempfile.mkdtemp(prefix="limpid-tmux-bulk-payload-")
try:
    payload = os.path.join(scratch, "payload.txt")
    with open(payload, "w") as f:
        for i in range(40000):
            f.write(
                f"\x1b[3{i % 7 + 1}m{i:06d}\x1b[0m \x1b[1mlorem ipsum dolor sit amet\x1b[22m"
                f" \\ backslash \x1b[4munderline\x1b[24m\n"
            )
    payload_bytes = os.path.getsize(payload)
    version = tmux("-V")
    tmux("new-session", "-d", "-s", "fx", "-x", "200", "-y", "50", "sh", "-c", "PS1='$ ' exec sh")
    tmux("set-option", "-g", "status", "off")
    time.sleep(0.3)
    socket_path = tmux("display-message", "-p", "#{socket_path}")
    pane = tmux("display-message", "-p", "-t", "fx", "#{pane_id}")
    p = subprocess.Popen(
        ["tmux", "-L", SOCK, "-f", "/dev/null", "-C", "attach", "-t", "fx"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        bufsize=0,
    )
    # Drain and drop the attach block; only the bulk is kept.
    end = time.time() + 0.6
    while time.time() < end:
        r, _, _ = select.select([p.stdout], [], [], 0.05)
        if r:
            os.read(p.stdout.fileno(), 65536)
    p.stdin.write(f"send-keys -t {pane} 'cat {payload}' Enter\n".encode())
    p.stdin.flush()
    raw = b""
    last = time.time()
    while time.time() - last < 1.5:
        r, _, _ = select.select([p.stdout], [], [], 0.1)
        if r:
            chunk = os.read(p.stdout.fileno(), 1 << 20)
            if not chunk:
                break
            raw += chunk
            last = time.time()
    p.stdin.close()
    p.terminate()
    p.wait(timeout=2)
finally:
    kill(socket_path)
    shutil.rmtree(scratch, ignore_errors=True)

kept = trim(raw, TRIM_BYTES)
output_lines, decoded_bytes = decoded_counts(kept)
with open(os.path.join(OUT, "control.raw"), "wb") as f:
    f.write(kept)
with open(os.path.join(OUT, "manifest.json"), "w") as f:
    json.dump(
        {
            "tmux_version": version,
            "recorded": time.strftime("%Y-%m-%d"),
            "payload_bytes": payload_bytes,
            "full_raw_bytes": len(raw),
            "raw_bytes": len(kept),
            "output_lines": output_lines,
            "decoded_bytes": decoded_bytes,
            "note": f"cat of a generated payload inside a 200x50 pane; control.raw is what the control client "
            f"received, cut at the last line boundary within {TRIM_BYTES} bytes by record_bulk.py",
        },
        f,
        indent=2,
    )
print("wrote", OUT)
print("payload:", payload_bytes, "raw:", len(raw), "kept:", len(kept), "output lines:", output_lines, "decoded:", decoded_bytes)
