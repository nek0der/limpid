# Changelog

## [0.1.10](https://github.com/nek0der/limpid/compare/v0.1.9...v0.1.10) (2026-10-09)


### Features

* **agent:** warn when Claude's prompt cache has expired ([#122](https://github.com/nek0der/limpid/issues/122)) ([a7f1247](https://github.com/nek0der/limpid/commit/a7f124754d573d7cf5ded2e2ecf99ed9a4db43b2))
* **keyboard:** show shortcuts beside items in Limpid's menus ([#126](https://github.com/nek0der/limpid/issues/126)) ([3c43fa4](https://github.com/nek0der/limpid/commit/3c43fa4b781a24d9a9c94f38e6ffaffe2125f814))
* **sidebar:** show the color picker in Limpid's floating panel ([#123](https://github.com/nek0der/limpid/issues/123)) ([f67f784](https://github.com/nek0der/limpid/commit/f67f784ef786f66ca3fb2a5a0f593579ce6265b4))
* **surface:** keep the pane header while zoomed, and zoom from the terminal menu ([#125](https://github.com/nek0der/limpid/issues/125)) ([ba64946](https://github.com/nek0der/limpid/commit/ba6494672acb9b617b039e384665cff92e13de46))
* **surface:** show a header on each pane of a split tab ([#120](https://github.com/nek0der/limpid/issues/120)) ([ac6f4ec](https://github.com/nek0der/limpid/commit/ac6f4ec8c17b73ee808912744ab53d71b284db41))


### Bug Fixes

* **settings:** switch every in-app string with the display language ([#127](https://github.com/nek0der/limpid/issues/127)) ([2b15658](https://github.com/nek0der/limpid/commit/2b15658a2cadf7b02147fc64262757da37799aba))


### Refactors

* **surface:** host the pane rename panel on the shared floating panel ([#124](https://github.com/nek0der/limpid/issues/124)) ([b33f12f](https://github.com/nek0der/limpid/commit/b33f12fa2ea07c18712c6b47a5be1d4e24755230))

## [0.1.9](https://github.com/nek0der/limpid/compare/v0.1.8...v0.1.9) (2026-10-02)


### Bug Fixes

* **approval:** clear answered questions from Waiting ([#117](https://github.com/nek0der/limpid/issues/117)) ([3c4f195](https://github.com/nek0der/limpid/commit/3c4f19588d9fe77ef4792c482be9976213756e17))
* **keyboard:** forward Control+Enter to the terminal ([#119](https://github.com/nek0der/limpid/issues/119)) ([36e1ed0](https://github.com/nek0der/limpid/commit/36e1ed07c98756caa7b11ace542022f15f0f3739))

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

## [0.1.6](https://github.com/nek0der/limpid/compare/v0.1.5...v0.1.6) (2026-09-14)


### Features

* **agent:** move hook lifecycle processing into Rust ([#67](https://github.com/nek0der/limpid/issues/67)) ([485250e](https://github.com/nek0der/limpid/commit/485250eb30e73e664207b1bfd41ffb093bca53fe))


### Bug Fixes

* **approval:** register the approval service on first install ([#70](https://github.com/nek0der/limpid/issues/70)) ([75ff985](https://github.com/nek0der/limpid/commit/75ff985f42da8cda9234e1b832ebd827c2038c65))

## [0.1.5](https://github.com/nek0der/limpid/compare/v0.1.4...v0.1.5) (2026-09-13)


### Features

* **approval:** add native agent approvals ([#61](https://github.com/nek0der/limpid/issues/61)) ([58d3aae](https://github.com/nek0der/limpid/commit/58d3aaeaba0bfc26f57ced1593d6b84a16c41505))
* **approval:** enable native approvals in Release builds ([#65](https://github.com/nek0der/limpid/issues/65)) ([70d6b74](https://github.com/nek0der/limpid/commit/70d6b747d28884c9cb471f91b29b4c345144da8b))
* **claude:** use session titles for tabs ([#54](https://github.com/nek0der/limpid/issues/54)) ([e68ffae](https://github.com/nek0der/limpid/commit/e68ffae23be41971bb071f7ff77ec9f5eb7cdfe9))
* **review:** add turn-scoped review ([#59](https://github.com/nek0der/limpid/issues/59)) ([5221a7f](https://github.com/nek0der/limpid/commit/5221a7f3744da45117e94881cc81dd9d68630fc7))
* **review:** rebuild the header around the insert destination ([#62](https://github.com/nek0der/limpid/issues/62)) ([75f3c43](https://github.com/nek0der/limpid/commit/75f3c43dc180f2d1d6a4d45aa08474ee073f124d))


### Bug Fixes

* **notifications:** distinguish viewed agent completions ([#64](https://github.com/nek0der/limpid/issues/64)) ([8f649d7](https://github.com/nek0der/limpid/commit/8f649d7fabba8010ddaa4f36edc3789ed03efff9))
* **worktree:** allow forced removal with submodules ([#63](https://github.com/nek0der/limpid/issues/63)) ([887e55b](https://github.com/nek0der/limpid/commit/887e55ba4175454c4460355377ee7b6e51aabfc9))


### Refactors

* **codex:** route tab titles through Rust ([#56](https://github.com/nek0der/limpid/issues/56)) ([fdca8ca](https://github.com/nek0der/limpid/commit/fdca8cab21a10d56e656a81fa676cce8c915daab))

## [0.1.4](https://github.com/nek0der/limpid/compare/v0.1.3...v0.1.4) (2026-09-12)


### Features

* **notifications:** align Waiting with notification history ([#48](https://github.com/nek0der/limpid/issues/48)) ([8e8691f](https://github.com/nek0der/limpid/commit/8e8691f1b06fbdd23f225a353da1b6f5f86e92ba))
* **review:** highlight intraline changes ([#44](https://github.com/nek0der/limpid/issues/44)) ([8c333d7](https://github.com/nek0der/limpid/commit/8c333d70e0366fdc33a4080e5cf6a89fbb27a0a5))
* **review:** improve diff inspection and file actions ([#42](https://github.com/nek0der/limpid/issues/42)) ([e00b308](https://github.com/nek0der/limpid/commit/e00b308130e69561e7e9a3084b8129ecc0c190c2))
* **settings:** add settings search ([#45](https://github.com/nek0der/limpid/issues/45)) ([ca8195c](https://github.com/nek0der/limpid/commit/ca8195cfa53000353781abb22c3ecbad75651d67))


### Bug Fixes

* **layout:** correct cursor styles across the interface ([#49](https://github.com/nek0der/limpid/issues/49)) ([d0d8ff2](https://github.com/nek0der/limpid/commit/d0d8ff2cf00218cab25ad7185e0e54fad5707260))
* **layout:** make column dividers easier to grab ([#43](https://github.com/nek0der/limpid/issues/43)) ([620460e](https://github.com/nek0der/limpid/commit/620460e8b15be0906b66b8c42709ad4dadf9485e))
* **layout:** stabilize pane sizing and search overlays ([#50](https://github.com/nek0der/limpid/issues/50)) ([031627a](https://github.com/nek0der/limpid/commit/031627a7e97bdecefc5c1350a8c1787e3cf91263))
* **layout:** stabilize sidebar transitions ([#47](https://github.com/nek0der/limpid/issues/47)) ([a8a5e64](https://github.com/nek0der/limpid/commit/a8a5e645e1e7a25b92ef8d8ea3e30619c6403b06))
* **surface:** keep startup commands out of tab titles ([#40](https://github.com/nek0der/limpid/issues/40)) ([a8a41ca](https://github.com/nek0der/limpid/commit/a8a41ca52c3f333fe28355ce9da9106a4fb55908))
* **updates:** avoid deprecated Sparkle appcast initializer ([#46](https://github.com/nek0der/limpid/issues/46)) ([a076c41](https://github.com/nek0der/limpid/commit/a076c41ab900c518d9950fa668038b00a3da178b))

## [0.1.3](https://github.com/nek0der/limpid/compare/v0.1.2...v0.1.3) (2026-09-11)


### Features

* **surface:** show terminal scroll position ([#36](https://github.com/nek0der/limpid/issues/36)) ([1609603](https://github.com/nek0der/limpid/commit/16096035c70d89517768e6739ab1c51b7ec0518d))


### Bug Fixes

* **codex:** test hooks against the selected Codex executable ([#35](https://github.com/nek0der/limpid/issues/35)) ([4bd9e58](https://github.com/nek0der/limpid/commit/4bd9e587117e6d3dbe7eb279d68a002225ef94d5))
* **config:** honor bell choices and stop emitting invalid settings ([#31](https://github.com/nek0der/limpid/issues/31)) ([8933cca](https://github.com/nek0der/limpid/commit/8933cca25e90cda9c75a4ef81e0a5de9e5ec7a43))
* **config:** report Ghostty errors and honor scrollback line limits ([#30](https://github.com/nek0der/limpid/issues/30)) ([da79391](https://github.com/nek0der/limpid/commit/da79391142c10bc83d0f85b0e071eda770341fdc))
* **glass:** remove shadows from glass surfaces ([#29](https://github.com/nek0der/limpid/issues/29)) ([5c84a31](https://github.com/nek0der/limpid/commit/5c84a31b7c651226b20a03078a122363411c7d92))
* **layout:** keep narrow windows usable ([#39](https://github.com/nek0der/limpid/issues/39)) ([df790be](https://github.com/nek0der/limpid/commit/df790be16635e9810c2c92605b6c60b085678a82))
* **surface:** enable Secure Keyboard Entry for local password prompts ([#32](https://github.com/nek0der/limpid/issues/32)) ([4bea63a](https://github.com/nek0der/limpid/commit/4bea63ae0166232950e2ffe2e3b48f51a215f993))
* **surface:** expose xterm-ghostty capabilities to terminal programs ([#34](https://github.com/nek0der/limpid/issues/34)) ([9820ddb](https://github.com/nek0der/limpid/commit/9820ddbc5088093c9c27797c219cff7d6040c327))
* **surface:** honor Option-as-Alt and input source changes ([#37](https://github.com/nek0der/limpid/issues/37)) ([253c5ba](https://github.com/nek0der/limpid/commit/253c5bacf18c8e5e7e0e186b073fab16aef01b29))
* **surface:** report the active color scheme to terminal programs ([#33](https://github.com/nek0der/limpid/issues/33)) ([9fca8c8](https://github.com/nek0der/limpid/commit/9fca8c86a66fd35d2ab93f7cd0b8c0fd72f469b3))
* **tmux:** follow agent state through tmux-hosted panes and shared shims ([#27](https://github.com/nek0der/limpid/issues/27)) ([4f19797](https://github.com/nek0der/limpid/commit/4f1979735c646227a572f187bfecd100428b7072))

## [0.1.2](https://github.com/nek0der/limpid/compare/v0.1.1...v0.1.2) (2026-09-08)


### Features

* **review:** comment on a diff and hand the notes to the agent below ([#25](https://github.com/nek0der/limpid/issues/25)) ([4930b39](https://github.com/nek0der/limpid/commit/4930b3923232b75c11a52d478c6f3637154afde7))
* **sidebar:** drop the floating card and reach the window edges ([#26](https://github.com/nek0der/limpid/issues/26)) ([12f9f3a](https://github.com/nek0der/limpid/commit/12f9f3aa524cbf818f13014d38498ee32ffd9abc))
* **sidebar:** show a row's linked pull request ([#13](https://github.com/nek0der/limpid/issues/13)) ([c1037b1](https://github.com/nek0der/limpid/commit/c1037b1d9178aa9a9f086be76dc95bb5054d141e))
* **tmux:** host agent panes in tmux so they outlive a quit ([#24](https://github.com/nek0der/limpid/issues/24)) ([863d073](https://github.com/nek0der/limpid/commit/863d073fc4b1bb6c09e619934664680ee485b0af))
* **tmux:** reattach a pane to the session it was showing ([#21](https://github.com/nek0der/limpid/issues/21)) ([4931139](https://github.com/nek0der/limpid/commit/493113949950ddfe44017032d8beb0aac93daa6b))


### Bug Fixes

* **claude:** merge a user-supplied --settings rather than losing to it ([#17](https://github.com/nek0der/limpid/issues/17)) ([ca98a5c](https://github.com/nek0der/limpid/commit/ca98a5cb83a98b265ad58fe10b801d6e65019f51))
* **codex:** update agent state on interrupted turns and session exit ([#16](https://github.com/nek0der/limpid/issues/16)) ([7d8cc39](https://github.com/nek0der/limpid/commit/7d8cc39ccaee20cb2b5d89e340438af54972b362))
* **entitlements:** allow microphone and Apple Events requests ([#20](https://github.com/nek0der/limpid/issues/20)) ([08da440](https://github.com/nek0der/limpid/commit/08da44080a352099a9819ccc54a0915151dcfc62))
* **sidebar:** accept tab drops on the last container row ([#10](https://github.com/nek0der/limpid/issues/10)) ([48f52ac](https://github.com/nek0der/limpid/commit/48f52acf9ec25cef6cfc8c58d0ce4ee0389dd822))
* **surface:** send input method commits as key events, not pastes ([#22](https://github.com/nek0der/limpid/issues/22)) ([90e494d](https://github.com/nek0der/limpid/commit/90e494dc5250d50eb108f1ac501224470735ffdc))
* **surface:** unblock dictation in a terminal pane ([#18](https://github.com/nek0der/limpid/issues/18)) ([5f857fb](https://github.com/nek0der/limpid/commit/5f857fbfad2d6b4b9a405b7d26548bf7e9588b8c))


### Refactors

* **codex:** retire the shadow CODEX_HOME for command-line hooks ([#19](https://github.com/nek0der/limpid/issues/19)) ([6a37768](https://github.com/nek0der/limpid/commit/6a377686ecf5902072339f1587078b9a58caa430))
* **session:** drop the unread tab-count cache ([#14](https://github.com/nek0der/limpid/issues/14)) ([95d3112](https://github.com/nek0der/limpid/commit/95d31126640f119a18bf1e8398134e99a80e1ed4))

## [0.1.1](https://github.com/nek0der/limpid/compare/v0.1.0...v0.1.1) (2026-06-09)


### Bug Fixes

* **surface:** sync layer scale on display switch ([#3](https://github.com/nek0der/limpid/issues/3)) ([22993e6](https://github.com/nek0der/limpid/commit/22993e6c7ec503b284ec35491e3b6d0d886de5e9))


### CI

* **dependabot:** drop the unusable swift ecosystem ([0d1a329](https://github.com/nek0der/limpid/commit/0d1a3294f4b779bd06e280c9d051090befa00e2f))
