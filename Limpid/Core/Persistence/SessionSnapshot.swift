// SessionSnapshot.swift
// Limpid — Codable mirror of WindowSession used for on-disk persistence.
//
// Schema v5 — sidebar containers persist as a single `containers[]` array
// (a `Container` enum of group / project) instead of separate `groups[]` /
// `projects[]` keys. The in-memory `WindowSession` still keeps typed
// `groups`/`projects` arrays; this is only the on-disk shape. Older
// snapshots whose `version` doesn't match are quarantined by `SessionStore`
// (renamed to `state.json.bak-version-mismatch-<unix>`) and the in-memory
// state starts fresh — the app is pre-release, so a future migration can
// decide later.

import Foundation

/// `@unchecked Sendable` is the deliberate choice: `SessionSnapshot` is a
/// value type whose fields (and nested `Tab` / `Container` structures) are
/// all value-typed, so sharing across a `DispatchQueue` is safe via copy
/// semantics. The transitive chain (`Tab`, `SplitTree`, `PaneState`, the
/// agent badge / session info types) isn't yet annotated `Sendable`, so we
/// can't get the checked variant; revisit when that chain catches up.
struct SessionSnapshot: Codable, @unchecked Sendable {
    static let currentVersion: Int = 5

    var version: Int
    var groups: [TabGroup]
    var projects: [Project]
    var tabs: [Tab]
    var activeTabID: UUID?
    var activeContainerID: ContainerID
    var sidebarWidth: Double
    var tabColumnWidth: Double = LimpidLayout.tabColumnWidth
    /// Container column Waiting region height as a fraction of slab height.
    /// Optional so a state.json written before this field existed still
    /// decodes (synthesized Decodable uses decodeIfPresent for
    /// Optionals; nil → default in `restore`).
    var attentionHeightFraction: Double?
    var sidebarHidden: Bool
    var tabColumnHorizontal: Bool
    var windowFrame: WindowFrame?
    var recentProjectPaths: [URL]

    /// See `LimpidSettings.unknownFields`. Preserves unknown root-level
    /// keys across decode → encode so a newer Limpid's `state.json`
    /// writes survive a Sparkle rollback to an older build.
    var unknownFields: [String: LimpidJSONValue] = [:]

    init(
        version: Int = SessionSnapshot.currentVersion,
        groups: [TabGroup],
        projects: [Project],
        tabs: [Tab],
        activeTabID: UUID?,
        activeContainerID: ContainerID = .loose,
        sidebarWidth: Double,
        tabColumnWidth: Double = LimpidLayout.tabColumnWidth,
        attentionHeightFraction: Double? = nil,
        sidebarHidden: Bool = false,
        tabColumnHorizontal: Bool = false,
        windowFrame: WindowFrame? = nil,
        recentProjectPaths: [URL] = []
    ) {
        self.version = version
        self.groups = groups
        self.projects = projects
        self.tabs = tabs
        self.activeTabID = activeTabID
        self.activeContainerID = activeContainerID
        self.sidebarWidth = sidebarWidth
        self.tabColumnWidth = tabColumnWidth
        self.attentionHeightFraction = attentionHeightFraction
        self.sidebarHidden = sidebarHidden
        self.tabColumnHorizontal = tabColumnHorizontal
        self.windowFrame = windowFrame
        self.recentProjectPaths = recentProjectPaths
    }

