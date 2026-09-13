# ADR 0002: Portable Agent Integration Core

- Status: Accepted.
- Date: 2026-09-13.
- Amends: ADR 0001 by assigning portable domain and protocol ownership.

## Context

The macOS integration needs XPC, Service Management, code-signing validation,
Keychain access, notifications, and SwiftUI. Approval state, protocol
validation, idempotency, and provider normalization do not inherently depend
on macOS. Keeping those rules in a Swift XPC service would require separate
implementations for future Windows and Linux applications.

## Decision

Provider-neutral agent logic will be implemented in Rust. The portable Rust
workspace owns:

- Versioned wire decoding, message limits, and framing.
- Approval request identity, state transitions, deadlines, and idempotency.
- Provider-neutral event and projection rules as those features migrate.
- Provider input normalization and output models used by the Hook CLI.

The Core does not import XPC, Service Management, Keychain, Windows service or
named-pipe APIs, Unix-domain-socket APIs, notification frameworks, or UI
frameworks. Time, transport, authenticated peer identity, storage, and process
lifetime are supplied by platform adapters.

Each operating system uses native integration at its boundary:

- macOS uses Swift for `SMAppService`, XPC, code-signing requirements,
  Keychain, notifications, and SwiftUI.
- Windows and Linux will select lifecycle, IPC, credential storage,
  notification, and UI technologies in platform-specific ADRs.

A narrow, versioned C ABI may link a native host to the Rust Core. C is the
interoperability ABI, not an implementation language. Panics, native object
layouts, and language-owned errors must not cross it.

The logical Hook CLI is `limpid-agent`, with provider-specific subcommands. It
may link a platform transport shim where peer authentication requires one, but
it never receives application-controller authority.

## Security boundary

The protocol accepts a `Principal` injected by an authenticated platform host.
It deliberately has no wire operation that upgrades a requester into a
controller. Same-user filesystem permissions or peer credentials establish a
user boundary but do not, by themselves, separate a hook from the approving
application.

Approval identity is `(ServiceEpoch, RunID, RequestID)`. Provider session IDs,
pane IDs, process IDs, titles, and tool inputs are correlation or display data,
not authorization credentials.

## Consequences

macOS debugging crosses a Swift/Rust boundary, and every wire change requires
compatibility tests. The tradeoff is that the correctness-sensitive state
machine is shared by all supported operating systems while native security and
UI remain idiomatic for each platform.

The implementation supplies the Rust broker, protocol messages, framing, and
stream session, with Unix socket-pair coverage on Unix CI. The macOS host also
uses a versioned C ABI with opaque service and session handles. Its XPC adapter
passes one bounded JSON message per call because XPC already preserves message
boundaries; the length-prefixed stream framing remains available to transports
that need it. Swift selects the authenticated role and injects the requester
run ID before Rust decodes sensitive request content.

## Acceptance criteria

- The same Rust reducer and codec tests run on macOS, Windows, and Linux CI.
- A requester cannot resolve its own request or access another run.
- A stale service epoch, conflicting retry, late decision, and oversized or
  truncated frame cannot produce an allow decision.
- The macOS host eventually enforces role separation at least as strictly as
  the signed XPC feasibility spike.
