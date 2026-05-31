// CodexHomeRedirector.swift
// Limpid — owns a Limpid-managed shadow `CODEX_HOME` directory at
// `~/Library/Application Support/Limpid/codex-home/`. The shadow dir
// is a symlink farm pointing at the user's real `~/.codex/` for every
// entry except `hooks.json` and `config.toml`, which we own.
//
// This is the "Orca pattern" — pioneered by stablyai/orca's
// `codex-runtime-home/home`. It lets us inject Limpid's lifecycle
// hooks without touching the user's `~/.codex/hooks.json` (and
// without surprising them when our hooks show up in `/hooks`).
//
// The shadow dir is rebuilt on every refresh:
//   1. ensureSymlinkFarm() — symlinks every `~/.codex/*` entry except
//      hooks.json and config.toml.
//   2. writeMirroredConfig() — copies `~/.codex/config.toml` after
//      stripping `[hooks.state.*]` blocks (they reference user-path
//      hooks.json paths that are invalid in the shadow) and appends
//      Limpid's own trust block computed via `CodexTrustHash`.
//   3. writeHooksJson() — writes a Limpid-managed `hooks.json` whose
//      handlers all point at the bundled `limpid-codex-hook` script.
//
// `environment(forPaneID:)` returns the env dict Limpid pushes into
// every Codex pty — `CODEX_HOME` set to the shadow path,
// `LIMPID_PANE_ID` + the sessions / states dirs the hook writes to.

import Foundation
import OSLog

private let log = Logger(subsystem: "dev.limpid", category: "codex.home.redirector")

@MainActor
final class CodexHomeRedirector {
    /// Singleton-style shared instance; LimpidApp owns it via env.
    static let shared = CodexHomeRedirector()

    /// Absolute URL of the user's real `~/.codex/`. Resolved at init
    /// and cached.
    let userCodexHome: URL

    /// Absolute URL of our shadow CODEX_HOME. Created (if missing)
    /// the first time `refresh()` runs.
    let shadowCodexHome: URL

    /// Bundled `limpid-codex-hook` script path. `nil` when running
    /// from a test bundle without the resource — in that case
    /// `refresh()` is a no-op.
    let hookScriptURL: URL?

    /// Bundled `limpid-codex-pretool-worktree-hook` script path. `nil`
    /// when missing from the bundle; in that case hooks.json ships
    /// without the second PreToolUse handler and the lifecycle hook
    /// alone still works.
    let worktreeHookScriptURL: URL?

    /// Subset of hook events we subscribe to. Mirrors what
    /// `limpid-codex-hook` knows how to handle. `nonisolated` so the
    /// pure `renderHooksJson` and `CodexTrustHash`-feeding helpers
    /// can read it off the main actor.
    nonisolated static let subscribedEvents: [(label: String, jsonKey: String)] = [
        (label: "session_start", jsonKey: "SessionStart"),
        (label: "user_prompt_submit", jsonKey: "UserPromptSubmit"),
        (label: "pre_tool_use", jsonKey: "PreToolUse"),
        (label: "post_tool_use", jsonKey: "PostToolUse"),
        (label: "pre_compact", jsonKey: "PreCompact"),
        (label: "post_compact", jsonKey: "PostCompact"),
        (label: "permission_request", jsonKey: "PermissionRequest"),
        (label: "stop", jsonKey: "Stop")
    ]

    /// Codex evaluates the handler's `matcher` field as a regex
    /// (Claude uses a flat string equal-match). `^Bash$` pins the
    /// worktree intercept to the exact Bash tool the way Claude's
    /// `settings.template.json` does with `"matcher": "Bash"`.
    nonisolated static let worktreeMatcher = "^Bash$"