    /// Hand-rolled so optional fields added after a snapshot was first
    /// written (`tabColumnWidth`, `attentionHeightFraction`,
    /// `tabColumnHorizontal`, `windowFrame`, `recentProjectPaths`) decode as
    /// their defaults instead of throwing — synthesized Codable would treat
    /// every property as required. Keep this in sync with the stored
    /// properties above: a new field needs a matching `decodeIfPresent`
    /// here, or old snapshots fail to load. Unknown `Container.kind` values
    /// drop the offending element rather than failing the snapshot.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.version = try c.decode(Int.self, forKey: .version)
        let containers = try c.decode([OptionalContainer].self, forKey: .containers)
            .compactMap(\.container)
        self.groups = containers.compactMap { if case let .group(g) = $0 { g } else { nil } }
        self.projects = containers.compactMap { if case let .project(p) = $0 { p } else { nil } }
        // Wire format separates content (`tabs: {id: Tab}`) from ordering
        // (`tabOrder: [UUID]`) so a future partial-update tool can rewrite
        // a single tab without re-encoding the whole array, and a reorder
        // doesn't churn every tab in the diff. Keys ride as UUID strings
        // because Swift's JSON encoder represents non-`String`-keyed
        // dictionaries as flat arrays; we want a real JSON object so the
        // schema is readable and JSON-Pointer-able.
        //
        // We reassemble the typed `[Tab]` in declared order; ids in
        // `tabOrder` that the dictionary doesn't carry are dropped, ids
        // in the dictionary that the order omits are appended at the end
        // so no data is silently lost.
        let rawTabs = try c.decode([String: Tab].self, forKey: .tabs)
        var tabsByID: [UUID: Tab] = [:]
        tabsByID.reserveCapacity(rawTabs.count)
        for (key, tab) in rawTabs {
            guard let id = UUID(uuidString: key) else { continue }
            tabsByID[id] = tab
        }
        let tabOrder = try c.decode([UUID].self, forKey: .tabOrder)
        var ordered: [Tab] = []
        ordered.reserveCapacity(tabsByID.count)
        var seen: Set<UUID> = []
        for id in tabOrder where !seen.contains(id) {
            if let tab = tabsByID[id] {
                ordered.append(tab)
                seen.insert(id)
            }
        }
        for (id, tab) in tabsByID where !seen.contains(id) {
            ordered.append(tab)
        }
        self.tabs = ordered
        self.activeTabID = try c.decodeIfPresent(UUID.self, forKey: .activeTabID)
        self.activeContainerID = try c.decode(ContainerID.self, forKey: .activeContainerID)
        self.sidebarWidth = try c.decode(Double.self, forKey: .sidebarWidth)
        self.tabColumnWidth = try c.decodeIfPresent(Double.self, forKey: .tabColumnWidth) ?? LimpidLayout.tabColumnWidth
        self.attentionHeightFraction = try c.decodeIfPresent(Double.self, forKey: .attentionHeightFraction)
        self.sidebarHidden = try c.decode(Bool.self, forKey: .sidebarHidden)
        self.tabColumnHorizontal = try c.decodeIfPresent(Bool.self, forKey: .tabColumnHorizontal) ?? false
        self.windowFrame = try c.decodeIfPresent(WindowFrame.self, forKey: .windowFrame)
        self.recentProjectPaths = try c.decodeIfPresent([URL].self, forKey: .recentProjectPaths) ?? []
        self.unknownFields = try CodableSidecar.decodeUnknownFields(
            from: decoder,
            knownKeys: Self.knownKeyStrings
        )
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        // Persist groups + projects as one unified `containers` array.
        try c.encode(groups.map(Container.group) + projects.map(Container.project), forKey: .containers)
        // Mirror of the dict + order shape the decoder expects. Keys are
        // UUID strings (see decoder's comment for why). Encode each
        // tab in place through a nested dynamic-key container so we
        // don't first build a `[(String, Tab)]` array and then a
        // `[String: Tab]` dictionary — both intermediates would
        // copy every `Tab` value (each carrying seven nested
        // `[UUID: …]` dictionaries) which adds up on the autosave hot
        // path.
        var tabsContainer = c.nestedContainer(keyedBy: LimpidDynamicKey.self, forKey: .tabs)
        for tab in tabs {
            try tabsContainer.encode(tab, forKey: LimpidDynamicKey(stringValue: tab.id.uuidString))
        }
        try c.encode(tabs.map(\.id), forKey: .tabOrder)
        try c.encodeIfPresent(activeTabID, forKey: .activeTabID)
        try c.encode(activeContainerID, forKey: .activeContainerID)
        try c.encode(sidebarWidth, forKey: .sidebarWidth)
        try c.encode(tabColumnWidth, forKey: .tabColumnWidth)
        try c.encodeIfPresent(attentionHeightFraction, forKey: .attentionHeightFraction)
        try c.encode(sidebarHidden, forKey: .sidebarHidden)
        try c.encode(tabColumnHorizontal, forKey: .tabColumnHorizontal)
        try c.encodeIfPresent(windowFrame, forKey: .windowFrame)
        try c.encode(recentProjectPaths, forKey: .recentProjectPaths)
        try CodableSidecar.encodeUnknownFields(unknownFields, to: encoder)
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case version, containers, tabs, tabOrder, activeTabID, activeContainerID
        case sidebarWidth, tabColumnWidth, attentionHeightFraction, sidebarHidden
        case tabColumnHorizontal, windowFrame, recentProjectPaths
    }

    /// Cached known-key set so `decodeUnknownFields` doesn't allocate
    /// + hash a 13-entry `Set` on every snapshot decode (state.json
    /// restore on launch, every settings watcher fire, every test
    /// round-trip).
    private static let knownKeyStrings: Set<String> = Set(CodingKeys.allCases.map(\.stringValue))
}

