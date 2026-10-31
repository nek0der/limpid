// WindowRecord.swift
// Weir — one window as `state.json` keeps it: what it showed, how it was laid out, and whether it was shown.

import CoreGraphics
import Foundation

/// One window as it is saved: the lasting part of its
/// `WindowSelection`, and whether it was hidden or in front at quit.
/// History, the scratch tabs' owner, and what lasts only while the app
/// runs are left out.
///
/// Decoded field by field with defaults, so a record a later build wrote
/// with fields this one lacks, or one written before a field was added,
/// still reads. A field this build no longer has is read past and not
/// written back: `tabOrientation` and `tabColumnWidth`, from when a
/// window could set its tabs in a column. A record that says
/// `column` opens on the strip, and the build before, which reads both
/// with `decodeIfPresent` and a default, reads a record without them as
/// the strip at the default width.
struct WindowRecord: Codable, Equatable, Sendable {
    /// The project the window showed; nil for a window that had shown none
    /// (New Window, or the one it showed was removed).
    var projectID: UUID?
    /// The tab the window was on; `nil` on a row with no tab (the scratch
    /// row of an empty project), and the project then opens on its last session.
    var activeTabID: UUID?
    var activeContainerID: ContainerID
    /// The frame the window goes back to out of full screen; nil when the
    /// window was never laid out (a record migrated from an older shape).
    var frame: WindowFrame?
    var isFullScreen = false
    var sidebarWidth: Double
    var sidebarHidden = false
    var isChangesPanelPresented = false
    /// The changes panel's width as the person last dragged it; `nil`
    /// for the default.
    var changesPanelWidth: Double?
    /// How the changes panel listed the turns. A build before reads past
    /// it and drops it on its next save.
    var changesPanelGrouping = ChangesPanelGrouping.timeline
    /// How the sidebar listed the projects; `nil` in a record written
    /// before arrangements, which lists them in the projects' order with
    /// the default folds. A build before reads past it and drops it on its
    /// next save.
    var sidebar: SidebarArrangement?
    /// Hidden as the last window closed: the only window saved then,
    /// and shown again at launch. An earlier build saved every window it
    /// had hidden; those become their projects' views (`normalized`).
    var isHidden = false
    /// The window the person was last in, shown last so it is in front.
    var isFront = false
    /// Stands in for a primary's record that did not read (`unread`): the
    /// defaults, holding the primary's place, and put back as no record
    /// at all (`WorkspaceSession.restore(from:)`), not as one saved on the
    /// scratch row, which the defaults' `.loose` would otherwise read as.
    /// Never saved: a later save writes the window as it is then.
    var isUnread = false

    /// The defaults in a primary's place whose record did not read.
    static var unread: WindowRecord {
        var record = WindowRecord()
        record.isUnread = true
        return record
    }

    /// A window from the defaults: the sessions sidebar's width unless
    /// said otherwise. The demo and fixtures lay windows out with it, and a
    /// primary whose saved record does not read starts from it.
    init(
        projectID: UUID? = nil,
        activeTabID: UUID? = nil,
        activeContainerID: ContainerID = .loose,
        frame: WindowFrame? = nil,
        sidebarWidth: Double = Double(SessionLayoutDefaults.sidebarWidth)
    ) {
        self.projectID = projectID
        self.activeTabID = activeTabID
        self.activeContainerID = activeContainerID
        self.frame = frame
        self.sidebarWidth = sidebarWidth
    }

