# ADR 0001: Agent Integration Service

- Status: Accepted.
- Date: 2026-09-13.

## Context

Limpid currently receives Claude Code and Codex lifecycle observations through
per-run JSON files. The application watches those files and projects the
observed state into tabs, Waiting, and notifications.

That snapshot-oriented path is not a request-response transport. Approval
requires a live request, cancellation, one accepted decision, a bounded wait,
and an explicit fallback when Limpid cannot answer. Extending the state files
with response files would introduce polling, stale replies, cleanup races, and
bidirectional semantics into a store designed for delayed observation.

The agent may also continue inside tmux after the Limpid application exits. A
service hosted by the UI process would therefore have the wrong lifetime.

## Decision

Limpid will use a per-user Agent Integration Service whose lifetime is
independent of the GUI. On macOS, `launchd` will manage the service after the
application registers its bundled executable through `SMAppService.agent`.
Closing Limpid will not unregister the service.

Provider hooks will invoke a signed Hook Helper. The helper will translate the
provider input into the versioned Limpid protocol, hold a live request while a
decision is pending, and translate the result back into provider output. It
will use a dedicated IPC connection and will not use lifecycle JSON for a
synchronous reply.

The macOS transport will use role-specific XPC Mach services for application
and hook clients. The platform host authenticates each peer and supplies a
trusted principal to the portable protocol implementation. A role claimed by
JSON never grants authority. Unix domain sockets or other local transports are
not interchangeable with this trust decision; any fallback requires its own
authentication design.

The service owns the live approval authority. Pending requests, tool inputs,
and decisions remain in memory. A service restart changes its epoch and makes
old decisions unusable. Connection, decoding, timeout, or service failures
never produce an allow decision. The provider adapter delegates to the
provider's normal approval path when that path is available.

## Migration

Migration is selected per run. A run uses either the legacy state-file backend
or the service backend for its entire lifetime. Both backends must not publish
the same run into the application.

The macOS service host and signed client boundary now exist, but neither
provider hook is enabled and the JSON observer is unchanged. A Debug build can
register, refresh, inspect, or unregister the development LaunchAgent only
when `LIMPID_AGENT_SERVICE_CONTROL` explicitly requests that operation.
Release builds do not register the service. Production activation still
requires the signed Hook Helper, provider adapters, update validation, and
application UI.

## Consequences

The service adds signed executables, update coordination, protocol
compatibility, and a lifecycle outside the GUI. In return, synchronous
decisions have an explicit authority and remain possible while the terminal
agent outlives the application.

The portable ownership boundary is defined by
[ADR 0002](0002-portable-agent-integration-core.md).

The service executable and LaunchAgent property list are versioned inside the
application bundle. Updating either one requires unregistering the old service
before registering the replacement. Registration must remain disabled for
normal users until the Sparkle replacement and re-registration sequence has
been validated with an installed release.

## References

- [Apple XPC](https://developer.apple.com/documentation/xpc).
- [Apple `SMAppService`](https://developer.apple.com/documentation/servicemanagement/smappservice).
- [Claude Code hooks](https://code.claude.com/docs/en/hooks).
- [OpenAI Codex hook schemas](https://github.com/openai/codex/tree/main/codex-rs/hooks/schema/generated).
