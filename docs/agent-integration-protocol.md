# Agent Integration Protocol

This document defines the provider-neutral contract between the Hook Helper,
Agent Integration Service, and native application. Provider hook schemas,
provider response JSON, and operating-system lifecycle and transport APIs are
adapters outside this boundary.

## Status and scope

Protocol major version 1 currently implements:

- `hello` and service-epoch negotiation.
- `approval.submit`, `approval.get`, `approval.wait`,
  `approval.cancel`, and `approval.resolve`.
- `approval.snapshot` for an authenticated controller.
- Typed errors and bounded length-prefixed JSON frames.

Push subscriptions, attachment bootstrap capabilities, lifecycle events,
provider adapters, persistence, and native approval UI are planned but are not
part of the current implementation. The macOS service host exists behind
explicit development-only registration.

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
role-specific Mach service endpoints; it does not add stream framing inside
XPC. Other operating
systems may use different local transports while preserving message
boundaries, trusted principals, limits, ordering, and failure behavior.

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

- `RunID` identifies one agent CLI process launch.
- `RequestID` identifies one immutable approval request.
- `message_id` correlates one protocol request with its response.
- `ServiceEpoch` is generated on every service start.
- `operation_id` is an optional provider tool-call correlation value.

The approval key is `(ServiceEpoch, RunID, RequestID)`. Claude Code and current
Codex `PermissionRequest` inputs do not provide a stable tool-call ID, so the
Limpid provider adapter must generate `RequestID`. A pane ID, session ID, PID,
or title is never part of authorization.

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

The response supplies the server epoch and negotiated capabilities:

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

The server computes a monotonic deadline when it first accepts the request. A
retry with the same key and identical content returns the existing record and
does not extend the deadline. Reusing the key with different content returns
`request_conflict`. The service retains terminal records for the host's
lifetime in the current implementation and rejects new requests with
`capacity_exceeded` instead of silently evicting a live result.

## State machine

```text
Pending
  |-- resolve(allow_once) --> Resolved(allow_once)
  |-- resolve(deny) -------> Resolved(deny)
  |-- resolve(delegate) ---> Resolved(delegate)
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

Persistent provider permission changes and tool-input rewriting are outside
version 1.

## Waiting and snapshots

`approval.wait` holds one requester connection until the request becomes
terminal, its approval deadline passes, or `maximum_wait_ms` elapses. A caller
wait timeout returns the still-pending snapshot; it does not extend the request
deadline and does not imply allow. The provider adapter then delegates unless
it deliberately continues waiting within its own hook deadline.

`approval.snapshot` returns one controller-only consistency point containing
the broker sequence and a lightweight index of current requests. The index
contains IDs, provider, terminal status, deadline, and record sequence, but not
tool input, summary, or deny reason. The controller retrieves selected details
with `approval.get`, which keeps a snapshot response within its fixed bound.

A later protocol revision will add ordered push updates. Until that exists, the
native UI integration is not complete and must not use polling as an approval
response path.

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
property lists. Only an explicit environment command in a Debug app registers
or unregisters the development service. Provider Hook Helper integration,
normal-user registration, and the native controller UI remain disabled.
