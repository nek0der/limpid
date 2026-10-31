// Tab.swift
// Weir — a tab is one work session. Every tab belongs to exactly one
// container (the scratch tabs, a project's own tabs, or a worktree's). The
// container decides where the tab shows up in the sidebar.

import Foundation
import WeirDomain

struct Tab: Codable, Equatable, Identifiable {

    /// Wire-level discriminator so a future tab kind (editor, agent
    /// dashboard, …) can land without breaking an older build that opens
    /// the same `state.json`. The defensive decoder routes unknown raw
    /// values back to `.terminal`, so the offending tab still loads.
    enum Kind: String, Codable, Equatable {
        case terminal

        static let unknownFallback: Kind = .terminal

        init(from decoder: any Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Kind(rawValue: raw) ?? .unknownFallback
        }
    }

    let id: UUID

    /// Wire-level kind tag. Today every tab is `.terminal`; the field
    /// exists so the next kind can be added as a Swift enum case without
    /// a state.json schema bump.
    var kind: Kind = .terminal

    /// Title reported by libghostty (OSC 0/2). Seeded from the
    /// container at creation.
    var title: String

    /// User-pinned title override. When non-nil and non-empty, replaces
    /// the auto title in the UI.
    var titleOverride: String?

    /// Put before the title: the name of the group a scratch tab was
    /// moved from, so "prod · ssh" still says where it came from. Survives
    /// title changes from the terminal; a rename replaces it (`rename`).
    var namePrefix: String?

    /// The tab's color as an index into the project palette, drawn as a
    /// mark at its leading edge: the color of the group it was moved from.
    var paletteIndex: Int?

    /// Where the tab's new panes start (`newPaneWorkingDirectory`): the
    /// default of the group it was moved from. `nil` for any other tab,
    /// whose new panes start where the tab did.
    var cwdMode: WorkingDirectoryMode?
    /// The directory `cwdMode` `.fixed` names.
    var cwdPath: URL?

    /// The folder the tab was opened in, where its new panes start unless
    /// `cwdMode` says otherwise (`newPaneWorkingDirectory`). `nil` leaves
    /// the start folder to libghostty (the home folder by default).
    var workingDirectory: String?

    /// Latest pwd reported by libghostty's PWD action.
    var pwd: String?

    var splitTree: SplitTree

    /// When non-nil, the session area's pane area renders only this leaf at full size
    /// instead of `splitTree`. tmux Prefix+z equivalent. Persisted so a
    /// zoomed tab survives quit/restore. Cleared automatically when the
    /// referenced pane goes away (split, close, etc.).
    var zoomedLeafID: UUID?

    /// Per-pane persisted state (unread count). Transient bits (bell
    /// flash, last child-exit code) live on `WorkspaceSession.paneTransients`
    /// so flipping them doesn't reassign `tabs[idx]` and trip autosave.
    var paneStates: [UUID: PaneState] = [:]

    /// On-disk paths to per-pane scrollback files written by libghostty
    /// (`ghostty_surface_write_scrollback`) at quit. Replayed into a fresh
    /// surface via `config.initial_scrollback_path` on next launch. Each
    /// entry is consumed and cleared once replayed so a later split / re-
    /// mount doesn't double-replay it.
    var scrollbackPaths: [UUID: String] = [:]

    /// Per-pane command (paneID → shell command) injected as typed
    /// text + newline once libghostty hands us a live surface. The
    /// surface registry caches `SurfaceView` instances per paneID, so
    /// `createSurface` (and therefore the command send) only fires
    /// once per process launch — re-mounts return the existing view.
    /// Used by demo mode to stage a reproducible hero screenshot, and by
    /// the pane strip's "+" to open a tab running `claude` or `codex`.
    /// Consumed when the pane's surface is made, so it runs once.
    var initialCommands: [UUID: String] = [:]

