// SessionSnapshot.swift
// Limpid — Codable mirror of WindowSession used for on-disk persistence.
//
// Schema v4 — `Tab.container: ContainerID` model. The 3-pane redesign
// (Notes 2026-style L1 / L2 / L3) replaced the old TabOwnership /
// section split. v3 snapshots and older are dropped silently on load;
// the app is still pre-release so a fresh session is acceptable.

import Foundation

struct SessionSnapshot: Codable {
    static let currentVersion: Int = 4

    var version: Int
    var groups: [TabGroup]
    var projects: [Project]
    var tabs: [Tab]
    var activeTabID: UUID?
    var activeContainerID: ContainerID
    var sidebarWidth: Double
    var l2Width: Double = LimpidLayout.l2Width
    /// L1 WAITING region height as a fraction of slab height.
    /// Optional so a state.json written before this field existed still
    /// decodes (synthesized Decodable uses decodeIfPresent for
    /// Optionals; nil → default in `restore`).
    var attentionHeightFraction: Double?
    var sidebarHidden: Bool
    var l2Horizontal: Bool
    var windowFrame: WindowFrame?
    var recentProjectPaths: [URL]

    init(
        version: Int = SessionSnapshot.currentVersion,
        groups: [TabGroup],
        projects: [Project],
        tabs: [Tab],
        activeTabID: UUID?,
        activeContainerID: ContainerID = .loose,
        sidebarWidth: Double,
        l2Width: Double = LimpidLayout.l2Width,
        attentionHeightFraction: Double? = nil,
        sidebarHidden: Bool = false,
        l2Horizontal: Bool = false,
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
        self.l2Width = l2Width
        self.attentionHeightFraction = attentionHeightFraction
        self.sidebarHidden = sidebarHidden
        self.l2Horizontal = l2Horizontal
        self.windowFrame = windowFrame
        self.recentProjectPaths = recentProjectPaths
    }

    /// Hand-rolled so optional fields added after a snapshot was first
    /// written (l2Width, l2Horizontal, windowFrame, recentProjectPaths)
    /// decode as their defaults instead of throwing — synthesized
    /// Codable would treat every property as required. Keep this in sync
    /// with the stored properties above: a new field needs a matching
    /// `decodeIfPresent` here, or old snapshots fail to load.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.version = try c.decode(Int.self, forKey: .version)
        self.groups = try c.decode([TabGroup].self, forKey: .groups)
        self.projects = try c.decode([Project].self, forKey: .projects)
        self.tabs = try c.decode([Tab].self, forKey: .tabs)
        self.activeTabID = try c.decodeIfPresent(UUID.self, forKey: .activeTabID)
        self.activeContainerID = try c.decode(ContainerID.self, forKey: .activeContainerID)
        self.sidebarWidth = try c.decode(Double.self, forKey: .sidebarWidth)
        self.l2Width = try c.decodeIfPresent(Double.self, forKey: .l2Width) ?? LimpidLayout.l2Width
        self.sidebarHidden = try c.decode(Bool.self, forKey: .sidebarHidden)
        self.l2Horizontal = try c.decodeIfPresent(Bool.self, forKey: .l2Horizontal) ?? false
        self.windowFrame = try c.decodeIfPresent(WindowFrame.self, forKey: .windowFrame)
        self.recentProjectPaths = try c.decodeIfPresent([URL].self, forKey: .recentProjectPaths) ?? []
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
            l2Width: Double(l2Width),
            attentionHeightFraction: Double(attentionHeightFraction),
            sidebarHidden: sidebarHidden,
            l2Horizontal: l2Horizontal,
            windowFrame: windowFrame.map(WindowFrame.init),
            recentProjectPaths: recentProjectPaths
        )
    }

    func restore(from snapshot: SessionSnapshot) {
        guard snapshot.version == SessionSnapshot.currentVersion else { return }
        groups = snapshot.groups
        projects = snapshot.projects
        sidebarWidth = CGFloat(snapshot.sidebarWidth)
        l2Width = CGFloat(snapshot.l2Width)
        attentionHeightFraction = snapshot.attentionHeightFraction
            .map { CGFloat($0) } ?? LimpidLayout.attentionHeightFraction
        sidebarHidden = snapshot.sidebarHidden
        l2Horizontal = snapshot.l2Horizontal
        recentProjectPaths = snapshot.recentProjectPaths
        activeContainerID = snapshot.activeContainerID
        // Transient pane bits (bell ring / child exit) live on
        // `paneTransients` now, not on `Tab.paneStates`, so the
        // snapshot's tab list already excludes them. Wiping
        // `paneTransients` here keeps a stale bell flash from
        // surviving the next launch.
        paneTransients = [:]
        tabs = snapshot.tabs
        // Rebuild the unread cache from the restored snapshot so the
        // dock badge reflects reality before the first mutation.
        cachedWindowUnreadCount = tabs.reduce(0) { sum, tab in
            sum + tab.paneStates.values.reduce(0) { $0 + $1.unreadCount }
        }
        windowFrame = snapshot.windowFrame?.cgRect

        if let id = snapshot.activeTabID, tabs.contains(where: { $0.id == id }) {
            activeTabID = id
        } else {
            activeTabID = tabs.first?.id
        }
    }
}
