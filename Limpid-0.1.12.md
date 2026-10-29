## [0.1.12](https://github.com/nek0der/limpid/compare/v0.1.11...v0.1.12) (2026-10-29)


### Features

* **agent:** show an agent waiting on an MCP server's question or a sign-in, which only its terminal status report says ([#173](https://github.com/nek0der/limpid/issues/173)) ([8a41545](https://github.com/nek0der/limpid/commit/8a41545354d4fef510c6d4cb078ce6ccff5c7d31))
* **sidebar:** fold missing worktrees under their own line and let the Ready to Clean Up line delete its worktrees ([#165](https://github.com/nek0der/limpid/issues/165)) ([090e05f](https://github.com/nek0der/limpid/commit/090e05fc0df5451d24961f75fccb0053ad8ba704))
* **supervision:** show each agent's plan usage in a panel from the rail ([#171](https://github.com/nek0der/limpid/issues/171)) ([5b8fd80](https://github.com/nek0der/limpid/commit/5b8fd80a2b921d8e574ad81e2c02eb3867cc6941))
* **supervision:** show the shells and subagents Claude leaves running after a turn ([#161](https://github.com/nek0der/limpid/issues/161)) ([20340cf](https://github.com/nek0der/limpid/commit/20340cfe819c05b37186078b4764c184db8e754a))
* **supervision:** tell agent conversations apart by name and color, and group the Changes panel's turns by conversation ([#167](https://github.com/nek0der/limpid/issues/167)) ([cbc7aac](https://github.com/nek0der/limpid/commit/cbc7aace3a316c64dea7ceb781d0f8f3e70dd22d))


### Bug Fixes

* **agent:** keep a Claude pane finished when a background subagent's tool call ends ([#164](https://github.com/nek0der/limpid/issues/164)) ([8954c0a](https://github.com/nek0der/limpid/commit/8954c0af56c5a8ce706a11b40f6d671e6cb81f16))
* **codex:** record the turns Codex begins for a /goal from their start, with the goal as their prompt ([#172](https://github.com/nek0der/limpid/issues/172)) ([859773b](https://github.com/nek0der/limpid/commit/859773bab8861fe4705d45fe8648deb103804a30))
* **codex:** run Limpid's hooks whatever CODEX_HOME is, and stop writing to ~/.codex/config.toml ([#168](https://github.com/nek0der/limpid/issues/168)) ([d5a8d9d](https://github.com/nek0der/limpid/commit/d5a8d9d78e81bc7115658fe9c8720cf36225f48a))
* **notifications:** fit the macOS notification notice on one line ([#166](https://github.com/nek0der/limpid/issues/166)) ([675cd9f](https://github.com/nek0der/limpid/commit/675cd9ffa2f32cbbc8afcaed641ccb92be42fa7e))
* **worktree:** stop waiting on killed processes launchd has not reaped, and fix the Windows replay test ([#174](https://github.com/nek0der/limpid/issues/174)) ([dedffb9](https://github.com/nek0der/limpid/commit/dedffb9c20fbdaeee572eb8ef3eb21702a739985))


### Refactors

* **agent:** stop reading hook fields neither Claude Code nor Codex sends ([#169](https://github.com/nek0der/limpid/issues/169)) ([e6bafa9](https://github.com/nek0der/limpid/commit/e6bafa9dfce991997d42953cf494f094a02a33b5))


### Documentation

* **agent:** describe when Claude Code sends its idle prompt, which it holds back while a subagent runs ([#170](https://github.com/nek0der/limpid/issues/170)) ([297af67](https://github.com/nek0der/limpid/commit/297af67793df1c7a5aec5512e8806e4f49bacc5b))

## What's Changed
* feat(supervision): show the shells and subagents Claude leaves running after a turn by @nek0der in https://github.com/nek0der/limpid/pull/161
* test(agent): give a shim test's argument list a type so Xcode 27 type-checks it by @nek0der in https://github.com/nek0der/limpid/pull/162
* fix(agent): keep a Claude pane finished when a background subagent's tool call ends by @nek0der in https://github.com/nek0der/limpid/pull/164
* feat(sidebar): fold missing worktrees under their own line and let the Ready to Clean Up line delete its worktrees by @nek0der in https://github.com/nek0der/limpid/pull/165
* fix(notifications): fit the macOS notification notice on one line by @nek0der in https://github.com/nek0der/limpid/pull/166
* feat(supervision): tell agent conversations apart by name and color, and group the Changes panel's turns by conversation by @nek0der in https://github.com/nek0der/limpid/pull/167
* fix(codex): run Limpid's hooks whatever CODEX_HOME is, and stop writing to ~/.codex/config.toml by @nek0der in https://github.com/nek0der/limpid/pull/168
* refactor(agent): stop reading hook fields neither Claude Code nor Codex sends by @nek0der in https://github.com/nek0der/limpid/pull/169
* docs(agent): describe when Claude Code sends its idle prompt, which it holds back while a subagent runs by @nek0der in https://github.com/nek0der/limpid/pull/170
* feat(supervision): show each agent's plan usage in a panel from the rail by @nek0der in https://github.com/nek0der/limpid/pull/171
* fix(codex): record the turns Codex begins for a /goal from their start, with the goal as their prompt by @nek0der in https://github.com/nek0der/limpid/pull/172
* feat(agent): show an agent waiting on an MCP server's question or a sign-in, which only its terminal status report says by @nek0der in https://github.com/nek0der/limpid/pull/173
* fix(worktree): stop waiting on killed processes launchd has not reaped, and fix the Windows replay test by @nek0der in https://github.com/nek0der/limpid/pull/174
* chore(main): release 0.1.12 by @nek0der in https://github.com/nek0der/limpid/pull/163


**Full Changelog**: https://github.com/nek0der/limpid/compare/v0.1.11...v0.1.12

<!-- limpid-source-commit: 9f2385508f30b9bcb4207dff6404276df8db72db -->
