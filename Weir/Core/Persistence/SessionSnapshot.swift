// SessionSnapshot.swift
// Weir — Codable mirror of WorkspaceSession used for on-disk persistence.
//
// Schema v6 — the projects persist in a `containers[]` array (a `Container`
// enum, whose one kind is a project since groups became scratch tabs), the
// tabs by ID with their order, and every window as a `WindowRecord`, the
// primary first. What each window shows and how it is laid out lives in its
// record, not at the root; what a project showed when a window last left it
// is at the root (`projectViews`), for the projects no window shows, an
// optional field, so it came without a version change. An older snapshot is
// brought forward by the steps in `VersionedDocumentMigrator` (`.session`);
// one with no step, or a newer one, is quarantined by `SessionStore`
// (renamed to `state.json.bak-version-mismatch-<unix>`) and the in-memory
// state starts fresh. `docs/data-migration.md` has the rules.

import Foundation
import OSLog

private let snapshotLog = Logger.weir("session.snapshot")

/// `@unchecked Sendable` is the deliberate choice: `SessionSnapshot` is a
/// value type whose fields (and nested `Tab` / `Container` structures) are
/// all value-typed, so sharing across a `DispatchQueue` is safe via copy
/// semantics. The transitive chain (`Tab`, `SplitTree`, `PaneState`, the
/// agent badge / session info types) isn't yet annotated `Sendable`, so we
/// can't get the checked variant; revisit when that chain catches up.
struct SessionSnapshot: Codable, @unchecked Sendable {
    static let currentVersion: Int = 6

    var version: Int
    var projects: [Project]
    var tabs: [Tab]
    /// Every window, the primary first (`WorkspaceSession.windowRecords`).
    /// Empty for a session that has none to restore, which then starts
    /// with the primary's defaults.
    var windows: [WindowRecord]
    var recentProjectPaths: [URL]
    /// What each project no window shows showed when a window last left it
    /// (`WorkspaceSession.projectViews`). A project a window shows is saved
    /// by that window's record alone.
    var projectViews: [ProjectView]
    /// The names the person gave tabs, by the conversation each stood for
    /// (`WorkspaceSession.conversationTabNames`). An optional field, so it
    /// came without a version change.
    var conversationTabNames: [ConversationTabName] = []

    /// See `WeirSettings.unknownFields`. Preserves unknown root-level
    /// keys across decode → encode so a newer Weir's `state.json`
    /// writes survive a Sparkle rollback to an older build.
    var unknownFields: [String: WeirJSONValue] = [:]

    init(
        version: Int = SessionSnapshot.currentVersion,
        projects: [Project],
        tabs: [Tab],
        windows: [WindowRecord] = [],
        recentProjectPaths: [URL] = [],
        projectViews: [ProjectView] = []
    ) {
        self.version = version
        self.projects = projects
        self.tabs = tabs
        self.windows = windows
        self.recentProjectPaths = recentProjectPaths
        self.projectViews = projectViews
    }

