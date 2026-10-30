// AgentProjectionInput.swift
// Limpid — what one projection pass is told, and what it answers with.

import Foundation
import OSLog

private let log = Logger.limpid("agent.projection.input")

/// Everything the rules read that this process had to look up: the files in
/// the watched directories, which panes exist, which processes are alive,
/// where the user is looking.
///
/// Typed rather than assembled as a dictionary because every field on the
/// other side has a default: a mistyped key would not fail, it would quietly
/// mean "nothing here", and a pane would simply stop showing a badge.
struct AgentProjectionInput: Encodable {
    var providers: [String: AgentProviderDescriptor] = [:]
    /// The person's home directory, which each provider's default
    /// configuration directory is under: the rules read a provider's own
    /// internal agent directories against it. `nil` reads every record as
    /// the person's.
    var home: String?
    /// Each provider's default home under `home`, by provider, with its
    /// symlinks resolved, where that differs from the path as written: a
    /// record of an agent that canonicalized a symlinked `~/.codex` names
    /// the target. The rules read no disk, so we resolve it here
    /// (`AgentProjectionInput.resolvedHomes`).
    var resolvedHomes: [String: String] = [:]
    var records: [AgentProjectionFile] = []
    var sessionRecords: [AgentProjectionFile] = []
    var cwdEvents: [AgentProjectionFile] = []
    var worktreeEvents: [AgentProjectionWorktreeFile] = []
    /// Every turn record, by turn id; content only for the ones new or
    /// changed since the last pass that succeeded (`TurnRecordCache`).
    var turnFiles: [AgentProjectionFile] = []
    var resumeIntents: [AgentProjectionIntent] = []
    var marks = AgentProjectionMarks()
    var presence = AgentProjectionPresence()
    var tabs: [AgentProjectionTabPanes] = []
    var pidStatus: [String: String] = [:]
    var focus: AgentProjectionFocus?
    /// The panes the person can see now. A run that finishes in one
    /// of them is read as it finishes.
    var seenPanes: [UUID] = []
    /// What each pane's program last reported about itself over OSC 7501,
    /// keyed by pane (`PaneProgramStatusStore`).
    var programStatus: [String: AgentProjectionProgramStatus] = [:]
    var acknowledged: [AgentCommandOutcome] = []
    var isBootstrap = false
    /// What the turn retention sweep needs; absent until the host
    /// knows which turns it protects, so none is deleted before then.
    var turnSweep: AgentProjectionTurnSweep?
}

/// The retention limits and the turns the host protects from them.
struct AgentProjectionTurnSweep: Encodable, Equatable {
    var maxAgeSeconds: Int
    var maxPerConversation: Int
    var maxRepositoryBytes: Int?
    var maxTurns: Int?
    /// Sorted, so the same protection always encodes the same input.
    var protectedTurnIDs: [String]
    var heldTurnIDs: [String]
    var shownConversations: [ConversationKey]

    private enum CodingKeys: String, CodingKey {
        case maxAgeSeconds = "maxAgeSecs"
        case maxPerConversation
        case maxRepositoryBytes
        case maxTurns
        case protectedTurnIDs = "protectedTurnIds"
        case heldTurnIDs = "heldTurnIds"
        case shownConversations
    }

    init(limits: TurnRetentionLimits, protection: TurnProtection) {
        maxAgeSeconds = limits.maxAgeSeconds
        maxPerConversation = limits.maxPerConversation
        maxRepositoryBytes = limits.maxRepositoryBytes
        maxTurns = limits.maxTurns
        protectedTurnIDs = protection.protectedTurnIDs.map(\.rawValue).sorted()
        heldTurnIDs = protection.heldTurnIDs.map(\.rawValue).sorted()
        shownConversations = protection.shownConversations.sorted {
            ($0.provider.rawValue, $0.conversationID, $0.isFallback ? 1 : 0)
                < ($1.provider.rawValue, $1.conversationID, $1.isFallback ? 1 : 0)
        }
    }
}

/// A change of the retention limits, both sides with the same protection,
/// for counting what it deletes (`AgentProjectionAdapter.turnsTaken`).
struct AgentProjectionTurnSweepChange: Encodable {
    var from: AgentProjectionTurnSweep
    var to: AgentProjectionTurnSweep
}

