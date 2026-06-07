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
```

Dependency direction is strictly **App → Core → FFI**. UI may consume
Core models but never reaches into private state; Core never imports
SwiftUI. The agent twin (`Core/Claude` ↔ `Core/Codex`) has zero
cross-module references — each is independent and parallel-shaped.

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
| `Limpid/Core/SurfaceRegistry.swift` | `[UUID: SurfaceView]` mapping — single source of truth for AppKit surface lifetime |
| `Limpid/UI/SurfaceView.swift` | The `NSView` subclass that owns the libghostty surface + Metal layer |
| `Limpid/UI/Pane/PaneHostView.swift` | `NSViewRepresentable` bridging `SurfaceRegistry` ↔ SplitTree |
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

### Forced-override Ghostty config keys

`GhosttyConfigBridge` always emits a fixed set of keys
(`background-opacity=0`, `term=xterm-256color`,
`shell-integration-features=no-cursor`, `confirm-close-surface=false`,
`custom-shader-animation=false`, plus three forced `keybind=` lines)
regardless of user settings — they protect the UI compositor and the
rendering path. Removing one silently breaks the app. See the
forced-overrides comment block in `GhosttyConfigBridge.makeConfigString`.

### Persistence

All four top-level stores (`SessionStore`, `SettingsStore`,
`NotificationHistoryStore`, `FrecencyStore`) route through
`PersistenceCoders.makeEncoder()` / `.makeDecoder()` for JSON shape
consistency and through `PersistenceTiming.interactive` /
`.coalescing` for debounces. `SettingsStore` keeps its own encoder
inline (always pretty-printed) because `settings.json` is the one
file the user is expected to open in an editor.

Per-pane agent stores (`Claude*Store`, `Codex*Store`, `CwdEventStore`)
keep their own tighter config — they write tiny records on the hot
path and the shim writes them in parallel from shell.

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
  `SettingsScene`.
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
