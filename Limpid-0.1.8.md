## [0.1.8](https://github.com/nek0der/limpid/compare/v0.1.7...v0.1.8) (2026-09-30)


### Features

* **review:** open a diff line in the editor ([#102](https://github.com/nek0der/limpid/issues/102)) ([36683b2](https://github.com/nek0der/limpid/commit/36683b21baeac6f7029296a2ae5cfa54e788932f))
* **surface:** open terminal file paths in the editor at the line ([#95](https://github.com/nek0der/limpid/issues/95)) ([a94433a](https://github.com/nek0der/limpid/commit/a94433a9c7589f73adaf16570b9eb85d687b359e))


### Bug Fixes

* **codex:** treat any LIMPID_DEMO value as demo mode ([#92](https://github.com/nek0der/limpid/issues/92)) ([b5a55b5](https://github.com/nek0der/limpid/commit/b5a55b5ee87b7c2783871169f01f44a1c3088798))
* **demo:** mask the hostname with localhost so panes keep their working directory ([#96](https://github.com/nek0der/limpid/issues/96)) ([b6e9ebf](https://github.com/nek0der/limpid/commit/b6e9ebfb7184c2f71e0a0860e403259a6e783076))
* **glass:** give floating panels one material surface ([#88](https://github.com/nek0der/limpid/issues/88)) ([36719cc](https://github.com/nek0der/limpid/commit/36719cc5ef2d9d0b23158fae94865474eca21c16))
* **keyboard:** fire menu shortcuts bound to function keys ([#108](https://github.com/nek0der/limpid/issues/108)) ([9422a86](https://github.com/nek0der/limpid/commit/9422a865968a297e2e149ed4b494d411421da671))
* **notifications:** show 99+ in both unread badges ([#91](https://github.com/nek0der/limpid/issues/91)) ([0546593](https://github.com/nek0der/limpid/commit/0546593338b80e21ee09dff95ba13ddc97331c8b))
* **palette:** abbreviate home paths the way the sheets do ([#90](https://github.com/nek0der/limpid/issues/90)) ([ea681b6](https://github.com/nek0der/limpid/commit/ea681b6dc494fadc205a4f5ba689c6fd8f168b1d))
* **palette:** open a recent project into a tab, as the sidebar does ([#111](https://github.com/nek0der/limpid/issues/111)) ([884825c](https://github.com/nek0der/limpid/commit/884825cf4d8c9244dc6728bf5521100f5e65b8f0))
* **review:** align the docked terminal's rows with the tab ([#86](https://github.com/nek0der/limpid/issues/86)) ([23969d0](https://github.com/nek0der/limpid/commit/23969d02c4b636679992b6cc4acc8f31877d5aab))
* **review:** unmark comments from a refused paste with no window open ([#100](https://github.com/nek0der/limpid/issues/100)) ([84bc945](https://github.com/nek0der/limpid/commit/84bc9458cb40d31a13a3c2fa2e92df07c895540b))
* **surface:** check terminal link targets before opening them ([#89](https://github.com/nek0der/limpid/issues/89)) ([35862d8](https://github.com/nek0der/limpid/commit/35862d8e8b5df96c911ffc5f1321ad6e36b26407))
* **worktree:** keep bootstrap commands and paths out of public logs ([#93](https://github.com/nek0der/limpid/issues/93)) ([8f90c09](https://github.com/nek0der/limpid/commit/8f90c09debedb90ba419f31d2a8170b4b707af7e))


### Refactors

* **agent:** centralize agent file layout ([#113](https://github.com/nek0der/limpid/issues/113)) ([6e692d1](https://github.com/nek0der/limpid/commit/6e692d1475b01287188b052fdf7ba6becb5fe6a9))
* **agent:** name run record files in one place ([#110](https://github.com/nek0der/limpid/issues/110)) ([e11bb8e](https://github.com/nek0der/limpid/commit/e11bb8e0e82b652606f9fbad432564b02b93a233))
* **confirmations:** keep the close and quit alert behind the policy gates ([#107](https://github.com/nek0der/limpid/issues/107)) ([a6772e1](https://github.com/nek0der/limpid/commit/a6772e112ea2f876554f398e9d3cea59b91d4930))
* **design:** drop unused tokens and modifiers ([#103](https://github.com/nek0der/limpid/issues/103)) ([48a696d](https://github.com/nek0der/limpid/commit/48a696d80b12a4f8ee29f4d4261cf11c90a99e5b))
* **design:** extract shared UI components ([#112](https://github.com/nek0der/limpid/issues/112)) ([cea4663](https://github.com/nek0der/limpid/commit/cea46637312742d9dd81c007bb862ee995d9d3ee))
* **ghostty:** route binding actions through GhosttyFFI ([#94](https://github.com/nek0der/limpid/issues/94)) ([22355f8](https://github.com/nek0der/limpid/commit/22355f88eb1c670af84867d6972765b49202c346))
* **keyboard:** read named keys from one table ([#106](https://github.com/nek0der/limpid/issues/106)) ([ec9858c](https://github.com/nek0der/limpid/commit/ec9858c5b75a3135b7efa32cd76e7f2bfccc1e30))
* **layout:** share the pane fit check between splits and edge drops ([#105](https://github.com/nek0der/limpid/issues/105)) ([5dddbba](https://github.com/nek0der/limpid/commit/5dddbbadb090a7f8e2f786c9ecb84bef04e009bc))
* **persistence:** move unreadable files aside in one place ([#104](https://github.com/nek0der/limpid/issues/104)) ([d34d080](https://github.com/nek0der/limpid/commit/d34d080902be606fc8404fe9bac41233d7a91cab))
* **session:** keep persisted layout defaults and timings in Core ([#99](https://github.com/nek0der/limpid/issues/99)) ([9d56889](https://github.com/nek0der/limpid/commit/9d568895afe5be6a10069aa099e2e99a1af7c93a))
* **settings:** build the settings file URL in one place ([#109](https://github.com/nek0der/limpid/issues/109)) ([589634d](https://github.com/nek0der/limpid/commit/589634df6756649b403d9fbcd0f6ae34ab90dde5))
* **settings:** move SettingsStore into Core ([#97](https://github.com/nek0der/limpid/issues/97)) ([4470306](https://github.com/nek0der/limpid/commit/4470306fd16f08ecf2b09e450a3d905c46739796))
* **updates:** keep window markers and the update menu item out of Core ([#98](https://github.com/nek0der/limpid/issues/98)) ([e5e2581](https://github.com/nek0der/limpid/commit/e5e2581bcff7f38c84bba872aa98e26e8f936212))

## What's Changed
* fix(review): align the docked terminal's rows with the tab by @nek0der in https://github.com/nek0der/limpid/pull/86
* fix(glass): give floating panels one material surface by @nek0der in https://github.com/nek0der/limpid/pull/88
* fix(surface): check terminal link targets before opening them by @nek0der in https://github.com/nek0der/limpid/pull/89
* fix(codex): treat any LIMPID_DEMO value as demo mode by @nek0der in https://github.com/nek0der/limpid/pull/92
* fix(palette): abbreviate home paths the way the sheets do by @nek0der in https://github.com/nek0der/limpid/pull/90
* fix(notifications): show 99+ in both unread badges by @nek0der in https://github.com/nek0der/limpid/pull/91
* fix(worktree): keep bootstrap commands and paths out of public logs by @nek0der in https://github.com/nek0der/limpid/pull/93
* refactor(ghostty): route binding actions through GhosttyFFI by @nek0der in https://github.com/nek0der/limpid/pull/94
* feat(surface): open terminal file paths in the editor at the line by @nek0der in https://github.com/nek0der/limpid/pull/95
* fix(demo): mask the hostname with localhost so panes keep their working directory by @nek0der in https://github.com/nek0der/limpid/pull/96
* refactor(settings): move SettingsStore into Core by @nek0der in https://github.com/nek0der/limpid/pull/97
* test(claude): stop comparing session start times across a compact restart by @nek0der in https://github.com/nek0der/limpid/pull/101
* refactor(updates): keep window markers and the update menu item out of Core by @nek0der in https://github.com/nek0der/limpid/pull/98
* refactor(session): keep persisted layout defaults and timings in Core by @nek0der in https://github.com/nek0der/limpid/pull/99
* fix(review): unmark comments from a refused paste with no window open by @nek0der in https://github.com/nek0der/limpid/pull/100
* refactor(design): drop unused tokens and modifiers by @nek0der in https://github.com/nek0der/limpid/pull/103
* feat(review): open a diff line in the editor by @nek0der in https://github.com/nek0der/limpid/pull/102
* refactor(layout): share the pane fit check between splits and edge drops by @nek0der in https://github.com/nek0der/limpid/pull/105
* refactor(persistence): move unreadable files aside in one place by @nek0der in https://github.com/nek0der/limpid/pull/104
* refactor(keyboard): read named keys from one table by @nek0der in https://github.com/nek0der/limpid/pull/106
* refactor(confirmations): keep the close and quit alert behind the policy gates by @nek0der in https://github.com/nek0der/limpid/pull/107
* fix(keyboard): fire menu shortcuts bound to function keys by @nek0der in https://github.com/nek0der/limpid/pull/108
* refactor(settings): build the settings file URL in one place by @nek0der in https://github.com/nek0der/limpid/pull/109
* refactor(agent): name run record files in one place by @nek0der in https://github.com/nek0der/limpid/pull/110
* fix(palette): open a recent project into a tab, as the sidebar does by @nek0der in https://github.com/nek0der/limpid/pull/111
* refactor(design): extract shared UI components by @nek0der in https://github.com/nek0der/limpid/pull/112
* refactor(agent): centralize agent file layout by @nek0der in https://github.com/nek0der/limpid/pull/113
* chore(main): release 0.1.8 by @nek0der in https://github.com/nek0der/limpid/pull/87


**Full Changelog**: https://github.com/nek0der/limpid/compare/v0.1.7...v0.1.8