extension AgentProjectionInput {
    /// Each provider's default home under `home` (`~/.<id>`, as
    /// `ProviderDescriptor::default_home` names it) with its symlinks
    /// resolved, where it exists and resolves to another path
    /// (`resolvedHomes`). `realpath` rather than
    /// `URL.resolvingSymlinksInPath`, which takes `/private` off a
    /// `/private/tmp` path and so names it as no agent writes it.
    static func resolvedHomes(of providers: some Sequence<String>, under home: String) -> [String: String] {
        var resolved: [String: String] = [:]
        for provider in providers {
            let written = (home as NSString).appendingPathComponent("." + provider)
            guard let physical = realpath(written, nil) else { continue }
            defer { free(physical) }
            let path = String(cString: physical)
            if path != written {
                resolved[provider] = path
            }
        }
        return resolved
    }
}

/// A resume hint the person ended its session by ("Start New
/// Conversation") that is still on disk, because a hook held its lock or
/// the file could not be removed (`AgentProjectionAdapter.forgetSession`):
/// kept from the rules until it is deleted, across launches
/// (`AgentForgottenHintFile`).
struct AgentForgottenHint: Equatable, Codable {
    let provider: String
    let pane: UUID
    let sessionID: String

    /// `files`, the hints read for a pass, without the ones `hints` name.
    /// A hint file is named by its pane (`AgentProjectionFile.files`), and
    /// counts only while it still names the ended session: one a newer
    /// session wrote is the pane's own.
    static func removing(_ hints: [Self], from files: [AgentProjectionFile]) -> [AgentProjectionFile] {
        guard !hints.isEmpty else { return files }
        return files.filter { file in
            !hints.contains { hint in
                hint.provider == file.provider
                    && hint.pane.uuidString == file.name
                    && sessionID(of: file) == hint.sessionID
            }
        }
    }

    private static func sessionID(of file: AgentProjectionFile) -> String? {
        file.recordFacts?.sessionID
    }
}

/// The few fields of a run record (or of a resume hint, which carries the
/// same keys) that this process reads itself rather than leaving to the
/// rules: which session it names, which process it runs as, and which tmux
/// pane hosts it. The schema belongs to the Rust `RunRecord`; we name its
/// keys in one place, so a renamed key fails a test here instead of quietly
/// reading as "absent" at three call sites.
struct AgentRunRecordFacts: Decodable, Equatable {
    var sessionID: String?
    var pid: String?
    var tmuxSocketPath: String?
    var tmuxPaneID: String?
    var tmuxServerPID: String?
    var tmuxServerStartedAt: String?

    private enum CodingKeys: String, CodingKey {
        case sessionID = "sessionId"
        case pid
        case tmuxSocketPath
        case tmuxPaneID = "tmuxPaneId"
        case tmuxServerPID
        case tmuxServerStartedAt
    }

    /// Each field on its own, so one of an unexpected type reads as absent
    /// without taking the others with it.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func field(_ key: CodingKeys) -> String? {
            // A value of another type is one this version does not
            // understand, which we act on as if it were absent.
            (try? container.decodeIfPresent(String.self, forKey: key)) ?? nil
        }
        sessionID = field(.sessionID)
        pid = field(.pid)
        tmuxSocketPath = field(.tmuxSocketPath)
        tmuxPaneID = field(.tmuxPaneID)
        tmuxServerPID = field(.tmuxServerPID)
        tmuxServerStartedAt = field(.tmuxServerStartedAt)
    }

    /// The facts `content` holds; `nil` when it is not a JSON object.
    init?(content: String) {
        // A file that does not decode names nothing we act on; the rules
        // judge it separately from the same content.
        guard let facts = try? JSONDecoder().decode(Self.self, from: Data(content.utf8)) else {
            return nil
        }
        self = facts
    }
}

/// One file found in a watched directory. `content` is absent when the file is
/// there but could not be read this pass, which is not the same as absent: the
/// rules keep the copy they already accepted rather than letting a badge blink
/// out and come back.
struct AgentProjectionFile: Encodable {
    var provider: String
    var name: String
    var content: String?
}

struct AgentProjectionWorktreeFile: Encodable {
    var provider: String
    var fileName: String
    var content: String
}

struct AgentProjectionIntent: Encodable {
    var runID: String
    var paneID: UUID
    var sessionID: String
    var ownerRunID: String?
    var pid: String
    var createdAt: String

