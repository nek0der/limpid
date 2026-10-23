# Limpid Agent Guide

> `CLAUDE.md` is a symlink to this file. They are the same document.

Limpid is a macOS 26 terminal app written primarily in Swift 6 + SwiftUI. It
embeds `libghostty` through its C ABI and links OS-independent Rust code through
a separate versioned C ABI. At its center is a supervision window for coding
agents. Each window shows one project at a time: a sidebar of every
project's worktrees, the session's pane strip and terminal with a decision bar under each agent pane,
and a Changes panel of the agent's turns. Limpid also ships tabs, projects
with Git worktree management, Sparkle auto-update, JSON session restoration,
and en/ja localization. It is an individual open-source project, so expect
the cadence of a single active developer.

## Table of contents

1. [Build / Test / Run](#1-build--test--run)
2. [Repository layout](#2-repository-layout)
3. [Code conventions](#3-code-conventions)
4. [Architecture pointers](#4-architecture-pointers)
5. [Do not touch](#5-do-not-touch)
6. [PR & workflow](#6-pr--workflow)
7. [Agent-specific tips](#7-agent-specific-tips)

## 1. Build / Test / Run

The Makefile is the canonical entry point — `make help` lists the common targets.

```bash
make dev           # Debug build + launch
make build         # Debug build only
make run           # Launch the most recently built app
make test          # Rust and Swift Testing suites
make test-measure  # Timing suite that `make test` leaves out (prints, checks nothing)
make rust-test     # Rust workspace tests only
make review-core   # Terminal-probe review scenario that runs outside the test target
make lint          # Rust and Swift lint plus the repo checks (mirrors CI)
make release-check # Unsigned Release archive, checked for what `exportArchive` needs
make dmg           # Release DMG artifact
make screenshot    # Regenerate .github/assets/hero.png (builds Release first)
make xcodegen      # Regenerate Limpid.xcodeproj from project.yml
make ghostty       # Build vendored libghostty
make clean         # Remove DerivedData for this project
```

Each target is a thin wrapper around the underlying tool (`xcodebuild`,
`xcodegen`, `scripts/*.sh`) — call those directly if you need flags the
Makefile doesn't expose.

Agent-side tips:

- Prefer the Xcode MCP (`mcp__xcode__BuildProject`, `RunSomeTests`, etc.) when
  available. It returns structured diff logs and reuses Xcode's index cache, so
  iteration is dramatically faster than `make build` shelling out to
  `xcodebuild`.
- Debug builds are ad-hoc signed by default. The approval service then never
  becomes ready, and Claude and Codex use their own permission prompts. To
  exercise native approvals, set `LIMPID_DEVELOPMENT_TEAM`; `CONTRIBUTING.md`
  has the details.
- Use `make build` (or direct `xcodebuild`) for the initial full build, CI
  repros, or when the MCP is not reachable.
- `vendor/ghostty` is a git submodule; run `make ghostty` after a fresh clone
  or submodule bump so `libghostty` is available to the linker.

## 2. Repository layout

```
Limpid/
  App/         entry point, AppState, window controllers and syncs, commands
  Core/        models, settings, notifications, git, persistence, clipboard, agents
               (`Domain/`: plain values and pure rules)
  Presentation/ display stores: window registry, attention list, view models
  FFI/         libghostty C ABI wrapper (`GhosttyFFI`)
  UI/          SwiftUI views (`Supervision/` window, panes, review, settings, design system, clipboard sheet)
  Resources/   Info.plist, Localizable.xcstrings, assets
AgentIntegrationService/  launchd-managed XPC service for native approvals
LimpidTests/   Swift Testing suites (no XCTest)
rust/          OS-independent Rust crates; `limpid-rust-bridge` owns the C ABI
vendor/ghostty/  submodule of our fork github.com/nek0der/ghostty (branch `limpid`).
                 Upstream ghostty-org is tracked via the `upstream` remote for rebases.
                 Run `git -C vendor/ghostty describe` for the current pin.
scripts/       Rust/Ghostty build bridges, packaging, and validation scripts
Cargo.toml     Rust workspace source of truth; toolchain is pinned separately
project.yml    xcodegen source of truth for the .xcodeproj
```

## 3. Code conventions

Most of the style is enforced by `make lint` (`cargo fmt`, Clippy,
`swiftformat --lint`, and `swiftlint --strict`). The rules a linter can't check:

- **English only** for source, comments, commits, and PR titles and bodies.
  No emoji anywhere. US spelling (`color`, `normalize`, `gray`); some
  older files still use British forms, so match the rule rather than
  the file you are editing.
- **SwiftUI before AppKit.** AppKit is the boundary (`NSWindow`,
  `NSTextInputClient`, `NSPasteboard`, `NSVisualEffectView`), not the
  default. Wrap AppKit classes in `*Representable` types and keep the
  boundary thin.
- **`@MainActor final class`** for long-lived state stores. Hot
  off-actor writes go through a `nonisolated static func` write helper
  that takes a value-typed snapshot and routes through
  `SecureFileWrite.writeAtomic` (see `SessionStore`,
  `NotificationHistoryStore`, `FrecencyStore`, `SettingsStore`,
  `TurnReadStore`). Use `actor` only when `MainActor` serializes too much.
- **FFI requires explicit `Sendable` proof.** The canonical wrapper is
  `GhosttyFFI.swift`. `nonisolated(unsafe)` is reserved for `deinit`
  cleanup of resources captured during a known-safe lifetime.
  Document the safety argument in the property's doc comment.
- **Comments answer why**, not what. Full sentences, first-person
  plural (`we` / `our`), no `I`. Every Swift file starts with a
  banner: `// FileName.swift` / `// Limpid — one-line description`.
- **Booleans read as predicates** (`isFocused`, `hasPendingChanges`),
  never bare `focused` / `pending`.
- **No force-unwrap (`!`)** in production. Document *why* a stored
  property is optional in its doc comment.
- **`throws` for recoverable failures**; `try?` is fine when the
  failure mode is "use a default" — document the intent inline.
  User-facing errors implement `LocalizedError`.
- **Every user-visible `Text` / `Label` / dialog button** routes through
  `Localizable.xcstrings` with both `en` and `ja`. Internal log
  messages stay English.
- **One subsystem (`dev.limpid`)**. User content (paths, prompts,
  hostnames) is `privacy: .private`. No `print()` in production.
- **Accessibility:** every interactive element has an
  `.accessibilityLabel`. Read `@Environment(\.accessibilityReduceMotion)`
  and gate decorative transitions on it. Liquid Glass appearance
  must not be the only thing that carries meaning.
- **Tests use Swift Testing** (`@Test`, `#expect`). Reuse fixtures
  from `LimpidTests/Support/`. Never write to `~/Library/...` from a
  test — inject the directory.

## 4. Architecture pointers

Short index of load-bearing files. Skim these before touching their domain.

- `Limpid/Core/Settings/GhosttyConfigBridge.swift` — four-layer config model
  and the forced-override keys handed to `libghostty`.
- `Limpid/Core/Rust/LimpidRustBridge.swift` — typed Swift entry point for the
  versioned Rust C ABI; `scripts/build-rust-bridge.sh` owns Xcode integration.
- `Limpid/Core/Models/WorkspaceSession.swift` — the session-state hub every
  window shares: projects, worktrees, tabs, each window's selection, and
  restore.
- `Limpid/UI/Supervision/SupervisionWindowView.swift` — the supervision
  window's root; `ARCHITECTURE.md` maps each part to its view and model.
- `Limpid/Presentation/Window/WindowRegistry.swift` — the windows, which one
  commands act on, and how a window switches projects in place.
- `Limpid/Presentation/Attention/AttentionQueueStore.swift` — the app's one
  attention list behind ⌘J, Needs Attention, and the decision bars.
- `Limpid/Core/Agent/ApprovalPresentationStore.swift` — native approvals as
  the app holds them: the requests, their ledger, and when a request goes to
  the agent's own prompt. Each window's approval card is
  `Limpid/Presentation/Approval/WindowApprovalCard.swift`.
- `Limpid/Core/Persistence/TurnReadStore.swift` — which turns are read; with
  `ViewedLineStore`, what decides an unread turn.
- `Limpid/Core/Review/ReviewSession.swift` — the review's state machine: what
  each comment state means, why a comment is validated against Git rather than
  trusted, and which failures the banner is allowed to clear.
- `Limpid/Core/Updates/SparkleUpdater.swift` — Sparkle auto-update wiring.

## 5. Do not touch

- `vendor/ghostty/` — our libghostty fork (`nek0der/ghostty`, branch `limpid`).
  C ABI patches land on the fork's `limpid` branch, then bump the submodule ref
  here. Don't edit the checkout in place from the Limpid repo — commit patches
  on the fork. A patch stays additive and carries a class and a retirement
  condition; `docs/libghostty-fork.md` holds the rules and the current
  inventory.
- `Limpid.xcodeproj/project.pbxproj` — generated. Edit `project.yml` and run
  `make xcodegen` instead.
- `Limpid/Resources/Info.plist` Sparkle public key (`SUPublicEDKey`). Changing
  it breaks update signature verification for every shipped build.
- The forced-override config keys passed to `libghostty`
  (`background-opacity=0`, `shell-integration-features=no-cursor`, …). They
  protect the UI compositor; removing one will silently break the rendering
  path. `clipboard-paste-protection = true` is in that block for a different
  reason. Review pastes repository content into whatever the pane is running.
  An unbracketed multi-line paste then needs confirmation, and that
  confirmation keeps a shell from running those lines as commands. The key
  overrides a user's own opt-out in `~/.config/ghostty/config` for every pane,
  because the C ABI has no per-surface form of it. Settings → Review tells the
  user so.
- `Localizable.xcstrings` — if you hand-edit the JSON, validate that Xcode can
  re-parse it. A malformed `xcstrings` file fails the build.

## 6. PR & workflow

- Branch names use conventional prefixes: `feat/<short>`, `fix/<short>`,
  `chore/<short>`, `docs/<short>`.
- Commit messages follow Conventional Commits: `feat(scope): summary`,
  `fix(scope): summary`, etc. Scopes are lowercase (kebab-case if
  multi-word); reuse a scope that already appears in `git log` when
  one fits, and coin a new one only when nothing matches. Singular
  vs. plural follows what reads naturally for the area
  (`fix(tab)`, `chore(deps)`).
- Do not append `Co-Authored-By` trailers — no AI / agent attribution
  in commits.
- PRs must follow `.github/pull_request_template.md`. Use
  `gh pr create --body-file` so the template is honored.
- CI runs the build, test, lint, review-core, and release-archive jobs, the
  guardrails (secrets, forbidden terms, notices), PR title check, CodeQL,
  release-please, and dependabot auto-merge. See `.github/workflows/` for the
  exact matrix.
- The contributor checklist lives in `CONTRIBUTING.md`, and the security
  disclosure policy in `SECURITY.md`.

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
- **Tests**: every test file uses Swift Testing (`@Test`, `#expect`);
  XCTest is not used. Reuse fixtures from `LimpidTests/Support/`
  (`RepoFixture`, `TempGitRepo`, `WithTempDir`, `FakeGit`,
  `WorkspaceSessionFixture`, `TurnSummaryFixture`, `Tags`) instead of
  rolling your own. Give tests descriptive function names with no `test_`
  prefix, since `@Test` already marks them (e.g.
  `@Test func addOrActivateProject_existingPath_activatesContainer()`).
  Stateful and UI suites need `@MainActor`. Smoke tests that require a
  local repo gate on
  `.disabled(if: !RepoFixture.hasLocalRepo)`. **Never** write to
  `~/Library/...` from a test — inject the directory via `init(directory:)`
  (see `NotificationHistoryStore`) or use `WithTempDir`. Real user data
  has been corrupted this way before. Under the test host,
  `LimpidPaths.applicationSupportDirectory()` is a per-run folder in the
  temporary directory, and `TestWriteGuard` refuses any change under the
  real `~/Library` or `~/.codex` that goes through `SecureFileWrite`
  (search the `dev.limpid` / `fs.guard` log for a fault after a run).
  Change files in Limpid's data folder through `SecureFileWrite`, not
  `FileManager`.
- **When stuck**, search GitHub issues/PRs, OSS projects, and WWDC sessions
  before guessing. Web-first beats trial-and-error rebuilds.
- **Demo mode**: set `LIMPID_DEMO=1` in the launching shell to swap the
  on-disk session for `DemoFixture` (a made-up invoicing product: 3
  projects, 16 worktree rows (one ready to clean up, five other worktrees,
  one project folded) with staged agents, turns, Git facts, and pane
  output, in one 1440×900 window with the Changes panel open).
  Persistence is short-circuited while the variable is set, so the
  user's real `state.json` is not touched. Demo mode also skips the
  approval service, so a demo run does not replace the running app's
  service and agents use their native prompts. It starts no updater
  either. `make screenshot` regenerates the hero screenshot at
  `.github/assets/hero.png`. It needs a one-time Screen Recording grant
  for the calling terminal and a 2x display with room for the window,
  and it depends on demo mode being reproducible. When you change the
  shape of `Tab`, `SplitTree`, or `SessionSnapshot`, run
  `DemoFixtureTests` first and update the fixture before shipping the
  model change.