    /// Per-pane path of the 0600 file holding a first instruction an
    /// earlier build's new session staged (`InitialPromptFile`), handed to
    /// the pane's shell as `WEIR_INITIAL_PROMPT_FILE` with its staged
    /// command. The agent's shim takes the file on its first launch;
    /// consumed with the command. This build writes no new one: it keeps,
    /// moves, and saves only what a restored tab already had, for one
    /// release (`InitialPromptFile` says when it goes).
    var initialPromptFiles: [UUID: String] = [:]

    /// Per-pane agent executable the new worktree sheet found, put in the
    /// environment of the pane's shell as the agent's `WEIR_FOUND_*`
    /// with its staged command (`AgentCatalogEntry.foundExecutableVariable`),
    /// and removed from here with the command once the pane is made. The
    /// shell keeps the variable while the pane is open, and the agent's
    /// shim takes it only when the shell's `PATH` has no agent; the shim
    /// takes it out of what it hands on, so the agent and a tmux server
    /// it starts never carry it. Never saved, unlike the command: a pane
    /// restored at the next launch searches afresh rather than holding a
    /// path read in an earlier one, which an update or uninstall may have
    /// moved.
    var initialAgentExecutables: [UUID: AgentInstallation] = [:]

    /// Where this tab lives. Drives which sidebar row selects it and which
    /// container's pane strip lists it.
    var container: ContainerID

    /// Per-pane resume hints, by provider. Keyed by split-tree leaf UUID
    /// (= `WEIR_PANE_ID`) so two splits running the same agent each
    /// remember their own conversation.
    ///
    /// One dictionary per provider rather than a field per provider: adding a
    /// provider is a Rust crate, and nothing about this type should have to
    /// change for it. On disk the map is an object keyed by provider id, and
    /// a key this build does not recognize is skipped on the way in: the
    /// projection reconciles both maps with the records on every pass, so
    /// nothing is lost by not reading it, whereas failing would drop the tab.
    var agentSessions: [AgentKind: [UUID: AgentSessionInfo]] = [:]

    /// Per-pane lifecycle badges, by provider, on the same terms. Mirrors the
    /// state records the selected receiver writes on every subscribed event;
    /// the tab and sidebar rows aggregate them for the status icons.
    var agentBadges: [AgentKind: [UUID: AgentBadge]] = [:]

    /// Which providers may auto-resume in each pane, as the projection decided
    /// on its last pass. A pane with hints from two providers resumes only the
    /// one the rules picked, so two agents do not fight over one terminal.
    /// Not persisted: the first pass after launch runs before any surface
    /// mounts, and the answer depends on the hints on disk, not on the tab.
    var agentResumeCandidates: [UUID: Set<AgentKind>] = [:]

    /// The agent each pane runs in front, read from its terminal's job at
    /// a command's start and end (`PaneAgentInFrontFollower`), or staged
    /// by "+" as the tab opened: the badge a pane wears before its run has
    /// a record. Not persisted: a pane restored at launch starts a fresh
    /// shell, and what it runs is read again.
    var agentsInFront: [UUID: PaneAgentInFront] = [:]

    /// Which tmux session each pane was showing when Weir last quit,
    /// read off the pane's tty rather than reported by the shell. A pane
    /// that was at its own prompt has no entry, so restoring it brings
    /// back a shell; one that was attached reattaches to the same
    /// session instead of leaving it running unreferenced. Optional
    /// default = `[:]` so an existing `state.json` decodes without a
    /// snapshot version bump.
    var tmuxBindings: [UUID: TmuxBinding] = [:]

    /// The first agent conversation that ran in the tab, by the name it
    /// last had while it ran (`ConversationName`). What names the tab's
    /// session row: unlike `title`, which the agent, the shell, and
    /// OSC 2 keep changing, it stays when the agent leaves, so a row keeps
    /// the name it is found by. It is the person's content (often their
    /// first prompt) and is kept until the tab closes. Optional because a
    /// tab no agent has named yet has none, and a `state.json` from before
    /// it decodes without it. A build from before it ignores the key, and
    /// if it saves the session, the name is gone; the next pass of a newer
    /// build names the tab again only while its agent still runs.
    var conversationName: ConversationName?

