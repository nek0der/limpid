# Changelog

All notable changes to Limpid are documented here. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - 2026-05-24

Initial public release.

### Added

- Embedded `libghostty` terminal surface via the upstream Ghostty C ABI: full keyboard / mouse / IME (preedit and marked text) input, scrollback persistence across relaunches, pane-scoped `⌘F` search, and DPI-aware Metal rendering.
- macOS 26 Notes-2026-style three-pane sidebar: L1 slab (Tabs / Groups / Projects), L2 list, L3 pane area. Liquid Glass chrome on the slab, drag-resizable L2 column.
- Tabs / Groups / Projects model with stable IDs, drag reordering, palette accent colors, and JSON session restoration (`state.json` under `Application Support/Limpid/`).
- Git worktree CRUD wired into Projects: create / delete / hide, three placement strategies (`siblingPrefixed`, `insideHidden`, `custom`), `git worktree list` reconciliation by `GitSyncCoordinator`.
- Notification system: in-pane bell flash + Dock badge + history popover (`notifications.json`), Trojan-source-aware sanitizer, per-pane focus-aware suppression.
- Settings window with live reload of font / theme / scrollback / cursor / bell preferences, plus `settings.json` file watcher for external edits.
- Sparkle auto-update wiring: EdDSA-signed appcast at `https://nek0der.github.io/limpid/appcast.xml`, `SUVerifyUpdateBeforeExtraction = YES`.
- en + ja localization via `Localizable.xcstrings`.
- OSC 52 / unsafe-paste confirmation sheet — terminal-issued clipboard reads require explicit user consent instead of being auto-approved.
- Session, notification, and scrollback files are written with `0600` permissions and parent directories with `0700`; OSLog statements that emit user content are marked `privacy: .private` so they don't leak into unified log / sysdiagnose archives.
- App icon (turquoise water drop) and SVG source under `design/`.
- OSS infrastructure: `LICENSE` (MIT), `CONTRIBUTING.md`, `CHANGELOG.md`, `SECURITY.md`, `CODE_OF_CONDUCT.md`, GitHub issue + PR templates, CI workflow (`.github/workflows/ci.yml`), SwiftLint (`.swiftlint.yml`) and SwiftFormat (`.swiftformat`) configs.

### Notes for developers

- Debug builds use bundle id `dev.limpid.Limpid.dev`, display name "Limpid Dev", and store data under `~/Library/Application Support/Limpid Dev/`, so an Xcode-driven Debug session and the installed dmg release coexist on the same Mac without colliding over `state.json`, `notifications.json`, `scrollback/`, or `settings.json`. Sparkle auto-checks are disabled in Debug builds so the runner doesn't get auto-replaced mid-session.

[Unreleased]: https://github.com/nek0der/limpid/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/nek0der/limpid/releases/tag/v0.1.0
