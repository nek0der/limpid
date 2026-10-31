// SidebarArrangement.swift
// Weir — how one window lays its sidebar out: the projects' order, which are folded, and which sections are open.

import Foundation

/// How one window lists its projects: in what order, which headers
/// are folded, and which of each project's folded sections the person
/// opened. The window's own, kept with it through every project it shows
/// (`WindowSelection.sidebarArrangement`), saved with its record, and taken
/// on by a window opened from it.
///
/// A project `projectOrder` does not name is one the arrangement has not
/// met (opened since, or a file from before arrangements): it is listed
/// last, folded or not by the sidebar's default rule, until the sidebar
/// settles it (`settled(projects:isOpenByDefault:)`). Only the
/// person changes what is settled.
struct SidebarArrangement: Codable, Equatable, Sendable {
    /// One project's folded section the person opened.
    struct SectionKey: Codable, Hashable, Sendable {
        let project: UUID
        /// `.missing`, `.cleanable`, or `.other`; the working rows have no fold.
        let section: SidebarSection

        init(project: UUID, section: SidebarSection) {
            self.project = project
            self.section = section
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: SectionKeyCodingKeys.self)
            project = try c.decode(UUID.self, forKey: .project)
            switch try c.decode(String.self, forKey: .section) {
            case "missing": section = .missing
            case "cleanable": section = .cleanable
            case "other": section = .other
            default:
                throw DecodingError.dataCorruptedError(forKey: .section, in: c, debugDescription: "not a folded section")
            }
        }