/// Unified sidebar container as persisted in state.json. A single
/// `containers[]` array replaces separate `groups[]` / `projects[]`, so a
/// future container kind is one more `case` here. `WindowSession` keeps
/// typed `groups`/`projects` arrays in memory — this is only the wire shape.
enum Container: Codable {
    case group(TabGroup)
    case project(Project)

    /// Thrown by `init(from:)` when the `kind` discriminant carries a value
    /// this build doesn't know — a newer Limpid added a case, the user
    /// later opens the file in an older build. `SessionSnapshot.init(from:)`
    /// catches and drops the offending element rather than failing the
    /// whole snapshot decode.
    struct UnknownKindError: Error {
        let rawKind: String
    }

    private enum CodingKeys: String, CodingKey { case kind, group, project }
    private enum Kind: String, Codable { case group, project }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rawKind = try c.decode(String.self, forKey: .kind)
        guard let kind = Kind(rawValue: rawKind) else {
            throw UnknownKindError(rawKind: rawKind)
        }
        switch kind {
        case .group: self = try .group(c.decode(TabGroup.self, forKey: .group))
        case .project: self = try .project(c.decode(Project.self, forKey: .project))
        }
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .group(g):
            try c.encode(Kind.group, forKey: .kind)
            try c.encode(g, forKey: .group)
        case let .project(p):
            try c.encode(Kind.project, forKey: .kind)
            try c.encode(p, forKey: .project)
        }
    }
}

/// Per-element wrapper used when decoding `containers[]` from disk: a
/// single unknown-kind item degrades to `nil` instead of aborting the
/// entire snapshot. Re-encoded only when wrapping an existing
/// `Container`; unknown-kind items are dropped on the next write.
private struct OptionalContainer: Codable {
    let container: Container?

    init(from decoder: any Decoder) throws {
        do {
            self.container = try Container(from: decoder)
        } catch is Container.UnknownKindError {
            self.container = nil
        }
    }

    func encode(to encoder: any Encoder) throws {
        if let container {
            try container.encode(to: encoder)
        }
    }
}

/// CGRect isn't Codable out of the box; this mirror keeps the JSON
/// stable (and human-readable) across builds.
struct WindowFrame: Codable, Equatable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    init(_ rect: CGRect) {
        x = Double(rect.origin.x)
        y = Double(rect.origin.y)
        width = Double(rect.size.width)
        height = Double(rect.size.height)
    }

    var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}

@MainActor
extension WindowSession {
    func makeSnapshot() -> SessionSnapshot {
        SessionSnapshot(
            groups: groups,
            projects: projects,
            tabs: tabs,
            activeTabID: activeTabID,
            activeContainerID: activeContainerID,
            sidebarWidth: Double(sidebarWidth),
            tabColumnWidth: Double(tabColumnWidth),
            attentionHeightFraction: Double(attentionHeightFraction),
            sidebarHidden: sidebarHidden,
            tabColumnHorizontal: tabColumnHorizontal,
            windowFrame: windowFrame.map(WindowFrame.init),
            recentProjectPaths: recentProjectPaths
        )
    }