    /// Keys a newer build wrote on the tab that this one does not know,
    /// written back as they were (`WeirSettings.unknownFields` has the
    /// pattern), so a round trip through this build keeps them. Empty for a
    /// tab this build made.
    var unknownFields: [String: WeirJSONValue] = [:]

    init(
        id: UUID = UUID(),
        kind: Kind = .terminal,
        title: String,
        titleOverride: String? = nil,
        workingDirectory: String? = nil,
        pwd: String? = nil,
        splitTree: SplitTree,
        paneStates: [UUID: PaneState] = [:],
        zoomedLeafID: UUID? = nil,
        container: ContainerID,
        agentSessions: [AgentKind: [UUID: AgentSessionInfo]] = [:],
        agentBadges: [AgentKind: [UUID: AgentBadge]] = [:],
        tmuxBindings: [UUID: TmuxBinding] = [:]
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.titleOverride = titleOverride
        self.workingDirectory = workingDirectory
        self.pwd = pwd
        self.splitTree = splitTree
        self.paneStates = paneStates
        self.zoomedLeafID = zoomedLeafID
        self.container = container
        self.agentSessions = agentSessions
        self.agentBadges = agentBadges
        self.tmuxBindings = tmuxBindings
    }

    /// Written and read explicitly because the decoder accepts a shape this
    /// build no longer writes: the four per-provider fields an older file
    /// carries. Auto-synthesis would not know those names.
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case id, kind, title, titleOverride, namePrefix, paletteIndex, cwdMode, cwdPath, workingDirectory, pwd, splitTree
        case zoomedLeafID, paneStates, scrollbackPaths, initialCommands, initialPromptFiles, container
        case agentSessions, agentBadges, tmuxBindings, conversationName
        case claudeSessions, claudeAgentBadges, codexSessions, codexAgentBadges
    }

    /// Every key the decoder reads, the older ones it no longer writes
    /// among them, so those are dropped rather than carried as unknown.
    private static let knownKeyStrings: Set<String> = Set(CodingKeys.allCases.map(\.stringValue))

    /// Folds an older file's two fields into one map, dropping a provider
    /// that had nothing so an empty entry is never mistaken for a reading.
    private static func legacyByProvider<Value>(
        claude: [UUID: Value]?,
        codex: [UUID: Value]?
    ) -> [AgentKind: [UUID: Value]] {
        var merged: [AgentKind: [UUID: Value]] = [:]
        if let claude, !claude.isEmpty {
            merged[.claude] = claude
        }
        if let codex, !codex.isEmpty {
            merged[.codex] = codex
        }
        return merged
    }

    /// Reads a provider-keyed map, keeping only the providers this build has.
    ///
    /// The map is an object keyed by provider id. `AgentKind` is not a coding
    /// key, so reading it as `[AgentKind: _]` would both take the array shape
    /// Swift gives a non-string key and fail on a provider id this build does
    /// not know, which is exactly the file a newer build leaves behind. A
    /// build before the object shape wrote that array; it was never released,
    /// but a machine that ran it must still restore, so the array is read too.
    private static func decodeByProvider<Value: Decodable>(
        _ container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) throws -> [AgentKind: [UUID: Value]]? {
        guard container.contains(key) else { return nil }
        do {
            let raw = try container.decode([String: [UUID: Value]].self, forKey: key)
            var known: [AgentKind: [UUID: Value]] = [:]
            for (name, entries) in raw {
                if let kind = AgentKind(rawValue: name) {
                    known[kind] = entries
                }
            }
            return known
        } catch DecodingError.typeMismatch {
            return try container.decode([AgentKind: [UUID: Value]].self, forKey: key)
        }
    }

    private static func encodedByProvider<Value>(
        _ map: [AgentKind: [UUID: Value]]
    ) -> [String: [UUID: Value]] {
        Dictionary(uniqueKeysWithValues: map.map { ($0.key.rawValue, $0.value) })
    }

    /// Custom decoding so a `state.json` written by an older build keeps
    /// decoding instead of throwing `keyNotFound`: every field that has not
    /// always been present is read with a default, and the two agent maps are
    /// additionally read from the per-provider fields they replaced.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        // Old state.json files predate the wire-level discriminator;
        // missing key defaults to `.terminal`. Unknown raw values are
        // caught by `Kind`'s defensive decoder.
        self.kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .terminal
        self.title = try c.decode(String.self, forKey: .title)
        self.titleOverride = try c.decodeIfPresent(String.self, forKey: .titleOverride)
        self.namePrefix = try c.decodeIfPresent(String.self, forKey: .namePrefix)
        self.paletteIndex = try c.decodeIfPresent(Int.self, forKey: .paletteIndex)
        // A mode a later build added reads as none: new panes then start
        // where the tab did.
        self.cwdMode = try? c.decodeIfPresent(WorkingDirectoryMode.self, forKey: .cwdMode)
        self.cwdPath = try c.decodeIfPresent(URL.self, forKey: .cwdPath)
        self.workingDirectory = try c.decodeIfPresent(String.self, forKey: .workingDirectory)
        self.pwd = try c.decodeIfPresent(String.self, forKey: .pwd)
        self.splitTree = try c.decode(SplitTree.self, forKey: .splitTree)
        self.zoomedLeafID = try c.decodeIfPresent(UUID.self, forKey: .zoomedLeafID)
        self.paneStates = try c.decodeIfPresent([UUID: PaneState].self, forKey: .paneStates) ?? [:]
        self.scrollbackPaths = try c.decodeIfPresent([UUID: String].self, forKey: .scrollbackPaths) ?? [:]
        self.initialCommands = try c.decodeIfPresent([UUID: String].self, forKey: .initialCommands) ?? [:]
        self.initialPromptFiles = try c.decodeIfPresent([UUID: String].self, forKey: .initialPromptFiles) ?? [:]
        self.container = try c.decode(ContainerID.self, forKey: .container)
        // A file written before the two maps existed keeps one field per
        // provider. Both are read so an upgrade does not blank the badges and
        // hints the interface is about to draw; only the new shape is written.
        self.agentSessions = try Self.decodeByProvider(c, forKey: .agentSessions)
            ?? Self.legacyByProvider(
                claude: c.decodeIfPresent([UUID: AgentSessionInfo].self, forKey: .claudeSessions),
                codex: c.decodeIfPresent([UUID: AgentSessionInfo].self, forKey: .codexSessions)
            )
        self.agentBadges = try Self.decodeByProvider(c, forKey: .agentBadges)
            ?? Self.legacyByProvider(
                claude: c.decodeIfPresent([UUID: AgentBadge].self, forKey: .claudeAgentBadges),
                codex: c.decodeIfPresent([UUID: AgentBadge].self, forKey: .codexAgentBadges)
            )
        self.tmuxBindings = try c.decodeIfPresent(
            [UUID: TmuxBinding].self,
            forKey: .tmuxBindings
        ) ?? [:]
        // A name of a shape this build cannot read (a provider a newer build
        // knows) costs the name, not the tab: the row then reads as its
        // branch until an agent names it again.
        self.conversationName = (try? c.decodeIfPresent(ConversationName.self, forKey: .conversationName)) ?? nil
        self.unknownFields = try CodableSidecar.decodeUnknownFields(from: decoder, knownKeys: Self.knownKeyStrings)
    }

    /// Title actually rendered in the UI: a manual override, else whatever
    /// libghostty last reported, after the name prefix either way. A
    /// name given after the move to the scratch tabs has no prefix, since
    /// a rename drops it.
    var displayTitle: String {
        prefixedTitle(name)
    }

    /// `name` after the name prefix, if any.
    func prefixedTitle(_ name: String) -> String {
        guard let namePrefix, !namePrefix.isEmpty else { return name }
        return "\(namePrefix) · \(name)"
    }

    /// The tab's own name, without the name prefix: a manual override, else
    /// the terminal's title. What names a session row, which never carries
    /// a group's name.
    var name: String {
        titleOverride.flatMap { $0.isEmpty ? nil : $0 } ?? title
    }

    /// Names the tab as the person typed it: the name prefix goes with the
    /// old name. An empty name goes back to the terminal's title. A
    /// submit that changes nothing never reaches here
    /// (`InlineRenameField.submission`).
    mutating func rename(_ name: String) {
        titleOverride = name.isEmpty ? nil : name
        namePrefix = nil
    }

    /// The directory a pane of this tab starts in: the tab's own
    /// default when it has one (a scratch tab moved from a group keeps the
    /// group's), else the directory the tab opened in. Also where its
    /// panes start again after a relaunch: with "continue where you are",
    /// that is the folder the tab was last in.
    var newPaneWorkingDirectory: String? {
        switch cwdMode {
        case nil:
            workingDirectory
        case .home:
            FileManager.default.homeDirectoryForCurrentUser.path
        case .inheritPrevious:
            pwd ?? workingDirectory
        case .fixed:
            cwdPath?.path ?? workingDirectory
        }
    }

    /// Only the current shape is written, and the keys a newer build added.
    /// An older build reading it finds no badges or hints and rebuilds both
    /// from the records on its next pass, which is what it does at every
    /// launch anyway.
    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(kind, forKey: .kind)
        try c.encode(title, forKey: .title)
        try c.encodeIfPresent(titleOverride, forKey: .titleOverride)
        try c.encodeIfPresent(namePrefix, forKey: .namePrefix)
        try c.encodeIfPresent(paletteIndex, forKey: .paletteIndex)
        try c.encodeIfPresent(cwdMode, forKey: .cwdMode)
        try c.encodeIfPresent(cwdPath, forKey: .cwdPath)
        try c.encodeIfPresent(workingDirectory, forKey: .workingDirectory)
        try c.encodeIfPresent(pwd, forKey: .pwd)
        try c.encode(splitTree, forKey: .splitTree)
        try c.encodeIfPresent(zoomedLeafID, forKey: .zoomedLeafID)
        try c.encode(paneStates, forKey: .paneStates)
        try c.encode(scrollbackPaths, forKey: .scrollbackPaths)
        try c.encode(initialCommands, forKey: .initialCommands)
        try c.encode(initialPromptFiles, forKey: .initialPromptFiles)
        try c.encode(container, forKey: .container)
        try c.encode(Self.encodedByProvider(agentSessions), forKey: .agentSessions)
        try c.encode(Self.encodedByProvider(agentBadges), forKey: .agentBadges)
        try c.encode(tmuxBindings, forKey: .tmuxBindings)
        try c.encodeIfPresent(conversationName, forKey: .conversationName)
        // A known key is written from its field alone, as
        // `SessionSnapshot.encode(to:)` does at the root.
        try CodableSidecar.encodeUnknownFields(
            unknownFields.filter { !Self.knownKeyStrings.contains($0.key) },
            to: encoder
        )
    }

    /// Pane whose agent session started most recently — the "owner" of
    /// `title` while at least one agent is alive. Compared across every
    /// provider because a tab can host a mixed set (e.g. pane 1 claude,
    /// pane 2 codex). Returns `nil` when no pane currently has a captured
    /// `sessionStartedAt`, in which case the caller falls back to whichever
    /// pane the OSC source happens to be focused on.
    ///
    /// The rule prevents an older session from clobbering a newer one:
    /// without it, pane 1 (older) typing a fresh turn would re-emit its
    /// own `firstPrompt` and overwrite pane 2's (newer) tab label.
    var latestAgentSessionPaneID: UUID? {
        var best: (paneID: UUID, started: Date)?
        for (paneID, badge) in agentBadges.values.flatMap(\.self) {
            guard let started = badge.sessionStartedAt else { continue }
            if best.map({ started > $0.started }) ?? true {
                best = (paneID, started)
            }
        }
        return best?.paneID
    }

    /// Convenience: tab containing a single empty pane.
    static func newWithSinglePane(
        title: String,
        workingDirectory: String? = nil,
        container: ContainerID
    ) -> (tab: Tab, paneID: UUID) {
        let paneID = UUID()
        let tab = Tab(
            title: title,
            workingDirectory: workingDirectory,
            splitTree: SplitTree(leafID: paneID),
            container: container
        )
        return (tab, paneID)
    }
}