        func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: SectionKeyCodingKeys.self)
            try c.encode(project, forKey: .project)
            try c.encode(name, forKey: .section)
        }

        /// The section's name in `state.json`. The working rows have no
        /// fold, so a key naming them is refused rather than written as
        /// another section.
        private var name: String {
            get throws {
                switch section {
                case .missing: return "missing"
                case .cleanable: return "cleanable"
                case .other: return "other"
                case .working:
                    throw EncodingError.invalidValue(section, .init(codingPath: [], debugDescription: "the working rows have no fold"))
                }
            }
        }

        /// The order a save writes the keys in, so the same arrangement is
        /// written the same way each time.
        fileprivate var sortKey: String {
            // The missing rows' fold came last, so it sorts last and an
            // arrangement saved before it is written as it was.
            switch section {
            case .working, .cleanable: project.uuidString + "0"
            case .other: project.uuidString + "1"
            case .missing: project.uuidString + "2"
            }
        }
    }

    /// The projects in the order the person left them; those it does not
    /// name follow (`ProjectOrder.ordered(saved:projects:)`).
    var projectOrder: [UUID] = []
    /// The folded headers among those `projectOrder` names.
    var collapsedProjects: Set<UUID> = []
    /// The folded sections the person opened; every other one is folded.
    var openSections: Set<SectionKey> = []

    init(projectOrder: [UUID] = [], collapsedProjects: Set<UUID> = [], openSections: Set<SectionKey> = []) {
        self.projectOrder = projectOrder
        self.collapsedProjects = collapsedProjects
        self.openSections = openSections
    }

    /// Each field read on its own, and a section the build does not know
    /// passed by, so one bad entry costs that entry, not the window's
    /// record.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        projectOrder = try c.decodeIfPresent([UUID].self, forKey: .projectOrder) ?? []
        collapsedProjects = try c.decodeIfPresent(Set<UUID>.self, forKey: .collapsedProjects) ?? []
        let sections = try c.decodeIfPresent([LossySectionKey].self, forKey: .openSections) ?? []
        openSections = Set(sections.compactMap(\.key))
    }

    /// Written with its sets in one order, so a save of the same
    /// arrangement writes the same `state.json`.
    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(projectOrder, forKey: .projectOrder)
        try c.encode(collapsedProjects.sorted { $0.uuidString < $1.uuidString }, forKey: .collapsedProjects)
        // A key for the working rows, which have no fold, is left out
        // rather than fail the whole save.
        try c.encode(openSections.filter { $0.section != .working }.sorted { $0.sortKey < $1.sortKey }, forKey: .openSections)
    }

    private enum CodingKeys: String, CodingKey {
        case projectOrder, collapsedProjects, openSections
    }

    /// One entry of `openSections`, `nil` when it does not read.
    private struct LossySectionKey: Decodable {
        let key: SectionKey?

        init(from decoder: any Decoder) throws {
            key = try? SectionKey(from: decoder)
        }
    }

    /// Whether the arrangement has met `projectID` (`projectOrder`).
    func knows(_ projectID: UUID) -> Bool {
        projectOrder.contains(projectID)
    }

    /// `projects` (in the session's order) in this window's order.
    func ordered(_ projects: [UUID]) -> [UUID] {
        ProjectOrder.ordered(saved: projectOrder, projects: projects)
    }

    /// Whether `projectID`'s header is folded; `isOpenByDefault` for one
    /// the arrangement has not met.
    func isCollapsed(_ projectID: UUID, isOpenByDefault: Bool) -> Bool {
        knows(projectID) ? collapsedProjects.contains(projectID) : !isOpenByDefault
    }

    /// Whether `section` of `projectID` is open. The working rows always
    /// are.
    func isOpen(_ section: SidebarSection, of projectID: UUID) -> Bool {
        section == .working || openSections.contains(SectionKey(project: projectID, section: section))
    }

    /// Folds or unfolds `projectID`'s header, meeting it first at the
    /// bottom when it is new.
    mutating func setCollapsed(_ isCollapsed: Bool, _ projectID: UUID) {
        if !knows(projectID) {
            projectOrder.append(projectID)
        }
        if isCollapsed {
            collapsedProjects.insert(projectID)
        } else {
            collapsedProjects.remove(projectID)
        }
    }

    /// Opens or folds one of `projectID`'s folded sections.
    mutating func setOpen(_ isOpen: Bool, _ section: SidebarSection, of projectID: UUID) {
        guard section != .working else { return }
        let key = SectionKey(project: projectID, section: section)
        if isOpen {
            openSections.insert(key)
        } else {
            openSections.remove(key)
        }
    }

    /// Moves `projectID`'s header `offset` places (−1 up, +1 down) among
    /// `projects`, in the window's order: Move Up, Move Down, ⌥⌘↑ ⌥⌘↓.
    mutating func move(_ projectID: UUID, by offset: Int, among projects: [UUID]) {
        projectOrder = ProjectOrder.moved(projectID, by: offset, in: ordered(projects))
    }

    /// Moves `projectID`'s header to the top.
    mutating func moveToTop(_ projectID: UUID, among projects: [UUID]) {
        projectOrder = ProjectOrder.movedToTop(projectID, in: ordered(projects))
    }

    /// Writes the order a drag made. A project that came or went while it
    /// ran is met as `ordered` meets any: gone from the order, or at its end.
    mutating func setOrder(_ order: [UUID], among projects: [UUID]) {
        let present = Set(projects)
        let kept = order.filter(present.contains)
        let listed = Set(kept)
        projectOrder = kept + projects.filter { !listed.contains($0) }
    }

    /// Folds (`true`) or opens every header of `projects`: ⌥-click.
    mutating func setAllCollapsed(_ isCollapsed: Bool, among projects: [UUID]) {
        projectOrder = ordered(projects)
        collapsedProjects = isCollapsed ? Set(projectOrder) : []
    }

    /// Folds every header of `projects` but `projectID`'s, which opens:
    /// Collapse Others.
    mutating func collapseOthers(than projectID: UUID, among projects: [UUID]) {
        projectOrder = ordered(projects)
        collapsedProjects = Set(projectOrder.filter { $0 != projectID })
    }

    /// The arrangement with every project of `projects` met, in the order
    /// the window shows them: those it did not know go at the bottom,
    /// folded as `isOpenByDefault` says, and those that are gone are let
    /// go. What the sidebar writes once a project appears, so a project's
    /// header never folds or opens later by itself as its rows change.
    func settled(projects: [UUID], isOpenByDefault: (UUID) -> Bool) -> SidebarArrangement {
        let present = Set(projects)
        var next = self
        next.projectOrder = ordered(projects)
        next.collapsedProjects = Set(next.projectOrder.filter { isCollapsed($0, isOpenByDefault: isOpenByDefault($0)) })
        next.openSections = openSections.filter { present.contains($0.project) }
        return next
    }

    /// The arrangement without `projectID`: the project was closed.
    func removing(_ projectID: UUID) -> SidebarArrangement {
        var next = self
        next.projectOrder.removeAll { $0 == projectID }
        next.collapsedProjects.remove(projectID)
        next.openSections = openSections.filter { $0.project != projectID }
        return next
    }

    /// The arrangement keeping only the projects `isKnown` names: a record
    /// read at launch can name a project that is gone.
    func keeping(_ isKnown: (UUID) -> Bool) -> SidebarArrangement {
        var next = self
        next.projectOrder = projectOrder.filter(isKnown)
        next.collapsedProjects = collapsedProjects.filter(isKnown)
        next.openSections = openSections.filter { isKnown($0.project) }
        return next
    }
}

/// The keys of `SidebarArrangement.SectionKey`'s form in `state.json`.
private enum SectionKeyCodingKeys: String, CodingKey {
    case project, section
}
