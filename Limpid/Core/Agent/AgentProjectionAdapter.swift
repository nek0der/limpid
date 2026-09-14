// AgentProjectionAdapter.swift
// Limpid — one pass of the Rust projection, applied to the interface.

import Foundation
import OSLog

private let log = Logger.limpid("agent.projection.adapter")

/// Drives one projection pass and applies its answer.
///
/// Everything this does is either looking something up that only this process
/// can (which files are there, which processes are alive, where the user is
/// looking) or applying an answer. No rule lives here: which badge a pane
/// shows, which change is worth announcing, and which record is safe to retire
/// are all decided on the other side of the boundary.
///
/// A pass is explicit rather than self-triggering. The directory watches and
/// the liveness timer that call it land when this replaces the trackers; until
/// then the tests drive it, which is also how it is compared against the path
/// it replaces.
@MainActor
final class AgentProjectionAdapter {
    private let directories: [String: AgentDirectories]
    private let descriptors: [String: AgentProviderDescriptor]
    private let executor: AgentCommandExecutor
    private let processStatus: (String?) -> AgentProcessStatus
    /// Read here as well as written through the executor: an intent is the
    /// evidence that a run was killed at quit rather than lost, and the rules
    /// retire a run whose intent they were not told about.
    private let resumeIntents: AgentResumeIntentStore

    private weak var session: WindowSession?
    private weak var attention: AttentionState?
    private weak var tmuxPresence: TmuxPanePresence?

    /// Opaque to this process: what one pass produced, handed back to the
    /// next. Reading it here would make its shape a contract.
    private var carried: Data?
    /// What the previous pass's commands came to, reported once and then
    /// dropped so an outcome cannot be replayed.
    private var pending: [AgentCommandOutcome] = []
    private var hasBootstrapped = false
    /// Why the last pass could not run, if it could not. Kept because a pass
    /// that fails changes nothing visible, so without this the only evidence
    /// is a log line nobody is watching.
    private(set) var lastFailure: String?

    init(
        directories: [String: AgentDirectories],
        descriptors: [String: AgentProviderDescriptor],
        resumeIntents: AgentResumeIntentStore,
        processStatus: @escaping (String?) -> AgentProcessStatus = AgentProcessStatus.inspect
    ) {
        self.directories = directories
        self.descriptors = descriptors
        self.processStatus = processStatus
        self.resumeIntents = resumeIntents
        executor = AgentCommandExecutor(directories: directories, resumeIntents: resumeIntents)
    }

    func bootstrap(
        into session: WindowSession,
        attention: AttentionState? = nil,
        tmuxPresence: TmuxPanePresence? = nil
    ) {
        self.session = session
        self.attention = attention
        self.tmuxPresence = tmuxPresence
        refresh()
    }

    /// Runs one pass: read the directories, ask the rules, apply the answer.
    func refresh() {
        guard let session, !DemoFixture.isDemoActive else { return }
        let input = buildInput(session: session)
        let response: AgentProjectionResponse
        let body: Data
        do {
            body = try LimpidProjectionBridge.project(
                state: carried,
                input: JSONEncoder().encode(input),
                now: JSONEncoder().encode(instants())
            )
            response = try JSONDecoder().decode(AgentProjectionResponse.self, from: body)
        } catch {
            // A pass that cannot run leaves the interface as it is. The next
            // file change tries again with the same carried state.
            lastFailure = String(describing: error)
            log.error("projection failed: \(String(describing: error), privacy: .public)")
            return
        }
        lastFailure = nil
        carried = carriedState(from: body)
        hasBootstrapped = true

        apply(response.projection, to: session)
        pending = perform(response.commands, session: session)
    }

    // MARK: - Reading

    private func buildInput(session: WindowSession) -> AgentProjectionInput {
        var input = AgentProjectionInput()
        input.providers = descriptors
        input.isBootstrap = !hasBootstrapped
        input.acknowledged = pending

        for (provider, directory) in directories {
            input.records += files(in: directory.state, suffix: ".state.json", provider: provider)
            input.sessionRecords += files(in: directory.sessions, suffix: ".json", provider: provider)
            if let cwd = directory.cwdEvents {
                input.cwdEvents += files(in: cwd, suffix: ".cwd.json", provider: provider)
            }
            input.worktreeEvents += worktreeFiles(in: directory.state, provider: provider)
        }
        input.resumeIntents = resumeIntents.allIntents().map {
            AgentProjectionIntent(
                runID: $0.runID,
                paneID: $0.paneID,
                sessionID: $0.sessionID,
                ownerRunID: $0.ownerRunID,
                pid: $0.pid,
                createdAt: AgentDateParsing.formatISO8601($0.createdAt)
            )
        }

        input.tabs = session.tabs.map {
            AgentProjectionTabPanes(id: $0.id, panes: Array($0.splitTree.allLeafIDs()))
        }
        input.pidStatus = pidStatus(for: input.records)
        input.marks = marks()
        input.presence = presence(for: input.records)
        input.focus = focus(in: session)
        return input
    }

