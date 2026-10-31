## [0.1.14](https://github.com/nek0der/weir/compare/v0.1.13...v0.1.14) (2026-10-31)


### Features

* **agent:** show the actions Claude's auto mode refused on each turn's Changes card ([#189](https://github.com/nek0der/weir/issues/189)) ([a6b2a26](https://github.com/nek0der/weir/commit/a6b2a26bf4cd20b21786b7b5e881836f2049d45f))
* **app:** add a weir command that opens a folder from the terminal ([#215](https://github.com/nek0der/weir/issues/215)) ([58b44fd](https://github.com/nek0der/weir/commit/58b44fdf4d525d61ba5bfde06880ae693722dfad))
* **app:** rename the app from Limpid to Weir, and give it a new icon ([#210](https://github.com/nek0der/weir/issues/210)) ([cb5d827](https://github.com/nek0der/weir/commit/cb5d827c8d6248feff408ff5adffe7689a8dd457))
* **notifications:** lead each history row with what it is about, and frame each source's rows as one group ([#193](https://github.com/nek0der/weir/issues/193)) ([b7fea13](https://github.com/nek0der/weir/commit/b7fea13dcf140ccafdcc951b7acab37b82496d77))
* **sidebar:** drag a tab or pane onto any project's row, and give every pane a header ([#195](https://github.com/nek0der/weir/issues/195)) ([2e6ffa7](https://github.com/nek0der/weir/commit/2e6ffa7a09302e1bab0ceca386ebe4ed0a13e5f9))
* **sidebar:** keep a project's header in sight while its rows scroll, and reorder projects on a layer over the list ([#197](https://github.com/nek0der/weir/issues/197)) ([b818dca](https://github.com/nek0der/weir/commit/b818dca3d4fc8ec7519169bd938f13252689967d))
* **sidebar:** look up a row's pull request as an agent's turn ends, and check open ones more often ([#198](https://github.com/nek0der/weir/issues/198)) ([c56fa8d](https://github.com/nek0der/weir/commit/c56fa8dedb358c8c86c0f910b7e1c924db0c7c21))
* **sidebar:** put the repository's row first with a tag, and say each row's Git counts and time with their units ([#188](https://github.com/nek0der/weir/issues/188)) ([482bfbf](https://github.com/nek0der/weir/commit/482bfbf017d44f13cee541ffc6d4ff3e7bf4e2c1))
* **supervision:** replace the Changes panel's viewed-turns button with a plain line that opens once ([#185](https://github.com/nek0der/weir/issues/185)) ([eb28c70](https://github.com/nek0der/weir/commit/eb28c70e29b28dffd18856d7078eea0394bb672c))
* **supervision:** show each agent pane's model and permission mode in its header, and warn when it runs without asking ([#187](https://github.com/nek0der/weir/issues/187)) ([baaeca3](https://github.com/nek0der/weir/commit/baaeca3586f6dbb8b66dc3ec37dccb9b867b811b))
* **supervision:** show each agent's effort and tokens in its pane header, and the worktree's tokens in the Changes panel ([#207](https://github.com/nek0der/weir/issues/207)) ([14e89cb](https://github.com/nek0der/weir/commit/14e89cbebd9a260b595eb5690eb518db9286a496))
* **supervision:** show every agent on a row and a tab, and mark each pane with its agent's badge ([#199](https://github.com/nek0der/weir/issues/199)) ([d65dcc6](https://github.com/nek0der/weir/commit/d65dcc6db4ee4f8cdf0fbe3012656ade70f6ee4f))


### Bug Fixes

* **agent:** end a stop, and the decision bar lines set during it, when the person starts another conversation in its pane ([#181](https://github.com/nek0der/weir/issues/181)) ([5ce4ee1](https://github.com/nek0der/weir/commit/5ce4ee141e6cf2384a16036f6eca5bd92f345574))
* **agent:** lift a provider's usage limit once another of its runs finishes a turn after the stop ([#183](https://github.com/nek0der/weir/issues/183)) ([417ad08](https://github.com/nek0der/weir/commit/417ad085a386712b12339100fac2c97c0f3522bc))
* **approval:** end a request left to the terminal once its agent's session ends ([#184](https://github.com/nek0der/weir/issues/184)) ([05af190](https://github.com/nek0der/weir/commit/05af1905ac969278fff0414671f96c5133482715))
* **codex:** take the session's folder from where Codex runs the hook, now that a tool's cwd is the folder the tool runs in ([#186](https://github.com/nek0der/weir/issues/186)) ([378d9bc](https://github.com/nek0der/weir/commit/378d9bc752bc668b05154d1ee0975c55556c5555))
* **design:** stop an inline rename's text moving 2pt as its edit opens on macOS 27.2 ([#191](https://github.com/nek0der/weir/issues/191)) ([be0bac4](https://github.com/nek0der/weir/commit/be0bac4b73f29569eb94566c217740860b62f42b))
* **design:** stop the running arc in All Projects drifting out of place as it turns ([#192](https://github.com/nek0der/weir/issues/192)) ([67d250f](https://github.com/nek0der/weir/commit/67d250fc221667bd09c45bbc9a8c9ee698789fc0))
* **notifications:** keep the macOS notification notice's button neutral on its amber band ([#203](https://github.com/nek0der/weir/issues/203)) ([747ac9a](https://github.com/nek0der/weir/commit/747ac9afdbc43794b9bf6923c54ebece7d945d17))
* **notifications:** stop a selected history row drawing a second frame inside its group's ([#205](https://github.com/nek0der/weir/issues/205)) ([21b46ba](https://github.com/nek0der/weir/commit/21b46ba2e0780a7ca48e90318ebe2ddbcc9a35b2))
* **sidebar:** show the scratch row's agents and state instead of a fixed mark ([#208](https://github.com/nek0der/weir/issues/208)) ([a07eea8](https://github.com/nek0der/weir/commit/a07eea8aaaec5e029ff9929be8316f3d339fe9e2))
* **supervision:** draw a pane's attention frame around its header and decision bar ([#202](https://github.com/nek0der/weir/issues/202)) ([26812b5](https://github.com/nek0der/weir/commit/26812b5156be121d249354fdc968f5e169fc59db))
* **supervision:** stop a pane counting as seen after its window moves to a row with no tabs ([#211](https://github.com/nek0der/weir/issues/211)) ([5acca2d](https://github.com/nek0der/weir/commit/5acca2d163e457ebc5bd2db8da65e051d7f3352d))
* **supervision:** stop the highlight of the pane strip's add button running into the rule ([#204](https://github.com/nek0der/weir/issues/204)) ([21794f2](https://github.com/nek0der/weir/commit/21794f2af540b7013857caae0a0d55518e78bad1))
* **supervision:** stop the menu bar window's buttons and lit row standing out of its glass ([#213](https://github.com/nek0der/weir/issues/213)) ([8b240a1](https://github.com/nek0der/weir/commit/8b240a11f629caa248c4773e74c964f1cefe19c8))
* **supervision:** take a pane header's model and permission mode from the agent the pane shows, and keep a split's warning in sight ([#194](https://github.com/nek0der/weir/issues/194)) ([c168ac0](https://github.com/nek0der/weir/commit/c168ac0f56a8dab1a5aa727b6be07f8c54282249))

## What's Changed
* fix(agent): end a stop, and the decision bar lines set during it, when the person starts another conversation in its pane by @nek0der in https://github.com/nek0der/weir/pull/181
* fix(agent): lift a provider's usage limit once another of its runs finishes a turn after the stop by @nek0der in https://github.com/nek0der/weir/pull/183
* fix(approval): end a request left to the terminal once its agent's session ends by @nek0der in https://github.com/nek0der/weir/pull/184
* feat(supervision): replace the Changes panel's viewed-turns button with a plain line that opens once by @nek0der in https://github.com/nek0der/weir/pull/185
* feat(sidebar): put the repository's row first with a tag, and say each row's Git counts and time with their units by @nek0der in https://github.com/nek0der/weir/pull/188
* feat(agent): show the actions Claude's auto mode refused on each turn's Changes card by @nek0der in https://github.com/nek0der/weir/pull/189
* test(review): keep the stack's read tests from timing out on a busy CI runner by @nek0der in https://github.com/nek0der/weir/pull/190
* fix(codex): take the session's folder from where Codex runs the hook, now that a tool's cwd is the folder the tool runs in by @nek0der in https://github.com/nek0der/weir/pull/186
* fix(design): stop an inline rename's text moving 2pt as its edit opens on macOS 27.2 by @nek0der in https://github.com/nek0der/weir/pull/191
* feat(supervision): show each agent pane's model and permission mode in its header, and warn when it runs without asking by @nek0der in https://github.com/nek0der/weir/pull/187
* fix(design): stop the running arc in All Projects drifting out of place as it turns by @nek0der in https://github.com/nek0der/weir/pull/192
* feat(notifications): lead each history row with what it is about, and frame each source's rows as one group by @nek0der in https://github.com/nek0der/weir/pull/193
* fix(supervision): take a pane header's model and permission mode from the agent the pane shows, and keep a split's warning in sight by @nek0der in https://github.com/nek0der/weir/pull/194
* feat(sidebar): drag a tab or pane onto any project's row, and give every pane a header by @nek0der in https://github.com/nek0der/weir/pull/195
* chore(build): build each pull request on main's last build instead of Xcode's compilation cache by @nek0der in https://github.com/nek0der/weir/pull/196
* feat(sidebar): keep a project's header in sight while its rows scroll, and reorder projects on a layer over the list by @nek0der in https://github.com/nek0der/weir/pull/197
* feat(sidebar): look up a row's pull request as an agent's turn ends, and check open ones more often by @nek0der in https://github.com/nek0der/weir/pull/198
* feat(supervision): show every agent on a row and a tab, and mark each pane with its agent's badge by @nek0der in https://github.com/nek0der/weir/pull/199
* test(support): keep the waits and held locks of seven suites from failing on a busy CI runner by @nek0der in https://github.com/nek0der/weir/pull/200
* test(support): fix what a review of every test found, and move the review scenarios into suites that report each failure by @nek0der in https://github.com/nek0der/weir/pull/201
* fix(notifications): keep the macOS notification notice's button neutral on its amber band by @nek0der in https://github.com/nek0der/weir/pull/203
* fix(notifications): stop a selected history row drawing a second frame inside its group's by @nek0der in https://github.com/nek0der/weir/pull/205
* fix(supervision): draw a pane's attention frame around its header and decision bar by @nek0der in https://github.com/nek0der/weir/pull/202
* chore(build): archive each pull request without Swift optimization, and keep it on main and the release pull request by @nek0der in https://github.com/nek0der/weir/pull/206
* feat(supervision): show each agent's effort and tokens in its pane header, and the worktree's tokens in the Changes panel by @nek0der in https://github.com/nek0der/weir/pull/207
* fix(supervision): stop the highlight of the pane strip's add button running into the rule by @nek0der in https://github.com/nek0der/weir/pull/204
* fix(sidebar): show the scratch row's agents and state instead of a fixed mark by @nek0der in https://github.com/nek0der/weir/pull/208
* chore(build): run CI for every commit on main instead of canceling the run before it by @nek0der in https://github.com/nek0der/weir/pull/209
* feat(app): rename the app from Limpid to Weir, and give it a new icon by @nek0der in https://github.com/nek0der/weir/pull/210
* chore(build): name the checkout path in the CI build cache keys, and stop a pull request's run at its first failure by @nek0der in https://github.com/nek0der/weir/pull/214
* feat(app): add a weir command that opens a folder from the terminal by @nek0der in https://github.com/nek0der/weir/pull/215
* fix(supervision): stop the menu bar window's buttons and lit row standing out of its glass by @nek0der in https://github.com/nek0der/weir/pull/213
* fix(supervision): stop a pane counting as seen after its window moves to a row with no tabs by @nek0der in https://github.com/nek0der/weir/pull/211
* chore(main): release 0.1.14 by @nek0der in https://github.com/nek0der/weir/pull/212


**Full Changelog**: https://github.com/nek0der/weir/compare/v0.1.13...v0.1.14

<!-- weir-source-commit: b6ff6b60760c93d26d7816f4df17419cf468e8c9 -->
