# Limpid architecture

A 1-page map of what owns what, the invariants the code depends on,
and the places that are deliberately not yet refactored. Read this
before touching `Limpid/Core/Models/`, the FFI boundary, or any
persistence store — those are the load-bearing surfaces.

For coding conventions (language, comments, lint discipline), see
[`AGENTS.md`](AGENTS.md) §3.

---

## Module map

```
Limpid/
  App/         entry point (LimpidApp), Scene tree, menu commands
  Core/        models, settings, FFI glue, persistence, domain logic
  UI/          SwiftUI views, NSViewRepresentable bridges, design system
  FFI/         libghostty C ABI wrapper (GhosttyFFI)
  Resources/   Info.plist, xcstrings, claude-shim, codex-shim, themes
AgentIntegrationService/
  Service/      launchd-managed macOS XPC host for the Rust approval broker
  Shared/       role-specific XPC contracts, identifiers, and signing policy
  Resources/    Debug and Release LaunchAgent property lists
rust/
  limpid-agent-core/      provider-neutral approval state machine
  limpid-agent-protocol/  versioned wire messages and authenticated sessions
  limpid-rust-bridge/     Rust entry points exposed through a stable C ABI
```

Swift dependencies flow from **App / UI → Core → external boundaries**.
The libghostty boundary lives in `FFI/`; the Rust boundary lives behind
`Core/Rust/LimpidRustBridge.swift` and the C header in
`rust/limpid-rust-bridge/include/`. Rust remains independent of Swift and
Apple frameworks. UI may consume Core models but never reaches into private
state; Core never imports SwiftUI. The agent twin (`Core/Claude` ↔
`Core/Codex`) has zero cross-module references — each is independent and
parallel-shaped.

The bridge-wide ABI number is a compatibility version, not a release or API
revision. Adding a new exported symbol keeps the current number. Increment it
only when an existing symbol's calling convention, exposed layout, ownership
contract, or documented behavior must become incompatible. Prefer a new
version-suffixed symbol, such as `_v2`, when both contracts can coexist.

Verified clean (architecture audit, 2026-06): no circular dependencies,
no `UI/` → `Core/Models/` private internal access, no SwiftUI imports
in `Core/`, no `Settings` ↔ `Persistence` cycles.

---

## Load-bearing files

| File | Owns |
|---|---|
| `Limpid/App/LimpidApp.swift` | Scene tree, command menu, and `AppState` — the process-wide singleton holding registries + trackers |
| `Limpid/Core/Models/WindowSession.swift` | Tab / container / worktree state, the source of truth |
| `Limpid/Core/Models/Tab.swift` + `SplitTree.swift` | Per-tab structure: kind, working dir, split tree, agent sessions |
| `Limpid/Core/Persistence/SessionSnapshot.swift` | The on-disk shape of `state.json` (forward-compat sidecar) |
| `Limpid/Core/Settings/LimpidSettings.swift` | Settings model + section structs, all `Codable` |
| `Limpid/Core/Settings/GhosttyConfigBridge.swift` | Generates the libghostty config string + the forced-override keys |
| `Limpid/Core/GhosttyApp.swift` | Wraps `ghostty_app_t`, runtime callbacks, lifecycle |
| `Limpid/Core/Rust/LimpidRustBridge.swift` | The typed Swift entry point for the versioned Rust C ABI |
| `Limpid/Core/Agent/AgentIntegrationServiceRegistrar.swift` | Explicit Debug-only registration and cleanup for the bundled LaunchAgent |
| `AgentIntegrationService/Service/main.swift` | Role-separated XPC listeners and authenticated principal creation |
| `AgentIntegrationService/Service/RustApprovalHost.swift` | Ownership-safe Swift wrapper around the Rust approval service/session C ABI |
| `AgentIntegrationService/Shared/AgentIntegrationConfiguration.swift` | Debug/Release identifiers and Team ID-bound peer requirements |
| `scripts/build-rust-bridge.sh` | Builds the architecture-specific Rust static library into Xcode DerivedData |
| `Limpid/Core/SurfaceRegistry.swift` | `[UUID: SurfaceView]` mapping — single source of truth for AppKit surface lifetime |
| `Limpid/UI/SurfaceView.swift` | The `NSView` subclass that owns the libghostty surface + Metal layer |
| `Limpid/UI/Pane/PaneHostView.swift` | `NSViewRepresentable` bridging `SurfaceRegistry` ↔ SplitTree |
| `Limpid/Core/Git/PRStatusSyncer.swift` | Schedules forge CLI lookups per sidebar row and writes them into `PRStatusStore` (opt-in; `gh` / `glab`) |
| `Limpid/Core/Review/ReviewStore.swift` | Review state: the comment lifecycle (written → inserted → resolved), read marks, and the draft it restores from |
| `Limpid/Core/Review/ReviewGitCommand.swift` | Every Git read the review makes, and the patch bytes both the change poll and the diff hash |
| `Limpid/Core/Actions/ReviewInsertion.swift` | The order an insert happens in: resolve the pane, validate, deliver, then record |
| `Limpid/Core/Review/ReviewPresentation.swift` | Where review sits in a window, and which terminal it delivers to — following the focused pane until the reader pins one |
| `Limpid/Core/Updates/SparkleUpdater.swift` | Sparkle integration (only `ObservableObject` site has been removed) |

