// Tab.swift
// Limpid — a tab is one work session. Every tab belongs to exactly one
// container (Loose / Group / Project-direct / Worktree). The container
// drives where the tab appears in the container column sidebar and which list it
// shows up in inside tab column.

import Foundation

struct Tab: Codable, Equatable, Identifiable {

    /// Wire-level discriminator so a future tab kind (editor, agent
    /// dashboard, …) can land without breaking an older build that opens
    /// the same `state.json`. The defensive decoder routes unknown raw
    /// values back to `.terminal`, so the offending tab still loads.
    enum Kind: String, Codable, Equatable {
        case terminal
        /// Every pane shows a pane of one tmux window over control mode;
        /// tmux owns the layout and the tab pins padding per pane.
        case tmuxMirror

        static let unknownFallback: Kind = .terminal

        init(from decoder: any Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Kind(rawValue: raw) ?? .unknownFallback
        }
    }

    /// Who asked for a mirror tab. The kind says what a tab shows; this says
    /// what it is for, which changes what the user may do to it
    /// (`TabCapabilities`) and, later, what becomes of it when tmux ends its
    /// session. Unknown raw values read as `.user`, the origin every mirror
    /// tab had before this field existed.
    enum MirrorOrigin: String, Codable, Equatable {
        /// Opened by the user from the palette, or by `break-pane`.
        case user
        /// Opened for an agent a shim started in Limpid's own tmux server.
        /// The tab's only leaf carries the agent's `LIMPID_PANE_ID`.
        case agent

        init(from decoder: any Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = MirrorOrigin(rawValue: raw) ?? .user
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

    /// cwd the tab was opened in.
    var workingDirectory: String?

    /// Latest pwd reported by libghostty's PWD action.
    var pwd: String?

    /// Pane layout inside the tab.
    var splitTree: SplitTree

    /// When non-nil, the terminal column pane area renders only this leaf at full size
    /// instead of `splitTree`. tmux Prefix+z equivalent. Persisted so a
    /// zoomed tab survives quit/restore. Cleared automatically when the
    /// referenced pane goes away (split, close, etc.).
    var zoomedLeafID: UUID?

    /// Per-pane persisted state (unread count). Transient bits (bell
    /// flash, last child-exit code) live on `WindowSession.paneTransients`
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
    /// Used by demo mode to stage a reproducible hero screenshot; a
    /// future "open new tab running `claude`" feature plugs into the
    /// same slot.
    var initialCommands: [UUID: String] = [:]

    /// Where this tab lives. Drives container column selection routing and tab column list
    /// membership.
    var container: ContainerID

    /// Per-pane resume hints, by provider. Keyed by split-tree leaf UUID
    /// (= `LIMPID_PANE_ID`) so two splits running the same agent each
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
    /// `TabRow` / `ContainerRow` aggregate them for the status icons.
    var agentBadges: [AgentKind: [UUID: AgentBadge]] = [:]

    /// Which providers may auto-resume in each pane, as the projection decided
    /// on its last pass. A pane with hints from two providers resumes only the
    /// one the rules picked, so two agents do not fight over one terminal.
    /// Not persisted: the first pass after launch runs before any surface
    /// mounts, and the answer depends on the hints on disk, not on the tab.
    var agentResumeCandidates: [UUID: Set<AgentKind>] = [:]

    /// Which tmux session each pane was showing when Limpid last quit,
    /// read off the pane's tty rather than reported by the shell. A pane
    /// that was at its own prompt has no entry, so restoring it brings
    /// back a shell; one that was attached reattaches to the same
    /// session instead of leaving it running unreferenced. Optional
    /// default = `[:]` so an existing `state.json` decodes without a
    /// snapshot version bump.
    var tmuxBindings: [UUID: TmuxBinding] = [:]

    /// Where each pane's bytes come from, keyed by leaf id. Only panes that
    /// are not plain shells have an entry; see `ioSource(for:)`. Kept beside
    /// the other per-pane dictionaries so `SplitTree` stays a tree of ids.
    var paneSources: [UUID: PaneIOSource] = [:]

    /// Meaningful only for a `.tmuxMirror` tab; every other tab keeps the
    /// default.
    var mirrorOrigin: MirrorOrigin = .user

    /// The provider an agent mirror tab was opened for, as its request named
    /// it. `nil` on every other tab, and on an agent tab whose provider this
    /// build does not know. Kept so the tab can be named before the agent's
    /// first record arrives and, later, so its end can be judged from that
    /// provider's run record.
    var mirroredAgent: AgentKind?

    func ioSource(for paneID: UUID) -> PaneIOSource {
        paneSources[paneID] ?? .local
    }

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
        tmuxBindings: [UUID: TmuxBinding] = [:],
        paneSources: [UUID: PaneIOSource] = [:]
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
        self.paneSources = paneSources
    }