    /// Hand-rolled so optional fields decode as their defaults instead of
    /// throwing — synthesized Codable would treat every property as
    /// required. Keep this in sync with the stored properties above: a new
    /// field needs a matching `decodeIfPresent` here. A `Container.kind`
    /// this build does not know drops the offending element rather than
    /// failing the snapshot: a newer build's, or a group, which version 6
    /// never writes. A tab in a container of a kind this build does not
    /// know is a scratch tab (`ContainerID`).
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.version = try c.decode(Int.self, forKey: .version)
        let containers = try c.decode([OptionalContainer].self, forKey: .containers)
            .compactMap(\.container)
        self.projects = containers.map {
            switch $0 {
            case let .project(p): p
            }
        }
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
        // A window that does not read costs its own layout, never the
        // session or another window's: a later window is passed over, and
        // the primary, which every session has, starts from its defaults.
        let records = (try? c.decodeIfPresent([LossyWindowRecord].self, forKey: .windows)) ?? []
        self.windows = records.first.map { [$0.record ?? .unread] + records.dropFirst().compactMap(\.record) } ?? []
        self.recentProjectPaths = try c.decodeIfPresent([URL].self, forKey: .recentProjectPaths) ?? []
        // A view that does not read costs only itself: its project then
        // opens on its last session, as one no window has left does.
        self.projectViews = ((try? c.decodeIfPresent([LossyProjectView].self, forKey: .projectViews)) ?? [])
            .compactMap(\.view)
        // A name that does not read costs only itself: its conversation is
        // then called by its agent's title again.
        self.conversationTabNames = ((try? c.decodeIfPresent([LossyConversationTabName].self, forKey: .conversationTabNames)) ?? [])
            .compactMap(\.name)
        self.unknownFields = try CodableSidecar.decodeUnknownFields(
            from: decoder,
            knownKeys: Self.knownKeyStrings
        )
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        // The projects as `containers`, the shape the shell worktree hook
        // reads (`.containers[] | select(.kind == "project")`).
        try c.encode(projects.map(Container.project), forKey: .containers)
        // Mirror of the dict + order shape the decoder expects. Keys are
        // UUID strings (see decoder's comment for why). Encode each
        // tab in place through a nested dynamic-key container so we
        // don't first build a `[(String, Tab)]` array and then a
        // `[String: Tab]` dictionary — both intermediates would
        // copy every `Tab` value (each carrying seven nested
        // `[UUID: …]` dictionaries) which adds up on the autosave hot
        // path.
        var tabsContainer = c.nestedContainer(keyedBy: WeirDynamicKey.self, forKey: .tabs)
        for tab in tabs {
            try tabsContainer.encode(tab, forKey: WeirDynamicKey(stringValue: tab.id.uuidString))
        }
        try c.encode(tabs.map(\.id), forKey: .tabOrder)
        try c.encode(windows, forKey: .windows)
        try c.encode(recentProjectPaths, forKey: .recentProjectPaths)
        try c.encode(projectViews, forKey: .projectViews)
        try c.encode(conversationTabNames, forKey: .conversationTabNames)
        // A known key is written from its field alone: one set in
        // `unknownFields` by hand would otherwise be written after it and
        // win.
        try CodableSidecar.encodeUnknownFields(
            unknownFields.filter { !Self.knownKeyStrings.contains($0.key) },
            to: encoder
        )
    }

    /// A root key taken out of here is carried as an unknown field from
    /// then on, so a key dropped without a version change is removed in a
    /// migration step instead (as `SessionSnapshotV5.movedRootKeys` does).
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case version, containers, tabs, tabOrder, windows, recentProjectPaths, projectViews, conversationTabNames
    }

    /// Cached known-key set so `decodeUnknownFields` doesn't allocate
    /// + hash the key `Set` on every snapshot decode (state.json
    /// restore on launch, every settings watcher fire, every test
    /// round-trip).
    private static let knownKeyStrings: Set<String> = Set(CodingKeys.allCases.map(\.stringValue))
}

/// A container as persisted in state.json, tagged with its `kind`, so a
/// future container kind is one more `case` here. `WorkspaceSession` keeps
/// the typed `projects` array in memory — this is only the wire shape.
enum Container: Codable {
    case project(Project)

    /// Thrown by `init(from:)` when the `kind` discriminant carries a value
    /// this build doesn't know — a newer Weir added a case, the user
    /// later opens the file in an older build; or a `group`, which builds
    /// before groups became scratch tabs wrote. `SessionSnapshot.init(from:)`
    /// catches and drops the offending element rather than failing the
    /// whole snapshot decode.
    struct UnknownKindError: Error {
        let rawKind: String
    }

    private enum CodingKeys: String, CodingKey { case kind, project }
    private enum Kind: String, Codable { case project }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rawKind = try c.decode(String.self, forKey: .kind)
        guard let kind = Kind(rawValue: rawKind) else {
            throw UnknownKindError(rawKind: rawKind)
        }
        switch kind {
        case .project: self = try .project(c.decode(Project.self, forKey: .project))
        }
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .project(p):
            try c.encode(Kind.project, forKey: .kind)
            try c.encode(p, forKey: .project)
        }
    }
}

/// Per-element wrapper used when decoding `containers[]` from disk: a
/// single unknown-kind item degrades to `nil` instead of aborting the
/// entire snapshot. Re-encoded only when wrapping an existing
/// `Container`; unknown-kind items are dropped on the next write, so the
/// one passed over is logged: its kind, which is the schema's own word,
/// and never what it held.
private struct OptionalContainer: Codable {
    let container: Container?

    init(from decoder: any Decoder) throws {
        do {
            self.container = try Container(from: decoder)
        } catch let error as Container.UnknownKindError {
            snapshotLog.notice("container of unknown kind \(error.rawKind, privacy: .public) passed over")
            self.container = nil
        }
    }

    func encode(to encoder: any Encoder) throws {
        if let container {
            try container.encode(to: encoder)
        }
    }
}

/// One element of `windows`, read on its own so one that does not decode
/// leaves the others. The one passed over is gone at the next save, so it
/// is logged: which one and why, not what it held.
private struct LossyWindowRecord: Decodable {
    let record: WindowRecord?

    init(from decoder: any Decoder) throws {
        do {
            record = try WindowRecord(from: decoder)
        } catch {
            let index = decoder.codingPath.last?.intValue ?? -1
            snapshotLog.error(
                "window record \(index, privacy: .public) not read: \(decodingFailure(error), privacy: .public)"
            )
            record = nil
        }
    }
}

