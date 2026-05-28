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

## What's Changed
* feat(keyboard): user-rebindable shortcuts via single source of truth by @nek0der in https://github.com/nek0der/limpid/pull/57
* fix(keyboard): drop libghostty keybinds for menu-owned actions by @nek0der in https://github.com/nek0der/limpid/pull/59
* fix(keyboard): route per-pane shortcuts to the focused pane by @nek0der in https://github.com/nek0der/limpid/pull/60
* fix(sidebar): clarify project header role when worktree is selected or list is expanded by @nek0der in https://github.com/nek0der/limpid/pull/61
* fix(claude): drop --continue fallback from resume chain by @nek0der in https://github.com/nek0der/limpid/pull/62
* feat(confirmations): agent-aware quit + tab/pane close prompts by @nek0der in https://github.com/nek0der/limpid/pull/63
* fix(shell): redirect HISTFILE off the read-only claude-shim bundle by @nek0der in https://github.com/nek0der/limpid/pull/64
* fix(keyboard): stop forwarding IME-consumed keystrokes without modifiers by @nek0der in https://github.com/nek0der/limpid/pull/65
* feat(codex): add Codex CLI integration parallel to Claude by @nek0der in https://github.com/nek0der/limpid/pull/66
* fix(rename): use AppKit hitTest for outside-click detection by @nek0der in https://github.com/nek0der/limpid/pull/67
* refactor(agent): unify Claude+Codex state behind AgentKind by @nek0der in https://github.com/nek0der/limpid/pull/68
* feat(pane): add right-click context menu on terminal surfaces by @nek0der in https://github.com/nek0der/limpid/pull/69
* feat(terminal): add essential terminal features by @nek0der in https://github.com/nek0der/limpid/pull/70
* feat(command-palette): add inline command palette with fuzzy search by @nek0der in https://github.com/nek0der/limpid/pull/71
* fix(lint): resolve SwiftLint errors blocking CI by @nek0der in https://github.com/nek0der/limpid/pull/72
* chore(main): release 0.1.9 by @nek0der in https://github.com/nek0der/limpid/pull/58


**Full Changelog**: https://github.com/nek0der/limpid/compare/v0.1.8...v0.1.9