    /// Written and read explicitly because the decoder accepts a shape this
    /// build no longer writes: the four per-provider fields an older file
    /// carries. Auto-synthesis would not know those names.
    private enum CodingKeys: String, CodingKey {
        case id, kind, title, titleOverride, workingDirectory, pwd, splitTree
        case zoomedLeafID, paneStates, scrollbackPaths, initialCommands, container
        case agentSessions, agentBadges, tmuxBindings, paneSources
        case mirrorOrigin, mirroredAgent
        case claudeSessions, claudeAgentBadges, codexSessions, codexAgentBadges
    }

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
        self.workingDirectory = try c.decodeIfPresent(String.self, forKey: .workingDirectory)
        self.pwd = try c.decodeIfPresent(String.self, forKey: .pwd)
        self.splitTree = try c.decode(SplitTree.self, forKey: .splitTree)
        self.zoomedLeafID = try c.decodeIfPresent(UUID.self, forKey: .zoomedLeafID)
        self.paneStates = try c.decodeIfPresent([UUID: PaneState].self, forKey: .paneStates) ?? [:]
        self.scrollbackPaths = try c.decodeIfPresent([UUID: String].self, forKey: .scrollbackPaths) ?? [:]
        self.initialCommands = try c.decodeIfPresent([UUID: String].self, forKey: .initialCommands) ?? [:]
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
        self.paneSources = try c.decodeIfPresent(
            [UUID: PaneIOSource].self,
            forKey: .paneSources
        ) ?? [:]
        self.mirrorOrigin = try c.decodeIfPresent(MirrorOrigin.self, forKey: .mirrorOrigin) ?? .user
        // `try?`: a provider this build does not know leaves the tab an agent
        // tab without a provider rather than failing the whole snapshot.
        self.mirroredAgent = try? c.decodeIfPresent(AgentKind.self, forKey: .mirroredAgent)
    }

    /// Title actually rendered in the UI. Honors a manual override; falls
    /// back to whatever libghostty last reported.
    var displayTitle: String {
        if let override = titleOverride, !override.isEmpty {
            return override
        }
        return title
    }