    init(
        userCodexHome: URL = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".codex", isDirectory: true),
        shadowCodexHome: URL? = nil,
        hookScriptURL: URL? = nil,
        worktreeHookScriptURL: URL? = nil
    ) {
        self.userCodexHome = userCodexHome
        self.shadowCodexHome = shadowCodexHome ?? LimpidPaths.applicationSupportDirectory()
            .appendingPathComponent("codex-home", isDirectory: true)
        self.hookScriptURL = hookScriptURL ?? CodexHomeRedirector.bundledHookScript()
        self.worktreeHookScriptURL = worktreeHookScriptURL ?? CodexHomeRedirector.bundledWorktreeHookScript()
    }

    /// Where the hook receiver writes session records. Mirrors
    /// `CodexSessionStore.directory`.
    static var sessionsDirectoryURL: URL {
        LimpidPaths.applicationSupportDirectory()
            .appendingPathComponent("codex-sessions", isDirectory: true)
    }

    /// Where the hook receiver writes agent lifecycle records.
    static var agentStatesDirectoryURL: URL {
        LimpidPaths.applicationSupportDirectory()
            .appendingPathComponent("codex-agent-states", isDirectory: true)
    }

    // MARK: - Lifecycle

    /// Rebuild the shadow dir from scratch (idempotent). Call once on
    /// app launch and again whenever the user's `~/.codex/hooks.json`
    /// or `~/.codex/config.toml` mtime changes (watcher TBD in a
    /// follow-up; for now LimpidApp just calls this at bootstrap).
    func refresh() {
        // Demo mode (`LIMPID_DEMO=1`, e.g. `make screenshot`) wires
        // up a synthetic WindowSession and must not touch real-user
        // state on disk. Bail out so the demo build never creates a
        // shadow CODEX_HOME on a test fixture's behalf.
        if ProcessInfo.processInfo.environment["LIMPID_DEMO"] == "1" {
            log.debug("LIMPID_DEMO=1 — skipping shadow build")
            return
        }
        guard let hookScriptURL else {
            log.debug("limpid-codex-hook not found in bundle; skipping shadow build")
            return
        }
        let fm = FileManager.default
        guard fm.fileExists(atPath: userCodexHome.path) else {
            // No `~/.codex/` — user hasn't run codex yet. Nothing to
            // mirror; we'll rebuild on the next refresh once they do.
            log.debug("user codex home missing at \(self.userCodexHome.path, privacy: .public); skipping")
            return
        }

        SecureFileWrite.ensureUserOnlyDirectory(shadowCodexHome)
        ensureSymlinkFarm()
        writeMirroredConfigAndTrust(hookScriptURL: hookScriptURL)
        writeHooksJson(hookScriptURL: hookScriptURL)
        log.notice("shadow CODEX_HOME ready at \(self.shadowCodexHome.path, privacy: .public)")
    }

    /// Env-var dictionary the pty inherits. Returns an empty dict
    /// when we have no shim resource OR when demo mode is active —
    /// the caller treats that as "no Codex integration this pane",
    /// which is safe. The demo-mode gate has to match `refresh()`
    /// so the demo build never ends up routing a pty at a
    /// non-existent shadow CODEX_HOME.
    func environment(forPaneID paneID: UUID?) -> [String: String] {
        guard hookScriptURL != nil else { return [:] }
        if ProcessInfo.processInfo.environment["LIMPID_DEMO"] == "1" { return [:] }
        var env: [String: String] = [:]
        // Only redirect CODEX_HOME when the shadow dir actually exists.
        // `refresh()` bails before creating it when the user has no
        // `~/.codex/` yet, so exporting the path unconditionally would
        // point every pty — and any `codex` the user runs by hand — at a
        // non-existent home, which the Codex CLI treats as a fatal error.
        if FileManager.default.fileExists(atPath: shadowCodexHome.path) {
            env["CODEX_HOME"] = shadowCodexHome.path
        }
        if let id = paneID {
            env["LIMPID_PANE_ID"] = id.uuidString
        }
        env["LIMPID_CODEX_SESSIONS_DIR"] = CodexHomeRedirector.sessionsDirectoryURL.path
        env["LIMPID_CODEX_AGENT_STATES_DIR"] = CodexHomeRedirector.agentStatesDirectoryURL.path
        return env
    }

    // MARK: - Symlink farm

    private func ensureSymlinkFarm() {
        let fm = FileManager.default
        let userEntries: [String]
        do {
            userEntries = try fm.contentsOfDirectory(atPath: userCodexHome.path)
        } catch {
            log.error("contentsOfDirectory \(self.userCodexHome.path, privacy: .public): \(String(describing: error), privacy: .public)")
            return
        }

        let ownedNames: Set = ["hooks.json", "config.toml"]

        // Drop any stale entries (symlinks pointing at deleted files,
        // junk left over from previous shadows). We do NOT touch
        // hooks.json or config.toml — those are rewritten below.
        if let existing = try? fm.contentsOfDirectory(atPath: shadowCodexHome.path) {
            for name in existing where !ownedNames.contains(name) {
                let url = shadowCodexHome.appendingPathComponent(name)
                try? fm.removeItem(at: url)
            }
        }

        for name in userEntries where !ownedNames.contains(name) {
            let target = userCodexHome.appendingPathComponent(name)
            let link = shadowCodexHome.appendingPathComponent(name)
            do {
                try fm.createSymbolicLink(at: link, withDestinationURL: target)
            } catch {
                log.error("symlink \(name, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    // MARK: - config.toml mirror + trust block

    /// Copy `~/.codex/config.toml` into the shadow dir with:
    /// 1. `[hooks.state."<shadow>:..."]` blocks stripped (they get
    ///    regenerated with fresh trust hashes below). Third-party
    ///    tools' trust entries are preserved.
    /// 2. The `[tui]` section's `terminal_title` forced to `[]` so
    ///    Codex doesn't write its animating braille spinner into the
    ///    OSC 2 title — Limpid mirrors that title into the L2 sidebar
    ///    and the constant updates make tab titles flicker. Mirrors
    ///    the Claude-side `CLAUDE_CODE_DISABLE_TERMINAL_TITLE=1`
    ///    trick the claude-shim already applies.
    /// 3. Our trust block appended — one `[hooks.state."<shadow>:<event>:0:0"]`
    ///    per subscribed event with `enabled = true` and the matching
    ///    SHA-256 `trusted_hash`.
    private func writeMirroredConfigAndTrust(hookScriptURL: URL) {
        let userConfigURL = userCodexHome.appendingPathComponent("config.toml")
        let userConfig: String
        do {
            userConfig = try String(contentsOf: userConfigURL, encoding: .utf8)
        } catch {
            // No config.toml in user dir — write a minimal one.
            userConfig = ""
            log.debug("user config.toml missing; writing minimal mirror")
        }

        let stripped = Self.stripHookStateBlocks(
            userConfig,
            ownedHooksJsonPath: canonicalHooksJsonPath()
        )
        let suppressed = Self.injectTitleSuppression(stripped)
        let trustBlock = buildTrustBlock(hookScriptURL: hookScriptURL)
        let merged = suppressed + "\n" + trustBlock

        let outURL = shadowCodexHome.appendingPathComponent("config.toml")
        do {
            try SecureFileWrite.writeAtomic(Data(merged.utf8), to: outURL)
        } catch {
            log.error("write shadow config.toml: \(String(describing: error), privacy: .public)")
        }
    }

    /// Force `tui.terminal_title = []` in the mirrored config. Three
    /// cases to handle:
    /// 1. The user already has a `[tui]` section — insert
    ///    `terminal_title = []` immediately after the header,
    ///    stripping any existing `terminal_title` line within the
    ///    same section to avoid duplicate-key TOML errors.
    /// 2. The user has no `[tui]` section — append one at the end
    ///    with just our override.
    ///
    /// Multi-line strings / nested arrays that span the `[tui]`
    /// region are not parsed; in practice user configs use plain
    /// scalar fields under `[tui]` so the line-based walk is safe.
    nonisolated static func injectTitleSuppression(_ toml: String) -> String {
        var inTuiSection = false
        var tuiSeen = false
        var filtered: [String] = []
        for line in toml.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") {
                inTuiSection = (trimmed == "[tui]")
                if inTuiSection { tuiSeen = true }
                filtered.append(line)
                continue
            }
            // Skip any prior `terminal_title = ...` while inside [tui]
            // so we don't end up with a duplicate after the inject.
            if inTuiSection, trimmed.hasPrefix("terminal_title") {
                continue
            }
            filtered.append(line)
        }

        if tuiSeen {
            // Insert directly after the [tui] header.
            if let headerIdx = filtered.firstIndex(where: {
                $0.trimmingCharacters(in: .whitespaces) == "[tui]"
            }) {
                filtered.insert("terminal_title = []", at: headerIdx + 1)
            }
        } else {
            // No [tui] section at all — append.
            filtered.append("")
            filtered.append("[tui]")
            filtered.append("terminal_title = []")
        }
        return filtered.joined(separator: "\n")
    }

    /// Strip ONLY `[hooks.state."..."]` blocks that reference our
    /// shadow hooks.json path — those are re-generated below with
    /// fresh hashes. Leave user-path entries (the bare `[hooks.state]`
    /// header plus blocks pointing at `~/.codex/hooks.json` or any
    /// other co-resident tool's hooks.json) intact, so:
    ///
    /// - Trust state for third-party hooks (e.g. Superset's
    ///   `notify.sh`) carries through into the shadow config, and
    ///   Codex doesn't keep prompting "Hooks need review" on every
    ///   Limpid launch.
    /// - When the user runs `/hooks → Trust all` inside Limpid-
    ///   launched codex, their click persists across restarts.
    ///
    /// Caller passes the canonical shadow hooks.json path; any
    /// `[hooks.state."<that-path>:..."]` block is dropped, everything
    /// else passes through.
    nonisolated static func stripHookStateBlocks(
        _ toml: String,
        ownedHooksJsonPath: String
    ) -> String {
        // The owned prefix lets us match `[hooks.state."<path>:...`
        // without overmatching user paths that happen to share a
        // prefix. We also need the escaped form because TOML escapes
        // `\` and `"` inside basic strings.
        let escapedPath = ownedHooksJsonPath
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let ownedPrefix = "[hooks.state.\"\(escapedPath):"

        var lines: [Substring] = []
        var inOwnedBlock = false
        for line in toml.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // A new section header always ends the previous block.
            if trimmed.hasPrefix("[") {
                if trimmed.hasPrefix(ownedPrefix) {
                    inOwnedBlock = true
                    continue
                }
                inOwnedBlock = false
            }
            if !inOwnedBlock {
                lines.append(line)
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Build `[hooks.state."<key>"]` blocks for every subscribed
    /// event. Output ends with a trailing newline so appending to
    /// the mirrored config doesn't glue our block onto the previous
    /// line.
    ///
    /// For `PreToolUse` we emit a second block keyed at
    /// `groupIndex=1` covering the worktree intercept handler (see
    /// `writeHooksJson` for the corresponding entry). The two blocks
    /// must match the two groups inside hooks.json exactly — Codex
    /// re-hashes the file on every change, and a missing trust entry
    /// would silently disable our intercept under
    /// `--dangerously-bypass-hook-trust`.
    private func buildTrustBlock(hookScriptURL: URL) -> String {
        let canonical = hookScriptURL.resolvingSymlinksInPath().path
        let hooksJsonCanonical = canonicalHooksJsonPath()
        let command = hookCommand(hookScriptCanonicalPath: canonical)
        let worktreeCmd = worktreeCommand()

        var out = ""
        out += "# Limpid-managed Codex hook trust. Regenerated on every app launch.\n"
        for ev in Self.subscribedEvents {
            let hash = CodexTrustHash.compute(
                eventLabel: ev.label,
                command: command,
                timeoutSec: 600,
                isAsync: false
            )
            let key = CodexTrustHash.trustKey(
                hooksJsonPath: hooksJsonCanonical,
                eventLabel: ev.label
            )
            out += "[hooks.state.\"\(escapeTomlKey(key))\"]\n"
            out += "enabled = true\n"
            out += "trusted_hash = \"\(hash)\"\n"

            if ev.jsonKey == "PreToolUse", let worktreeCmd {
                let worktreeHash = CodexTrustHash.compute(
                    eventLabel: ev.label,
                    command: worktreeCmd,
                    timeoutSec: 600,
                    isAsync: false,
                    matcher: Self.worktreeMatcher
                )
                let worktreeKey = CodexTrustHash.trustKey(
                    hooksJsonPath: hooksJsonCanonical,
                    eventLabel: ev.label,
                    groupIndex: 1,
                    handlerIndex: 0
                )
                out += "[hooks.state.\"\(escapeTomlKey(worktreeKey))\"]\n"
                out += "enabled = true\n"
                out += "trusted_hash = \"\(worktreeHash)\"\n"
            }
        }
        return out
    }

    /// TOML basic-string escape for keys. Keys go inside `"..."` so
    /// `"` and `\` must be escaped. macOS paths rarely contain them,
    /// but defensive coding for paths under e.g. an external SSD with
    /// weird mount points.
    private func escapeTomlKey(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    // MARK: - hooks.json writer

    /// Write a Limpid-managed `hooks.json` to the shadow dir.
    private func writeHooksJson(hookScriptURL: URL) {
        let canonical = hookScriptURL.resolvingSymlinksInPath().path
        let command = hookCommand(hookScriptCanonicalPath: canonical)
        let worktreeCmd = worktreeCommand()

        let out = Self.renderHooksJson(
            lifecycleCommand: command,
            worktreeCommand: worktreeCmd
        )

        let outURL = shadowCodexHome.appendingPathComponent("hooks.json")
        do {
            try SecureFileWrite.writeAtomic(Data(out.utf8), to: outURL)
        } catch {
            log.error("write shadow hooks.json: \(String(describing: error), privacy: .public)")
        }
    }

    /// Pure renderer for the shadow `hooks.json`. PreToolUse gets two
    /// groups: group 0 is the lifecycle handler (same as every other
    /// event), group 1 is the worktree intercept handler matched on
    /// `^Bash$`. The Claude-side analogue is
    /// `settings.template.json`'s two-entry PreToolUse array. Pure
    /// (no I/O, no instance state) so tests can pin the exact byte
    /// output — Codex re-hashes hooks.json on every change, and a
    /// drifted byte means a broken trust match.
    ///
    /// We build the JSON manually rather than via `JSONSerialization`
    /// because we control every byte: the exact serialisation must
    /// match what `CodexTrustHash.compute` would re-hash if we
    /// re-derived the trust block from the file on disk.
    nonisolated static func renderHooksJson(
        lifecycleCommand: String,
        worktreeCommand: String?
    ) -> String {
        var out = "{\"hooks\":{"
        let parts: [String] = subscribedEvents.map { ev in
            let handler = "{\"type\":\"command\",\"command\":\(jsonString(lifecycleCommand))}"
            var groups = "{\"hooks\":[\(handler)]}"
            if ev.jsonKey == "PreToolUse", let worktreeCommand {
                let worktreeHandler = "{\"type\":\"command\",\"command\":\(jsonString(worktreeCommand))}"
                let worktreeGroup = "{\"matcher\":\(jsonString(worktreeMatcher)),\"hooks\":[\(worktreeHandler)]}"
                groups += "," + worktreeGroup
            }
            return "\(jsonString(ev.jsonKey)):[\(groups)]"
        }
        out += parts.joined(separator: ",")
        out += "}}"
        return out
    }

    /// Canonicalised `/bin/sh '<path>'` invocation for the worktree
    /// hook script — `nil` when the bundled script is missing. Used by
    /// both `writeHooksJson` and `buildTrustBlock` so the byte-exact
    /// command string is computed in exactly one place.
    private func worktreeCommand() -> String? {
        worktreeHookScriptURL.map {
            hookCommand(hookScriptCanonicalPath: $0.resolvingSymlinksInPath().path)
        }
    }

    /// Realpath of the shadow `hooks.json`. The trust block key must
    /// reference the canonicalized path because Codex calls
    /// `realpath()` on hooks.json before keying the trust state.
    private func canonicalHooksJsonPath() -> String {
        let url = shadowCodexHome.appendingPathComponent("hooks.json")
        // We can't realpath before the file exists; instead we
        // realpath the parent dir and append. The parent always
        // exists (we created it above) and realpath of a non-existent
        // file is unreliable across macOS / Linux.
        let parent = shadowCodexHome.resolvingSymlinksInPath().path
        return parent + "/" + url.lastPathComponent
    }

    /// Exact `command` string written into hooks.json. Both the
    /// `[hooks.state]` trust hash and the hooks.json handler must use
    /// the byte-identical command for Codex to recognise the hook as
    /// trusted; even a trailing space breaks the hash match.
    private func hookCommand(hookScriptCanonicalPath: String) -> String {
        "/bin/sh \(singleQuote(hookScriptCanonicalPath))"
    }

    private func singleQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    nonisolated static func jsonString(_ s: String) -> String {
        var out = "\""
        for char in s.unicodeScalars {
            switch char {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if char.value < 0x20 {
                    out += String(format: "\\u%04x", char.value)
                } else {
                    out.unicodeScalars.append(char)
                }
            }
        }
        out += "\""
        return out
    }

    // MARK: - Bundle lookup

    /// Locate `Limpid.app/Contents/Resources/codex-shim/limpid-codex-hook`.
    /// Returns `nil` if missing (test bundles, broken installs).
    static func bundledHookScript() -> URL? {
        guard let resources = Bundle.main.resourceURL else { return nil }
        let url = resources
            .appendingPathComponent("codex-shim", isDirectory: true)
            .appendingPathComponent("limpid-codex-hook")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Locate `Limpid.app/Contents/Resources/codex-shim/limpid-codex-pretool-worktree-hook`.
    /// Returns `nil` if missing — in that case hooks.json is built
    /// without the second PreToolUse handler and the lifecycle
    /// integration alone keeps working.
    static func bundledWorktreeHookScript() -> URL? {
        guard let resources = Bundle.main.resourceURL else { return nil }
        let url = resources
            .appendingPathComponent("codex-shim", isDirectory: true)
            .appendingPathComponent("limpid-codex-pretool-worktree-hook")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}
