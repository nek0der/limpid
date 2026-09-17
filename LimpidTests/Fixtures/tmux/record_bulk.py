#!/usr/bin/env python3
"""Record a bulk %output stream: real tmux escaping of a large colored payload."""
import os, select, subprocess, sys, time, json
SOCK="limpid-fixture-bulk"; OUT=sys.argv[1]; os.makedirs(OUT, exist_ok=True)
def tmux(*a): return subprocess.run(["tmux","-L",SOCK,"-f","/dev/null",*a],capture_output=True,text=True).stdout.strip()
def kill(): subprocess.run(["tmux","-L",SOCK,"-f","/dev/null","kill-server"],capture_output=True)
kill()
payload=os.path.join(OUT,"payload.txt")
with open(payload,"w") as f:
    for i in range(40000):
        f.write(f"\x1b[3{i%7+1}m{i:06d}\x1b[0m \x1b[1mlorem ipsum dolor sit amet\x1b[22m \\ backslash \x1b[4munderline\x1b[24m\n")
size=os.path.getsize(payload)
tmux("new-session","-d","-s","fx","-x","200","-y","50","sh","-c","PS1='$ ' exec sh")
tmux("set-option","-g","status","off"); time.sleep(0.3)
pane=tmux("display-message","-p","-t","fx","#{pane_id}")
p=subprocess.Popen(["tmux","-L",SOCK,"-f","/dev/null","-C","attach","-t","fx"],stdin=subprocess.PIPE,stdout=subprocess.PIPE,bufsize=0)
raw=b""; end=time.time()+0.6
while time.time()<end:
    r,_,_=select.select([p.stdout],[],[],0.05)
    if r: raw+=os.read(p.stdout.fileno(),65536)
raw=b""  # drop the attach block; keep only the bulk
p.stdin.write(f"send-keys -t {pane} 'cat {payload}' Enter\n".encode()); p.stdin.flush()
quiet=0; last=time.time()
while quiet<1.5:
    r,_,_=select.select([p.stdout],[],[],0.1)
    if r:
        chunk=os.read(p.stdout.fileno(),1<<20); raw+=chunk; last=time.time()
    quiet=time.time()-last
p.stdin.close(); p.terminate(); p.wait(timeout=2)
open(os.path.join(OUT,"control.raw"),"wb").write(raw)
json.dump({"tmux_version":tmux("-V") or "tmux 3.7c","recorded":time.strftime("%Y-%m-%d"),"payload_bytes":size,
           "note":"cat of payload.txt inside a 200x50 pane; control.raw is what the control client received"},
          open(os.path.join(OUT,"manifest.json"),"w"),indent=2)
kill()
print("payload:",size,"raw:",len(raw),"output lines:",raw.count(b"\n%output ")+1)