// MARK: - ContainerID

/// Which container a Tab belongs to.
///
/// - `.loose`    : the scratch tabs, in no project.
/// - `.project`  : a Project's own tabs, in its root folder rather than
///                 in any worktree.
/// - `.worktree` : inside a specific worktree of a Project.
///
/// Forward-compat: a kind this build does not know lands on `.loose`
/// via the defensive decoder rather than quarantining the whole
/// snapshot: a future one (`.workspace`, …) a newer Weir wrote, or a
/// group's, which earlier builds wrote before groups became scratch
/// tabs. Same shape `Tab.Kind` / `ConfirmPolicy` already follow.
enum ContainerID: Codable, Hashable {
    case loose
    case project(UUID)
    case worktree(projectID: UUID, worktreeID: UUID)

    /// Unknown / future case lands here on decode so a state.json
    /// written by a newer Weir still opens — the tab moves to Loose
    /// instead of dropping out of the snapshot.
    static let unknownFallback: ContainerID = .loose

    var projectID: UUID? {
        switch self {
        case let .project(pid): pid
        case let .worktree(pid, _): pid
        case .loose: nil
        }
    }

    var worktreeID: UUID? {
        if case let .worktree(_, wid) = self {
            return wid
        }
        return nil
    }

    /// `true` when the container is anything other than `.loose`.
    var hasParent: Bool {
        if case .loose = self {
            return false
        }
        return true
    }

