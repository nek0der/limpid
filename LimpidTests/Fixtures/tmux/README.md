# tmux control-mode fixtures

Recorded traffic from a real tmux server, used by the `TmuxProtocol`,
`TmuxLayout`, and `TmuxReplyAssembler` tests. They are the reference for
what tmux actually sends over control mode, as opposed to what its manual
says.

## Layout

```
tmux/
  <schema-date>/<case>/
    control.raw      every byte the control client received, in order
    commands.txt     the commands the client sent (session-basic only)
    manifest.json    tmux version, recording date, and the ids tmux handed out
  record_tmux.py     re-records session-basic on a private socket
  record_bulk.py     re-records bulk-output (a large colored payload)
```

`<schema-date>` is the year and month of the recording. When a tmux
release changes the wire format, record a new dated directory and keep
the old one: both must keep passing, because users update tmux and Limpid
at different times.

Both scripts use `tmux -L <private name>` so the user's own server is
never touched. `bulk-output/control.raw` is trimmed to about 1.2 MB at a
line boundary; the script produces the full stream.