    private enum CodingKeys: String, CodingKey {
        case runID, paneID, sessionID, ownerRunID, pid, createdAt
    }
}

/// Viewed marks, as runtime identifier to the attention episode they were
/// taken against.
struct AgentProjectionMarks: Codable, Equatable, Sendable {
    var viewed: [String: String] = [:]
}

/// Which panes each tmux endpoint reaches, and whether each is the active one
/// in its window.
///
/// Keys are identifier strings rather than `UUID` values: Swift encodes a
/// dictionary whose key is not a string as an array of alternating keys and
/// values, which is not the object shape the rules read.
struct AgentProjectionPresence: Encodable {
    var attachments: [String: [UUID]] = [:]
    /// Endpoint key, as in `attachments`, to where the endpoint's tmux pane
    /// sits in each pane attached to it (pane IDs as strings, for the reason
    /// above). Keyed by the endpoint so the rules read each run's own
    /// location: two runs of one tmux session reach the same pane.
    var locations: [String: [String: AgentProjectionPaneLocation]] = [:]

    /// Keyed by socket, tmux server, and pane because the three identify one
    /// tmux endpoint, and the rules match a record's own fields against it.
    /// The server is in it because a tmux server started again on the same
    /// socket numbers its panes from `%0` again, and a record of a run on the
    /// old server can outlive it: without the server, that record and a new
    /// run's would share a key. The topology probe matches on the same three
    /// (`TmuxTopology.locations(for:)`).
    ///
    /// The rules build the same key from the record's own fields, so this
    /// spelling is a contract neither side owns: change it here and a
    /// tmux-hosted run stops matching the pane it is showing in, with no error
    /// anywhere. `endpoint_key` is the other half.
    ///
    /// No part is escaped: the socket path is the only free text in it and
    /// comes first, and the other three hold digits and `%` only, so the key
    /// splits from the right into one endpoint even when the path holds a
    /// `|`.
    static func key(for endpoint: TmuxRuntimeEndpoint) -> String {
        "\(endpoint.socketPath)|\(endpoint.serverPID)|\(endpoint.serverStartedAt)|\(endpoint.paneID)"
    }
}

struct AgentProjectionPaneLocation: Encodable {
    var isActive: Bool
}

struct AgentProjectionTabPanes: Encodable {
    var id: UUID
    var panes: [UUID]
}

/// Where keys go. What the person has seen travels separately, as
/// `AgentProjectionInput.seenPanes`.
struct AgentProjectionFocus: Encodable {
    var tab: UUID
    var pane: UUID
}

/// A pane program's latest OSC 7501 report about itself, as the rules read it
/// (`ProgramStatus` in `limpid-agent-model`).
struct AgentProjectionProgramStatus: Encodable, Equatable {
    var app: String
    /// `idle`, `working`, `done`, `blocked`, or `error`.
    var state: String
    /// `permission`, `question`, or `auth`, what a blocked program waits on.
    /// Optional because only a block carries one.
    var kind: String?
    var observedAt: String
}

/// What a provider declares about itself, as the Rust registry reports it.
/// The host reads only some of it, but every field is named here: the
/// descriptors go back to the rules in each pass's input, and a field left
/// out would reach them as its default (`LimpidProjectionBridgeTests` holds
/// the round trip to the registry's own JSON).
struct AgentProviderDescriptor: Codable {
    var id: String
    var displayName: String
    var capabilities: [String]
    var pidSweepIntervalMs: Int
    var stateDirectory: String
    var sessionDirectory: String
    var cwdEventsDirectory: String?
    var processNames: [String]
    var sessionEndDropReasons: [String]
    var internalAgentDirectories: [String]
    /// The `app` name the provider's agent gives itself in OSC 7501, when it
    /// reports its status.
    var programStatusApp: String?
}

/// What one pass answers with. The state it also returns travels as raw bytes
/// this process never reads, so it is lifted from the body separately.
struct AgentProjectionResponse: Decodable, Sendable {
    var projection: AgentProjection
    var commands: [AgentProjectionCommand]
}

