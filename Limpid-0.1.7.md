## [0.1.7](https://github.com/nek0der/limpid/compare/v0.1.6...v0.1.7) (2026-09-29)


### Features

* **agent:** move the agent lifecycle projection to Rust ([#71](https://github.com/nek0der/limpid/issues/71)) ([1b19655](https://github.com/nek0der/limpid/commit/1b196554fc8d967ada27f89650bf5afc9ab9840e))
* **approval:** answer AskUserQuestion from the approval card ([#81](https://github.com/nek0der/limpid/issues/81)) ([58aa312](https://github.com/nek0der/limpid/commit/58aa312bc2e08d8a6f7c6aab474356e25b68c7b3))
* **keyboard:** add a keyboard shortcut cheat sheet ([#80](https://github.com/nek0der/limpid/issues/80)) ([091c517](https://github.com/nek0der/limpid/commit/091c5179532ddf23ef2173fec9c051bf652b0d9e))
* **quick-terminal:** add a quick terminal toggled by a global hotkey ([#79](https://github.com/nek0der/limpid/issues/79)) ([80ffe5b](https://github.com/nek0der/limpid/commit/80ffe5b21267e05e924f0ebaa7d528c667c201fa))
* **settings:** align the Settings window with System Settings ([#82](https://github.com/nek0der/limpid/issues/82)) ([7b83f40](https://github.com/nek0der/limpid/commit/7b83f40caa9f9e6660223576c880f008e0cdb576))


### Bug Fixes

* **approval:** skip the alert in ad-hoc builds and let Debug sign with a Team ID ([#83](https://github.com/nek0der/limpid/issues/83)) ([5f5d5b8](https://github.com/nek0der/limpid/commit/5f5d5b8de22f7dde0cb9bc897003ac908074d8c4))
* **layout:** keep toolbar controls in place ([#84](https://github.com/nek0der/limpid/issues/84)) ([9847a13](https://github.com/nek0der/limpid/commit/9847a1330d4a3a470741faab6d677b340a83699a))
* **palette:** evict frecency entries that have decayed to nothing ([#75](https://github.com/nek0der/limpid/issues/75)) ([fa9e2d9](https://github.com/nek0der/limpid/commit/fa9e2d9f24259fa3f98aed2b0fc9fafb32e281e1))


### Performance

* **agent:** stop idle wakeups and redundant sidebar work ([#74](https://github.com/nek0der/limpid/issues/74)) ([1f9e8cf](https://github.com/nek0der/limpid/commit/1f9e8cf8f2c82752a2cb1db702b23931b735286e))


### Documentation

* **ghostty:** add libghostty fork maintenance rules ([#76](https://github.com/nek0der/limpid/issues/76)) ([558d98c](https://github.com/nek0der/limpid/commit/558d98c5ccf95d35b648f9d364543e93fc4f6601))

## What's Changed
* feat(agent): move the agent lifecycle projection to Rust by @nek0der in https://github.com/nek0der/limpid/pull/71
* chore(build): track every ADR without a per-file ignore entry by @nek0der in https://github.com/nek0der/limpid/pull/73
* perf(agent): stop idle wakeups and redundant sidebar work by @nek0der in https://github.com/nek0der/limpid/pull/74
* fix(palette): evict frecency entries that have decayed to nothing by @nek0der in https://github.com/nek0der/limpid/pull/75
* docs(ghostty): add libghostty fork maintenance rules by @nek0der in https://github.com/nek0der/limpid/pull/76
* chore(build): check Release archives on PRs and publish releases only with a dmg by @nek0der in https://github.com/nek0der/limpid/pull/77
* chore(github): stop pinning the PR checklist to macOS 26 by @nek0der in https://github.com/nek0der/limpid/pull/78
* feat(quick-terminal): add a quick terminal toggled by a global hotkey by @nek0der in https://github.com/nek0der/limpid/pull/79
* feat(keyboard): add a keyboard shortcut cheat sheet by @nek0der in https://github.com/nek0der/limpid/pull/80
* feat(approval): answer AskUserQuestion from the approval card by @nek0der in https://github.com/nek0der/limpid/pull/81
* feat(settings): align the Settings window with System Settings by @nek0der in https://github.com/nek0der/limpid/pull/82
* fix(approval): skip the alert in ad-hoc builds and let Debug sign with a Team ID by @nek0der in https://github.com/nek0der/limpid/pull/83
* fix(layout): keep toolbar controls in place by @nek0der in https://github.com/nek0der/limpid/pull/84
* chore(screenshot): skip approval-service registration in demo runs by @nek0der in https://github.com/nek0der/limpid/pull/85
* chore(main): release 0.1.7 by @nek0der in https://github.com/nek0der/limpid/pull/72


**Full Changelog**: https://github.com/nek0der/limpid/compare/v0.1.6...v0.1.7