/// One element of `conversationTabNames`: a conversation, and the name the
/// person gave the tab that stood for it.
struct ConversationTabName: Codable, Equatable, Sendable {
    let conversation: ConversationKey
    let name: String
}

/// One element of `conversationTabNames`, read on its own, as
/// `LossyProjectView` reads a view: one that does not read is passed over.
private struct LossyConversationTabName: Decodable {
    let name: ConversationTabName?

    init(from decoder: any Decoder) throws {
        do {
            name = try ConversationTabName(from: decoder)
        } catch {
            let index = decoder.codingPath.last?.intValue ?? -1
            snapshotLog.error(
                "conversation tab name \(index, privacy: .public) not read: \(decodingFailure(error), privacy: .public)"
            )
            name = nil
        }
    }
}

/// One element of `projectViews`, read on its own as `LossyWindowRecord`
/// reads a window, and logged the same way.
private struct LossyProjectView: Decodable {
    let view: ProjectView?

    init(from decoder: any Decoder) throws {
        do {
            view = try ProjectView(from: decoder)
        } catch {
            let index = decoder.codingPath.last?.intValue ?? -1
            snapshotLog.error(
                "project view \(index, privacy: .public) not read: \(decodingFailure(error), privacy: .public)"
            )
            view = nil
        }
    }
}

