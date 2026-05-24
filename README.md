# Limpid

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![CI](https://github.com/nek0der/limpid/actions/workflows/ci.yml/badge.svg)](https://github.com/nek0der/limpid/actions/workflows/ci.yml)
![macOS 26+](https://img.shields.io/badge/macOS-26%2B-black)

> A macOS-native terminal for the AI coding agent era — built on libghostty, designed around projects, worktrees, and parallel sessions.

<p align="center"><img src=".github/assets/hero.png" alt="Limpid screenshot" width="800" /></p>

## Why Limpid?

- **libghostty under a Mac-native shell.** Ghostty's renderer + parser + shell-integration core, wrapped in a SwiftUI app that feels like something Apple would ship — Liquid Glass chrome, full IME, native menus, Sparkle updates.
- **Projects and worktrees are first-class.** A three-pane sidebar (loose tabs → groups → projects → git worktrees) keeps every repository, branch, and agent session in its own scope. No more 30 anonymous tabs.
- **Built for parallel AI sessions.** Tab/group/project containers are designed so a Claude Code or Codex run can own its own pane tree without colliding with your editing shell.

## Status

**Pre-alpha**, but usable for everyday terminal work. Requires **macOS 26 (Tahoe) or later** and Apple Silicon. APIs and storage format may change between minor versions; auto-updates will pick up breaking changes for you.

## Install

Grab the latest signed + notarized DMG from the [Releases page](https://github.com/nek0der/limpid/releases/latest), open it, and drag `Limpid.app` to `/Applications`. Sparkle handles updates from then on.

If you want to hack on Limpid instead, see [CONTRIBUTING.md](CONTRIBUTING.md#setup) for build instructions.

## Usage

Limpid is a SwiftUI app — all commands live in the macOS menu bar with their keyboard shortcuts shown next to each item. `⌘,` opens Settings. The sidebar (`⌘B` to toggle) is the main navigation surface for tabs, groups, projects, and git worktrees.

## Roadmap

See [open issues](https://github.com/nek0der/limpid/issues) and the [`roadmap` label](https://github.com/nek0der/limpid/issues?q=is%3Aissue+label%3Aroadmap) for what's planned next.

## Contributing

PRs welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) for the workflow, [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md) for ground rules, and [SECURITY.md](SECURITY.md) for vulnerability reporting. Release notes live in [CHANGELOG.md](CHANGELOG.md). Questions and ideas: [Discussions](https://github.com/nek0der/limpid/discussions).

## License

[MIT](LICENSE) © 2026 nek0der
