# Agent Integration Protocol

This document defines the provider-neutral contract between the Hook Helper,
the Agent Integration Service, and the native application. Provider hook
schemas, provider response JSON, and operating-system lifecycle and transport
APIs are adapters outside this boundary.

## Status and scope

Protocol major version 1 currently implements:

- `hello` and service-epoch negotiation.
- `approval.submit`, `approval.get`, `approval.wait`,
  `approval.cancel`, and `approval.resolve`.
- `approval.snapshot` for an authenticated controller.
- Cursor-based `approval.subscribe` for controller change delivery.
- Typed errors and bounded length-prefixed JSON frames.

Attachment bootstrap capabilities, lifecycle events, and approval persistence
are not part of the current implementation. Release service registration is a
macOS host responsibility outside this provider-neutral protocol.

## Transport and framing

The normative boundary is versioned UTF-8 JSON owned by the portable Rust
protocol crate. A stream carries each JSON message as a four-byte unsigned
big-endian payload length followed by exactly that many bytes.

The service validates the length before allocating the payload. Authenticated
client requests are limited to 1 MiB and service responses to 64 KiB. A clean
EOF is valid only between frames. A partial header, partial payload, zero
length, invalid JSON, or over-limit frame terminates the connection without a
decision. An individual approval body is limited to 48 KiB so its result fits
inside the response limit. An approval lifetime and one blocking wait are each
limited to ten minutes. A decision is limited to 8 KiB. One service epoch holds
at most 128 request records.

The platform host owns transport creation and peer authentication. macOS
carries each encoded request and response as one bounded XPC `Data` value over
role-specific Mach service endpoints. It does not add stream framing inside
XPC. Other operating systems may use different local transports, provided
they preserve message boundaries, trusted principals, limits, ordering, and
failure behavior.

## Trusted principals

The host injects exactly one principal when it accepts a connection:

- `Requester { run_id }` submits, reads, waits for, and cancels requests for
  that run only.
- `Controller` reads snapshots and resolves requests.
- `Diagnostic` has no access to approval content or decisions in version 1.

The principal is not decoded from JSON. The public hook endpoint cannot select
`Controller` in `hello` or any later message. On macOS, separate Mach service
names and Team ID plus signing-identifier requirements enforce this split
before Rust sees a message. The host generates the requester `RunID` while
opening the authenticated requester session.

## IDs and service epoch

- `RunID` identifies one authenticated Hook Helper requester session in the
  current macOS adapter.