/// What to show. Pane and tab keys arrive as identifier strings for the same
/// reason the input uses them.
struct AgentProjection: Decodable, Sendable {
    var runtimes: [AgentProjectedRuntime] = []
    var badges: [String: [String: AgentProjectedBadge]] = [:]
    var sessions: [String: [String: AgentProjectedSession]] = [:]
    var tabTitles: [String: String] = [:]
    var marksToKeep = AgentProjectionMarks()
    var resumeCandidates: [String: [String]] = [:]
    /// Absent when no turn changed and no run came or went since the
    /// previous pass, and the history stays as it is. A conversation of a provider this build does not have
    /// is dropped rather than failing the pass: there is nothing here to
    /// show it in.
    var conversations: AgentProjectionLossyList<ConversationTurns>?
    /// How soon to run a pass though nothing watched changes, in
    /// milliseconds: a finished turn's notice is held a moment, in case a
    /// queued instruction starts the next turn, and only a pass after
    /// that releases it. Nil when nothing is held.
    var nextPassInMs: UInt64?

    /// The pane-keyed maps, re-keyed by identifier rather than by the text of
    /// one. The two sides spell an identifier differently — lower case on the
    /// way out, upper case here — so comparing the strings would silently
    /// match nothing. Parsing them is what makes the spelling irrelevant.
    var badgesByPane: [UUID: [String: AgentProjectedBadge]] {
        Self.keyed(badges)
    }

    var sessionsByPane: [UUID: [String: AgentProjectedSession]] {
        Self.keyed(sessions)
    }

    var titlesByTab: [UUID: String] {
        Self.keyed(tabTitles)
    }

    var resumeCandidatesByPane: [UUID: [String]] {
        Self.keyed(resumeCandidates)
    }

    private static func keyed<Value>(_ source: [String: Value]) -> [UUID: Value] {
        var result: [UUID: Value] = [:]
        for (key, value) in source {
            if let identifier = UUID(uuidString: key) {
                result[identifier] = value
            }
        }
        return result
    }
}

struct AgentProjectedRuntime: Decodable, Sendable {
    var id: String
    var provider: String
    var runID: String?
    var revision: Int?
    var badge: AgentProjectedBadge
    var panes: [UUID]
    var attachment: String
    var eventToken: String
    var episodeToken: String
    var pid: String?
    var sessionID: String?
    var conversation: AgentProjectedConversationKey?
    var currentTurnID: String?
    /// The tmux endpoint key the run's record names, when it runs in tmux:
    /// where the host looks up the run's own tmux locations.
    var tmuxEndpointKey: String?

    private enum CodingKeys: String, CodingKey {
        case id, provider
        case runID = "runId"
        case revision, badge, panes, attachment, eventToken, episodeToken, pid
        case sessionID = "sessionId"
        case conversation
        case currentTurnID = "currentTurnId"
        case tmuxEndpointKey
    }
}

/// A conversation key as the projection spells it, with the provider as
/// text: a runtime of a provider this build does not have still shows, it
/// just has no conversation here.
struct AgentProjectedConversationKey: Decodable, Sendable {
    var provider: String
    var conversationID: String
    var isFallback: Bool

    var key: ConversationKey? {
        AgentKind(rawValue: provider).map {
            ConversationKey(provider: $0, conversationID: conversationID, isFallback: isFallback)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case provider
        case conversationID = "conversationId"
        case isFallback
    }
}

/// The elements of a list that decode; the rest are skipped one by one, so a
/// single entry from a newer writer costs that entry and not the pass.
struct AgentProjectionLossyList<Element: Decodable>: Decodable {
    var elements: [Element] = []

    init() {}

    init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var skipped = 0
        while !container.isAtEnd {
            if let element = try? container.decode(Element.self) {
                elements.append(element)
            } else {
                // Moves past the entry; a failed decode does not.
                _ = try container.decode(Skipped.self)
                skipped += 1
            }
        }
        // Expected for a provider this build lacks; anything else is the two
        // sides disagreeing about a shape, which nothing else would show.
        if skipped > 0 {
            log.notice("skipped \(skipped) \(String(describing: Element.self), privacy: .public) entries")
        }
    }

    private struct Skipped: Decodable {
        init(from _: any Decoder) {}
    }
}

struct AgentProjectedBadge: Decodable, Sendable {
    var state: String
    var detail: String?
    var runStartedAt: String?
    var isTmuxHosted: Bool?
    var updatedAt: String
    var lastPrompt: String?
    var firstPrompt: String?
    var turnBaseTree: String?
    var turnRoot: String?
    var worktreeRoot: String?
    var conversationID: String?
    var providerSessionTitle: String?
    var providerGeneratedTitle: String?
    var sessionStartedAt: String?
    var runLaunchOrder: UInt64?
    var parentRunID: String?
    var runObservedOrder: UInt64?
    var cacheWindow: AgentProjectedCacheWindow?
    var usageLimit: AgentProjectedUsageLimit?
    var waitKind: String?
    var tool: String?
    var stopReason: String?
    var hasPrompt: Bool?
    var backgroundWork: AgentProjectedBackgroundWork?
    var model: String?
    var permissionMode: String?

