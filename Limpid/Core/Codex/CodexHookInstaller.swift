// CodexHookInstaller.swift
// Limpid — installs our lifecycle hooks into Codex.
//
// The hooks themselves ride on the `codex` shim's command line, as `-c`
// overrides. Codex reports those under a `sessionFlags` source of their
// own, so they sit alongside whatever the user has configured rather than
// replacing it — which is what the shadow `CODEX_HOME` this replaced
// existed to achieve, at the cost of mirroring their whole config
// directory on every launch.
//
// What a flag cannot carry is trust: Codex refuses to run a hook whose
// hash is not recorded, and it deliberately ignores a trust entry supplied
// by the same flags that define the hook. So one block, and only that
// block, is written into the user's own `~/.codex/config.toml`. See
// `CodexUserConfig` for how narrowly that write is scoped.

import Foundation
import OSLog

private let log = Logger.limpid("codex.hook.installer")

@MainActor
final class CodexHookInstaller {
    /// Singleton-style shared instance; LimpidApp owns it via env.
    static let shared = CodexHookInstaller()

    /// The codex home whose config carries our trust block. `~/.codex/`
    /// in a normal run — see `defaultUserCodexHome()` for the exception.
    let userCodexHome: URL

    /// Bundled `codex-shim/limpid-hook` script path. `nil` when running
    /// from a test bundle without the resource — in that case `refresh()`
    /// is a no-op and no hooks are installed.
    let hookScriptURL: URL?

    /// Bundled `codex-shim/limpid-pretool-worktree-hook` path. `nil` when
    /// missing; the lifecycle hook alone still works, only the second
    /// `PreToolUse` handler goes away.
    let worktreeHookScriptURL: URL?

    /// One hook event we ask Codex to call us on.
    struct SubscribedEvent {
        /// Our own name for the event. Doubles as the group segment of the
        /// trust key, so changing it invalidates that entry.
        let label: String
        /// The name Codex uses, both as the `hooks.<key>` table and as the
        /// payload's `hook_event_name`.
        let jsonKey: String
        /// Part of the identity Codex hashes, so it has to be stated
        /// rather than left to a default: measured 2026-09, the two events
        /// that end a session or a turn abruptly default to one second
        /// while every other event defaults to 600, and `SessionEnd`
        /// refuses anything above three. Hashing all of them at 600 left
        /// those two permanently `modified`, which is to say never run.
        let timeoutSec: Int
    }

    /// Hook events we subscribe to. Mirrors what `codex-shim/limpid-hook`
    /// knows how to handle. `nonisolated` so the pure builders in
    /// `CodexHookInjection` can read it off the main actor.
    nonisolated static let subscribedEvents: [SubscribedEvent] = [
        SubscribedEvent(label: "session_start", jsonKey: "SessionStart", timeoutSec: 600),
        SubscribedEvent(label: "session_end", jsonKey: "SessionEnd", timeoutSec: 1),
        SubscribedEvent(label: "user_prompt_submit", jsonKey: "UserPromptSubmit", timeoutSec: 600),
        SubscribedEvent(label: "pre_tool_use", jsonKey: "PreToolUse", timeoutSec: 600),
        SubscribedEvent(label: "post_tool_use", jsonKey: "PostToolUse", timeoutSec: 600),
        SubscribedEvent(label: "pre_compact", jsonKey: "PreCompact", timeoutSec: 600),
        SubscribedEvent(label: "post_compact", jsonKey: "PostCompact", timeoutSec: 600),
        SubscribedEvent(label: "permission_request", jsonKey: "PermissionRequest", timeoutSec: 600),
        SubscribedEvent(label: "interrupt", jsonKey: "Interrupt", timeoutSec: 1),
        SubscribedEvent(label: "stop", jsonKey: "Stop", timeoutSec: 600)
    ]

    /// Codex evaluates the handler's `matcher` field as a regex (Claude
    /// uses a flat string equal-match). `^Bash$` pins the worktree
    /// intercept to the exact Bash tool the way Claude's
    /// `settings.template.json` does with `"matcher": "Bash"`.
    nonisolated static let worktreeMatcher = "^Bash$"

    /// Separator for `LIMPID_CODEX_HOOK_ARGS`. Newline because every
    /// fragment we generate is single-line, and the shim can split on it
    /// with nothing but `IFS`.
    nonisolated static let argumentSeparator = "\n"

