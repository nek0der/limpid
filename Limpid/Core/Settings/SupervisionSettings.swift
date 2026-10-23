// SupervisionSettings.swift
// Limpid — the settings the supervision window adds: menu bar, usage limit, the new worktree sheet's choices, turn history.

import Foundation

/// The General pane's settings that came with the supervision window.
/// Each key is read on its own with its default, so a file written before
/// one existed, or by a later build with more, still reads.
struct GeneralSettings: Codable, Equatable {
    /// Whether Limpid shows its menu bar extra.
    var showMenuBarExtra = true
    /// Whether a notification comes when an agent's usage limit resets.
    /// Off by default.
    var notifyOnUsageLimitReset = false
    /// See `LimpidSettings.unknownFields`.
    var unknownFields: [String: LimpidJSONValue] = [:]

    init() {}

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        showMenuBarExtra = try c.decodeIfPresent(Bool.self, forKey: .showMenuBarExtra) ?? true
        notifyOnUsageLimitReset = try c.decodeIfPresent(Bool.self, forKey: .notifyOnUsageLimitReset) ?? false
        unknownFields = try CodableSidecar.decodeUnknownFields(from: decoder, knownKeys: Self.knownKeyStrings)
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(showMenuBarExtra, forKey: .showMenuBarExtra)
        try c.encode(notifyOnUsageLimitReset, forKey: .notifyOnUsageLimitReset)
        try CodableSidecar.encodeUnknownFields(unknownFields, to: encoder)
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case showMenuBarExtra, notifyOnUsageLimitReset
    }

    /// Keys an earlier build of the supervision window wrote and this one
    /// no longer has: read past rather than kept as unknown fields, which
    /// would write them back forever. `movedGroups` counted the groups the
    /// move to the scratch tabs moved, for the first-run guide that told it.
    ///
    /// `isFirstRunGuideDismissed` is not here on purpose. The guide is gone
    /// until onboarding is designed, but a build that still shows it reads
    /// the key: carried through `unknownFields`, a person who closed the
    /// guide and goes back a build does not meet it again. A file this
    /// build starts never gains the key.
    private static let droppedKeys: Set = ["movedGroups"]

    private static let knownKeyStrings = Set(CodingKeys.allCases.map(\.stringValue)).union(droppedKeys)
}

/// What the new worktree sheet remembers between worktrees: what was
/// opened last anywhere, and whether to fetch first, and per project what
/// was opened there last and whether its ignored files were copied and its
/// setup run. Only what made a worktree is remembered.
struct NewSessionSettings: Codable, Equatable {
    /// What the sheet last opened in a worktree it made, a
    /// `WorktreeOpenChoice` as stored. `nil` until one has been made.
    /// Text, so a choice a later build adds reads back rather than failing
    /// the file.
    var lastOpen: String?
    /// Whether the sheet fetches the base's remote before it makes a
    /// worktree. On by default: a worktree started from a stale branch is
    /// the mistake the fetch is there to prevent.
    var fetchesBeforeCreate = true
    /// The agent an earlier build's sheet last started, an `AgentKind` raw
    /// value or `"none"` for a terminal. Read only to start from it while
    /// `lastOpen` is not set, and written back as it was read, so going
    /// back a build still finds it.
    var lastAgent: String?
    /// Each project's last choices, by its folder's path: a project
    /// removed and added again keeps them, and its id does not.
    var projects: [String: NewWorktreeProjectMemory] = [:]
    /// See `LimpidSettings.unknownFields`.
    var unknownFields: [String: LimpidJSONValue] = [:]

    init() {}

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lastOpen = try? c.decodeIfPresent(String.self, forKey: .lastOpen)
        fetchesBeforeCreate = (try? c.decodeIfPresent(Bool.self, forKey: .fetchesBeforeCreate)) ?? true
        lastAgent = try c.decodeIfPresent(String.self, forKey: .lastAgent)
        // A hand-edited entry that does not read drops itself only, not
        // the other projects' or the whole file: the choices are a
        // convenience.
        let entries = (try? c.decodeIfPresent([String: LenientDecoded<NewWorktreeProjectMemory>].self, forKey: .projects)) ?? [:]
        projects = entries.compactMapValues(\.value)
        unknownFields = try CodableSidecar.decodeUnknownFields(from: decoder, knownKeys: Self.knownKeyStrings)
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(lastOpen, forKey: .lastOpen)
        // Written only once turned off, so a file that never changed it
        // reads as it did.
        if !fetchesBeforeCreate {
            try c.encode(fetchesBeforeCreate, forKey: .fetchesBeforeCreate)
        }
        try c.encodeIfPresent(lastAgent, forKey: .lastAgent)
        if !projects.isEmpty {
            try c.encode(projects, forKey: .projects)
        }
        try CodableSidecar.encodeUnknownFields(unknownFields, to: encoder)
    }

    /// What the sheet opens with for the project at `root`, most specific
    /// first, for `WorktreeOpenChoice.initial`: the project's last choice,
    /// the last anywhere, then what an earlier build kept as the agent,
    /// for the project and anywhere.
    func rememberedOpen(forProjectAt root: URL) -> [String?] {
        let memory = memory(forProjectAt: root)
        return [memory?.open, lastOpen, memory?.agent, lastAgent]
    }

    /// The key a project's choices are kept under.
    static func key(forProjectAt root: URL) -> String {
        root.standardizedFileURL.path
    }

    /// The choices last made in the project at `root`, if any.
    func memory(forProjectAt root: URL) -> NewWorktreeProjectMemory? {
        projects[Self.key(forProjectAt: root)]
    }

    /// Remembers what a worktree was made with, for the project at `root`
    /// and, for what it opened and the fetch, anywhere.
    mutating func remember(_ choices: NewWorktreeChoices, forProjectAt root: URL) {
        let key = Self.key(forProjectAt: root)
        var memory = projects[key] ?? NewWorktreeProjectMemory()
        memory.open = choices.open.stored
        memory.copiesIgnoredFiles = choices.copiesIgnoredFiles
        memory.runsSetup = choices.runsSetup
        projects[key] = memory
        lastOpen = choices.open.stored
        fetchesBeforeCreate = choices.fetches
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case lastOpen, fetchesBeforeCreate, lastAgent, projects
    }

    private static let knownKeyStrings = Set(CodingKeys.allCases.map(\.stringValue))
}