---

## Invariants

### Active-selection invariant

When `WindowSession.activeTabID` is non-nil,
`tabs.first(where: { $0.id == activeTabID })?.container` equals
`activeContainerID`. Maintained by `setActiveTab(_:)` (mirrors the
tab's container) and `setActiveContainer(_:)` (clears `activeTabID`
when the container is empty, otherwise routes via `setActiveTab`).
Legitimate transient violations live in `init`, `restore(from:)`,
and mid-close paths (`closeTab` / `closeTabs(where:)`) that null
out `activeTabID` before the caller picks the next container.

### SurfaceView lifetime

`SurfaceView` instances are held by `SurfaceRegistry` keyed on the
`SplitTree` leaf UUID. SwiftUI rebuilds the surrounding view tree on
tab switches (`PaneAreaView` applies `.id(tab.id)` to force a fresh
layout); the registry's strong reference keeps the surface alive
across those rebuilds. `registry.unregister(_:)` and
`registry.reconcile(activeIDs:)` are called only by destructive
operations (close tab / remove worktree / surface-exit callback) —
never by tab switches.

The libghostty handle (`ghostty_surface_t`) is freed exactly once,
in `SurfaceView.deinit`. The deinit hops to MainActor via
`Task { @MainActor in ghostty_surface_free(s) }` because Swift 6
runs deinits on arbitrary threads.

`SurfaceView.viewDidMoveToWindow` calls `createSurface()` only when
`window != nil`. If AppKit lands the first `viewDidMoveToWindow` with
a nil window (split race, divider drag), `PaneHostView.updateNSView`
retries `createSurface()` on the next layout pass to recover.

### FFI userdata

C callbacks from libghostty pass `UnsafeRawPointer` userdata that
points at a `SurfaceView`. The `SurfaceView` may have deinited
between the callback firing on libghostty's thread and the MainActor
hop landing; `SurfaceView.liveView(forUserdata:)` resolves the
pointer through a weak registry so a freed view returns nil instead
of dereferencing into freed memory.

### Rust ABI boundary

Swift imports Rust only through the C declarations in
`rust/limpid-rust-bridge/include/`. Exported functions use fixed-width C types,
and `limpid_rust_abi_version()` is the compatibility contract checked by the
Swift smoke test. Do not expose Rust layout, ownership, or panic behavior
across this boundary.

The approval host owns one opaque Rust service handle and creates one opaque
session handle per authenticated XPC connection. XPC preserves discrete
`Data` message boundaries, so the bridge exchanges one bounded JSON request
and one allocated JSON response per call rather than reusing the stream
framing adapter. Swift always releases response bytes through the matching
Rust free function. The requester run ID is generated by the host and passed
as fixed 16-byte UUID data; it is never accepted as a claim of authority from
the JSON payload.

Xcode invokes `scripts/build-rust-bridge.sh` on every app build and lets Cargo
own the fine-grained Rust dependency graph. The script places Cargo output in
DerivedData and replaces the linked static library only when its contents
change, so new Rust modules cannot be missed without forcing unchanged Swift
targets to relink.

### Forced-override Ghostty config keys

`GhosttyConfigBridge` always emits a fixed set of keys
(`background-opacity=0`, `term=xterm-256color`,
`shell-integration-features=no-cursor`, `confirm-close-surface=false`,
`custom-shader-animation=false`, `clipboard-paste-protection=true`, plus
three forced `keybind=` lines)
regardless of user settings — they protect the UI compositor and the
rendering path. Removing one silently breaks the app. See the
forced-overrides comment block in `GhosttyConfigBridge.makeConfigString`.

### Persistence

All five top-level stores (`SessionStore`, `SettingsStore`,
`NotificationHistoryStore`, `FrecencyStore`, and the review's
`FileReviewDraftStore`) route through
`PersistenceCoders.makeEncoder()` / `.makeDecoder()` for JSON shape
consistency and `PersistenceTiming.interactive` / `.coalescing` for debounces.
Review navigation metadata is coalesced on a serial write queue; comment
edits wait for storage so a failed save keeps the composer open. `SettingsStore` keeps its own encoder
inline (always pretty-printed) because `settings.json` is the one
file the user is expected to open in an editor.

### Turn review snapshots

At `UserPromptSubmit`, each agent hook copies the worktree's real index into
`<git-dir>/limpid/turn-<pane>.index`, runs `git add -A` against that private
index, writes its tree, and protects the tree with
`refs/limpid/turn/<pane>`. The ref keeps the otherwise-unreachable tree out of
Git's normal garbage collection while the session is active without adding a
commit or changing history. Review never writes that hook index. It refreshes
`turn-<pane>.read.index` instead and compares the recorded tree with the
read-side index through `git diff --cached`, so a reload cannot race the next
prompt snapshot. Both indexes are separate from the real index; user staging
state and `git status` remain untouched.

