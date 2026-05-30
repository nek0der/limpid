# Limpid Agent Guide

> `CLAUDE.md` is a symlink to this file. They are the same document.

Limpid is a macOS 26 terminal app written in Swift 6 + SwiftUI that embeds
`libghostty` through its C ABI. It ships a Notes-2026-style three-pane sidebar
(L1 slab + L2/L3 flush), Tabs / Groups / Projects with git-worktree CRUD,
Sparkle auto-update, JSON session restoration, and en/ja localization. It is
an individual open-source project; expect a single-active-developer cadence.

## Table of contents

1. [Build / Test / Run](#1-build--test--run)
2. [Repository layout](#2-repository-layout)
3. [Code conventions](#3-code-conventions)
4. [Architecture pointers](#4-architecture-pointers)
5. [Do not touch](#5-do-not-touch)
6. [PR & workflow](#6-pr--workflow)
7. [Agent-specific tips](#7-agent-specific-tips)

## 1. Build / Test / Run

The Makefile is the canonical entry point — `make help` lists every target.

```bash
make dev         # Debug build + launch
make build       # Debug build only
make run         # Launch the most recently built app
make test        # XCTest + Swift Testing suites
make dmg         # Release DMG artifact
make screenshot  # Regenerate .github/assets/hero.png (builds Release first)
make xcodegen    # Regenerate Limpid.xcodeproj from project.yml
make ghostty     # Build vendored libghostty
make clean       # Remove DerivedData for this project
```

Each target is a thin wrapper around the underlying tool (`xcodebuild`,
`xcodegen`, `scripts/*.sh`) — call those directly if you need flags the
Makefile doesn't expose.

Agent-side tips:

- Prefer the Xcode MCP (`mcp__xcode__BuildProject`, `RunSomeTests`, etc.) when
  available. It returns structured diff logs and reuses Xcode's index cache, so
  iteration is dramatically faster than `make build` shelling out to
  `xcodebuild`.
- Use `make build` (or direct `xcodebuild`) for the initial full build, CI
  repros, or when the MCP is not reachable.
- `vendor/ghostty` is a git submodule; run `make ghostty` after a fresh clone
  or submodule bump so `libghostty` is available to the linker.

## 2. Repository layout

```
Limpid/
  App/         entry point, scenes, commands
  Core/        models, settings, notifications, git, persistence, clipboard
  FFI/         libghostty C ABI wrapper (`GhosttyFFI`)
  UI/          SwiftUI views (sidebar, L2, L3, chrome, design system, clipboard sheet)
  Resources/   Info.plist, Localizable.xcstrings, assets
LimpidTests/   Swift Testing (new) + XCTest (legacy, being migrated)
vendor/ghostty/  submodule of our fork github.com/nek0der/ghostty (branch `limpid`),
                 currently pinned to `ce986eead "Add scrollback save/restore C API"`.
                 Upstream ghostty-org is tracked via the `upstream` remote for rebases.
                 Run `git -C vendor/ghostty describe` for the current pin.
scripts/       build-ghostty.sh, package-dmg.sh, ExportOptions.plist
project.yml    xcodegen source of truth for the .xcodeproj
```

## 3. Code conventions

- **Language**: source code, comments, doc strings, commit messages,
  branch names, and PR titles / bodies are **English only**.
- **SwiftUI first**: reach for SwiftUI before AppKit. AppKit is reserved for
  cases SwiftUI cannot express (e.g. `NSVisualEffectView` behind-window blur,
  `NSTextInputClient`, `NSWindow` chrome tweaks).
- **Comment grain**: explain *why*, not *what*. Let well-named identifiers
  carry the *what*.
- **File banner** (top of every Swift file):

  ```swift
  // FileName.swift
  // Limpid — one-line description
  ```

- **First person**: comments use `we` / `our`, never `I` (except inside quoted
  proper nouns).
- **AppKit type references in prose/comments** are wrapped in backticks:
  `` `NSWindow` ``, `` `NSView` ``, `` `NSTextView` ``.
- **No emoji** anywhere in the codebase. Chat is exempt.
- **Format**: `swiftformat .` — config in `.swiftformat`. Run before every
  commit, not just UI-heavy ones.
- **Lint**: `swiftlint lint --strict --fix` — config in `.swiftlint.yml`.
  The `--fix` autofix runs locally; CI fails on `--strict` violations.
- **Scope diffs**: keep formatting changes to the lines you actually
  touched. Don't reformat unrelated files in the same PR.

## 4. Architecture pointers

Short index of load-bearing files. Skim these before touching their domain.

- `Limpid/Core/Settings/GhosttyConfigBridge.swift` — four-layer config model
  and the forced-override keys handed to `libghostty`.
- `Limpid/Core/Models/WindowSession.swift` — the session-state hub used by
  tabs, groups, projects, and restore.
- `Limpid/UI/Design/LiquidGlassSlab.swift` — entry point for the macOS 26
  `.glassEffect` slab treatment.
- `Limpid/Core/Updates/SparkleUpdater.swift` — Sparkle auto-update wiring.

## 5. Do not touch

- `vendor/ghostty/` — our libghostty fork (`nek0der/ghostty`, branch `limpid`).
  C ABI patches land on the fork's `limpid` branch, then bump the submodule ref
  here. Don't edit the checkout in place from the Limpid repo — commit patches
  on the fork.
- `Limpid.xcodeproj/project.pbxproj` — generated. Edit `project.yml` and run
  `make xcodegen` instead.
- `Limpid/Resources/Info.plist` Sparkle public key (`SUPublicEDKey`). Changing
  it breaks update signature verification for every shipped build.
- The forced-override config keys passed to `libghostty`
  (`background-opacity=0`, `shell-integration-features=no-cursor`, …). They
  protect the UI compositor; removing one will silently break the rendering
  path.
- `Localizable.xcstrings` — if you hand-edit the JSON, validate that Xcode can
  re-parse it. A malformed `xcstrings` file fails the build.

## 6. PR & workflow

- Branch names use conventional prefixes: `feat/<short>`, `fix/<short>`,
  `chore/<short>`, `docs/<short>`.
- Commit messages follow Conventional Commits: `feat(scope): summary`,
  `fix(scope): summary`, etc. Scopes are lowercase (kebab-case if
  multi-word); re-use a scope that already appears in `git log` when
  one fits, and coin a new one only when nothing matches. Singular
  vs. plural follows what reads naturally for the area
  (`fix(tab)`, `chore(deps)`).
- Do not append `Co-Authored-By` trailers — no AI / agent attribution
  in commits.
- PRs must follow `.github/pull_request_template.md`. Use
  `gh pr create --body-file` so the template is honored.
- CI runs PR title check, CodeQL, release-please, and dependabot auto-merge.
  See `.github/workflows/` for the exact matrix.
- Contributor checklist lives in `CONTRIBUTING.md`; security disclosures in
  `SECURITY.md`.

## 7. Agent-specific tips

- **Parallel agents**: when running multiple agents simultaneously, use
  `isolation: worktree` so changes stay separated. Merge by cherry-pick after
  each agent finishes.
- **Always verify the build**: after a change, run `make build` (or the Xcode
  MCP equivalent) and confirm zero warnings before declaring done.
- **Localization is a hard requirement**: any new user-facing string must be
  added to `Localizable.xcstrings` with both `en` and `ja` translations. An
  English-only entry is considered incomplete.
- **Never edit `project.pbxproj` by hand**: add files via `project.yml`, then
  run `make xcodegen` to regenerate the project.
- **Tests**: new test files use Swift Testing (`@Test`, `#expect`); only
  extend an existing XCTest class when adding to a legacy suite (don't mix
  the two in one file). Reuse fixtures from `LimpidTests/Support/`
  (`RepoFixture`, `TempGitRepo`, `WithTempDir`, `FakeGit`,
  `WindowSessionFixture`, `Tags`) instead of rolling your own. Name tests
  as descriptive function names — no `test_` prefix since `@Test`
  identifies them (e.g. `@Test func addOrActivateProject_existingPath_activatesContainer()`).
  Stateful/UI suites need
  `@MainActor`. Smoke tests that require a local repo gate on
  `.disabled(if: !RepoFixture.hasLocalRepo)`. **Never** write to
  `~/Library/...` from a test — inject the directory via `init(directory:)`
  (see `NotificationHistoryStore`) or use `WithTempDir`. Real user data
  has been corrupted this way before.
- **When stuck**, search GitHub issues/PRs, OSS projects, and WWDC sessions
  before guessing. Web-first beats trial-and-error rebuilds.
- **Demo mode**: set `LIMPID_DEMO=1` in the launching shell to swap the
  on-disk session for `DemoFixture` (6 containers, 2 worktrees, an
  editor split with staged output). Persistence is short-circuited
  while the env var is set, so the user's real `state.json` is not
  touched. The hero screenshot at `.github/assets/hero.png` is
  regenerated by `make screenshot` (requires Screen Recording
  permission on the calling terminal, one-time grant), which depends
  on demo mode being reproducible — when you change `Tab` /
  `SplitTree` / `SessionSnapshot` shapes, run `DemoFixtureTests`
  first and update the fixture before shipping the model change.
