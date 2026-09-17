#!/usr/bin/env python3
"""Record real tmux control-mode traffic for Limpid's protocol fixtures.

Usage: ./record_tmux.py [output-directory]

Without an argument the recording goes to a new temporary directory, whose
path is printed; nothing under the fixtures directory changes until its files
are copied there.

Everything runs on a private socket with no config file, so the user's own tmux
server is untouched and their ~/.tmux.conf cannot shape the recording.
The case writes the raw bytes the control client received (control.raw) and
the commands it sent (commands.txt), plus a small manifest of the ids tmux
handed out so expectations can be written against real ids.

The commands are fixed, so the layouts, replies, and notifications come out
the same on every run with the same tmux. What tmux picks per run does not:
reply timestamps and numbers, and the pane's tty. The tests check those by
shape only.
"""
import json
import os
import select
import subprocess
import sys
import tempfile
import time

SOCK = "limpid-fixture"
OUT = sys.argv[1] if len(sys.argv) > 1 else tempfile.mkdtemp(prefix="limpid-tmux-session-basic-")
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


class Client:
    def __init__(self):
        self.p = subprocess.Popen(
            ["tmux", "-L", SOCK, "-f", "/dev/null", "-C", "attach", "-t", "fx"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            bufsize=0,
        )
        self.raw = b""
        self.sent = []

    def send(self, cmd):
        self.sent.append(cmd)
        self.p.stdin.write(cmd.encode() + b"\n")
        self.p.stdin.flush()

    def pump(self, secs):
        end = time.time() + secs
        while time.time() < end:
            r, _, _ = select.select([self.p.stdout], [], [], 0.05)
            if r:
                chunk = os.read(self.p.stdout.fileno(), 65536)
                if not chunk:
                    break
                self.raw += chunk

    def close(self):
        try:
            self.p.stdin.close()
        except Exception:
            pass
        self.p.terminate()
        self.p.wait(timeout=2)


kill()
socket_path = None
try:
    version = tmux("-V")
    tmux("new-session", "-d", "-s", "fx", "-x", "120", "-y", "40", "sh", "-c", "PS1='$ ' exec sh")
    tmux("set-option", "-g", "status", "off")
    time.sleep(0.3)
    socket_path = tmux("display-message", "-p", "#{socket_path}")
    pane1 = tmux("display-message", "-p", "-t", "fx", "#{pane_id}")
    win = tmux("display-message", "-p", "-t", "fx", "#{window_id}")

    c = Client()
    c.pump(0.6)  # attach block
    c.send(f"display-message -p -t {pane1} '#{{version}}|#{{pane_tty}}|#{{cursor_x}} #{{cursor_y}} #{{alternate_on}}'")
    c.pump(0.4)
    c.send(f"refresh-client -C '{win}:100x30'")  # window resize -> %layout-change
    c.pump(0.5)
    c.send(f"split-window -h -t {pane1} sh -c \"PS1='$ ' exec sh\"")  # 2 panes side by side
    c.pump(0.6)
    c.send(f"split-window -v -t {win}.1 sh -c \"PS1='$ ' exec sh\"")  # main-vertical: right column split
    c.pump(0.6)
    # %output with control bytes and a backslash: octal escaping for <0x20 and 0x5c
    c.send(
        f"send-keys -t {pane1} -H 70 72 69 6e 74 66 20 27 5c 5c 5c 5c 5c 5c 30 33 33 5b 33 31 6d 68 69 "
        "5c 5c 5c 5c 5c 5c 30 33 33 5b 30 6d 5c 5c 5c 5c 5c 5c 6e 27 0a"
    )
    c.pump(0.6)
    c.send(f"display-message -p -t {win} '#{{window_layout}}'")
    c.pump(0.4)
    c.send("select-layout -t fx even-horizontal")  # flat 3-way sibling list -> n-ary layout
    c.pump(0.5)
    c.send(f"display-message -p -t {win} '#{{window_layout}}'")
    c.pump(0.4)
    c.send("bogus-command-for-error")  # %error block
    c.pump(0.4)
    c.send(f"kill-pane -t {win}.2")  # pane removed -> %layout-change
    c.pump(0.5)
    c.send("detach-client")  # %exit
    c.pump(0.6)
    c.close()
finally:
    kill(socket_path)

with open(os.path.join(OUT, "control.raw"), "wb") as f:
    f.write(c.raw)
with open(os.path.join(OUT, "commands.txt"), "w") as f:
    f.write("\n".join(c.sent) + "\n")
with open(os.path.join(OUT, "manifest.json"), "w") as f:
    json.dump(
        {
            "tmux_version": version,
            "recorded": time.strftime("%Y-%m-%d"),
            "window": win,
            "first_pane": pane1,
            "note": "private socket, 120x40 then refresh-client 100x30; shells are sh with PS1='$ '",
        },
        f,
        indent=2,
    )
print("wrote", OUT)
print("version:", version, "| bytes:", len(c.raw), "| lines:", c.raw.count(b"\n"))
