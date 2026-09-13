# Agent Integration Service

This directory contains the bundled, per-user macOS LaunchAgent that hosts the
Rust approval broker. Requester and controller clients use separate Mach
services. Each listener installs a Team ID and signing-identifier requirement
before it accepts a connection, then creates a Rust session with a host-selected
principal.

Normal-user registration is deliberately disabled. A signed Debug build
registers the service on launch. `LIMPID_AGENT_SERVICE_CONTROL` can override
that default while iterating on the bundled executable:

```bash
LIMPID_AGENT_SERVICE_CONTROL=register make dev
LIMPID_AGENT_SERVICE_CONTROL=status make dev
LIMPID_AGENT_SERVICE_CONTROL=refresh make dev
LIMPID_AGENT_SERVICE_CONTROL=unregister make dev
```

Ad hoc-signed builds cannot register because they have no Team ID for the peer
requirements. Debug and Release use distinct LaunchAgent labels, Mach service
names, bundle identifiers, and property lists. Development cleanup must target
only `dev.limpid.agent-integration-service.dev`.

The signed Hook Helper is embedded in the application's `Contents/MacOS`
directory and is the only requester accepted by the Release configuration. In
Debug, the Requester and Controller probe targets also validate the real
development transport. They are not embedded in the application, and their
signing identifiers are accepted only by the Debug service configuration.

Debug Claude and Codex `PermissionRequest` hooks invoke the helper. It translates
provider JSON into the versioned approval protocol, waits for the Rust broker,
and writes provider-specific JSON only after an explicit Allow or Deny. Any
launch, authentication, decoding, transport, timeout, or service-restart error
produces no approval output, so the provider retains control of its native
permission flow. The Limpid Waiting section subscribes to broker changes and
exposes Allow and Deny only in Debug builds for now. Release Codex integration
continues routing `PermissionRequest` through the legacy lifecycle receiver.

The service executable and property list are installed inside the application
bundle. Apple requires a changed registered service to be unregistered before
its replacement is registered. Before normal-user activation, validate that an
installed Sparkle update replaces the bundle, re-registers the service, does
not lose unresolved requests without fail-closed client behavior, and preserves
the expected code-signing requirements.
