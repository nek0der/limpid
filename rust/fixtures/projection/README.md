# Projection corpus

Input for the reader side: the record sets `limpid_agent_core::project` reduces
into badges, tab titles, notification transitions, and commands.

## Why the records are generated

Every `*.state.json` here is produced by replaying the hook fixtures in
`rust/fixtures/<provider>/` through the real hook runtime, not written by hand.
Hand-written records would let the writer fixtures and the reader corpus drift: a provider
schema change would update the writer fixtures and leave the reader corpus
describing records no hook writes any more. Deriving them means one regeneration
updates both.

Regenerate with `scripts/derive-projection-corpus.sh` and review the diff. The
generated records are goldens, reviewed like `expected.json`. CI regenerates
them too and fails on any diff, so a record edited by hand, or left behind by
a hook change, is caught rather than trusted: every step's clock comes from
its `scenario.json`, which is what makes the output reproducible.

## Layout

```
projection/<case>/
  scenario.json                  hand-written: which hook payloads to replay, under which identity
  input.json                     hand-written: everything in ProjectionInput that is not on disk
  expected.json                  reviewed golden: the projection and commands
  agent-states/*.state.json      generated (Claude keeps the legacy directory names)
  codex-agent-states/*.state.json
  sessions/*.json                generated resume hints
  sessions/tmux-hosted/*.json    generated resume hints of runs Limpid hosts in tmux,
                                 kept where a build from before mirror tabs does not read them
  codex-sessions/*.json
  cwd-events/*.cwd.json          generated
  worktree-events/*.json         hand-written; the intercept creates real worktrees, so it is not replayed
```

## scenario.json

`runs` is ordered, and so is each run's `replay`, because the record a step
writes depends on the record before it.

```json
{
  "description": "One line on why this case exists.",
  "runs": [
    {
      "provider": "claude",
      "pane": "<uuid>",
      "run": "<uuid>",
      "pid": "4242",
      "tmux": false,
      "replay": [
        { "case": "session-basic", "payload": "0000-SessionStart.json", "now": "2026-09-14T12:00:00Z" }
      ]
    }
  ]
}
```

- `case` names a directory under `rust/fixtures/<provider>/2026-09/`. Prefix it
  with `<provider>/` to borrow another provider's payload.
- `pid` is what the shim exports. Leave it out for a tmux-hosted run, which is
  how a pane inside tmux actually reaches the hook.
- `tmux` sets a fixed endpoint so the generated record carries the tmux fields.
- `tmuxHostMode` is what the shim exports as `LIMPID_AGENT_TMUX_HOST_MODE` for
  a run in tmux. `limpidHosted` writes the resume hint as a native run does;
  `manual`, or leaving it out, withholds it.
- `now` is explicit on every step. Retention rules (a viewed finish older than a
  day, a resume intent past its window) are only reachable with a controlled
  clock, and a wall clock would make the records unstable.

## input.json

The part of `ProjectionInput` that does not come from the state directories.

| Key | Meaning |
| --- | --- |
| `now` | Wall clock for record comparison and retention |
| `monotonicMs` | Monotonic uptime for the notification outbox's pending lifetime |
| `isBootstrap` | The first pass after launch records runtimes and announces nothing |
| `tabs` | Tab identity and its split-tree leaves, so badges and titles can be placed |
| `pidStatus` | `alive`, `dead`, or `unknown` per pid, evaluated by the host |
| `focus` | The focused tab and pane, or null |
| `marks` | `viewed` and `dismissed` as runtime id to episode token |
| `presence` | tmux attachments per endpoint, and whether each location is active |
| `resumeIntents` | Live resume intents, which keep a dead record from being retired |
| `acknowledged` | Outcomes of the commands the previous pass returned |

## Adding a case

Add the directory with `scenario.json` and `input.json`, run the script, and
review the generated records before committing them. Cover a rule that no other
case reaches; the point of the corpus is the rules, not the payload count.