    @MainActor
    init(_ selection: WindowSelection, isHidden: Bool, isFront: Bool) {
        projectID = selection.projectID
        activeTabID = selection.activeTabID
        activeContainerID = selection.activeContainerID
        frame = selection.frame.map(WindowFrame.init)
        isFullScreen = selection.isFullScreen
        sidebarWidth = Double(selection.sidebarWidth)
        sidebarHidden = selection.sidebarHidden
        isChangesPanelPresented = selection.isChangesPanelPresented
        changesPanelWidth = selection.changesPanelWidth.map(Double.init)
        changesPanelGrouping = selection.changesPanelGrouping
        sidebar = selection.sidebarArrangement == SidebarArrangement() ? nil : selection.sidebarArrangement
        self.isHidden = isHidden
        self.isFront = isFront
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        projectID = try c.decodeIfPresent(UUID.self, forKey: .projectID)
        activeTabID = try c.decodeIfPresent(UUID.self, forKey: .activeTabID)
        activeContainerID = try c.decodeIfPresent(ContainerID.self, forKey: .activeContainerID) ?? .loose
        frame = try c.decodeIfPresent(WindowFrame.self, forKey: .frame)
        isFullScreen = try c.decodeIfPresent(Bool.self, forKey: .isFullScreen) ?? false
        sidebarWidth = try c.decodeIfPresent(Double.self, forKey: .sidebarWidth)
            ?? Double(SessionLayoutDefaults.sidebarWidth)
        sidebarHidden = try c.decodeIfPresent(Bool.self, forKey: .sidebarHidden) ?? false
        isChangesPanelPresented = try c.decodeIfPresent(Bool.self, forKey: .isChangesPanelPresented) ?? false
        changesPanelWidth = try c.decodeIfPresent(Double.self, forKey: .changesPanelWidth)
        // A grouping a later build added, or one that does not read, is the
        // timeline, not a window lost.
        changesPanelGrouping = (try? c.decodeIfPresent(ChangesPanelGrouping.self, forKey: .changesPanelGrouping))
            ?? .timeline
        // A sidebar that does not read is the default one, not a window
        // lost.
        sidebar = try? c.decodeIfPresent(SidebarArrangement.self, forKey: .sidebar)
        isHidden = try c.decodeIfPresent(Bool.self, forKey: .isHidden) ?? false
        isFront = try c.decodeIfPresent(Bool.self, forKey: .isFront) ?? false
    }

    /// Lays `selection` out as the window was. What it showed is put back
    /// by `WorkspaceSession.restoreWindows`, which checks it against the
    /// restored session first.
    @MainActor
    func applyLayout(to selection: WindowSelection) {
        selection.frame = frame?.cgRect
        selection.sidebarWidth = CGFloat(sidebarWidth)
        selection.sidebarHidden = sidebarHidden
        selection.isFullScreen = isFullScreen
        selection.isChangesPanelPresented = isChangesPanelPresented
        selection.changesPanelWidth = changesPanelWidth.map { CGFloat($0) }
        selection.changesPanelGrouping = changesPanelGrouping
        selection.sidebarArrangement = sidebar ?? SidebarArrangement()
    }

    private enum CodingKeys: String, CodingKey {
        case projectID, activeTabID, activeContainerID, frame, isFullScreen
        case sidebarWidth, sidebarHidden
        case isChangesPanelPresented, changesPanelWidth, changesPanelGrouping
        case sidebar
        case isHidden, isFront
    }
}

extension WindowRecord {
    /// The windows to make of `records`, the primary first, and the views
    /// of the projects the rest showed. A build before
    /// windows really closed hid every window it closed and saved each, so
    /// its records can hold many hidden windows, the primary among them.
    ///
    /// Every shown window is made, the one the person was last in (else
    /// the first shown) first, so the primary is one that was on screen:
    /// its selection and layout are that record's, not a hidden one's.
    /// With every window hidden, only the one last used (else the first)
    /// is made, still hidden, for the Dock to bring back. A hidden window
    /// not made becomes its project's view, so coming back to the project
    /// finds what it showed; its frame was the window's, and goes with it.
    ///
    /// Records this build wrote are all made again, as it writes only the
    /// shown windows, or the one hidden window; the one in front still
    /// comes first, so the primary is the window last used. Read at
    /// launch, ahead of everything that takes the first record for the
    /// primary.
    static func normalized(_ records: [WindowRecord]) -> (windows: [WindowRecord], views: [ProjectView]) {
        let shown = records.indices.filter { !records[$0].isHidden }
        let made: [Int] = if let first = shown.first(where: { records[$0].isFront }) ?? shown.first {
            [first] + shown.filter { $0 != first }
        } else {
            (records.firstIndex(where: \.isFront) ?? records.indices.first).map { [$0] } ?? []
        }
        let views = records.indices.filter { !made.contains($0) }.compactMap { records[$0].projectView }
        return (made.map { records[$0] }, views)
    }

    /// What this window showed of its project, kept as the project's view
    /// once the window is not made again. `nil` for a window that showed
    /// no project.
    var projectView: ProjectView? {
        guard let projectID = projectID ?? activeContainerID.projectID else { return nil }
        return ProjectView(
            projectID: projectID,
            activeContainerID: activeContainerID,
            activeTabID: activeTabID,
            sidebarWidth: sidebarWidth,
            sidebarHidden: sidebarHidden,
            isChangesPanelPresented: isChangesPanelPresented,
            changesPanelWidth: changesPanelWidth
        )
    }
}
