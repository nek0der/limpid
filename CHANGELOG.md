# Changelog

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
