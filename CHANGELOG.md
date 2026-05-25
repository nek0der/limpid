# Changelog

All notable changes to Limpid are documented here. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.5](https://github.com/nek0der/limpid/compare/v0.1.4...v0.1.5) (2026-05-25)


### Features

* **appearance:** macOS light/dark tracking and Appearance preference ([#32](https://github.com/nek0der/limpid/issues/32)) ([f79cdc0](https://github.com/nek0der/limpid/commit/f79cdc0572108d08bff328ae86efa88c644c68a5))


### Bug Fixes

* **lint:** clean up SwiftFormat violations from [#34](https://github.com/nek0der/limpid/issues/34) ([#39](https://github.com/nek0der/limpid/issues/39)) ([5258bba](https://github.com/nek0der/limpid/commit/5258bbad2668f6bf2bb3c6288f49a09f38f4ac5b))
* **notification:** drop permission guard that races with OS prompt ([#37](https://github.com/nek0der/limpid/issues/37)) ([b468104](https://github.com/nek0der/limpid/commit/b468104ecbb5029cdfd81c15b53b970d64ba706e))
* **notification:** fail closed when pane id is missing ([#38](https://github.com/nek0der/limpid/issues/38)) ([8a047e4](https://github.com/nek0der/limpid/commit/8a047e40b77dd00e9ddb3870401c3dcb1e174527))
* **notification:** replace duplicate banners by pinning identifier to paneID ([#36](https://github.com/nek0der/limpid/issues/36)) ([0b1eb49](https://github.com/nek0der/limpid/commit/0b1eb49865f775a004316ef8f4685a853527e61f))
* **notification:** route taps back to the originating pane ([#34](https://github.com/nek0der/limpid/issues/34)) ([0df94fd](https://github.com/nek0der/limpid/commit/0df94fdb776fae979861590d001e734efc1b1ae3))
* **project:** collapse non-git project rows into a single tappable header ([#40](https://github.com/nek0der/limpid/issues/40)) ([1a0d273](https://github.com/nek0der/limpid/commit/1a0d273c2e3ab2626c5ef3e969d1ea1be4e30fd0))
* **project:** resolve linked worktree paths to the main checkout on Add ([#41](https://github.com/nek0der/limpid/issues/41)) ([86765cf](https://github.com/nek0der/limpid/commit/86765cf801aae1c0637ba3e4ea6971e3178bb1a5))
* **sidebar:** expand rename hit area to the full row width ([#42](https://github.com/nek0der/limpid/issues/42)) ([6f526b3](https://github.com/nek0der/limpid/commit/6f526b3992df1af0829b00fdf064db90bce485ba))
* **tab:** keep L2 view in place when dragging tabs across containers ([#35](https://github.com/nek0der/limpid/issues/35)) ([7b45add](https://github.com/nek0der/limpid/commit/7b45add3fc09a97422eead58545af2bad85a1845))

## [0.1.4](https://github.com/nek0der/limpid/compare/v0.1.3...v0.1.4) (2026-05-25)


### Features

* **pane:** equalize splits, zoom toggle, directional focus ([#26](https://github.com/nek0der/limpid/issues/26)) ([9b2eb06](https://github.com/nek0der/limpid/commit/9b2eb060b7f5da98e94e3610e56aa1e272180eba))
* **tab:** rename and reopen closed tab ([#31](https://github.com/nek0der/limpid/issues/31)) ([9ee8884](https://github.com/nek0der/limpid/commit/9ee88843ffa689b779cfd09572d2bf26c8d27e18))


### Bug Fixes

* **keybind:** map shift+enter to a literal newline ([#24](https://github.com/nek0der/limpid/issues/24)) ([849305b](https://github.com/nek0der/limpid/commit/849305b61987a94351cd735da8a6b659aa47759b))
* **makefile:** stop quitting the installed Release app on `make run` ([#29](https://github.com/nek0der/limpid/issues/29)) ([6f1da9f](https://github.com/nek0der/limpid/commit/6f1da9f2e0d3ceabd59022d142f98fd1433d2191))
* **resize:** drop the 150 ms debounce on libghostty surface size pushes ([#30](https://github.com/nek0der/limpid/issues/30)) ([b199a8d](https://github.com/nek0der/limpid/commit/b199a8d5ecf97efde847e0d0a156c02d55edc3cb))


### Documentation

* **rules:** commit + PR body English-only, PR must follow template ([#27](https://github.com/nek0der/limpid/issues/27)) ([8091a63](https://github.com/nek0der/limpid/commit/8091a63ed6c6525e6b5fafc6db4443cc748611c1))

## [0.1.3](https://github.com/nek0der/limpid/compare/v0.1.2...v0.1.3) (2026-05-24)


### Bug Fixes

* **ci:** drop dispatch step so release.yml fires only once per tag ([#22](https://github.com/nek0der/limpid/issues/22)) ([85b85bd](https://github.com/nek0der/limpid/commit/85b85bd2cdb4d238e22a58d3bc76b5dc7d03715f))

## [0.1.2](https://github.com/nek0der/limpid/compare/v0.1.1...v0.1.2) (2026-05-24)


### Bug Fixes

* **ci:** keep NSSupports*Termination off in project.yml ([#20](https://github.com/nek0der/limpid/issues/20)) ([84f119e](https://github.com/nek0der/limpid/commit/84f119e2b110eac12d78019c5ff99d6bf8ed4b75))
* **ci:** use PAT for release-please so release PRs trigger CI ([#19](https://github.com/nek0der/limpid/issues/19)) ([1c7985b](https://github.com/nek0der/limpid/commit/1c7985b9fb8b816cecd433c8d0a3d98e99eae3cd))

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