    private enum CodingKeys: String, CodingKey {
        case state, detail, runStartedAt, isTmuxHosted, updatedAt
        case lastPrompt, firstPrompt, turnBaseTree, turnRoot, worktreeRoot
        case conversationID = "conversationId"
        case providerSessionTitle, providerGeneratedTitle, sessionStartedAt, runLaunchOrder, parentRunID, runObservedOrder
        case cacheWindow, usageLimit, waitKind, tool, stopReason, hasPrompt
        case backgroundWork, model, permissionMode
    }

    /// The badge as the interface holds it. An unreadable state shows as
    /// unknown rather than being dropped, matching what the rules decided
    /// about a state string this build does not know.
    var asAgentBadge: AgentBadge {
        AgentBadge(
            state: AgentState(rawValue: state) ?? .unknown,
            detail: detail,
            runStartedAt: AgentDateParsing.parseOptional(runStartedAt),
            isTmuxHosted: isTmuxHosted,
            updatedAt: AgentDateParsing.parseISO8601(updatedAt) ?? Date(),
            lastPrompt: lastPrompt,
            turnBaseTree: turnBaseTree,
            turnRoot: turnRoot,
            worktreeRoot: worktreeRoot,
            firstPrompt: firstPrompt,
            conversationID: conversationID,
            providerSessionTitle: providerSessionTitle,
            providerGeneratedTitle: providerGeneratedTitle,
            sessionStartedAt: AgentDateParsing.parseOptional(sessionStartedAt),
            runLaunchOrder: runLaunchOrder,
            parentRunID: parentRunID,
            runObservedOrder: runObservedOrder,
            cacheWindow: cacheWindow?.window,
            usageLimit: usageLimit?.limit,
            waitKind: waitKind,
            tool: tool,
            stopReason: stopReason,
            hasPrompt: hasPrompt,
            backgroundWork: backgroundWork?.work,
            model: model,
            permissionMode: permissionMode
        )
    }
}

/// The badge's background work as the projection spells it: a count per
/// kind, each left out at zero. Decoding never fails: the counts only mark
/// a resting run and add a sentence to its decision bar and session row, and
/// a shape this build cannot read must cost those and not the whole
/// projection pass.
struct AgentProjectedBackgroundWork: Decodable, Sendable {
    /// `nil` when the value is not an object or counts nothing.
    var work: BackgroundWork?

    private enum CodingKeys: String, CodingKey {
        case shells, subagents, others
    }

    init(from decoder: any Decoder) throws {
        guard let container = try? decoder.container(keyedBy: CodingKeys.self) else {
            work = nil
            return
        }
        // Each count on its own, as the run record's fields are read
        // (`AgentRunRecordFacts`): one of another type, or below zero, counts
        // nothing without taking the others with it.
        func count(_ key: CodingKeys) -> Int {
            max(0, (try? container.decodeIfPresent(Int.self, forKey: key)) ?? 0)
        }
        let work = BackgroundWork(shells: count(.shells), subagents: count(.subagents), others: count(.others))
        // The rules leave the field out when nothing runs; an object that
        // counts nothing says the same.
        self.work = work.isEmpty ? nil : work
    }
}

/// The badge's usage limit as the projection spells it (`resetsAt`, an
/// ISO-8601 time, and `window`). Decoding never fails: a shape this build
/// cannot read costs the limit's time, and the limit still stands.
struct AgentProjectedUsageLimit: Decodable, Sendable {
    var limit: UsageLimit

    private enum CodingKeys: String, CodingKey {
        case resetsAt, window
    }

    init(from decoder: any Decoder) throws {
        let container = try? decoder.container(keyedBy: CodingKeys.self)
        let resetsAt = (try? container?.decodeIfPresent(String.self, forKey: .resetsAt)) ?? nil
        limit = UsageLimit(
            resetAt: resetsAt.flatMap(AgentDateParsing.parseISO8601),
            window: (try? container?.decodeIfPresent(String.self, forKey: .window)) ?? nil
        )
    }
}