    private func files(in directory: URL, suffix: String, provider: String) -> [AgentProjectionFile] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
            return []
        }
        return names.sorted().compactMap { name in
            guard name.hasSuffix(suffix), !name.hasPrefix(".") else { return nil }
            let url = directory.appendingPathComponent(name)
            return AgentProjectionFile(
                provider: provider,
                name: String(name.dropLast(suffix.count)),
                // A read that fails here is reported as present-but-unread so
                // the rules keep the record they already accepted.
                content: (try? Data(contentsOf: url)).flatMap { String(data: $0, encoding: .utf8) }
            )
        }
    }

    private func worktreeFiles(in state: URL, provider: String) -> [AgentProjectionWorktreeFile] {
        let directory = state.appendingPathComponent("worktree-events", isDirectory: true)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
            return []
        }
        return names.sorted().compactMap { name in
            // The writer renames a dot-prefixed temporary into place, and a
            // command that deletes one of these takes no lock, so anything
            // that is not a finished event file is something we would create
            // and then keep rediscovering as new.
            guard name.hasSuffix(".json"), !name.hasPrefix(".") else { return nil }
            guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)),
                  let content = String(data: data, encoding: .utf8)
            else { return nil }
            return AgentProjectionWorktreeFile(
                provider: provider,
                fileName: name,
                content: content
            )
        }
    }

    /// Liveness for every process a record names. Asking is a system call, so
    /// it happens here and the answer travels as a fact.
    private func pidStatus(for records: [AgentProjectionFile]) -> [String: String] {
        var status: [String: String] = [:]
        for record in records {
            guard let content = record.content,
                  let object = try? JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String: Any],
                  let pid = object["pid"] as? String, status[pid] == nil
            else { continue }
            status[pid] = switch processStatus(pid) {
            case .alive: "alive"
            case .dead: "dead"
            case .unknown: "unknown"
            }
        }
        return status
    }

    private func marks() -> AgentProjectionMarks {
        guard let attention else { return AgentProjectionMarks() }
        return AgentProjectionMarks(
            viewed: attention.viewedRuntimeTokens,
            dismissed: attention.dismissedRuntimeTokens
        )
    }

    /// Which panes each tmux-hosted run reaches.
    ///
    /// Resolved per endpoint rather than by listing every pane tmux knows,
    /// because the topology probe answers that question and only that
    /// question. An endpoint with no answer is left out of the map entirely,
    /// which is how the rules tell "nobody is attached" from "not known yet".
    private func presence(for records: [AgentProjectionFile]) -> AgentProjectionPresence {
        var presence = AgentProjectionPresence()
        guard let tmuxPresence else { return presence }
        for record in records {
            guard let endpoint = endpoint(in: record) else { continue }
            let key = AgentProjectionPresence.key(
                socketPath: endpoint.socketPath,
                pane: endpoint.paneID
            )
            guard presence.attachments[key] == nil else { continue }
            let attachments = tmuxPresence.attachments(for: endpoint)
            guard !attachments.isEmpty || tmuxPresence.resolution(for: endpoint) == .detached else {
                continue
            }
            presence.attachments[key] = Array(attachments.keys)
            for (pane, location) in attachments {
                presence.locations[pane.uuidString] = .init(isActive: location.isActive)
            }
        }
        return presence
    }

    private func endpoint(in record: AgentProjectionFile) -> TmuxRuntimeEndpoint? {
        guard let content = record.content,
              let object = try? JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String: Any],
              let socketPath = object["tmuxSocketPath"] as? String, !socketPath.isEmpty,
              let paneID = object["tmuxPaneId"] as? String, !paneID.isEmpty
        else { return nil }
        return TmuxRuntimeEndpoint(
            socketPath: socketPath,
            serverPID: object["tmuxServerPID"] as? String ?? "",
            serverStartedAt: object["tmuxServerStartedAt"] as? String ?? "",
            paneID: paneID
        )
    }

    private func focus(in session: WindowSession) -> AgentProjectionFocus? {
        guard let tab = session.activeTab, let pane = tab.splitTree.focusedLeafID else { return nil }
        return AgentProjectionFocus(tab: tab.id, pane: pane)
    }

    private func instants() -> [String: AnyEncodableInstant] {
        [
            "wall": .text(AgentDateParsing.formatISO8601(Date())),
            // Uptime rather than the wall clock, so a clock adjustment cannot
            // expire or revive a notification that is waiting for a pane.
            "monotonicMs": .number(UInt64(ProcessInfo.processInfo.systemUptime * 1000))
        ]
    }

    /// Lifts the opaque state out of the body without decoding it, so its
    /// shape stays a private matter for the rules.
    private func carriedState(from body: Data) -> Data? {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let state = object["state"]
        else { return nil }
        return try? JSONSerialization.data(withJSONObject: state)
    }

    // MARK: - Applying

    private func apply(_ projection: AgentProjection, to session: WindowSession) {
        for (provider, descriptor) in descriptors {
            guard let kind = AgentKind(rawValue: descriptor.id) else { continue }
            attention?.replaceRuntimes(
                projection.runtimes
                    .filter { $0.provider == provider }
                    .map(runtimePresentation),
                kind: kind
            )
        }

        let badgesByPane = projection.badgesByPane
        let sessionsByPane = projection.sessionsByPane
        let titlesByTab = projection.titlesByTab
        session.applyAcrossTabs { tab in
            let leaves = tab.splitTree.allLeafIDs()
            for (provider, keyPath) in Self.badgeKeyPaths {
                var badges: [UUID: AgentBadge] = [:]
                for leaf in leaves {
                    if let badge = badgesByPane[leaf]?[provider] {
                        badges[leaf] = badge.asAgentBadge
                    }
                }
                if tab[keyPath: keyPath] != badges {
                    tab[keyPath: keyPath] = badges
                }
            }
            for (provider, keyPath) in Self.sessionKeyPaths {
                var sessions: [UUID: AgentSessionInfo] = [:]
                for leaf in leaves {
                    if let info = sessionsByPane[leaf]?[provider] {
                        sessions[leaf] = AgentSessionInfo(sessionId: info.sessionID, cwd: info.cwd)
                    }
                }
                if tab[keyPath: keyPath] != sessions {
                    tab[keyPath: keyPath] = sessions
                }
            }
            if let title = titlesByTab[tab.id], tab.title != title {
                tab.title = title
            }
        }
    }

    private func runtimePresentation(
        _ runtime: AgentProjectedRuntime
    ) -> AgentRuntimePresentation {
        let panes = Set(runtime.panes)
        let resolution: AgentAttachmentResolution = switch runtime.attachment {
        case "attached": .attached
        case "detached": .detached
        default: .unresolved
        }
        return AgentRuntimePresentation(
            kind: AgentKind(rawValue: runtime.provider) ?? .claude,
            runID: runtime.runID ?? runtime.id,
            revision: runtime.revision,
            badge: runtime.badge.asAgentBadge,
            paneIDs: panes,
            // The suppression this used to feed is decided by the rules now
            // and travels on the notification itself, so nothing reads it.
            tmuxLocations: [:],
            stateEpisodeToken: runtime.episodeToken,
            attachmentResolution: resolution
        )
    }

    /// Runs the file commands and applies the rest here, where the interface
    /// is. The split is the executor's contract: it owns the lock, this owns
    /// everything that is not a file.
    private func perform(
        _ commands: [AgentProjectionCommand],
        session: WindowSession
    ) -> [AgentCommandOutcome] {
        var outcomes = executor.run(commands)
        for command in commands {
            switch command.op {
            case let .markViewed(runtimeID, token):
                attention?.viewedRuntimeTokens[runtimeID] = token
            case let .cwdChanged(pane, newCwd, oldCwd):
                onCwdChanged?(pane, newCwd, oldCwd)
            case let .gitSyncRefetch(repoRoot):
                onGitSyncRequested?(repoRoot)
            case let .notify(payload):
                if deliver(payload, session: session) {
                    outcomes.append(.notified(
                        runtimeID: payload.runtimeID,
                        eventToken: payload.eventToken,
                        state: payload.state
                    ))
                }
            default:
                continue
            }
        }
        return outcomes
    }

    /// Set by the host to receive the two events that leave this subsystem.
    var onCwdChanged: ((UUID, String, String?) -> Void)?
    var onGitSyncRequested: ((String) -> Void)?
    /// Set by the host to actually raise a notification. Returns whether it
    /// was delivered, which is what retires the pending entry.
    var onNotify: ((AgentNotifyPayload, Tab) -> Bool)?

    private func deliver(_ payload: AgentNotifyPayload, session: WindowSession) -> Bool {
        guard let onNotify, let tab = session.tabs.first(where: { $0.id == payload.tab }) else {
            return false
        }
        return onNotify(payload, tab)
    }

    private static let badgeKeyPaths: [(String, WritableKeyPath<Tab, [UUID: AgentBadge]>)] = [
        ("claude", \Tab.claudeAgentBadges),
        ("codex", \Tab.codexAgentBadges)
    ]

    private static let sessionKeyPaths: [(String, WritableKeyPath<Tab, [UUID: AgentSessionInfo]>)] = [
        ("claude", \Tab.claudeSessions),
        ("codex", \Tab.codexSessions)
    ]
}

/// One value of the two-clock envelope. A tiny type rather than a dictionary
/// of `Any` so the encoded shape cannot drift.
enum AnyEncodableInstant: Encodable {
    case text(String)
    case number(UInt64)

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .text(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        }
    }
}
