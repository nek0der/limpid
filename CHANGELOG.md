# Changelog

All notable changes to Limpid are documented here. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

Baseline implementation:

- Embedded `libghostty` terminal surface via the upstream Ghostty C ABI: full keyboard / mouse / IME (preedit and marked text) input, scrollback persistence across relaunches, pane-scoped `⌘F` search, and DPI-aware Metal rendering.
- macOS 26 Notes-2026-style three-pane sidebar: L1 slab (Tabs / Groups / Projects), L2 list, L3 pane area. Liquid Glass chrome on the slab, drag-resizable L2 column.
- Tabs / Groups / Projects model with stable IDs, drag reordering, palette accent colors, and JSON session restoration (`state.json` under `Application Support/Limpid/`).
- Git worktree CRUD wired into Projects: create / delete / hide, three placement strategies (`siblingPrefixed`, `insideHidden`, `custom`), `git worktree list` reconciliation by `GitSyncCoordinator`.
- Notification system: in-pane bell flash + Dock badge + history popover (`notifications.json`), Trojan-source-aware sanitizer, per-pane focus-aware suppression.
- Settings window with live reload of font / theme / scrollback / cursor / bell preferences, plus `settings.json` file watcher for external edits.
- Sparkle auto-update wiring: EdDSA-signed appcast at `https://nek0der.github.io/limpid/appcast.xml`, `SUVerifyUpdateBeforeExtraction = YES`.
- en + ja localization via `Localizable.xcstrings`.
- OSC 52 / unsafe-paste confirmation sheet — terminal-issued clipboard reads now require explicit user consent instead of being auto-approved.
- OSS infrastructure: `LICENSE` (MIT), `CONTRIBUTING.md`, `CHANGELOG.md`, `SECURITY.md`, `CODE_OF_CONDUCT.md`, GitHub issue + PR templates, CI workflow (`.github/workflows/ci.yml`), SwiftLint (`.swiftlint.yml`) and SwiftFormat (`.swiftformat`) configs.
- App icon (turquoise water drop) and SVG source under `design/`.

### Developer experience

- Debug builds now use bundle id `dev.limpid.Limpid.dev`, display name "Limpid Dev", and store data under `~/Library/Application Support/Limpid Dev/`, so an Xcode-driven Debug session and the installed dmg release coexist on the same Mac without colliding over `state.json`, `notifications.json`, `scrollback/`, or `settings.json`. Sparkle auto-checks are disabled in Debug builds so the runner doesn't get auto-replaced mid-session.

### Security

- Session, notification, and scrollback files are now written with `0600` permissions and parent directories with `0700`.
- OSLog statements that previously emitted user content (`SET_TITLE`, `PWD`, `START_SEARCH needle`, `DESKTOP_NOTIFICATION` title, scrollback path) are marked `privacy: .private` so they no longer leak into unified log / sysdiagnose archives.
- Removed the hard-coded `~/personal/limpid/...` dev-fallback path from `GhosttyApp.resolveResourcesDir`; dev builds now use the `LIMPID_GHOSTTY_RESOURCES` environment override exclusively.

### Performance

- Split transient per-pane state (`isBellRinging`, `childExitCode`) off `Tab.paneStates` onto `WindowSession.paneTransients` so bell flashes no longer trigger autosave.
- Window-wide unread total is now an incrementally maintained cache; `DockBadgeSync` reads it instead of walking every pane on every mutation.
- `SurfaceView.syncLayerOnly` short-circuits when bounds + backing scale haven't changed, killing redundant `CATransaction`s during window drag.
- `SessionStore` / `NotificationHistoryStore` encode and write on a background queue and skip `.prettyPrinted` in Release builds.

[Unreleased]: https://github.com/nek0der/limpid/commits/main