    /// Only the current shape is written. An older build reading it finds no
    /// badges or hints and rebuilds both from the records on its next pass,
    /// which is what it does at every launch anyway.
    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(kind, forKey: .kind)
        try c.encode(title, forKey: .title)
        try c.encodeIfPresent(titleOverride, forKey: .titleOverride)
        try c.encodeIfPresent(workingDirectory, forKey: .workingDirectory)
        try c.encodeIfPresent(pwd, forKey: .pwd)
        try c.encode(splitTree, forKey: .splitTree)
        // Written only when a pane is not a plain shell, so an ordinary
        // tab's snapshot is byte-identical to what earlier builds wrote.
        if !paneSources.isEmpty {
            try c.encode(paneSources, forKey: .paneSources)
        }
        // Likewise only for an agent tab, so a user's mirror tab and every
        // ordinary tab are written as before.
        if mirrorOrigin != .user {
            try c.encode(mirrorOrigin, forKey: .mirrorOrigin)
        }
        try c.encodeIfPresent(mirroredAgent, forKey: .mirroredAgent)
        try c.encodeIfPresent(zoomedLeafID, forKey: .zoomedLeafID)
        try c.encode(paneStates, forKey: .paneStates)
        try c.encode(scrollbackPaths, forKey: .scrollbackPaths)
        try c.encode(initialCommands, forKey: .initialCommands)
        try c.encode(container, forKey: .container)
        try c.encode(Self.encodedByProvider(agentSessions), forKey: .agentSessions)
        try c.encode(Self.encodedByProvider(agentBadges), forKey: .agentBadges)
        try c.encode(tmuxBindings, forKey: .tmuxBindings)
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
    ///
    /// `paneID` is fresh unless the caller already owns the leaf's
    /// identity, as an agent mirror tab does: its leaf must carry the id
    /// the agent's records name.
    static func newWithSinglePane(
        title: String,
        workingDirectory: String? = nil,
        container: ContainerID,
        paneID: UUID = UUID()
    ) -> (tab: Tab, paneID: UUID) {
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

/// Which container a Tab belongs to. The four cases map 1:1 to the
/// rows the user can select in container column.
///
/// - `.loose`    : the implicit "Loose Tabs" pseudo-container (top of
///                 container column). Tabs that aren't filed under a Group or Project.
/// - `.group`    : labelled bucket, no path, no git.
/// - `.project`  : a Project's "direct" tabs — sit under the Project
///                 header itself, not under any worktree (shown as the
///                 "general" leaf in container column).
/// - `.worktree` : inside a specific worktree of a Project.
///
/// Forward-compat: a future container kind (`.workspace`, …) added by
/// a newer Limpid lands in an older build's `state.json` and gets
/// folded back to `.loose` via the defensive decoder rather than
/// quarantining the whole snapshot. Same shape `Tab.Kind` /
/// `ConfirmPolicy` already follow.
enum ContainerID: Codable, Hashable {
    case loose
    case group(UUID)
    case project(UUID)
    case worktree(projectID: UUID, worktreeID: UUID)

    /// Unknown / future case lands here on decode so a state.json
    /// written by a newer Limpid still opens — the tab moves to Loose
    /// instead of dropping out of the snapshot.
    static let unknownFallback: ContainerID = .loose

    var projectID: UUID? {
        switch self {
        case let .project(pid): pid
        case let .worktree(pid, _): pid
        default: nil
        }
    }

    var worktreeID: UUID? {
        if case let .worktree(_, wid) = self {
            return wid
        }
        return nil
    }

    var groupID: UUID? {
        if case let .group(gid) = self {
            return gid
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
        case "group":
            let nested = try outer.nestedContainer(keyedBy: PositionalKey.self, forKey: key)
            guard let id = try? nested.decode(UUID.self, forKey: ._0) else {
                self = .unknownFallback
                return
            }
            self = .group(id)
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
            // Unknown discriminator from a newer Limpid — forward-compat
            // fallback. Tab moves to Loose rather than dropping out of
            // the snapshot.
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

    var groupID: UUID? {
        container.groupID
    }
}

// MARK: - Leaf removal

extension Tab {
    /// Remove one leaf and everything this tab keeps about it.
    @discardableResult
    mutating func removeLeaf(_ leafID: UUID) -> RemovedLeaves {
        removeLeaves { $0.splitTree = $0.splitTree.remove(leafID).tree }
    }

    /// Run `reshape` over the tab, then forget every leaf it took out of the
    /// tree. The set is the tree's difference rather than a list the caller
    /// passes, so a caller that rebuilds the whole tree (a tmux layout)
    /// cannot sweep a different set from the one it removed. Every per-pane
    /// dictionary is persisted except the resume candidates, so a missed one
    /// accumulates on disk; the unread count also keeps the tab's dot lit,
    /// since `hasUnread(in:)` reads the dictionary rather than the leaves.
    @discardableResult
    mutating func removeLeaves(reshaping reshape: (inout Tab) -> Void) -> RemovedLeaves {
        let before = Set(splitTree.allLeafIDs())
        reshape(&self)
        let removed = before.subtracting(splitTree.allLeafIDs())
        var unreadCount = 0
        for leafID in removed {
            unreadCount += paneStates.removeValue(forKey: leafID)?.unreadCount ?? 0
            scrollbackPaths.removeValue(forKey: leafID)
            initialCommands.removeValue(forKey: leafID)
            for provider in AgentKind.allCases {
                agentSessions[provider]?.removeValue(forKey: leafID)
                agentBadges[provider]?.removeValue(forKey: leafID)
            }
            agentResumeCandidates.removeValue(forKey: leafID)
            tmuxBindings.removeValue(forKey: leafID)
            paneSources.removeValue(forKey: leafID)
        }
        if let zoomed = zoomedLeafID, !splitTree.contains(leafID: zoomed) {
            zoomedLeafID = nil
        }
        // `SplitTree.remove` already hands focus to a neighbor; a rebuilt
        // tree keeps whatever focus the caller gave it, which may be gone.
        if let focused = splitTree.focusedLeafID, !splitTree.contains(leafID: focused) {
            splitTree.focusedLeafID = splitTree.allLeafIDs().first
        }
        return RemovedLeaves(ids: removed, unreadCount: unreadCount)
    }
}

/// What `Tab.removeLeaves` took out, for the state the session keeps
/// outside the tab.
struct RemovedLeaves {
    let ids: Set<UUID>
    /// Unread notifications the removed panes still held.
    let unreadCount: Int
}
