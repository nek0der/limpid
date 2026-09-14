# Agent Integration Service

This directory contains the bundled, per-user macOS LaunchAgent that hosts the
Rust approval broker. Requester and controller clients use separate Mach
services. Each listener installs a Team ID and signing-identifier requirement
before it accepts a connection, then creates a Rust session with a host-selected
principal.

Signed Debug and Release builds reconcile their respective services on launch.
`LIMPID_AGENT_SERVICE_CONTROL` overrides automatic reconciliation in Debug while
iterating on the bundled executable:

```bash
LIMPID_AGENT_SERVICE_CONTROL=register make dev
LIMPID_AGENT_SERVICE_CONTROL=status make dev
LIMPID_AGENT_SERVICE_CONTROL=refresh make dev
LIMPID_AGENT_SERVICE_CONTROL=unregister make dev
```

Ad hoc-signed builds cannot become ready because they have no Team ID for the
peer requirements. Debug and Release use distinct LaunchAgent labels, Mach
service names, bundle identifiers, property lists, markers, and Application
Support directories. Development cleanup must target only
`dev.limpid.agent-integration-service.dev`.

The signed Hook Helper is embedded in the application's `Contents/MacOS`
directory and is the only requester accepted by the Release configuration. In
Debug, the Requester and Controller probe targets also validate the real
development transport. They are not embedded in the application, and their
signing identifiers are accepted only by the Debug service configuration.

Claude and Codex `PermissionRequest` hooks invoke the helper. The helper
authenticates the service and verifies that its in-memory artifact identity
matches the executable and property list in its own app bundle before it
submits a request. It translates provider JSON into the
versioned approval protocol, waits for the Rust broker, and writes
provider-specific JSON only after an explicit Allow or Deny. Any launch, authentication,
decoding, transport, timeout, or service-restart error produces no approval
output, so the provider retains control of its native permission flow. The Limpid
Waiting section subscribes only while reconciliation is ready. Codex always
uses the same signed-helper command so panes created before reconciliation do
not retain stale routing or trust state. The helper publishes the lifecycle
fallback itself whenever it delegates the permission decision.

The service executable and property list are installed inside the application
bundle. The app fingerprints both files, validates the service and helper against
the current Team ID and signing identifiers, and obtains the running fingerprint
through the authenticated controller connection. An atomic marker records the
artifact for which replacement started, registration completed, or verification
completed; it is recovery state, not proof of authenticity. A matching running
fingerprint and `registered` or `ready` marker preserve the service PID and epoch,
then complete verification. A `replacing`, missing, corrupt, or mismatched marker
uses asynchronous unregister completion before registering and authenticating
the replacement.

`.requiresApproval` leaves the registration intact and directs the user to Login
Items. Before the first registration on a machine, `SMAppService` reports
`.notFound` rather than `.notRegistered` because Background Task Management has
no record for the label yet; the app has already validated the bundled service
at that point, so it registers instead of reporting a missing service.
`.notFound` after a registration call, signing failures, and other
reconciliation failures disable controller observation. A transient controller
failure with a current marker leaves the registered service and its pending
requests intact and schedules another observation. A slow
unregister reports an error but remains in flight until its completion callback;
registration never races that callback. Returning to the app or choosing Retry
attempts recovery. A rollback uses the same fingerprint mismatch path. Moving an
unchanged app preserves the service because absolute bundle paths are not part of
its identity. Running separate production copies concurrently is unsupported
because they share one production LaunchAgent registration.

Production cleanup must target only `dev.limpid.agent-integration-service` with
the signed disposable app that registered it. Never use a global background-item
reset for Limpid cleanup.
