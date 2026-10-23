// CodexHookInstaller.swift
// Limpid — installs our lifecycle hooks into Codex.
//
// The hooks themselves ride on the `codex` shim's command line, as `-c`
// overrides. Codex reports those under a `sessionFlags` source of their
// own, so they sit alongside whatever the user has configured rather than
// replacing it, without mirroring their whole config directory into a
// `CODEX_HOME` of our own on every launch.
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
    /// A `CODEX_HOME` is not read: the one that matters is the pane's,
    /// which its shell sets from the person's `.zshrc` or a project's
    /// `.envrc` after Limpid starts, and may differ from pane to pane. A
    /// Codex started with another home finds no trust for our hooks and
    /// does not run them (docs/known-limitations.md).
    let userCodexHome: URL

    /// Bundled `codex-shim/limpid-hook` script path. `nil` when running
    /// from a test bundle without the resource — in that case `refresh()`
    /// is a no-op and no hooks are installed.
    let hookScriptURL: URL?

    /// Bundled `codex-shim/limpid-pretool-worktree-hook` path. `nil` when
    /// missing; the lifecycle hook alone still works, only the second
    /// `PreToolUse` handler goes away.
    let worktreeHookScriptURL: URL?

    /// Bundled signed requester. It authenticates the running service and
    /// verifies its artifact identity on every request; when unavailable it
    /// publishes the lifecycle fallback and emits no approval decision.
    let approvalHelperURL: URL?

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
        worktreeHookScriptURL: URL? = nil,
        approvalHelperURL: URL? = nil
    ) {
        let userCodexHome = userCodexHome ?? CodexHookInstaller.defaultUserCodexHome()
        self.userCodexHome = userCodexHome
        self.hookScriptURL = hookScriptURL ?? CodexHookInstaller.bundledHookScript()
        self.worktreeHookScriptURL = worktreeHookScriptURL
            ?? CodexHookInstaller.bundledWorktreeHookScript()
        self.approvalHelperURL = approvalHelperURL
            ?? CodexHookInstaller.bundledHookHelper()
    }

    /// `~/.codex/` in a normal run. Under the Xcode test host it is a
    /// stray directory instead: `LimpidApp` refreshes the installer during
    /// bootstrap, and the test host runs that same bootstrap, so the
    /// default would otherwise rewrite the developer's own config on every
    /// test run. The stray path does not exist, so `refresh()` also stops
    /// at its "user has not run codex yet" guard. Mirrors the reasoning
    /// behind `LimpidPaths.applicationSupportDirectory()`, and
    /// `TestWriteGuard` refuses the real `~/.codex` besides.
    private static func defaultUserCodexHome() -> URL {
        if LimpidPaths.isRunningInTests {
            return LimpidPaths.applicationSupportDirectory()
                .appendingPathComponent("codex-home-stray", isDirectory: true)
        }
        return URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".codex", isDirectory: true)
    }

    // MARK: - Lifecycle

    /// What one `refresh` did.
    enum RefreshOutcome: Equatable {
        /// Nothing was looked at: a demo run, no hook in the bundle, or no
        /// codex home yet.
        case skipped
        /// The block was already there as it should be.
        case unchanged
        case installed
        /// The config was left as it was, because we could not read it,
        /// could not write it, or would have written one Codex refuses.
        case failed(RefreshFailure)
    }

    enum RefreshFailure: Error, Equatable {
        /// The file is there but could not be read.
        case unreadable
        /// The file is not UTF-8, so we cannot tell their lines from ours.
        case notUTF8
        /// `config.toml` is a symbolic link to nothing: writing would
        /// replace the link rather than create what it points at.
        case danglingLink
        /// Our splice would have produced a config Codex refuses to load
        /// (`CodexUserConfig.problem(in:)`), so it was not written.
        case invalidResult
        case writeFailed
    }

    /// Bring the trust block in the user's config up to date. Idempotent,
    /// and a no-op when the block already matches — a config kept under
    /// version control only shows a diff when our hooks actually change.
    /// `writesUserFiles` is the app's decision for the run: a demo run
    /// (`make screenshot`) leaves `~/.codex/config.toml` alone.
    ///
    /// A config that is there but that we cannot read is left alone, and
    /// the refresh fails: read as empty, it would be replaced by our block
    /// and nothing else, which is every model, trust and server setting the
    /// person had. A `config.toml` that is a symbolic link (a dotfiles
    /// checkout) is written through, so the link and the file it names stay
    /// what they were.
    @discardableResult
    func refresh(writesUserFiles: Bool) -> RefreshOutcome {
        guard writesUserFiles else {
            log.debug("demo mode — skipping trust block")
            return .skipped
        }
        guard let lifecycleCommand else {
            log.debug("codex-shim/limpid-hook not found in bundle; skipping trust block")
            return .skipped
        }
        // No `~/.codex/` means the user has not run codex yet. Creating
        // one for them would be presumptuous; we install on a later
        // refresh once it exists.
        guard FileManager.default.fileExists(atPath: userCodexHome.path) else {
            log.debug("user codex home missing; skipping trust block")
            return .skipped
        }
        let config: CodexConfigFile
        switch CodexConfigFile.read(userCodexHome.appendingPathComponent("config.toml")) {
        case let .success(file):
            config = file
        case let .failure(failure):
            return .failed(failure)
        }
        let updated = CodexUserConfig.applying(
            block: CodexHookInjection.trustBlock(
                lifecycleCommand: lifecycleCommand,
                worktreeCommand: worktreeCommand,
                approvalCommand: approvalCommand
            ),
            to: config.text
        )
        guard updated != config.text else { return .unchanged }
        // A config Codex cannot parse stops it from starting at all, which
        // is far worse than starting without our hooks. Whatever the fault
        // in the splice, the person's file stays as it was.
        if let problem = CodexUserConfig.problem(in: updated) {
            log.error("""
            not writing codex config \(config.target.path, privacy: .private): \
            \(problem.description, privacy: .public)
            """)
            return .failed(.invalidResult)
        }
        do {
            try SecureFileWrite.writeAtomic(config.data(for: updated), to: config.target)
            log.notice("codex hook trust installed")
            return .installed
        } catch {
            log.error("""
            write codex config \(config.target.path, privacy: .private): \
            \(String(describing: error), privacy: .private)
            """)
            return .failed(.writeFailed)
        }
    }

    /// The Codex-specific half of a pane's environment: where the receiver
    /// writes, and the flags the shim splices into its own invocation.
    /// Empty when we have no receiver to point at — the caller treats that
    /// as "no Codex integration this pane". When the run may not write the
    /// person's files (demo mode) the directories and the flags are exported
    /// empty, so neither an inherited value nor our hook writes a record;
    /// `AgentProviderRegistry.environment` says why they are named at all.
    func environment(writesRecords: Bool) -> [String: String] {
        guard let lifecycleCommand else {
            return writesRecords ? [:] : Self.blankRecordDirectories()
        }
        // The variable names come from the provider's install recipe and the
        // directories from its descriptor, so the receiver writes exactly
        // where the projection reads. Only the hook arguments are assembled
        // here, because only here is the installed hook's path known.
        var env: [String: String] = [:]
        if let directories = AgentProviderRegistry.directories(
            under: LimpidPaths.applicationSupportDirectory()
        )[AgentKind.codex.rawValue] {
            env = AgentProviderRegistry.environment(
                for: AgentKind.codex.rawValue,
                state: directories.state,
                sessions: directories.sessions,
                cwdEvents: directories.cwdEvents,
                writesRecords: writesRecords
            )
        } else {
            // Without a descriptor we have no name for the directories, and
            // the projection reads none either, so guessing one would only
            // scatter records nobody collects.
            log.error("codex provider directories unavailable; exporting no record directories")
        }
        if let variable = AgentProviderRegistry.hookArgumentsVariable(for: AgentKind.codex.rawValue) {
            let arguments = CodexHookInjection.arguments(
                lifecycleCommand: lifecycleCommand,
                worktreeCommand: worktreeCommand,
                approvalCommand: approvalCommand
            )
            env[variable] = writesRecords ? arguments.joined(separator: CodexHookInstaller.argumentSeparator) : ""
        } else {
            // The shim splices these flags into its own invocation; under a
            // name we invented it would read none of them, which is the same
            // as installing no hooks at all.
            log.error("codex recipe names no hook arguments variable; installing no hook flags")
        }
        return env
    }

    /// The record directories named and empty, for a demo pane with no hook
    /// to point at: an inherited value would otherwise still reach a hook
    /// that another build installed.
    private static func blankRecordDirectories() -> [String: String] {
        guard let directories = AgentProviderRegistry.directories(
            under: LimpidPaths.applicationSupportDirectory()
        )[AgentKind.codex.rawValue] else { return [:] }
        return AgentProviderRegistry.environment(
            for: AgentKind.codex.rawValue,
            state: directories.state,
            sessions: directories.sessions,
            cwdEvents: directories.cwdEvents,
            writesRecords: false
        )
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

    private var approvalCommand: String? {
        guard let helper = approvalHelperURL else { return nil }
        guard FileManager.default.isExecutableFile(atPath: helper.path) else { return nil }
        return Self.executableCommand(for: helper) + " permission-request codex"
    }

    private static func shellCommand(for url: URL) -> String {
        "/bin/sh " + executableCommand(for: url)
    }

    static func executableCommand(for url: URL) -> String {
        let path = url.resolvingSymlinksInPath().path
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func bundledHookScript() -> URL? {
        bundledScript(named: "limpid-hook")
    }

    static func bundledWorktreeHookScript() -> URL? {
        bundledScript(named: "limpid-pretool-worktree-hook")
    }

    /// Says in the log, at launch, when the bundle has no Hook Helper. Every
    /// hook wrapper execs it and nothing else, so without it no agent's turns
    /// are recorded: each hook call fails in the agent's pane, and this is
    /// where the logs say why.
    static func reportMissingHookHelper() {
        guard bundledHookHelper() == nil else { return }
        log.fault("AgentIntegrationHookHelper missing from the bundle; agent hooks will fail and record nothing")
    }

    /// The signed Hook Helper beside the app's executable, which both
    /// providers' hook wrappers exec and Codex calls for an approval; `nil`
    /// when the bundle lacks it.
    static func bundledHookHelper() -> URL? {
        guard let executable = Bundle.main.executableURL else { return nil }
        let helper = executable.deletingLastPathComponent()
            .appendingPathComponent("AgentIntegrationHookHelper")
        return FileManager.default.isExecutableFile(atPath: helper.path) ? helper : nil
    }

    private static func bundledScript(named name: String) -> URL? {
        guard let resources = Bundle.main.resourceURL else { return nil }
        let url = resources
            .appendingPathComponent("codex-shim", isDirectory: true)
            .appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}

/// The person's `config.toml` as we read it: where to write it back, and
/// its text.
struct CodexConfigFile {
    /// The file itself, past any symbolic links: an atomic write replaces
    /// what is at the path it is given, and given the link it would leave a
    /// regular file in its place, so the dotfiles checkout the link named
    /// would never see our block.
    let target: URL
    let text: String
    /// Whether the file began with a UTF-8 byte order mark, which the text
    /// leaves out and the write puts back.
    let hasByteOrderMark: Bool

    private static let byteOrderMark: [UInt8] = [0xEF, 0xBB, 0xBF]

    func data(for text: String) -> Data {
        (hasByteOrderMark ? Data(Self.byteOrderMark) : Data()) + Data(text.utf8)
    }

    /// Reads the config at `url`. A missing file reads as empty, since our
    /// block is then the whole of it; one that is there but cannot be read
    /// or decoded is a failure, logged here.
    static func read(_ url: URL) -> Result<CodexConfigFile, CodexHookInstaller.RefreshFailure> {
        let fm = FileManager.default
        let target = url.resolvingSymlinksInPath()
        // `fileExists` follows links; the attributes of the item itself do
        // not, which tells a dangling link from no file at all.
        let isLink = (try? fm.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType) == .typeSymbolicLink
        guard fm.fileExists(atPath: target.path) else {
            if isLink {
                log.error("codex config \(url.path, privacy: .private) is a link to nothing; leaving it alone")
                return .failure(.danglingLink)
            }
            return .success(CodexConfigFile(target: target, text: "", hasByteOrderMark: false))
        }
        let data: Data
        do {
            data = try Data(contentsOf: target)
        } catch {
            log.error("""
            read codex config \(target.path, privacy: .private): \
            \(String(describing: error), privacy: .private); leaving it alone
            """)
            return .failure(.unreadable)
        }
        let hasByteOrderMark = data.starts(with: byteOrderMark)
        guard let text = String(bytes: data.dropFirst(hasByteOrderMark ? byteOrderMark.count : 0), encoding: .utf8) else {
            log.error("codex config \(target.path, privacy: .private) is not UTF-8; leaving it alone")
            return .failure(.notUTF8)
        }
        return .success(CodexConfigFile(target: target, text: text, hasByteOrderMark: hasByteOrderMark))
    }
}
