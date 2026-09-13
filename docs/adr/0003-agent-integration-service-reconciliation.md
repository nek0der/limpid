# ADR 0003: Agent Integration Service Reconciliation

- Status: Accepted.
- Date: 2026-09-13.

## Context

The approval service outlives the Limpid GUI. Ordinary quit and relaunch must
therefore preserve its process, epoch, and pending requests. A Sparkle update,
rollback, or interrupted replacement can instead leave an `SMAppService`
registration or process associated with a different bundled executable.

`SMAppService.Status` reports eligibility and approval state but not the version,
path, or process identity of the registered artifact. `BundleProgram` supports
application relocation, so an absolute bundle path is also the wrong identity.
Apple requires changed property lists and executables to be re-registered and
recommends unregistering a changed executable first. The asynchronous unregister
completion is the boundary after which the old process has been killed and
re-registration is safe.

## Decision

Limpid fingerprints the SHA-256 content of its bundled service executable and
LaunchAgent property list. The service computes the same identity at process
startup and retains it in memory. It returns the identity through the controller
session bootstrap, after XPC has authenticated the service's Team ID and signing
identifier. Before registration, the app separately validates the bundled service
and Hook Helper signatures against its current Team ID and their expected signing
identifiers.

An atomic `0600` marker under the build-specific Application Support directory
records `replacing`, `registered`, or `ready`, the artifact identity, and the app
build version.
The marker proves only that this app started a registration attempt; it is not an
authentication credential. A healthy registration is retained only when the
status is `.enabled`, the authenticated running artifact matches the bundle, and
the marker names that artifact. A matching `registered` marker is completed as
`ready` after authentication, which covers a process exit immediately after
registration. `replacing` means unregister or registration was not known to have
completed. A replacing, missing, corrupt, or mismatched marker causes one
deliberate repair.

Reconciliation applies the following actions:

| Status and evidence | Action |
| --- | --- |
| `.notRegistered` | Write `replacing`, register, write `registered`, authenticate the running artifact, then write `ready`. |
| `.enabled` with matching running artifact and `registered` or `ready` marker | Keep the service process, PID, epoch, and pending requests; complete the marker as `ready`. |
| `.enabled` with any artifact or marker mismatch | Write `replacing`, await asynchronous unregister completion, register, write `registered`, authenticate, then write `ready`. |
| `.enabled` with an unreachable controller and current `registered` or `ready` marker | Keep the service and pending requests, disable controller observation, and retry. A marker mismatch remains explicit replacement evidence. |
| `.requiresApproval` | Keep the registration, disable native routing, and direct the user to Login Items. Retry when the app becomes active. |
| `.notFound` or unknown status | Disable native routing and expose a recoverable error. Do not treat it as unregistered. |

The same content comparison handles upgrades, downgrades, and rollbacks. Moving
an unchanged app does not replace the service because paths are excluded from the
identity. If execution stops before unregister, `replacing` forces repair even
when launchd has lazily started a current executable against an older registered
property list. If it stops after unregister and before register, the next launch
observes `.notRegistered`. If it stops after writing `registered` and before
`ready`, the matching authenticated artifact completes the interrupted attempt
without resetting a pending Login Items approval. A slow unregister keeps
reconciliation in flight and never proceeds to registration until the OS
completion callback.

Controller observation starts only after the replacement has been authenticated
and stops on a later reconciliation failure. Codex uses one stable Helper command
for every pane. The signed Helper independently compares the authenticated
service artifact with its own bundle on every request and publishes Codex's
lifecycle fallback when it emits no approval decision. Claude's helper also emits
no decision on failure, so the provider retains its native permission flow.
Restarting the service changes
the Rust-owned epoch; requests and controller actions from the prior epoch cannot
authorize the new process.

## Consequences

An update that changes the service loses its in-memory pending requests, but every
requester fails closed and no old decision crosses the epoch boundary. Ordinary
launches do not restart a healthy service. Corrupting or deleting the marker can
cause one safe extra restart but cannot establish trust.

Debug and Release use separate identifiers, endpoints, property lists, markers,
and Application Support directories. Multiple concurrently running copies of the
same production identity are unsupported because macOS provides one registration
for that per-user label. Update verification must use one disposable production
copy at a time and restore the prior registration and data state exactly.

## References

- [Apple `SMAppService`](https://developer.apple.com/documentation/servicemanagement/smappservice).
- [Apple `SMAppService.unregister(completionHandler:)`](https://developer.apple.com/documentation/servicemanagement/smappservice/unregister(completionhandler:)).
- [Apple Updating Mac Software](https://developer.apple.com/documentation/security/updating-mac-software).
- [ADR 0001](0001-agent-integration-service.md).
- [ADR 0002](0002-portable-agent-integration-core.md).
