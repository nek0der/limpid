// CodexHookInstaller.swift
// Weir — installs our lifecycle hooks into Codex.
//
// The hooks ride on the `codex` shim's command line as `-c` overrides,
// trust and all (`CodexHookInjection`). Codex reports those under a
// `sessionFlags` source of their own, so they sit alongside whatever the
// user has configured rather than replacing it, and nothing is written to
// the user's own `~/.codex/config.toml`. All that is left to do there is
// take out the trust tables earlier builds kept in it (`CodexUserConfig`).

import Foundation
import OSLog

private let log = Logger.weir("codex.hook.installer")

@MainActor
final class CodexHookInstaller {
    /// Singleton-style shared instance; WeirApp owns it via env.
    static let shared = CodexHookInstaller()

    /// The codex home whose config may still hold the trust tables an
    /// earlier build wrote. `~/.codex/` in a normal run; see
    /// `defaultUserCodexHome()` for the exception. A `CODEX_HOME` is not
    /// read: earlier builds wrote only into `~/.codex/config.toml`.
    let userCodexHome: URL

    /// Bundled `codex-shim/weir-hook` script path. `nil` when running
    /// from a test bundle without the resource — in that case no hooks are
    /// installed.
    let hookScriptURL: URL?

    /// Bundled `codex-shim/weir-pretool-worktree-hook` path. `nil` when
    /// missing; the lifecycle hook alone still works, only the second
    /// `PreToolUse` handler goes away.
    let worktreeHookScriptURL: URL?

    /// Bundled signed requester. It authenticates the running service and
    /// verifies its artifact identity on every request; when unavailable it
    /// publishes the lifecycle fallback and emits no approval decision.
    let approvalHelperURL: URL?

    /// Separator for `WEIR_CODEX_HOOK_ARGS`. Newline because every
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
    /// stray directory instead: `WeirApp` cleans the config during
    /// bootstrap, and the test host runs that same bootstrap, so the
    /// default would otherwise rewrite the developer's own config on every
    /// test run. The stray path does not exist, so `removeLegacyTrust`
    /// also stops at its "no codex home" guard. Mirrors the reasoning
    /// behind `WeirPaths.applicationSupportDirectory()`, and
    /// `TestWriteGuard` refuses the real `~/.codex` besides.
    private static func defaultUserCodexHome() -> URL {
        if WeirPaths.isRunningInTests {
            return WeirPaths.applicationSupportDirectory()
                .appendingPathComponent("codex-home-stray", isDirectory: true)
        }
        return URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".codex", isDirectory: true)
    }

    // MARK: - Lifecycle

    /// What one `removeLegacyTrust` did.
    enum CleanupOutcome: Equatable {
        /// Nothing was looked at: a demo run, or no codex home.
        case skipped
        /// The config holds nothing of ours.
        case unchanged
        case removed
        /// The config was left as it was, because we could not read it,
        /// could not write it, or would have written one Codex refuses.
        case failed(CleanupFailure)
    }

    enum CleanupFailure: Error, Equatable {
        /// The file is there but could not be read.
        case unreadable
        /// The file is not UTF-8, so we cannot tell their lines from ours.
        case notUTF8
        /// `config.toml` is a symbolic link to nothing: writing would
        /// replace the link rather than create what it points at.
        case danglingLink
        /// Our edit would have produced a config Codex refuses to load
        /// (`CodexUserConfig.problem(in:)`), so it was not written.
        case invalidResult
        case writeFailed
    }

    /// Take the trust tables an earlier build wrote out of the user's
    /// config. Earlier builds rewrote them at every launch, with a hash
    /// that covered the bundle path they ran from, so a table left behind
    /// would only hold a stale hash; Codex now takes ours from the flags.
    /// A no-op when the file holds nothing of ours, so a config kept under
    /// version control shows a diff only once. `writesUserFiles` is the
    /// app's decision for the run: a demo run (`make screenshot`) leaves
    /// `~/.codex/config.toml` alone.
    ///
    /// A config that is there but that we cannot read is left alone, and
    /// the cleanup fails. A `config.toml` that is a symbolic link (a
    /// dotfiles checkout) is written through, so the link and the file it
    /// names stay what they were.
    @discardableResult
    func removeLegacyTrust(writesUserFiles: Bool) -> CleanupOutcome {
        guard writesUserFiles else {
            log.debug("demo mode — leaving codex config alone")
            return .skipped
        }
        guard FileManager.default.fileExists(atPath: userCodexHome.path) else {
            return .skipped
        }
        let config: CodexConfigFile
        switch CodexConfigFile.read(userCodexHome.appendingPathComponent("config.toml")) {
        case let .success(file):
            config = file
        case let .failure(failure):
            return .failed(failure)
        }
        let updated = CodexUserConfig.removing(keys: CodexUserConfig.legacyTrustKeys, from: config.text)
        guard updated != config.text else { return .unchanged }
        // A config Codex cannot parse stops it from starting at all. Whatever
        // the fault in our edit, the person's file stays as it was, and the
        // tables left in it do no harm: the flags' trust takes precedence.
        if let problem = CodexUserConfig.problem(in: updated) {
            log.error("""
            not writing codex config \(config.target.path, privacy: .private): \
            \(problem.description, privacy: .public)
            """)
            return .failed(.invalidResult)
        }
        do {
            try SecureFileWrite.writeAtomic(config.data(for: updated), to: config.target)
            log.notice("removed legacy codex hook trust")
            return .removed
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
            under: WeirPaths.applicationSupportDirectory()
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
            under: WeirPaths.applicationSupportDirectory()
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
        bundledScript(named: "weir-hook")
    }

    static func bundledWorktreeHookScript() -> URL? {
        bundledScript(named: "weir-pretool-worktree-hook")
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
    /// would never see our edit.
    let target: URL
    let text: String
    /// Whether the file began with a UTF-8 byte order mark, which the text
    /// leaves out and the write puts back.
    let hasByteOrderMark: Bool

    private static let byteOrderMark: [UInt8] = [0xEF, 0xBB, 0xBF]

    func data(for text: String) -> Data {
        (hasByteOrderMark ? Data(Self.byteOrderMark) : Data()) + Data(text.utf8)
    }

    /// Reads the config at `url`. A missing file reads as empty, which holds
    /// nothing of ours; one that is there but cannot be read
    /// or decoded is a failure, logged here.
    static func read(_ url: URL) -> Result<CodexConfigFile, CodexHookInstaller.CleanupFailure> {
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
