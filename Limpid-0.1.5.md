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

## What's Changed
* feat(appearance): macOS light/dark tracking and Appearance preference by @nek0der in https://github.com/nek0der/limpid/pull/32
* fix(notification): route taps back to the originating pane by @nek0der in https://github.com/nek0der/limpid/pull/34
* fix(notification): replace duplicate banners by pinning identifier to paneID by @nek0der in https://github.com/nek0der/limpid/pull/36
* fix(tab): keep L2 view in place when dragging tabs across containers by @nek0der in https://github.com/nek0der/limpid/pull/35
* fix(lint): clean up SwiftFormat violations from #34 by @nek0der in https://github.com/nek0der/limpid/pull/39
* fix(notification): drop permission guard that races with OS prompt by @nek0der in https://github.com/nek0der/limpid/pull/37
* fix(notification): fail closed when pane id is missing by @nek0der in https://github.com/nek0der/limpid/pull/38
* fix(project): collapse non-git project rows into a single tappable header by @nek0der in https://github.com/nek0der/limpid/pull/40
* fix(project): resolve linked worktree paths to the main checkout on Add by @nek0der in https://github.com/nek0der/limpid/pull/41
* fix(sidebar): expand rename hit area to the full row width by @nek0der in https://github.com/nek0der/limpid/pull/42
* chore(main): release 0.1.5 by @nek0der in https://github.com/nek0der/limpid/pull/33


**Full Changelog**: https://github.com/nek0der/limpid/compare/v0.1.4...v0.1.5