/// What went wrong reading an element, by kind and by key, never by value:
/// the keys are the schema's own, the values the person's.
private func decodingFailure(_ error: any Error) -> String {
    guard let error = error as? DecodingError else { return String(describing: type(of: error)) }
    let (kind, context): (String, DecodingError.Context) = switch error {
    case let .typeMismatch(_, context): ("typeMismatch", context)
    case let .valueNotFound(_, context): ("valueNotFound", context)
    case let .keyNotFound(key, context): ("keyNotFound \(key.stringValue)", context)
    case let .dataCorrupted(context): ("dataCorrupted", context)
    @unknown default: ("unknown", DecodingError.Context(codingPath: [], debugDescription: ""))
    }
    return "\(kind) at \(context.codingPath.map(\.stringValue).joined(separator: "."))"
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
extension WorkspaceSession {
    func makeSnapshot() -> SessionSnapshot {
        var snapshot = SessionSnapshot(
            projects: projects,
            tabs: tabs,
            windows: windowRecords(),
            recentProjectPaths: recentProjectPaths,
            projectViews: savedProjectViews()
        )
        // In a fixed order, so a save that changes nothing writes the
        // same file.
        snapshot.conversationTabNames = conversationTabNames
            .map { ConversationTabName(conversation: $0.key, name: $0.value) }
            .sorted { lhs, rhs in
                let left = lhs.conversation
                let right = rhs.conversation
                return (left.provider.rawValue, left.conversationID) < (right.provider.rawValue, right.conversationID)
            }
        snapshot.unknownFields = carriedRootFields
        return snapshot
    }

    /// Reads everything `makeSnapshot()` writes, for the autosave to
    /// observe, so a change to any of it schedules a save even when nothing
    /// else changes in the same tick. Kept beside `makeSnapshot()` so a
    /// field added there is read here too.
    ///
    /// `_ = tabs` covers every persistable tab mutation (title, split
    /// tree, container, scrollback paths, the unread counts on
    /// `Tab.paneStates`): it tracks every write to `tabs[idx]`, so looping
    /// over the tabs' pane states adds nothing. The transient pane bits
    /// (bell, child exit) are on `paneTransients`, which is deliberately
    /// not read: kept in `tabs[idx]`, every BEL would encode the whole
    /// snapshot.
    func readSavedState() {
        _ = tabs
        _ = projects
        _ = recentProjectPaths
        // Every window's saved part, the primary's included, built the way
        // `makeSnapshot()` builds it. The window in front is not observed
        // (it changes with every click between windows); it is written
        // with the next change and at quit.
        _ = windowRecords()
        // A view alone can change, as when a window leaves a project, and
        // so can what a hidden window not written shows of its project.
        _ = projectViews
        _ = savedProjectViews()
        _ = conversationTabNames
    }

    /// A record can name a project that is gone since: its place in each
    /// window's order and its folds go with it.
    private func forgetGoneProjectsInSidebars() {
        for id in windowIDs {
            guard let selection = selection(id) else { continue }
            let kept = selection.sidebarArrangement.keeping { project($0) != nil }
            if kept != selection.sidebarArrangement {
                selection.sidebarArrangement = kept
            }
        }
    }

    /// Restore from a decoded snapshot, sanitizing anything that would crash
    /// or mislead the UI. A tampered or partially-written state.json can carry
    /// duplicate pane UUIDs — which collide in `SurfaceRegistry` and trip an
    /// AppKit view-hierarchy assertion — or an active container that no
    /// longer exists. We drop / reset those and return a `SessionLoadIssue`
    /// so the caller can tell the user.
    ///
    /// The primary window comes from the first window record. A tab still
    /// in a group, made after groups became scratch tabs by a build
    /// that could still make one, reads as a scratch tab (`ContainerID`),
    /// rather than going out of sight.
    ///
    /// The windows past the primary are made again (`restoreWindows`), each
    /// project's in its own, once a shown window is put first and an earlier
    /// build's hidden windows are turned into views
    /// (`WindowRecord.normalized`). The projects' views are taken once the
    /// windows are settled, so a project a window record holds keeps the
    /// record's (`restoreProjectViews`).
    @discardableResult
    func restore(from snapshot: SessionSnapshot) -> SessionLoadIssue? {
        guard snapshot.version == SessionSnapshot.currentVersion else { return nil }
        carriedRootFields = snapshot.unknownFields
        projects = snapshot.projects
        conversationTabNames = Dictionary(
            snapshot.conversationTabNames.map { ($0.conversation, $0.name) },
            uniquingKeysWith: { _, last in last }
        )
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

        // A shown window becomes the primary, and an earlier build's hidden
        // windows their projects' views, before the first record is taken
        // for the primary.
        let (records, hiddenViews) = WindowRecord.normalized(snapshot.windows)
        // A primary's record that did not read is put back as none.
        let primary = records.first.flatMap { $0.isUnread ? nil : $0 }
        primary?.applyLayout(to: primarySelection)
        let savedTabID = primary?.activeTabID
        let savedContainer = primary?.activeContainerID ?? .loose
        // From here on this is the primary's selection, from the first
        // normalized record, or from none when that record did not read;
        // the windows past it are made in `restoreWindows`. Pin the active
        // tab first, then derive the active container from it — the
        // invariant on `WindowSelection.activeTabID` requires the two to
        // agree when a tab is active, and the saved pair can disagree when
        // duplicate-pane dedup dropped the saved tab, or the container got
        // deleted while the tab moved to loose.
        var resetContainer = false
        // These are the projects held by the later windows whose records
        // read. A primary with no
        // record that read, or whose row is gone, does not stand in on one
        // of their tabs: that window, made next, would be dropped as a
        // second window of its project, and lose its own record for the
        // primary's (`restoreWindows`). With no other tab, it opens on the
        // scratch row.
        let laterProjects = Set(records.dropFirst().compactMap(\.projectID).filter { project($0) != nil })
        if let id = savedTabID, let tab = tabs.first(where: { $0.id == id }) {
            primarySelection.activeTabID = id
            // Prefer the saved container if it still exists AND agrees
            // with the tab; otherwise mirror the tab's container.
            if savedContainer == tab.container, containerExists(savedContainer) {
                primarySelection.activeContainerID = savedContainer
            } else {
                primarySelection.activeContainerID = tab.container
                if !containerExists(savedContainer) {
                    resetContainer = true
                }
            }
        } else if primary != nil, containerExists(savedContainer) {
            // Saved on a row that is still there with its tab gone or never
            // there (the scratch row, or a project with no tab yet): back on
            // it, on the tab choosing it opens, or on the empty row, rather
            // than on another project's tab as if the row were gone. That
            // project's own window, made next, would then be dropped as a
            // second window of it. A window that showed nothing is saved on
            // the scratch row (`windowRecords`).
            primarySelection.activeContainerID = savedContainer
            primarySelection.activeTabID = tabOpened(choosing: savedContainer)
        } else if let first = tabs.first(where: { tab in
            guard containerExists(tab.container) else { return false }
            return tab.container.projectID.map { !laterProjects.contains($0) } ?? true
        }) {
            primarySelection.activeTabID = first.id
            primarySelection.activeContainerID = first.container
            resetContainer = primary != nil
                && (!containerExists(savedContainer) || savedContainer != first.container)
        } else {
            primarySelection.activeTabID = nil
            if containerExists(savedContainer) {
                primarySelection.activeContainerID = savedContainer
            } else {
                primarySelection.activeContainerID = .loose
                resetContainer = true
            }
        }

        let views = hiddenViews + snapshot.projectViews
        restoreWindows(from: records, viewedProjects: Set(views.map(\.projectID)))
        forgetGoneProjectsInSidebars()
        // A window's chrome is its record's. A primary with no
        // record that read takes the chrome of the window that last showed
        // its project, which an earlier build kept with the project's view,
        // rather than the defaults; the view itself goes, as the window
        // holds the project now.
        if primary == nil, let shown = primarySelection.shownProjectID,
           let view = views.first(where: { $0.projectID == shown })
        {
            primarySelection.applyChrome(of: view)
        }
        restoreProjectViews(views)

        guard droppedTabs > 0 || resetContainer else { return nil }
        return .recovered(droppedTabCount: droppedTabs, didResetActiveContainer: resetContainer)
    }
}
