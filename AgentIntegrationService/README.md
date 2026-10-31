# Agent Integration Service

This directory contains the bundled, per-user macOS LaunchAgent that hosts the
Rust approval broker. Requester and controller clients use separate Mach
services. Each listener installs a Team ID and signing-identifier requirement
before it accepts a connection, then creates a Rust session with a host-selected
principal.

Signed Debug and Release builds reconcile their own services on launch. In
Debug, `WEIR_AGENT_SERVICE_CONTROL` replaces automatic reconciliation with a
single command, for iterating on the bundled executable:

```bash
WEIR_AGENT_SERVICE_CONTROL=register make dev
WEIR_AGENT_SERVICE_CONTROL=status make dev
WEIR_AGENT_SERVICE_CONTROL=refresh make dev
WEIR_AGENT_SERVICE_CONTROL=unregister make dev
```

Ad-hoc signed builds cannot become ready because they have no Team ID for the
peer requirements. Weir then shows no alert and leaves the providers on
their native prompts. `make build` signs Debug with a Team ID when
`WEIR_DEVELOPMENT_TEAM` is set (see `CONTRIBUTING.md`). Debug and Release use
distinct LaunchAgent labels, Mach service names, bundle identifiers, property
lists, markers, and Application Support directories. Development cleanup must
target only `com.nekoder.weir.agent-integration-service.dev`.

The signed Hook Helper is embedded in the application's `Contents/MacOS`
directory and is the only requester accepted by the Release configuration. In
Debug, the `AgentIntegrationRequesterProbe` and
`AgentIntegrationControllerProbe` targets also validate the real development
transport. They are not embedded in the application, and their
signing identifiers are accepted only by the Debug service configuration.

The Claude and Codex `PermissionRequest` hooks invoke the helper. Before it
submits a request, the helper authenticates the service and verifies that the
service's in-memory artifact identity matches the executable and property list
in the helper's own app bundle. It translates provider JSON into the versioned
approval protocol, waits for the Rust broker, and writes provider-specific
JSON only after an explicit Allow or Deny, or an explicit Answer to a
Claude question that asks for one. Any launch, authentication,
decoding, transport, timeout, or service-restart error produces no approval
output, so the provider keeps control of its native permission flow. The
app's approval controller (`ApprovalPresentationStore`, behind the approval
card and the Needs Attention list) subscribes only while reconciliation is
ready. Codex always uses the same signed-helper command, so panes created
before reconciliation do not keep stale routing or trust state. Whenever the
helper delegates a Codex permission decision, it writes that request's
lifecycle record itself.

The lifecycle and worktree hooks run in the same helper
(`hook <provider> [worktree]`, exec'd by the bundled `weir-hook` wrappers).
The helper is the only receiver of hook events, and those hooks do not need
the service.

The service executable and property list are installed inside the application
bundle. The app fingerprints both files, validates the service and helper
against the current Team ID and signing identifiers, and obtains the running
service's fingerprint through the authenticated controller connection. An
atomic marker records the artifact for which replacement started,
registration completed, or verification completed. The marker is recovery
state, not proof of authenticity. When the running fingerprint matches and the
marker is `registered` or `ready`, the app keeps the service's PID and epoch
and completes verification. When the marker is `replacing`, missing, corrupt,
or mismatched, the app waits for an asynchronous unregister to complete before
it registers and authenticates the replacement.

When `SMAppService` reports `.requiresApproval`, the app leaves the
registration intact and directs the user to Login Items. Before the first registration on a machine, `SMAppService`
reports `.notFound` rather than `.notRegistered`, because Background Task
Management has no record for the label yet. The app has already validated the
bundled service at that point, so it registers instead of reporting a missing
service. `.notFound` after a registration call, signing failures, and other
reconciliation failures disable controller observation. A transient
controller failure with a current marker leaves the registered service and its
pending requests intact and schedules another observation. A slow unregister
reports an error but stays in flight until its completion callback, and
registration never races that callback. The app attempts recovery when the
user returns to it or chooses Retry. A rollback takes the same fingerprint-mismatch path.
Moving an unchanged app keeps the service, because absolute bundle paths are
not part of its identity. Running separate production copies at the same time
is unsupported, because they share one production LaunchAgent registration.

Production cleanup must target only `com.nekoder.weir.agent-integration-service` with
the signed disposable app that registered it. Never use a global background-item
reset for Weir cleanup.
