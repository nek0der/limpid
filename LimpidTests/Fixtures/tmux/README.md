# tmux control-mode fixtures

Recorded traffic from a real tmux server, used by the `TmuxProtocol`,
`TmuxLayout`, `TmuxReplyAssembler`, and `TmuxControlTransport` tests. They
are the reference for what tmux actually sends over control mode, as opposed
to what its manual says.

## Layout

```
tmux/
  <schema-date>/<case>/
    control.raw      every byte the control client received, in order
    commands.txt     the commands the client sent (session-basic only)
    manifest.json    tmux version, recording date, and what the tests read
  record_tmux.py     records session-basic on a private socket
  record_bulk.py     records bulk-output (a large colored payload)
```

## Recording

```
./record_tmux.py [output-directory]
./record_bulk.py [output-directory]
```

Both scripts write to a new temporary directory unless given one, and print
where. They use `tmux -L <private name> -f /dev/null`, so the user's own server
is never touched and the recording does not depend on the recording machine's
`~/.tmux.conf`; the server and its socket are removed when the script ends.
`record_bulk.py` keeps its payload in a temporary directory of its own, cuts
`control.raw` at the last line boundary within 1.2 MB, and writes the counts
the tests compare against into the manifest. No step is done by hand.

## What the tests read

Each test of a case runs once for every dated directory that holds the case
(`TmuxRecording.all`). When a tmux release changes the wire format, record a
new dated directory and keep the old one: both must keep passing, because
users update tmux and Limpid at different times.

A recording made again with the same tmux can replace the files of its dated
directory without breaking a test. What follows from the scripts' commands
(layouts, notifications, reply text) is pinned in the tests. What tmux picks
per run is not: reply timestamps and numbers and the pane's tty are checked by
shape, the version comes from the manifest, and so do the `%output` line and
byte counts of `bulk-output`, since how tmux splits that stream into lines
differs from run to run.

## How long a recording is kept

A dated directory costs about 1.2 MB, most of it `bulk-output`, and every
tmux release that changes the wire format adds one. Drop a dated directory
once the oldest tmux we support has passed the release it was recorded on:
after that nothing a user can run speaks that older wire format, and keeping
it only pins a shape no version still sends. `record_tmux.py` and
`record_bulk.py` produce the directory again from any tmux, so a version
dropped here is not lost — it is re-recordable from that tmux.

Removing one is a commit of its own, with the tmux version that made it
obsolete named in the message, so the reason survives in the log.