/// A value that reads as `nil` rather than failing what holds it, for a
/// map whose entries are each worth keeping without the others.
private struct LenientDecoded<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: any Decoder) throws {
        value = try? Value(from: decoder)
    }
}

/// What a worktree was made with in the new worktree sheet, or by ⌥⌘N,
/// which the next one starts from.
struct NewWorktreeChoices: Equatable, Sendable {
    var open: WorktreeOpenChoice
    var fetches: Bool
    var copiesIgnoredFiles: Bool
    var runsSetup: Bool
}

/// One project's last choices in the new worktree sheet. Text, as
/// `NewSessionSettings.lastOpen` is, so a value a later build writes
/// reads back.
struct NewWorktreeProjectMemory: Codable, Equatable {
    /// A `WorktreeOpenChoice` as stored.
    var open: String?
    /// Whether the files Git ignores were copied from the project's folder.
    /// `nil` before the first worktree made: on.
    var copiesIgnoredFiles: Bool?
    /// Whether the setup commands ran. `nil` before the first worktree
    /// made: on.
    var runsSetup: Bool?
    /// What an earlier build kept: the agent (an `AgentKind` raw value, or
    /// `"none"` for a terminal) and where it ran (`newWorktree` or
    /// `projectFolder`). Read only while `open` is not set, and written
    /// back as read, so going back a build still finds them.
    var agent: String?
    var location: String?
    /// See `LimpidSettings.unknownFields`.
    var unknownFields: [String: LimpidJSONValue] = [:]

    init(
        open: String? = nil,
        copiesIgnoredFiles: Bool? = nil,
        runsSetup: Bool? = nil,
        agent: String? = nil,
        location: String? = nil
    ) {
        self.open = open
        self.copiesIgnoredFiles = copiesIgnoredFiles
        self.runsSetup = runsSetup
        self.agent = agent
        self.location = location
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        open = try c.decodeIfPresent(String.self, forKey: .open)
        copiesIgnoredFiles = try c.decodeIfPresent(Bool.self, forKey: .copiesIgnoredFiles)
        runsSetup = try c.decodeIfPresent(Bool.self, forKey: .runsSetup)
        agent = try c.decodeIfPresent(String.self, forKey: .agent)
        location = try c.decodeIfPresent(String.self, forKey: .location)
        unknownFields = try CodableSidecar.decodeUnknownFields(from: decoder, knownKeys: Self.knownKeyStrings)
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(open, forKey: .open)
        try c.encodeIfPresent(copiesIgnoredFiles, forKey: .copiesIgnoredFiles)
        try c.encodeIfPresent(runsSetup, forKey: .runsSetup)
        try c.encodeIfPresent(agent, forKey: .agent)
        try c.encodeIfPresent(location, forKey: .location)
        try CodableSidecar.encodeUnknownFields(unknownFields, to: encoder)
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case open, copiesIgnoredFiles, runsSetup, agent, location
    }

    private static let knownKeyStrings = Set(CodingKeys.allCases.map(\.stringValue))
}

/// How long the turns' records are kept: the days a read turn
/// stays and how many turns a conversation keeps. Held within their ranges
/// on the way in, so a hand-edited file cannot let the records grow
/// without end.
struct TurnRetentionSettings: Codable, Equatable {
    static let dayRange = 1...90
    static let turnRange = 20...500

    var days = TurnRetentionLimits.standardDays {
        didSet { days = days.clamped(to: Self.dayRange) }
    }

    var turns = TurnRetentionLimits.standardTurns {
        didSet { turns = turns.clamped(to: Self.turnRange) }
    }

    /// See `LimpidSettings.unknownFields`.
    var unknownFields: [String: LimpidJSONValue] = [:]

    init() {}

    init(days: Int, turns: Int) {
        self.days = days.clamped(to: Self.dayRange)
        self.turns = turns.clamped(to: Self.turnRange)
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            days: c.decodeIfPresent(Int.self, forKey: .days) ?? TurnRetentionLimits.standardDays,
            turns: c.decodeIfPresent(Int.self, forKey: .turns) ?? TurnRetentionLimits.standardTurns
        )
        unknownFields = try CodableSidecar.decodeUnknownFields(from: decoder, knownKeys: Self.knownKeyStrings)
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(days, forKey: .days)
        try c.encode(turns, forKey: .turns)
        try CodableSidecar.encodeUnknownFields(unknownFields, to: encoder)
    }

    /// The limits the retention sweep runs with.
    var limits: TurnRetentionLimits {
        var limits = TurnRetentionLimits.standard
        limits.maxAgeSeconds = days * 24 * 60 * 60
        limits.maxPerConversation = turns
        return limits
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case days, turns
    }

    private static let knownKeyStrings = Set(CodingKeys.allCases.map(\.stringValue))
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