    // MARK: - Codable

    /// Outer discriminator: the case name. Swift's auto-synthesized
    /// `Codable` for an enum with associated values writes
    /// `{ "<case>": { …assoc… } }`; we match that exact shape so the
    /// encoder side stays auto-synth and a hand-written `state.json`
    /// keeps working.
    private struct DiscriminatorKey: CodingKey, Equatable {
        var stringValue: String
        var intValue: Int? {
            nil
        }

        init?(intValue _: Int) {
            nil
        }

        init(stringValue: String) {
            self.stringValue = stringValue
        }
    }

    /// Positional payload key matching auto-synth (`{"_0": value}` for
    /// single-UUID cases). The `_0` raw name is Swift's auto-synth
    /// convention, not ours — locked here to keep the wire shape
    /// identical to what older builds wrote.
    private enum PositionalKey: String, CodingKey {
        // swiftlint:disable:next identifier_name
        case _0
    }

    /// Named payload key matching auto-synth for the worktree case.
    private enum WorktreeKey: String, CodingKey {
        case projectID
        case worktreeID
    }

    init(from decoder: any Decoder) throws {
        let outer = try decoder.container(keyedBy: DiscriminatorKey.self)
        guard let key = outer.allKeys.first else {
            self = .unknownFallback
            return
        }
        switch key.stringValue {
        case "loose":
            self = .loose
        case "project":
            let nested = try outer.nestedContainer(keyedBy: PositionalKey.self, forKey: key)
            guard let id = try? nested.decode(UUID.self, forKey: ._0) else {
                self = .unknownFallback
                return
            }
            self = .project(id)
        case "worktree":
            let nested = try outer.nestedContainer(keyedBy: WorktreeKey.self, forKey: key)
            guard let pid = try? nested.decode(UUID.self, forKey: .projectID),
                  let wid = try? nested.decode(UUID.self, forKey: .worktreeID)
            else {
                self = .unknownFallback
                return
            }
            self = .worktree(projectID: pid, worktreeID: wid)
        default:
            // A discriminator this build does not know: a newer Weir's,
            // or a group's. The tab moves to the scratch tabs rather than
            // dropping out of the snapshot.
            self = .unknownFallback
        }
    }

    // `encode(to:)` stays auto-synthesized so the wire format is
    // identical to what older builds emit; no schema migration needed.
}

extension Tab {
    /// Mirror of `container.projectID` so consumers can stay terse.
    var projectID: UUID? {
        container.projectID
    }

    var worktreeID: UUID? {
        container.worktreeID
    }
}
