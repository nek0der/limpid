# Contributing to Limpid

Thanks for your interest! Limpid is in pre-alpha, so things move fast and APIs are unstable.

By participating, you agree to follow the [Code of Conduct](CODE_OF_CONDUCT.md).

## Before you start

- For non-trivial changes, open an issue first to discuss the approach.
- Bug fixes and small improvements: PR directly is fine.

## Setup

### Prerequisites

- macOS 26 (Tahoe) or later
- Xcode 26 with the Metal Toolchain component
  ```bash
  xcodebuild -downloadComponent MetalToolchain
  ```
- [Homebrew](https://brew.sh)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) and Zig 0.15.2
  ```bash
  brew install xcodegen zig@0.15
  ```
  `zig@0.15` is keg-only; the build script invokes it by its full path
  (`/opt/homebrew/opt/zig@0.15/bin/zig`), so no `PATH` change is required.

### Build

```bash
# 1. Clone with submodules (Ghostty lives at vendor/ghostty)
git clone --recursive https://github.com/nek0der/limpid.git
cd limpid

# 2. Build libghostty as an xcframework (10–20 min on first run; cached after)
make ghostty

# 3. Generate the Xcode project
make xcodegen

# 4. Build + launch (Debug)
make dev
```

`make help` lists every available target (`build`, `run`, `test`, `dmg`, `screenshot`, `clean`, …).

You should see a Limpid window with a working terminal pane (zsh by default), a sidebar, and the tab list. The embedded libghostty version is logged via `os_log` under the `dev.limpid` subsystem (`log stream --predicate 'subsystem == "dev.limpid"'`).

> First-launch tip: a locally-built Debug binary is ad-hoc signed, so macOS may quarantine it. Right-click → Open the first time.

### Open in Xcode

```bash
make xcodegen
open Limpid.xcodeproj
```

`Limpid.xcodeproj` is gitignored — always regenerate from `project.yml`.

## Language policy

- **Source code, comments, and doc strings**: English only.
- **User-facing documentation** (`README.md`, `CONTRIBUTING.md`, `SECURITY.md`, `CHANGELOG.md`, `CODE_OF_CONDUCT.md`): English.
- **Internal design documents** under `docs/`: Japanese is the convention. Mixed-language research notes (e.g. `key-handling-research.md`) are kept as-is; new docs follow this rule.
- Chat, commit message bodies, and PR descriptions: either language is fine. The commit summary line stays English so `git log` reads cleanly.

## Pull requests

- Branch off `main` using a conventional prefix: `feat/<short>`, `fix/<short>`, `docs/<short>`, `chore/<short>`, `refactor/<short>`, `test/<short>`. See [`docs/branching.md`](docs/branching.md) for the full convention.
- Keep commits focused. Use [Conventional Commits](https://www.conventionalcommits.org/) (`feat:`, `fix:`, `docs:`, etc.).
- Code comments must be in English.
- Update `CHANGELOG.md` under `[Unreleased]` when your change is user-visible.

### Before opening the PR

Run the following from the repo root and make sure all three pass:

```bash
make xcodegen     # Regenerate the Xcode project from project.yml.
make test         # Build + run the full test suite.

# Formatter + linter (both configured via .swiftformat / .swiftlint.yml).
swiftformat .
swiftlint lint --strict
```

`make help` lists every available target.

If you are editing `vendor/ghostty/` content, you're probably on the wrong path — that's a pinned upstream submodule. Bump it by updating the submodule ref, never by editing in place.

## Tests

- New tests use [Swift Testing](https://developer.apple.com/documentation/testing) (`import Testing`, `@Test`, `#expect`). Existing XCTest tests are kept and migrated opportunistically — don't mix the two styles in one file.
- Reuse fixtures from `LimpidTests/Support/` (`RepoFixture`, `TempGitRepo`, `WithTempDir`, `FakeGit`, `WindowSessionFixture`, `Tags`) instead of rolling your own.
- Smoke tests that touch the local filesystem or shell out to `git` should gate themselves on `RepoFixture.hasLocalRepo` so they no-op cleanly outside the source tree.
- **Never write to `~/Library/Application Support/Limpid/` from a test.** Production stores (`SessionStore`, `NotificationHistoryStore`) accept an `init(directory:)` override; pair it with `WithTempDir` so each test runs against an isolated temp directory. Real user data has been corrupted by tests that called the no-arg `init()` and then `clearAll()`.

## Regenerating the hero screenshot

The `.github/assets/hero.png` shown at the top of `README.md` is captured from the app launched in demo mode. To refresh it after a UI change:

```bash
make screenshot   # Release build → launch in demo mode → capture → quit.
                  # Output lands at .github/assets/hero.png.
```

The script sets `LIMPID_DEMO=1` so the app loads `DemoFixture` instead of the user's real `state.json` — persistence is disabled while the env var is set.

**One-time setup**: grant your terminal Screen Recording permission so the script can both query Limpid's window bounds via `CGWindowListCopyWindowInfo` and capture the pixels via `screencapture` (one permission covers both).

> System Settings → Privacy & Security → Screen Recording → click `+` → add your terminal app (Terminal / iTerm / Ghostty / etc.) → toggle on.

If `Tab`, `SplitTree`, or `SessionSnapshot` shapes change, run `DemoFixtureTests` first; the fixture is anchored on stable UUIDs and a JSON round-trip.

## AI tools

Using AI assistants (Claude, Copilot, Cursor, etc.) is welcome. Please be able to explain what your PR does without leaning on the tool.

See [`AGENTS.md`](AGENTS.md) for the conventions agents (and humans) should follow inside the repository.

## Reporting security issues

See [SECURITY.md](SECURITY.md).

## Questions

Open a [Discussion](https://github.com/nek0der/limpid/discussions) or an issue.
