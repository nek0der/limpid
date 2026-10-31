# Contributing to Weir

Thanks for your interest! Weir is in pre-alpha, so things move fast and APIs are unstable.

By participating, you agree to follow the [Code of Conduct](CODE_OF_CONDUCT.md).

## Before you start

- For non-trivial changes, open an issue first to discuss the approach.
- For bug fixes and small improvements, a direct PR is fine.

## Setup

### Prerequisites

- macOS 26 (Tahoe) or later
- Xcode 26 with the Metal Toolchain component
  ```bash
  xcodebuild -downloadComponent MetalToolchain
  ```
- [Homebrew](https://brew.sh)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen), Zig 0.17.0, and Rustup
  ```bash
  brew install xcodegen zig@0.17 rustup
  export PATH="$(brew --prefix rustup)/bin:$PATH"
  ```
  The version of record is `minimum_zig_version` in
  `vendor/ghostty/build.zig.zon`. The build script reads it and runs the
  Homebrew Zig of exactly that version by its full path, so no `PATH` change
  is required. It looks in `/opt/homebrew/opt/zig@0.17/bin/zig` and in
  `/opt/homebrew/opt/zig/bin/zig`, because `zig@0.17` is an alias of `zig`
  while 0.17 is Homebrew's current release.
- [Mint](https://github.com/yonaskolb/Mint), for the `swiftformat` version
  pinned in `Mintfile` (`make fmt` / `make lint`)
  ```bash
  brew install mint
  mint bootstrap
  ```
- [SwiftLint](https://github.com/realm/SwiftLint), for `make lint`
  ```bash
  brew install swiftlint
  ```
  It is not pinned: CI installs Homebrew's current release the same way,
  and `make lint` runs whichever `swiftlint` is on your `PATH`.

### Build

```bash
# 1. Clone with submodules (Ghostty lives at vendor/ghostty)
git clone --recursive https://github.com/nek0der/weir.git
cd weir

# If you already cloned without --recursive, pull the submodules
# now — `make ghostty` fails on an empty vendor/ghostty/ checkout:
#   git submodule update --init --recursive

# 2. Confirm Zig 0.17.0 is installed (the build script only looks in
# Homebrew's opt paths, so a missing zig@0.17 yields a clear error
# rather than silently picking up a system Zig):
#   brew list --versions zig@0.17

# 3. Build libghostty as an xcframework (10–20 min on first run; cached after)
make ghostty

# 4. Install the Rust toolchain rust-toolchain.toml pins, then verify the
# workspace with it
rustup toolchain install
make rust-test

# 5. Generate the Xcode project
make xcodegen

# 6. Build + launch (Debug)
make dev
```

`make help` lists the common targets (`build`, `run`, `test`, `lint`, `dmg`, `screenshot`, `clean`, …).

You should see a Weir window with a working terminal pane (zsh by default), the Worktrees sidebar with that terminal on its Scratch row, and the pane strip. Weir logs the embedded libghostty version through `os_log` under the `com.nekoder.weir` subsystem (`log stream --predicate 'subsystem == "com.nekoder.weir"'`).

> First-launch tip: a locally built Debug binary is ad-hoc signed, so macOS may quarantine it. Right-click the app and choose Open the first time.

### Native approvals in a Debug build

The approval service accepts connections only from executables signed with its own Team ID. A Debug build is ad-hoc signed by default, so it runs without native approvals, and Claude and Codex use their own permission prompts. To try native approvals, build with a signing identity that has a Team ID. The service accepts an Apple Development certificate, which a free Apple Account can create in Xcode.

```bash
export WEIR_DEVELOPMENT_TEAM=<your Team ID>
# Optional; the identity defaults to "Apple Development".
# export WEIR_CODE_SIGN_IDENTITY="Developer ID Application"
make dev
```

### Slowing the motion in a Debug build

`WEIR_SLOW_MOTION=<factor>` makes every animation in a Debug build `<factor>` times as long (`WeirMotion.pace`). Use it to step frame by frame through a recording of a surface as it opens. `open`, and therefore `make run`, does not pass the shell's environment on, so start the built binary directly: `WEIR_SLOW_MOTION=10 "<DerivedData>/Build/Products/Debug/Weir Dev.app/Contents/MacOS/Weir Dev"`. A Release build ignores the variable.

### Open in Xcode

```bash
make xcodegen
open Weir.xcodeproj
```

`Weir.xcodeproj` is gitignored, so always regenerate it from `project.yml`. `make build` and `make test` regenerate it on their own when `project.yml` changes, or when a file under `Weir/`, `WeirTests/`, or `AgentIntegrationService/` is added, removed, or renamed. Run `make xcodegen` to force a regeneration.

## Language policy

- **Source code, comments, and doc comments**: English only.
- **User-facing documentation** (`README.md`, `CONTRIBUTING.md`, `SECURITY.md`, `CODE_OF_CONDUCT.md`): English.
- **Internal design documents** under `docs/` (ADRs, protocol and migration notes): English, like the rest of the repository.
- **Commit messages, PR titles, and PR descriptions**: English. A squash merge turns the PR into the commit on `main`, and the release notes are built from those commits, so they have to read for every contributor and user.
- **Issues and discussion**: either language is fine.
- **In-app strings** are bilingual. Every user-visible label, tooltip, alert, and accessibility annotation has to land in `Weir/Resources/Localizable.xcstrings` with both an `en` and a `ja` entry. CI and `make lint` run `scripts/check-localization.sh`. It fails on a translatable key with no `ja` entry, no string units, or a state other than translated. Whether the Japanese reads well is still the reviewer's job.

## Pull requests

- Branch off `main` using a conventional prefix: `feat/<short>`, `fix/<short>`, `docs/<short>`, `chore/<short>`, `refactor/<short>`, `test/<short>`.
- Keep commits focused. Use [Conventional Commits](https://www.conventionalcommits.org/) (`feat:`, `fix:`, `docs:`, etc.).
- Code comments must be in English.
- Code style: see [`AGENTS.md`](AGENTS.md) §3 for the conventions a linter can't enforce (comments explain *why*, file banners, naming).
- `release-please` generates `CHANGELOG.md` from commit messages, so don't edit it by hand.

### Before opening the PR

Run the following from the repo root and make sure each one passes:

```bash
make ghostty      # Only if vendor/ghostty/macos/GhosttyKit.xcframework is
                  # missing (fresh clone). `make test` does not rebuild it
                  # and will fail at link time without the xcframework.
make xcodegen     # Regenerate the Xcode project from project.yml.
make test         # Run the Rust and Swift test suites.
make review-core  # The one review scenario the test target cannot host. It
                  # opens a pty and spawns processes, and under the parallel
                  # suites its descriptors reuse numbers another test
                  # asserts are closed. CI runs it as its own job, so
                  # `make test` alone does not predict a green build.
make lint         # cargo fmt + Clippy + SwiftFormat + SwiftLint, plus the
                  # localization and script checks.
```

If you are editing files under `vendor/ghostty/`, you are probably on the wrong path. That directory is a submodule of our libghostty fork, pinned to one commit. Patch the fork and bump the submodule ref; never edit the checkout in place. `docs/libghostty-fork.md` covers what a fork patch has to carry and how we retire one.

### Opening the PR

Create the PR with `gh pr create --body-file <file>` so
`.github/pull_request_template.md` is honored verbatim. The
template has four sections (Summary, Related issue, How verified,
Screenshots / video) plus a checklist. Fill in each section, and
write `Skip.` when one does not apply (e.g. a PR with no related
issue). `gh pr create --fill` and the GitHub web UI both skip the
template silently. That is the most common review nit on a first
PR.

## Tests

- Tests use [Swift Testing](https://developer.apple.com/documentation/testing) (`import Testing`, `@Test`, `#expect`). XCTest is not used; do not add it.
- Reuse fixtures from `WeirTests/Support/` (`RepoFixture`, `TempGitRepo`, `WithTempDir`, `FakeGit`, `WorkspaceSessionFixture`, `TurnSummaryFixture`, `Tags`) instead of rolling your own.
- Smoke tests that touch the local filesystem or shell out to `git` should gate themselves on `RepoFixture.hasLocalRepo` (`.disabled(if: !RepoFixture.hasLocalRepo)`) so they skip cleanly outside the source tree.
- **Never write to `~/Library/Application Support/Weir/` from a test.** Production stores (`SessionStore`, `NotificationHistoryStore`) accept an `init(directory:)` override. Pair it with `WithTempDir` so each test runs against an isolated temporary directory. Tests that called the no-argument `init()` and then `clearAll()` have corrupted real user data before. A test run refuses such a change (`TestWriteGuard`), but a refused write still means the test is not testing what it claims. Test runs keep their data in a per-run temporary folder; a `~/Library/Application Support/Weir Tests Stray/` left by older builds is no longer used and can be removed by hand.

## Regenerating the hero screenshot

The hero image at the top of `README.md`, `.github/assets/hero.png`, is captured from the app launched in demo mode. To refresh it after a UI change:

```bash
make screenshot   # Release build → launch in demo mode → capture → quit.
                  # Output lands at .github/assets/hero.png.
```

The script sets `WEIR_DEMO=1`, so the app loads `DemoFixture` instead of the user's real `state.json`. Demo mode writes none of the user's files: persistence and restores are off, the agent projection runs no pass, and the updater does not start. The fixture, not Git or a real agent, supplies the agents' turns and viewed lines (`DemoFixture+Turns.swift`), the session header's Git facts (`DemoFixture+Git.swift`), and what each pane prints (`DemoFixture+Transcripts.swift`). The terminal font is pinned to the default family at 12 points. Together these make the capture show the same supervision scene on every machine.

**Display**: the hero is a 1440×900-point window captured at 2x (2880×1800 pixels). The demo opens it at (16, 16) on the main display. That display has to be a 2x (Retina) display with at least 1456×956 points, menu bar included. A 13.6-inch MacBook Air at its default resolution has room; a 1440×900 display does not. The script refuses a capture of any other size.

**One-time setup**: grant your terminal Screen Recording permission so the script can find Weir's window and capture it through ScreenCaptureKit (one permission covers both).

> System Settings → Privacy & Security → Screen Recording → click `+` → add your terminal app (Terminal, Ghostty, etc.) → toggle on.

If the shape of `Tab`, `SplitTree`, or `SessionSnapshot` changes, run `DemoFixtureTests` first. The fixture is anchored on stable UUIDs and a JSON round-trip.

## AI tools

Using AI assistants (Claude, Copilot, Cursor, etc.) is welcome. Please be able to explain what your PR does without leaning on the tool.

See [`AGENTS.md`](AGENTS.md) for the conventions agents (and humans) should follow inside the repository.

## Reporting security issues

See [SECURITY.md](SECURITY.md).

## Questions

Open a [Discussion](https://github.com/nek0der/weir/discussions) or an issue.