    init(
        userCodexHome: URL? = nil,
        hookScriptURL: URL? = nil,
        worktreeHookScriptURL: URL? = nil
    ) {
        let userCodexHome = userCodexHome ?? CodexHookInstaller.defaultUserCodexHome()
        self.userCodexHome = userCodexHome
        self.hookScriptURL = hookScriptURL ?? CodexHookInstaller.bundledHookScript()
        self.worktreeHookScriptURL = worktreeHookScriptURL
            ?? CodexHookInstaller.bundledWorktreeHookScript()
    }

    /// `~/.codex/` in a normal run. Under the Xcode test host it is a
    /// stray directory instead: `LimpidApp` refreshes the installer during
    /// bootstrap, and the test host runs that same bootstrap, so the
    /// default would otherwise rewrite the developer's own config on every
    /// test run. The stray path does not exist, so `refresh()` also stops
    /// at its "user has not run codex yet" guard. Mirrors the reasoning
    /// behind `LimpidPaths.applicationSupportDirectoryName`.
    private static func defaultUserCodexHome() -> URL {
        if LimpidPaths.isRunningInTests {
            return LimpidPaths.applicationSupportDirectory()
                .appendingPathComponent("codex-home-stray", isDirectory: true)
        }
        return URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".codex", isDirectory: true)
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

    /// Bring the trust block in the user's config up to date. Idempotent,
    /// and a no-op when the block already matches — a config kept under
    /// version control only shows a diff when our hooks actually change.
    func refresh() {
        // Demo mode (`LIMPID_DEMO=1`, e.g. `make screenshot`) must not
        // touch real-user state on disk.
        if ProcessInfo.processInfo.environment["LIMPID_DEMO"] == "1" {
            log.debug("LIMPID_DEMO=1 — skipping trust block")
            return
        }
        guard let lifecycleCommand else {
            log.debug("codex-shim/limpid-hook not found in bundle; skipping trust block")
            return
        }
        let configURL = userCodexHome.appendingPathComponent("config.toml")
        // No `~/.codex/` means the user has not run codex yet. Creating
        // one for them would be presumptuous; we install on a later
        // refresh once it exists.
        guard FileManager.default.fileExists(atPath: userCodexHome.path) else {
            log.debug("user codex home missing; skipping trust block")
            return
        }
        let existing = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
        let updated = CodexUserConfig.applying(
            block: CodexHookInjection.trustBlock(
                lifecycleCommand: lifecycleCommand,
                worktreeCommand: worktreeCommand
            ),
            to: existing
        )
        guard updated != existing else { return }
        do {
            try SecureFileWrite.writeAtomic(Data(updated.utf8), to: configURL)
            log.notice("codex hook trust installed")
        } catch {
            log.error("write codex config: \(String(describing: error), privacy: .public)")
        }
    }

    /// The Codex-specific half of a pane's environment: where the receiver
    /// writes, and the flags the shim splices into its own invocation.
    /// Empty when we have no receiver to point at, or in demo mode — the
    /// caller treats that as "no Codex integration this pane".
    func environment() -> [String: String] {
        guard let lifecycleCommand else { return [:] }
        if ProcessInfo.processInfo.environment["LIMPID_DEMO"] == "1" {
            return [:]
        }
        return [
            "LIMPID_CODEX_SESSIONS_DIR": CodexHookInstaller.sessionsDirectoryURL.path,
            "LIMPID_CODEX_AGENT_STATES_DIR": CodexHookInstaller.agentStatesDirectoryURL.path,
            "LIMPID_CODEX_HOOK_ARGS": CodexHookInjection.arguments(
                lifecycleCommand: lifecycleCommand,
                worktreeCommand: worktreeCommand
            ).joined(separator: CodexHookInstaller.argumentSeparator)
        ]
    }

    // MARK: - Commands

    /// Codex passes each `command` to `sh -c`, so the path is quoted here
    /// rather than relying on the caller. Symlinks are resolved because
    /// the string is hashed and Codex compares against the resolved form.
    private var lifecycleCommand: String? {
        hookScriptURL.map { Self.shellCommand(for: $0) }
    }

    private var worktreeCommand: String? {
        worktreeHookScriptURL.map { Self.shellCommand(for: $0) }
    }

    private static func shellCommand(for url: URL) -> String {
        let path = url.resolvingSymlinksInPath().path
        return "/bin/sh '" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func bundledHookScript() -> URL? {
        bundledScript(named: "limpid-hook")
    }

    static func bundledWorktreeHookScript() -> URL? {
        bundledScript(named: "limpid-pretool-worktree-hook")
    }

    private static func bundledScript(named name: String) -> URL? {
        guard let resources = Bundle.main.resourceURL else { return nil }
        let url = resources
            .appendingPathComponent("codex-shim", isDirectory: true)
            .appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}
