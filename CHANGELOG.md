# Changelog

All notable changes to Limpid are documented here. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.15](https://github.com/nek0der/limpid/compare/v0.1.14...v0.1.15) (2026-05-31)


### Features

* **worktree:** extend project-policy worktree routing to Codex CLI ([#106](https://github.com/nek0der/limpid/issues/106)) ([59069d6](https://github.com/nek0der/limpid/commit/59069d60fb5d27a8d6ed9e7aec6563c9dea4fa37))
* **worktree:** keep Claude-initiated worktrees on project policy ([#104](https://github.com/nek0der/limpid/issues/104)) ([81eb118](https://github.com/nek0der/limpid/commit/81eb1185a9c007d7a84e6e1e015131664fbb7bb3))


### Bug Fixes

* **chrome:** give L3 container title a min width ([#102](https://github.com/nek0der/limpid/issues/102)) ([29b7337](https://github.com/nek0der/limpid/commit/29b7337e09d06dcc4dca8a40195f785af40b6eb7))
* **triage:** demote viewed-finished below running in L1/L2 aggregate ([#105](https://github.com/nek0der/limpid/issues/105)) ([ef183a0](https://github.com/nek0der/limpid/commit/ef183a065e8347847355beef57420d98ab40cc0d))

## [0.1.14](https://github.com/nek0der/limpid/compare/v0.1.13...v0.1.14) (2026-05-31)


### Features

* **worktree:** suggest reparenting when Claude cd's into a worktree ([#101](https://github.com/nek0der/limpid/issues/101)) ([2271297](https://github.com/nek0der/limpid/commit/22712972d9d7b4f1d844ff18eb8a4a8d4be049d8))


### Bug Fixes

* **terminal:** improve ANSI palette contrast in both appearances ([#98](https://github.com/nek0der/limpid/issues/98)) ([686f387](https://github.com/nek0der/limpid/commit/686f3872dc215688a6a66e62a4f27742b1807682))
* **triage:** align ⌘J cursor and menu state with the WAITING list ([#100](https://github.com/nek0der/limpid/issues/100)) ([a74f807](https://github.com/nek0der/limpid/commit/a74f807cbf392f0a8ded314017976d072e6c4de3))

## [0.1.13](https://github.com/nek0der/limpid/compare/v0.1.12...v0.1.13) (2026-05-30)


### Bug Fixes

* **chrome:** tighten L2 overlap and tab + palette polish ([#95](https://github.com/nek0der/limpid/issues/95)) ([89058de](https://github.com/nek0der/limpid/commit/89058de1bf5300b9d259a436561c5441bcebfe8d))


### Documentation

* **readme:** rework hero with WAITING + Agents demo ([#97](https://github.com/nek0der/limpid/issues/97)) ([1aa9f8f](https://github.com/nek0der/limpid/commit/1aa9f8f7e00bc0a56b595004f6b3c08e9bc909b9))

## [0.1.12](https://github.com/nek0der/limpid/compare/v0.1.11...v0.1.12) (2026-05-30)


### Features

* **chrome:** scale up header icons and L1 markers to Apple's metrics ([#92](https://github.com/nek0der/limpid/issues/92)) ([3a44e4f](https://github.com/nek0der/limpid/commit/3a44e4f52b3c2779631be1f12b79b58fe995b84f))
* **tab:** name tabs from the agent conversation ([#93](https://github.com/nek0der/limpid/issues/93)) ([4704189](https://github.com/nek0der/limpid/commit/4704189f1ac24bd8f5f4935c52601454bbde31f5))
* **transparency:** follow the system Reduce Transparency flag live ([#90](https://github.com/nek0der/limpid/issues/90)) ([36714f1](https://github.com/nek0der/limpid/commit/36714f18731391a0bba42489c6c2f399910cba25))
* **triage:** cross-pane WAITING list and ⌘J cursor ([#94](https://github.com/nek0der/limpid/issues/94)) ([6e46cdb](https://github.com/nek0der/limpid/commit/6e46cdb0ed7c381dc707c9436c3c7f9f020b26b4))


### Bug Fixes

* **codex:** only export CODEX_HOME when the shadow dir exists ([#91](https://github.com/nek0der/limpid/issues/91)) ([f800c38](https://github.com/nek0der/limpid/commit/f800c388460b9141b3832a66bedb97777d6d7805))
* **ime:** keep navigation keys with the IME while composing ([#88](https://github.com/nek0der/limpid/issues/88)) ([83b0eec](https://github.com/nek0der/limpid/commit/83b0eecc3788708077f4add7eff329487f01c328))

## [0.1.11](https://github.com/nek0der/limpid/compare/v0.1.10...v0.1.11) (2026-05-30)


### Features

* **tab:** add vertical/horizontal L2 tab layout toggle ([#81](https://github.com/nek0der/limpid/issues/81)) ([50f9e72](https://github.com/nek0der/limpid/commit/50f9e7201b3ee7f99fff3bd3d0d32f53f8f71bbe))
* **welcome:** add a command list to the empty detail pane ([#83](https://github.com/nek0der/limpid/issues/83)) ([8614df3](https://github.com/nek0der/limpid/commit/8614df3af357df13d40ff3979c2d515c05363732))


### Bug Fixes

* **ci:** use generic macOS destination for CodeQL build ([#80](https://github.com/nek0der/limpid/issues/80)) ([62f1368](https://github.com/nek0der/limpid/commit/62f13684345d406b3f190f3055d9c6a2b519cc12))
* **confirm:** keep quit alert frontmost when app is in background ([#82](https://github.com/nek0der/limpid/issues/82)) ([e0d360f](https://github.com/nek0der/limpid/commit/e0d360fd1acfb975de7eec284bdc4307cadfc7f7))
* **energy:** reduce idle power by stopping hidden surface renderers ([#84](https://github.com/nek0der/limpid/issues/84)) ([8885c7d](https://github.com/nek0der/limpid/commit/8885c7db378b1efdd52acebaaaf58c26e63885fb))
* **split:** eliminate divider-cursor drift during pane resize ([#86](https://github.com/nek0der/limpid/issues/86)) ([8293597](https://github.com/nek0der/limpid/commit/8293597fdafe6080da3c97cebd6adfb542e900a4))
* **tab:** keep L2 reorder result on drop instead of bouncing to bottom ([#78](https://github.com/nek0der/limpid/issues/78)) ([09e6a65](https://github.com/nek0der/limpid/commit/09e6a65bec1d8ce280c9e07da98eb876e3b8bdd7))


### Refactors

* **tab:** unify session terminology to tab ([#85](https://github.com/nek0der/limpid/issues/85)) ([7fed297](https://github.com/nek0der/limpid/commit/7fed297475267ebac3efd98a997e896399e9bf5f))

## [0.1.10](https://github.com/nek0der/limpid/compare/v0.1.9...v0.1.10) (2026-05-28)


### Features

* **command-palette:** add prefix modes and Quick Open shortcut ([#75](https://github.com/nek0der/limpid/issues/75)) ([40386d8](https://github.com/nek0der/limpid/commit/40386d818af0919666ebbb17b1d3d9ff9a52721e))


### Bug Fixes

* **chrome:** add L3 palette leading padding and L2/L3 divider ([#73](https://github.com/nek0der/limpid/issues/73)) ([b8dfd9f](https://github.com/nek0der/limpid/commit/b8dfd9f297d0c05b46d1a85dd7ca4a9dbbece4d1))
* **ci:** gate build on lint and remove dead code ([#76](https://github.com/nek0der/limpid/issues/76)) ([65fdd19](https://github.com/nek0der/limpid/commit/65fdd19b3d347c99c2fc0111407d368868066274))
* **ime:** preserve composed text when Shift+Enter confirms IME ([#77](https://github.com/nek0der/limpid/issues/77)) ([a273c65](https://github.com/nek0der/limpid/commit/a273c65af95e48b4c925c1c3b9850f1ff8c7be8a))

## [0.1.9](https://github.com/nek0der/limpid/compare/v0.1.8...v0.1.9) (2026-05-28)


### Features

* **codex:** add Codex CLI integration parallel to Claude ([#66](https://github.com/nek0der/limpid/issues/66)) ([45da76f](https://github.com/nek0der/limpid/commit/45da76fece957534e5983f0028fbf43d33ae63ec))
* **command-palette:** add inline command palette with fuzzy search ([#71](https://github.com/nek0der/limpid/issues/71)) ([5b86e25](https://github.com/nek0der/limpid/commit/5b86e251cf7ca2d2fe033011b0756793706aa5a5))
* **confirmations:** agent-aware quit + tab/pane close prompts ([#63](https://github.com/nek0der/limpid/issues/63)) ([41069e5](https://github.com/nek0der/limpid/commit/41069e50ffa95a8340c6cab5f2425393bd1a2324))
* **keyboard:** user-rebindable shortcuts via single source of truth ([#57](https://github.com/nek0der/limpid/issues/57)) ([d8ddccb](https://github.com/nek0der/limpid/commit/d8ddccbd285c77f9b03fae1864d41075d5d8b5fd))
* **pane:** add right-click context menu on terminal surfaces ([#69](https://github.com/nek0der/limpid/issues/69)) ([983658c](https://github.com/nek0der/limpid/commit/983658caca54ac786c8b2abb15816b22eca1933d))
* **terminal:** add essential terminal features ([#70](https://github.com/nek0der/limpid/issues/70)) ([fc2fffd](https://github.com/nek0der/limpid/commit/fc2fffde472fea19911b383a8e7b7e201db25010))


### Bug Fixes

* **claude:** drop --continue fallback from resume chain ([#62](https://github.com/nek0der/limpid/issues/62)) ([5217bd8](https://github.com/nek0der/limpid/commit/5217bd8af99c8aabb4993fa74ab47b95ce94d682))
* **keyboard:** drop libghostty keybinds for menu-owned actions ([#59](https://github.com/nek0der/limpid/issues/59)) ([ac972e4](https://github.com/nek0der/limpid/commit/ac972e4c17e6bfea9eba92871fa6332913b0c16b))
* **keyboard:** route per-pane shortcuts to the focused pane ([#60](https://github.com/nek0der/limpid/issues/60)) ([ff8eaba](https://github.com/nek0der/limpid/commit/ff8eaba6abd6373f295b8deaffbe508b13fec8a5))
* **keyboard:** stop forwarding IME-consumed keystrokes without modifiers ([#65](https://github.com/nek0der/limpid/issues/65)) ([0933286](https://github.com/nek0der/limpid/commit/0933286b42459e24d00ba25eab1c44e2f9f9e965))
* **lint:** resolve SwiftLint errors blocking CI ([#72](https://github.com/nek0der/limpid/issues/72)) ([90b735a](https://github.com/nek0der/limpid/commit/90b735a05ff14b1b47bc91fc72d9a5e373c61190))
* **shell:** redirect HISTFILE off the read-only claude-shim bundle ([#64](https://github.com/nek0der/limpid/issues/64)) ([5197519](https://github.com/nek0der/limpid/commit/5197519c5a863e19439738977dee6ec8fb113598))
* **sidebar:** clarify project header role when worktree is selected or list is expanded ([#61](https://github.com/nek0der/limpid/issues/61)) ([f44d25c](https://github.com/nek0der/limpid/commit/f44d25ce8d1873725894de07092a4c38640d88c8))


### Refactors

* **agent:** unify Claude+Codex state behind AgentKind ([#68](https://github.com/nek0der/limpid/issues/68)) ([d5cc44b](https://github.com/nek0der/limpid/commit/d5cc44bb7e230bdaf35ab86fb6604d357611b340))

## [0.1.8](https://github.com/nek0der/limpid/compare/v0.1.7...v0.1.8) (2026-05-27)


### Features

* **sidebar:** mark L2 tab rows with an AI vs terminal identity glyph ([#52](https://github.com/nek0der/limpid/issues/52)) ([52ed198](https://github.com/nek0der/limpid/commit/52ed198285aec44f9d44ce7b3db5d54bb8a92b24))


### Bug Fixes

* **update:** swiftformat spaceAroundOperators on range literals ([#55](https://github.com/nek0der/limpid/issues/55)) ([f26ee6d](https://github.com/nek0der/limpid/commit/f26ee6dffe53120f0e3cce73e3feeb26bf5bce18))

## [0.1.7](https://github.com/nek0der/limpid/compare/v0.1.6...v0.1.7) (2026-05-26)


### Features

* **update:** replace Sparkle modal with inline chrome bubble + state machine ([#53](https://github.com/nek0der/limpid/issues/53)) ([457ff18](https://github.com/nek0der/limpid/commit/457ff187ccce0780d0ab62d56d710a8e7640e55d))

## [0.1.6](https://github.com/nek0der/limpid/compare/v0.1.5...v0.1.6) (2026-05-26)


### Features

* **claude:** Claude Code resume, live agent state, and UI polish ([#43](https://github.com/nek0der/limpid/issues/43)) ([c24e0f2](https://github.com/nek0der/limpid/commit/c24e0f2a00774d53d9c76560ae10f59fcc5ce0a2))
* **claude:** per-pane prompt history sidebar with jump-to-prompt ([#46](https://github.com/nek0der/limpid/issues/46)) ([132c143](https://github.com/nek0der/limpid/commit/132c143d0429ea13a1037ecf547f20718907bad5))
* **settings:** unify project/group settings and add default working directory ([#48](https://github.com/nek0der/limpid/issues/48)) ([e28c6c3](https://github.com/nek0der/limpid/commit/e28c6c33628e424bccad3592500f3e74faf6a59e))


### Bug Fixes

* **l2:** make tab activation tap fire immediately ([#50](https://github.com/nek0der/limpid/issues/50)) ([52ee818](https://github.com/nek0der/limpid/commit/52ee818a010fa0ee0447fa8a9e110d0713826a7c))
* **shell:** activate ghostty shell integration for OSC 7 cwd reporting ([#47](https://github.com/nek0der/limpid/issues/47)) ([becc37e](https://github.com/nek0der/limpid/commit/becc37ea1ed51ad479f687f35f47a897a6a60d2b))


### Reverts

* feat(claude): per-pane prompt history sidebar ([#46](https://github.com/nek0der/limpid/issues/46)) ([#49](https://github.com/nek0der/limpid/issues/49)) ([628caef](https://github.com/nek0der/limpid/commit/628caefc8ec842eb503e420f5336de72e32962c9))


### Documentation

* **agents:** tighten language rule and codify commit scope conventions ([#44](https://github.com/nek0der/limpid/issues/44)) ([ef1fc39](https://github.com/nek0der/limpid/commit/ef1fc393eddef0b7400502103149fcd2f94ed9b3))

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
