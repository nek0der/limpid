## [0.1.11](https://github.com/nek0der/limpid/compare/v0.1.10...v0.1.11) (2026-10-28)


### Features

* **agent:** name a tab by the title Codex gives its session and by Claude's /rename ([#156](https://github.com/nek0der/limpid/issues/156)) ([1e6a282](https://github.com/nek0der/limpid/commit/1e6a2823261b693e983dce4ca8d08fc048f49b92))
* **sidebar:** title the sidebar "Projects" and open a folder from its + ([#146](https://github.com/nek0der/limpid/issues/146)) ([14d7f98](https://github.com/nek0der/limpid/commit/14d7f98a9668505bbfbc8de901504f7b419caddf))
* **supervision:** list the session's tabs to search and switch from the pane strip ([#144](https://github.com/nek0der/limpid/issues/144)) ([cb8391e](https://github.com/nek0der/limpid/commit/cb8391e7ed8c4e88485377b0a4898486116fda20))
* **supervision:** show each turn's tokens and test runs on its Changes card ([#151](https://github.com/nek0der/limpid/issues/151)) ([ebb828a](https://github.com/nek0der/limpid/commit/ebb828a0330d331ad2f2e3f853af49d6eb629e01))
* **supervision:** show the agent's last reply on each turn's Changes card and notification ([#160](https://github.com/nek0der/limpid/issues/160)) ([e4dcff3](https://github.com/nek0der/limpid/commit/e4dcff312141eaac8082a56e89eb1edb32424df1))


### Bug Fixes

* **agent:** end a Claude turn stopped with Esc or Ctrl+C right away ([#155](https://github.com/nek0der/limpid/issues/155)) ([1e12443](https://github.com/nek0der/limpid/commit/1e124431c16cfdeec5470eb72acd032962a897e3))
* **approval:** clear an approval refused in Claude's own dialog right away ([#149](https://github.com/nek0der/limpid/issues/149)) ([831ab00](https://github.com/nek0der/limpid/commit/831ab00992936247dc1e5058350efee7eabda1a4))
* **codex:** count the tokens of a Codex turn's subagents ([#158](https://github.com/nek0der/limpid/issues/158)) ([942c325](https://github.com/nek0der/limpid/commit/942c32581ccd212481501b34b7482f7c89366424))
* **codex:** show "Needs answer" while Codex waits on a question ([#154](https://github.com/nek0der/limpid/issues/154)) ([5523c59](https://github.com/nek0der/limpid/commit/5523c5937cef4a461e8e62f0c839d183695cfd11))
* **codex:** show any failed Codex turn as failed, not only one at the usage limit ([#159](https://github.com/nek0der/limpid/issues/159)) ([77a2c00](https://github.com/nek0der/limpid/commit/77a2c00a0b44d3c4059c69df2b4cf6fb0721868e))
* **codex:** show the tokens and test runs of a Codex turn stopped with Esc ([#157](https://github.com/nek0der/limpid/issues/157)) ([85c6918](https://github.com/nek0der/limpid/commit/85c6918b27fe68a10d5064b8e7f7150f5d6625f8))
* **sidebar:** move the project-wide worktree entries from each row's menu to the project header ([#147](https://github.com/nek0der/limpid/issues/147)) ([d8efef3](https://github.com/nek0der/limpid/commit/d8efef3db8fd7fe98d4ed856f82af25fa4aa1924))
* **supervision:** show a row and a pane header as running while an earlier turn is unread ([#152](https://github.com/nek0der/limpid/issues/152)) ([8c5a1e1](https://github.com/nek0der/limpid/commit/8c5a1e1d328045b111a24b2652872e1dd16e3c57))
* **surface:** save a pane's scrollback while a full-screen program runs in it ([#150](https://github.com/nek0der/limpid/issues/150)) ([5d17765](https://github.com/nek0der/limpid/commit/5d17765e2e452a814a9f182e341f2d919cb65c62))

## What's Changed
* test(support): keep a hosted test window at the size it was given by @nek0der in https://github.com/nek0der/limpid/pull/131
* chore(deps): move the workflows' actions to their Node.js 24 releases by @nek0der in https://github.com/nek0der/limpid/pull/132
* chore(deps): bump github/codeql-action/analyze from 4.38.3 to 4.39.0 by @dependabot[bot] in https://github.com/nek0der/limpid/pull/136
* chore(deps): bump github/codeql-action/init from 4.38.3 to 4.39.0 by @dependabot[bot] in https://github.com/nek0der/limpid/pull/137
* chore(build): analyze the Rust workspace with CodeQL instead of the Swift app by @nek0der in https://github.com/nek0der/limpid/pull/138
* chore(build): fill in the Rust crate notices from Cargo.lock when the app is built by @nek0der in https://github.com/nek0der/limpid/pull/139
* chore(build): install the pinned Rust toolchain without rustup's auto-install by @nek0der in https://github.com/nek0der/limpid/pull/140
* chore(deps): bump libc from 0.2.189 to 0.2.191 by @dependabot[bot] in https://github.com/nek0der/limpid/pull/135
* chore(deps): bump uuid from 1.26.1 to 1.28.0 by @dependabot[bot] in https://github.com/nek0der/limpid/pull/134
* chore(deps): bump serde_json from 1.0.151 to 1.0.154 by @dependabot[bot] in https://github.com/nek0der/limpid/pull/133
* test(support): run the tests in parallel, and the window tests one at a time by @nek0der in https://github.com/nek0der/limpid/pull/141
* chore(build): keep Mint's SwiftFormat build between CI runs by @nek0der in https://github.com/nek0der/limpid/pull/142
* test(tmux): keep the cancel test from racing the timeout by @nek0der in https://github.com/nek0der/limpid/pull/143
* feat(supervision): list the session's tabs to search and switch from the pane strip by @nek0der in https://github.com/nek0der/limpid/pull/144
* feat(sidebar): title the sidebar "Projects" and open a folder from its + by @nek0der in https://github.com/nek0der/limpid/pull/146
* fix(sidebar): move the project-wide worktree entries from each row's menu to the project header by @nek0der in https://github.com/nek0der/limpid/pull/147
* chore(deps): update libghostty to upstream main and build it with Zig 0.17 by @nek0der in https://github.com/nek0der/limpid/pull/148
* fix(approval): clear an approval refused in Claude's own dialog right away by @nek0der in https://github.com/nek0der/limpid/pull/149
* fix(surface): save a pane's scrollback while a full-screen program runs in it by @nek0der in https://github.com/nek0der/limpid/pull/150
* feat(supervision): show each turn's tokens and test runs on its Changes card by @nek0der in https://github.com/nek0der/limpid/pull/151
* test(agent): keep the turn deletion tests from timing out behind a full parallel run by @nek0der in https://github.com/nek0der/limpid/pull/153
* fix(supervision): show a row and a pane header as running while an earlier turn is unread by @nek0der in https://github.com/nek0der/limpid/pull/152
* fix(codex): show "Needs answer" while Codex waits on a question by @nek0der in https://github.com/nek0der/limpid/pull/154
* fix(agent): end a Claude turn stopped with Esc or Ctrl+C right away by @nek0der in https://github.com/nek0der/limpid/pull/155
* feat(agent): name a tab by the title Codex gives its session and by Claude's /rename by @nek0der in https://github.com/nek0der/limpid/pull/156
* fix(codex): show the tokens and test runs of a Codex turn stopped with Esc by @nek0der in https://github.com/nek0der/limpid/pull/157
* fix(codex): count the tokens of a Codex turn's subagents by @nek0der in https://github.com/nek0der/limpid/pull/158
* fix(codex): show any failed Codex turn as failed, not only one at the usage limit by @nek0der in https://github.com/nek0der/limpid/pull/159
* feat(supervision): show the agent's last reply on each turn's Changes card and notification by @nek0der in https://github.com/nek0der/limpid/pull/160
* chore(main): release 0.1.11 by @nek0der in https://github.com/nek0der/limpid/pull/145


**Full Changelog**: https://github.com/nek0der/limpid/compare/v0.1.10...v0.1.11

<!-- limpid-source-commit: 598745c62f7543be7dffdbfe0f8b4cdb622e9836 -->