- `RequestID` identifies one immutable approval request.
- `message_id` correlates one protocol request with its response.
- `ServiceEpoch` is generated on every service start.
- `operation_id` is an optional provider tool-call correlation value.
- `agent_run_id` is an optional correlation value naming the agent run whose
  hook asked (see [Approval request](#approval-request)). It is never part of
  authorization.
- `provider` is an open identifier, not a fixed set: one to thirty-two
  characters of lowercase letters, digits, and hyphens. A service accepts one
  it does not recognize, because the value is correlation and display data
  rather than an authorization credential, and adding a provider must not
  require a protocol change.

The approval key is `(ServiceEpoch, RunID, RequestID)`. Claude Code and current
Codex `PermissionRequest` inputs do not provide a stable tool-call ID, so the
Limpid provider adapter must generate `RequestID`. A pane ID, session ID, PID,
or title is never part of authorization.

Each current `PermissionRequest` starts a short-lived signed Hook Helper,
which therefore receives a fresh host-generated `RunID`. Reusing one run
across a complete agent CLI launch requires a separate unforgeable resume
capability. A provider environment variable is not accepted as authority.

Every message after `hello` must echo the accepted `service_epoch`. A mismatch
returns `epoch_mismatch`. A client must delegate an unresolved provider request
after reconnecting to a different epoch; it must not replay an old allow
decision into the new service.

## Handshake

`hello` must be the first message and contains no sensitive agent data:

```json
{
  "version": 1,
  "message_id": "2f7ad460-bfc0-4d8d-9827-62ec65c4ce67",
  "type": "hello",
  "body": {
    "client_version": "0.1.5"
  }
}
```

The response supplies the service epoch and the negotiated capabilities:

```json
{
  "version": 1,
  "message_id": "352cc73c-8218-440c-93de-19f99f36d180",
  "in_reply_to": "2f7ad460-bfc0-4d8d-9827-62ec65c4ce67",
  "service_epoch": "662c2cf4-c48e-41e1-9a44-932a03565564",
  "type": "hello.result",
  "body": {
    "capabilities": [
      "approval.allow_once",
      "approval.deny",
      "approval.delegate",
      "approval.answer",
      "approval.agent_run",
      "approval.subscribe",
      "approval.wait"
    ]
  }
}
```

An unsupported major version returns `unsupported_version`. A second `hello`
returns `already_initialized`. Sensitive requests sent before a successful
handshake return `hello_required`.

## Approval request

`approval.submit` registers immutable provider-neutral content:

```json
{
  "version": 1,
  "message_id": "459542b6-4a7c-4493-90f0-5288fc242d22",
  "service_epoch": "662c2cf4-c48e-41e1-9a44-932a03565564",
  "type": "approval.submit",
  "body": {
    "run_id": "99d053bc-ca34-4f34-9437-01f2d74e4bac",
    "request_id": "81999e23-5d95-4b74-ac90-b85d17d1c2d2",
    "provider": "claude",
    "session_id": "opaque-provider-session",
    "operation_id": null,
    "tool_name": "Bash",
    "summary": "Run the test suite",
    "input": { "command": "make test" },
    "timeout_ms": 570000
  }
}
```

The body may also carry an optional `questions` list when the provider asks
the user to answer rather than to grant a permission. The field is omitted when
the list is empty, so an ordinary approval, and a Hook Helper that predates
the field, keep the shape above. Each question has these fields:

- `header` (optional) is a short label the card may show above the prompt.
- `prompt` is the question text, which also keys the answer in an `answer`
  decision.
- `options` lists the selectable choices, each with a `label` and an optional
  `description`.
- `multi_select` is `true` when the user may pick more than one option.

`approval.get` and `approval.wait` return the list unchanged under
`request.questions`.

The body may also carry `agent_run_id`, a UUID naming the agent run whose
hook asked. The Hook Helper reads it from the run's environment
(`LIMPID_AGENT_RUN_ID`, set by the Limpid launcher). It is correlation data
like `session_id`, never authority: it is not part of the approval key, and
the service grants nothing by it. When a conversation is resumed in a second
run, that run keeps the session ID. The application uses `agent_run_id` to
tell one run's request from the other's. The field is omitted when the Hook
Helper runs outside a Limpid run. A value that is not a UUID makes the
message malformed, as any other mistyped field does. The service advertises
the field as the `approval.agent_run` capability, and `approval.get` and
`approval.wait` return it unchanged under `request.agent_run_id`.

The service computes a monotonic deadline when it first accepts the request. A
retry with the same key and identical content returns the existing record and
does not extend the deadline. Reusing the key with different content returns
`request_conflict`.

The service keeps terminal records so that a requester can still read its
result after the decision:

- A terminal record becomes consumed when its requester reads it with
  `approval.get` or `approval.wait`, or cancels it.
- A controller's `approval.get` does not consume it. The application can
  therefore learn how a request ended without taking the result from the hook
  that waits for it.
- A record nobody consumed counts as consumed once twice its request's
  timeout has passed since it was created. By then its requester can no
  longer be waiting.

When the broker is full, a new request evicts the oldest consumed terminal
record. Pending records and unconsumed terminal records are never evicted. If
no record can go, the new request is rejected with `capacity_exceeded` rather
than taking a result its requester has not read.

Consumed results stay until a slot is needed, so once the record count reaches
the limit, it stays there. Every `approval.snapshot.result` therefore also
carries `unevictable_records`: the number of pending and unconsumed records,
which could not make room. A controller checks this count, not the record
count, to warn of a full broker.

## State machine

```text
Pending
  |-- resolve(allow_once) --> Resolved(allow_once)
  |-- resolve(deny) -------> Resolved(deny)
  |-- resolve(delegate) ---> Resolved(delegate)
  |-- resolve(answer) -----> Resolved(answer)
  |-- requester cancel ----> Canceled
  `-- deadline ------------> Expired
```

Terminal states are immutable. The broker serializes resolve, cancel, and
expiry. Only the first valid transition is accepted. Repeating the identical
accepted decision is idempotent; a different later decision returns
`already_terminal`. The deadline is checked during every operation, so a late
allow is rejected even if no timer callback has run.

The supported decisions are:

- `allow_once` grants only this provider request.
- `deny` may include a reason for the provider.
- `delegate` makes no decision and returns control to the provider's normal UI.
- `answer` carries an `answers` map from each question's `prompt` to its
  answer text, as in `{"decision":"answer","answers":{"Which color?":"Red"}}`.
  The text is the chosen label, or text the user typed in its place. For a
  multi-select question it is every chosen label joined with `, `, with typed
  text last.
  The 8 KiB decision limit applies to the whole decision, answers included.
  `approval.get` and `approval.wait` return it under `state.result`. A provider
  that cannot render an answer treats it as `delegate`.

Persistent provider permission changes are outside version 1. Rewriting the
input of an approved tool call is also outside version 1, except that a
provider may render an `answer` decision as the input of the question-asking
call it answers.

## Waiting, snapshots, and subscriptions

`approval.wait` holds one requester connection until the request becomes
terminal, its approval deadline passes, or `maximum_wait_ms` elapses. When the
caller's wait times out, the service returns the still-pending snapshot. That
does not extend the request deadline and does not imply allow. The provider
adapter then delegates, unless it deliberately continues waiting within its
own hook deadline.

`approval.snapshot` returns one controller-only consistency point containing
the broker sequence and a lightweight index of current requests. The index
contains IDs, provider, terminal status, deadline, and record sequence, but not
tool input, summary, or deny reason. The controller retrieves selected details
with `approval.get`, which keeps a snapshot response within its fixed bound.

`approval.subscribe` takes the last observed sequence and holds the controller
connection until the sequence changes, the next pending deadline expires, or
its bounded wait ends. It returns the same consistent lightweight index as
`approval.snapshot`. The application immediately reissues the subscription with
the returned cursor; it does not use a timer or an on-disk polling path to make
approval decisions. A service epoch change invalidates the cursor and every
stale UI action.

Deadlines are milliseconds of the service's own monotonic clock, which starts
when the service does, so a controller cannot compare them with its own time.
Every `approval.snapshot.result`, and the body of a controller's
`approval.get`, therefore carries `now_ms`: the service clock when it
answered. The controller subtracts it from `deadline_ms`, counts the
difference down on its own monotonic clock, and reads the time again after the
Mac wakes from sleep. A requester has no use for the time left, so its
responses do not carry `now_ms` and keep their current shape. The field is
optional on the wire. The application and the Hook Helper both refuse a
service that is not the one bundled with them, so a response without the
field is a defensive case rather than a supported mix of versions.

## Provider mapping and failure behavior

For Claude Code, `allow_once` maps to
`hookSpecificOutput.decision.behavior = "allow"`, and `deny` maps to
`"deny"`. Returning no decision delegates to Claude Code's normal permission
flow. A `PermissionRequest` hook exit code alone does not grant or deny.

Current Codex hook schemas likewise accept `allow` or `deny` in
`hookSpecificOutput.decision.behavior`; no decision leaves the native path in
control. Current Codex fields such as `updatedInput`, `updatedPermissions`, and
`interrupt` are reserved and fail closed when supplied, so version 1 does not
emit them.

If transport, peer authentication, framing, schema validation, service state,
or waiting fails, the Hook Helper emits no allow decision. When the provider
has a native interactive approval path, the helper delegates to it. Provider
behavior in non-interactive sessions remains provider-owned.

## Current implementation boundary

`limpid-agent-core` contains the portable approval broker.
`limpid-agent-protocol` contains wire types, framing, the authenticated stream
session, a discrete-message session for XPC, and a blocking wait primitive.
Unix tests connect independent requester and controller streams through a real
socket pair. The versioned Rust C ABI exposes opaque broker and session handles
to the macOS service without exposing Rust-owned layouts or panic behavior.

The bundled macOS LaunchAgent owns separate requester and controller Mach
services and applies code-signing requirements before accepting connections.
Debug and Release use different labels, service names, bundle identifiers, and
property lists. Signed Debug and Release apps reconcile their isolated services
on launch; the Debug environment command can refresh, inspect, or unregister its
development service. The signed Hook Helper translates Claude and Codex
`PermissionRequest` JSON and delegates on every integration failure. Codex uses
that stable helper command in every pane. The helper verifies the authenticated
service artifact against its own app bundle, and publishes the lifecycle
fallback when it delegates. The application consumes the controller
subscription. It holds pending requests for its approval card and its
attention list only after it authenticates the running service as the
currently bundled and registered artifact. The XPC session bootstrap includes
that artifact identity as an additive optional field. On the first update, a
service from an older build therefore fails closed and is replaced.

## Turn records

Turn records are not protocol messages. The Hook Helper writes them as files,
and the application reads them through the Rust projection; nothing about
them crosses the service. They are described here because the Hook Helper
and the application share their shape, which `limpid-agent-model`
(`turn.rs`, `TurnRecord`) owns.

A provider whose descriptor has the `turn_snapshot` capability (Claude Code
and Codex today) records turns. Its hook events map to provider-neutral
events, and those decide what is written (`turn_step` in
`limpid-agent-core`):

| Provider hook | Event | Effect on the turn |
|---|---|---|
| `UserPromptSubmit` | `PromptSubmitted` | begins a turn: a begin snapshot, the counter's next number, a new record |
| `Stop` | `TurnFinished` | ends the turn as `finished` with an end snapshot and the difference |
| Claude `StopFailure`, a Codex `Stop` that carries an error (none does today), the usage limit Limpid's watcher reports for Codex | `Failed` | ends it as `failed` |
| Codex `Interrupt` | `Interrupted` | ends it as `interrupted` |
| Claude `Notification` (`idle_prompt`) | `AwaitingPrompt` | for a run working after its turn's `Stop`, takes that turn's end snapshot and difference again and keeps how it ended; for a turn open at least 55 seconds, ends it as `interrupted`, a turn waiting on a question or permission only when the transcript shows the awaited call ended: every call of the latest assistant message has a result, or an interrupt line follows it (`awaited_call_ended`); otherwise nothing (docs/adr/0004-provider-adapter-contract.md, "Work outside a turn") |
| Claude `PostToolUse` / `PostToolUseFailure` of a check command | — | sets the turn's `lastCheck` |

Not every hook call comes from the pane's agent. Codex's memory feature runs a
"Memory Writing Agent" thread in the same process after a session starts.
That thread runs the user's `SessionStart`, `UserPromptSubmit`, and tool
hooks with its own `session_id` and no subagent marker, while its `Stop`
reaches no user hook. The Codex adapter recognizes the thread as follows:

- Codex's descriptor names the directories under its home where such an
  agent of its own works (`internalAgentDirectories`: `memories` and
  `memories_v2`, one per memory format). The adapter recognizes the thread by
  its `cwd` lying there, under the home the agent's environment names
  (`CODEX_HOME`, or `~/.codex`). It yields no event for the thread, so the
  thread neither begins a turn, names the tab, nor replaces the resume hint
  (`rust/fixtures/codex/2026-10/memory-agent`).
- The home and the `cwd` are both compared with their symlinks resolved,
  because Codex canonicalizes a `CODEX_HOME` the environment sets.
- Codex resolves a relative `CODEX_HOME` against the directory it starts in,
  which a hook running in the session's `cwd` cannot know. The `codex` shim
  therefore makes the value absolute before Codex starts. A home that still
  reaches the hook as a relative path matches nothing.

The reading side guards against what builds from before that rule left
behind. Consider a provider's own internal agent directories under its
default home (`~/.codex/memories` for Codex). A resume hint whose `cwd` lies
in one of them is not offered for resume, and a turn whose snapshot root or
repository lies in one is not shown. Only that provider's records are read
this way, so a Claude session, or a project of the person's under a path with
the same names, stays theirs. The projection takes the person's home from the
host (`home` in its input). It knows only the default home, since the
application's environment is not the agent's. It reads the default home both
as written and as the host resolved its symlinks (`resolvedHomes` in its
input). The rules read no disk, and a record of an agent that canonicalized a
`~/.codex` that links elsewhere names the link's target.

A `Stop` the provider marks as following work another stop hook asked for
(`stop_hook_active`) ends the same turn again, since the turn went on. Any other
end with no turn of its own to close writes an end-only record, which reads
as incomplete and has `hasPrompt` false in the projection. A prompt whose
hook call has no event identity begins no record, since a retry could not be
told apart from it. Each record lists the events it applied
(`appliedEvents`), so a retried hook is applied once.

The files live in the provider's state directory, under `turns/`:

- `<turn-id>.turn.json`, schema 1: `turnId`, `provider`, `conversation` (the
  provider's session ID, or the run ID marked `isFallback` when the provider
  reported none), `runId`, `paneId`, `displayNumber`, `promptHead`,
  `promptKind`, `startedAt`, `finishedAt`, `phase`, `gitContext`, the
  `begin` and `end` snapshot states, the untracked files each snapshot left
  out for their size (`skippedBegin`, `skippedEnd`), `changes`,
  `durationSeconds`, `addedBytes`, `lastCheck`, and `appliedEvents`. Fields a version does not model are kept
  and written back. A record a reader cannot write back exactly as it read
  it, including any newer schema, is left alone: never rewritten, never
  deleted.

  `startedAt`, like the run record's `runStartedAt`, is when the prompt's
  hook was through waiting for the worktree lock, or when the hook was
  called for a prompt outside a repository. The agent starts only then, and
  a turn that began before a restore is one the restore took back.

  The agent's harness hands the hook some prompts that nobody typed: a
  background task's end (`<task-notification>`), a subagent's hand-back
  (`<agent-message`), and reminders before the person's words
  (`<system-reminder>`, `<local-command-caveat>`). `promptKind` (`text`,
  `backgroundTask`, `subagentMessage`, `injected`) says who wrote the
  prompt. It is judged from the whole prompt when the turn begins
  (`classify_prompt`). `promptHead` is the prompt's first 80 characters on
  one line. For `text`, it holds the person's words, with the leading
  reminders left out however long they were. For any other kind, it holds
  the prompt as it came, which the application never shows.

  A record without `promptKind` (from before the field was kept) is judged
  again from its head when it is summarized. A reminder that closes within
  the head leaves the person's words after it, and one longer than the head
  reads as `injected`. Unlike other values, a kind this version does not
  know does not make the record read-only. It is kept as it came, written
  back, and read as `text`, since the kind only changes how the turn is
  worded; a new kind needs no new schema. The projection's summary always
  carries `promptKind`, and an application that does not find it, or does
  not know it, reads it as `text`.

- `<hash>.counter`, one per conversation, from which turns are numbered. The
  number only grows, so a deleted turn's number is never given again.

The run record names the run's current turn in `currentTurnId`, written only
after the turn's record is. Each snapshot tree is pinned in the repository by
`refs/limpid/turns/<turn-id>/begin` and `/end`, which go with the record when
the retention sweep deletes it.

Earlier builds also moved a per-pane `refs/limpid/turn/<pane>` at every
prompt, for a review of "This turn" that no build offers now. The Hook Helper
no longer writes it; it still removes it, with the private index files, when
the session ends.

Whether a turn is read is decided by the application, not stored in the
record. A turn that changed no files is read once its pane is seen, and one
that changed files is read once the viewed line passes it. A finished run that
no turn record stands for is still marked seen through the projection's
`markViewed` command, which carries the run ID and the episode token it was
seen in. That command remains.