Project and Worktree review remains repository-scoped as focus moves between
their panes. Turn badges from another repository are not eligible while those
containers are active, even if the shell has changed directory. A turn review
opened from Quick Tabs or a Group is instead owned
by the pane that produced the snapshot: switching tab or pane, closing that
pane, or moving its working directory outside the recorded repository closes
the review. A tmux-hosted owner is the exception: OSC 7 describes the host
shell rather than the active tmux pane, so focus and cwd changes do not close
the review. Insert instead resolves the current hosted pane path and checks its
repository again after comment validation. The same post-validation check runs
for non-tmux owners, so an asynchronous close cannot leave a window for
delivery to an unrelated shell.
While its owner context remains unchanged, the loaded snapshot stays
authoritative when a later prompt records a new tree. The scope control keeps
the exact turn already on screen until the reader explicitly chooses another
scope or jumps to another finished turn. This preserves in-progress comments
and prevents a newer turn label from describing an older diff. A scope request
is refused while the composer contains unsaved text; the reader must save or
cancel it before the loaded diff can change. A turn is
offered after leaving that scope only when
the current destination still carries a matching root and base tree.

Agent lifecycle stores are runtime-scoped: one UUID per shim invocation, with
tmux socket/server-generation/pane metadata when a multiplexer sits between the
agent and Limpid. Hooks never query tmux; `TmuxTopology` resolves current pane
membership (including linked windows), and `TmuxPanePresence` joins clients to
surface ttys. Unresolved tmux records never fall back to a launch pane or saved
restore binding. `AgentRuntimePresentation` retains each invocation through
notification and Attention processing; badges are only the final reduction.
Native resume hints remain pane-scoped but carry the owning run ID; hooks and
cleanup coordinate through `AgentFileLock` / macOS `lockf`. tmux hooks do not
overwrite native resume hints. Cwd event stores still remain pane-scoped. All keep
their own tighter config — they write tiny records on the hot path and the shim
writes them in parallel from shell.

Forward-compat shape (Phase 4-15 of relaunch):

- Defensive `init(from:)` for every `Codable` enum with an
  `unknownFallback` case (`Tab.Kind`, `ConfirmPolicy`, `ContainerID`)
- `LimpidJSONValue` sidecar carrying unknown fields through round
  trips (`SessionSnapshot`, `LimpidSettings` and section structs)
- `tabs: {UUID: Tab}` + `tabOrder: [UUID]` shape on `SessionSnapshot`
  so reorder doesn't churn the whole tab block
- `[.sortedKeys]` everywhere for clean diffs

---

## How to add X

Quick pointers — the touch points are deliberately concentrated so
`grep` finds them. Defensive `Codable` decoders mean an older build
reading a newer file degrades cleanly.

- **New `Tab.Kind`** — case in `Tab.swift` (decoder routes unknown to
  `.terminal`); branch `PaneAreaView` / `TerminalColumnView` if it
  doesn't render as a terminal.
- **New container kind** — case in `ContainerID` (decoder folds to
  `.loose`). ~15 consumers: `WindowSession.{setActiveContainer,
  containerExists, containerLabel, lastActiveTabID, rememberLastActive,
  forgetLastActive}`, `WindowSession+Containers.{cycleTopLevelContainer,
  activateTopLevelContainer}`, `WindowSession+Tabs.tabs(in:)`,
  `SessionSnapshot` container-pruning, sidebar section view +
  `MoveDropDelegate`, `GhosttyEventCoordinator.{closeSurface, gotoTab}`,
  `SessionSnapshotTests` + `WindowSessionFixture`.
- **New Ghostty event** — wire callback in `GhosttyApp.swift`
  (`wakeupCallback` pattern), add case to `GhosttyEvent` in
  `GhosttyActionRouter.swift`, decode it there, then handle in
  `GhosttyEventCoordinator.dispatch(_:)`.
- **New settings section** — `Codable` struct in `LimpidSettings.swift`
  with `unknownFields` + `CodingKeys: CaseIterable`, add property to
  `LimpidSettings`, drop pane in `UI/Settings/Panes/`, register in
  `SettingsScene`, and add every searchable row to
  `SettingsSearchCatalog` with the same stable anchor ID used by its view.
- **New keyboard shortcut** — case in `LimpidShortcutAction` (5
  compiler-enforced spots: `defaultShortcut`, `localizedTitle`,
  `category`, `iconName`, `ghosttyAction`), menu bar `Button` in
  `LimpidApp.commands`, case in
  `TabActions.dispatch<Category>Action`.
- **New agent CLI** — record + store typealias under `Core/<Agent>/`,
  `AgentSpec` conformer in `Core/Agent/<Agent>Agent.swift`, tab fields
  on `Tab.swift`, tracker typealiases, shim under `Resources/<agent>-shim/`,
  trackers instantiated in `AppState.init`. ~200-300 LOC.

---

## See also

- [`AGENTS.md`](AGENTS.md) §3 — Swift conventions a linter can't enforce
- [`CONTRIBUTING.md`](CONTRIBUTING.md) — PR conventions, branch
  prefixes, commit message style