/// The badge's prompt cache window as the projection spells it. Decoding
/// never fails: the window feeds the clock marks and their panel, and a shape this
/// build cannot read must cost that and not the whole projection pass.
struct AgentProjectedCacheWindow: Decodable, Sendable {
    /// `nil` when the value could not be read.
    var window: AgentCacheWindow?

    private enum CodingKeys: String, CodingKey {
        case observedAt, ttlSeconds, rewriteTokens, precision
    }

    init(from decoder: any Decoder) throws {
        guard let container = try? decoder.container(keyedBy: CodingKeys.self),
              let observed = try? container.decode(String.self, forKey: .observedAt),
              let observedAt = AgentDateParsing.parseISO8601(observed),
              let ttl = try? container.decode(Int.self, forKey: .ttlSeconds),
              ttl > 0
        else {
            window = nil
            return
        }
        let precision = (try? container.decode(String.self, forKey: .precision))
            .flatMap(AgentCacheWindow.Precision.init(rawValue:)) ?? .unknown
        window = AgentCacheWindow(
            observedAt: observedAt,
            ttlSeconds: ttl,
            rewriteTokens: (try? container.decodeIfPresent(Int.self, forKey: .rewriteTokens)) ?? nil,
            precision: precision
        )
    }
}

struct AgentProjectedSession: Decodable, Sendable {
    var sessionID: String
    var cwd: String?

    private enum CodingKeys: String, CodingKey {
        case sessionID = "sessionId"
        case cwd
    }
}

extension AgentProjectionLossyList: Sendable where Element: Sendable {}

extension AgentProjectionFile {
    /// The files in `directory` whose names end with `suffix`, named
    /// without it.
    static func files(in directory: URL, suffix: String, provider: String) -> [AgentProjectionFile] {
        guard let names = TurnRecordCache.sortedNames(atPath: directory.path) else {
            return []
        }
        return names.compactMap { name in
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

    /// The tmux pane a run record says its agent runs in, if it says one.
    var tmuxEndpoint: TmuxRuntimeEndpoint? {
        recordFacts?.tmuxEndpoint
    }

    /// The fields of this file this process reads itself. Decoded on each
    /// call rather than stored, because most files a pass reads are never
    /// asked and travel to the rules as they are.
    var recordFacts: AgentRunRecordFacts? {
        content.flatMap(AgentRunRecordFacts.init(content:))
    }
}

extension AgentRunRecordFacts {
    /// The tmux pane the record says its agent runs in, if it says one.
    var tmuxEndpoint: TmuxRuntimeEndpoint? {
        guard let tmuxSocketPath, !tmuxSocketPath.isEmpty,
              let tmuxPaneID, !tmuxPaneID.isEmpty
        else { return nil }
        return TmuxRuntimeEndpoint(
            socketPath: tmuxSocketPath,
            serverPID: tmuxServerPID ?? "",
            serverStartedAt: tmuxServerStartedAt ?? "",
            paneID: tmuxPaneID
        )
    }
}

/// One value of the two-clock envelope. A tiny type rather than a dictionary
/// of `Any` so the encoded shape cannot drift.
enum AnyEncodableInstant: Encodable {
    case text(String)
    case number(UInt64)

    /// Both clocks as a pass reads them now.
    static func now() -> [String: AnyEncodableInstant] {
        [
            "wall": .text(AgentDateParsing.formatISO8601(Date())),
            // Uptime rather than the wall clock, so a clock adjustment cannot
            // expire or revive a notification that is waiting for a pane.
            "monotonicMs": .number(UInt64(ProcessInfo.processInfo.systemUptime * 1000))
        ]
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .text(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        }
    }
}

extension AgentProjectionWorktreeFile {
    /// The provider's finished worktree events.
    static func events(in owner: AgentDirectories, provider: String) -> [AgentProjectionWorktreeFile] {
        guard let directory = owner.worktreeEvents,
              let suffix = owner.layout?.worktreeEventSuffix,
              let names = TurnRecordCache.sortedNames(atPath: directory.path)
        else {
            return []
        }
        return names.compactMap { name in
            // The writer renames a temporary into place, so a name that is
            // not a finished event's is a write in progress and must not be
            // read as an event.
            guard name.hasSuffix(suffix), !name.hasPrefix(".") else { return nil }
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
}
