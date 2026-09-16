#!/usr/bin/env python3
"""Record real tmux control-mode traffic for Limpid's protocol fixtures.

Everything runs on a private socket so the user's own tmux server is untouched.
Each case writes the raw bytes the control client received (control.raw) and
the commands it sent (commands.txt), plus a small manifest of the pane ids
tmux handed out so expectations can be written against real ids.
"""
import os, select, subprocess, sys, time, json, re
SOCK = "limpid-fixture"
OUT = sys.argv[1]
os.makedirs(OUT, exist_ok=True)

def tmux(*a): return subprocess.run(["tmux", "-L", SOCK, *a], capture_output=True, text=True).stdout.strip()
def kill(): subprocess.run(["tmux", "-L", SOCK, "kill-server"], capture_output=True)

class Client:
    def __init__(self):
        self.p = subprocess.Popen(["tmux", "-L", SOCK, "-C", "attach", "-t", "fx"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, bufsize=0)
        self.raw = b""; self.sent = []
    def send(self, cmd):
        self.sent.append(cmd); self.p.stdin.write(cmd.encode() + b"\n"); self.p.stdin.flush()
    def pump(self, secs):
        end = time.time() + secs
        while time.time() < end:
            r, _, _ = select.select([self.p.stdout], [], [], 0.05)
            if r:
                chunk = os.read(self.p.stdout.fileno(), 65536)
                if not chunk: break
                self.raw += chunk
    def close(self):
        try: self.p.stdin.close()
        except Exception: pass
        self.p.terminate(); self.p.wait(timeout=2)

kill()
version = tmux("-V")
tmux("new-session", "-d", "-s", "fx", "-x", "120", "-y", "40", "sh", "-c", "PS1='$ ' exec sh")
tmux("set-option", "-g", "status", "off")
time.sleep(0.3)
pane1 = tmux("display-message", "-p", "-t", "fx", "#{pane_id}")
win = tmux("display-message", "-p", "-t", "fx", "#{window_id}")

c = Client(); c.pump(0.6)                       # attach block
c.send(f"display-message -p -t {pane1} '#{{version}}|#{{pane_tty}}|#{{cursor_x}} #{{cursor_y}} #{{alternate_on}}'"); c.pump(0.4)
c.send(f"refresh-client -C '{win}:100x30'"); c.pump(0.5)          # window resize -> %layout-change
c.send(f"split-window -h -t {pane1} sh -c \"PS1='$ ' exec sh\""); c.pump(0.6)   # 2 panes side by side
pane2 = tmux("display-message", "-p", "-t", "fx:.1", "#{pane_id}") if False else None
c.send(f"split-window -v -t {win}.1 sh -c \"PS1='$ ' exec sh\""); c.pump(0.6)   # main-vertical: right column split
# %output with control bytes and a backslash: octal escaping for <0x20 and 0x5c
c.send(f"send-keys -t {pane1} -H 70 72 69 6e 74 66 20 27 5c 5c 5c 5c 5c 5c 30 33 33 5b 33 31 6d 68 69 5c 5c 5c 5c 5c 5c 30 33 33 5b 30 6d 5c 5c 5c 5c 5c 5c 6e 27 0a"); c.pump(0.6)
c.send(f"display-message -p -t {win} '#{{window_layout}}'"); c.pump(0.4)
c.send("select-layout -t fx even-horizontal"); c.pump(0.5)        # flat 3-way sibling list -> n-ary layout
c.send(f"display-message -p -t {win} '#{{window_layout}}'"); c.pump(0.4)
c.send("bogus-command-for-error"); c.pump(0.4)                     # %error block
c.send(f"kill-pane -t {win}.2"); c.pump(0.5)                       # pane removed -> %layout-change
c.send("detach-client"); c.pump(0.6)                                # %exit
c.close()

open(os.path.join(OUT, "control.raw"), "wb").write(c.raw)
open(os.path.join(OUT, "commands.txt"), "w").write("\n".join(c.sent) + "\n")
json.dump({"tmux_version": version, "recorded": time.strftime("%Y-%m-%d"), "window": win, "first_pane": pane1,
           "note": "private socket, 120x40 then refresh-client 100x30; shells are sh with PS1='$ '"},
          open(os.path.join(OUT, "manifest.json"), "w"), indent=2)
kill()
print("version:", version, "| bytes:", len(c.raw), "| lines:", c.raw.count(b"\n"))