    /// Restore from a decoded snapshot, sanitizing anything that would crash
    /// or mislead the UI. A tampered or partially-written state.json can carry
    /// duplicate pane UUIDs — which collide in `SurfaceRegistry` and trip an
    /// AppKit view-hierarchy assertion — or an `activeContainerID` pointing at
    /// a container that no longer exists. We drop / reset those and return a
    /// `SessionLoadIssue` so the caller can tell the user.
    @discardableResult
    func restore(from snapshot: SessionSnapshot) -> SessionLoadIssue? {
        guard snapshot.version == SessionSnapshot.currentVersion else { return nil }
        groups = snapshot.groups
        projects = snapshot.projects
        sidebarWidth = CGFloat(snapshot.sidebarWidth)
        tabColumnWidth = CGFloat(snapshot.tabColumnWidth)
        attentionHeightFraction = snapshot.attentionHeightFraction
            .map { CGFloat($0) } ?? LimpidLayout.attentionHeightFraction
        sidebarHidden = snapshot.sidebarHidden
        tabColumnHorizontal = snapshot.tabColumnHorizontal
        recentProjectPaths = snapshot.recentProjectPaths
        // Transient pane bits (bell ring / child exit) live on
        // `paneTransients` now, not on `Tab.paneStates`, so the
        // snapshot's tab list already excludes them. Wiping
        // `paneTransients` here keeps a stale bell flash from
        // surviving the next launch.
        paneTransients = [:]

        // Drop any tab that reuses a pane UUID already claimed by an earlier
        // tab, or that repeats one within its own tree: duplicate leaf IDs
        // collide in `SurfaceRegistry` and assert in AppKit on mount.
        var seenLeafIDs: Set<UUID> = []
        var keptTabs: [Tab] = []
        var droppedTabs = 0
        for tab in snapshot.tabs {
            let leafIDs = tab.splitTree.allLeafIDs()
            let unique = Set(leafIDs)
            if unique.count != leafIDs.count || !unique.isDisjoint(with: seenLeafIDs) {
                droppedTabs += 1
                continue
            }
            seenLeafIDs.formUnion(unique)
            keptTabs.append(tab)
        }
        tabs = keptTabs

        // Rebuild the unread cache from the restored snapshot so the
        // dock badge reflects reality before the first mutation.
        cachedWindowUnreadCount = tabs.reduce(0) { sum, tab in
            sum + tab.paneStates.values.reduce(0) { $0 + $1.unreadCount }
        }
        // Same posture for the per-project / per-worktree tab-count
        // caches the Project header and worktree rows consume — the
        // canonical `tabs` list just changed wholesale, so rebuild.
        rebuildTabCountCaches()
        windowFrame = snapshot.windowFrame?.cgRect

        // Pin the active tab first, then derive `activeContainerID`
        // from it — the invariant in `WindowSession.swift` requires
        // the two to agree when `activeTabID` is non-nil, and the
        // two-block form used previously could leave them disjoint
        // when the snapshot's active tab is in a different container
        // than the snapshot's active container (e.g. duplicate-pane
        // dedup dropped the original active tab, or the container
        // got deleted while the tab moved to loose).
        var resetContainer = false
        if let id = snapshot.activeTabID, let tab = tabs.first(where: { $0.id == id }) {
            activeTabID = id
            // Prefer the snapshot's active container if it still
            // exists AND agrees with the tab; otherwise mirror the
            // tab's container.
            if snapshot.activeContainerID == tab.container, containerExists(snapshot.activeContainerID) {
                activeContainerID = snapshot.activeContainerID
            } else {
                activeContainerID = tab.container
                if !containerExists(snapshot.activeContainerID) {
                    resetContainer = true
                }
            }
        } else if let first = tabs.first(where: { containerExists($0.container) }) {
            activeTabID = first.id
            activeContainerID = first.container
            resetContainer = !containerExists(snapshot.activeContainerID)
                || snapshot.activeContainerID != first.container
        } else {
            activeTabID = nil
            if containerExists(snapshot.activeContainerID) {
                activeContainerID = snapshot.activeContainerID
            } else {
                activeContainerID = .loose
                resetContainer = true
            }
        }

        guard droppedTabs > 0 || resetContainer else { return nil }
        var parts: [String] = []
        if droppedTabs > 0 { parts.append("\(droppedTabs) tab(s) with duplicate pane IDs were dropped") }
        if resetContainer { parts.append("the active container no longer existed") }
        return .decodeFailed(message: "Recovered a corrupt session: \(parts.joined(separator: "; ")).")
    }
}
