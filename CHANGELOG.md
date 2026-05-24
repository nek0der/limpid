# Changelog

All notable changes to Limpid are documented here. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.1](https://github.com/nek0der/limpid/compare/v0.1.0...v0.1.1) (2026-05-24)


### Bug Fixes

* **ci:** chain release.yml dispatch from release-please ([#10](https://github.com/nek0der/limpid/issues/10)) ([603f8a4](https://github.com/nek0der/limpid/commit/603f8a40009be1187872b11b0cc32d635830e8d8))
* **ci:** initialize CodeQL after libghostty build, not before ([#14](https://github.com/nek0der/limpid/issues/14)) ([2cc80e5](https://github.com/nek0der/limpid/commit/2cc80e523a38c69d9814bccc8d44e3c487d61294))
* **ci:** stop running CodeQL on every pull request ([#12](https://github.com/nek0der/limpid/issues/12)) ([5b8fde3](https://github.com/nek0der/limpid/commit/5b8fde3065ec02556e2583614da547b8cda3407c))
* **release:** publish release notes .md alongside appcast.xml ([#16](https://github.com/nek0der/limpid/issues/16)) ([9688d16](https://github.com/nek0der/limpid/commit/9688d16c6c0fb10c88884c69d52f08149168b7fa))
* **sidebar:** drop project-header body tap to prevent rapid-click freeze ([#18](https://github.com/nek0der/limpid/issues/18)) ([98c78cc](https://github.com/nek0der/limpid/commit/98c78cc5969b1426260a08cd047546800bf08841))
* **ui:** preserve scrollback + state on ⌘Q quit ([#17](https://github.com/nek0der/limpid/issues/17)) ([4118ff5](https://github.com/nek0der/limpid/commit/4118ff57ad2c718f6c1843c2cd81c66095b4bb5a))

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
