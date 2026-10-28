// SidebarArrangementTests.swift
// Limpid — one window's sidebar arrangement: meeting new projects at the bottom, folding, moving, and its saved form.

import Foundation
import Testing
@testable import Limpid

struct SidebarArrangementTests {
    private static let a = UUID()
    private static let b = UUID()
    private static let c = UUID()

    /// A project the arrangement has not met is listed last, folded or not
    /// by the default; once met, the default is not read again, so a header
    /// never opens or folds later by itself.
    @Test func settling_meetsNewProjectsAtTheBottom_byTheDefault_once() {
        var arrangement = SidebarArrangement(projectOrder: [Self.b], collapsedProjects: [Self.b])
        arrangement = arrangement.settled(projects: [Self.a, Self.b, Self.c]) { $0 == Self.c }

        #expect(arrangement.projectOrder == [Self.b, Self.a, Self.c])
        #expect(arrangement.collapsedProjects == [Self.b, Self.a])

        let again = arrangement.settled(projects: [Self.a, Self.b, Self.c]) { _ in true }
        #expect(again == arrangement, "the default is read only as a project is met")
    }

    @Test func settling_letsGoOfProjectsThatAreGone() {
        let arrangement = SidebarArrangement(
            projectOrder: [Self.a, Self.b],
            collapsedProjects: [Self.b],
            openSections: [.init(project: Self.b, section: .other), .init(project: Self.a, section: .cleanable)]
        ).settled(projects: [Self.a]) { _ in true }

        #expect(arrangement == SidebarArrangement(
            projectOrder: [Self.a],
            openSections: [.init(project: Self.a, section: .cleanable)]
        ))
    }

    @Test func aProjectNotMetYet_isFoldedOrNotByTheDefault() {
        let arrangement = SidebarArrangement(projectOrder: [Self.a], collapsedProjects: [Self.a])
        #expect(arrangement.isCollapsed(Self.a, isOpenByDefault: true), "a met project keeps its own")
        #expect(!arrangement.isCollapsed(Self.b, isOpenByDefault: true))
        #expect(arrangement.isCollapsed(Self.b, isOpenByDefault: false))
    }

    @Test func foldingAProjectNotMetYet_meetsItAtTheBottom() {
        var arrangement = SidebarArrangement(projectOrder: [Self.a])
        arrangement.setCollapsed(true, Self.c)
        #expect(arrangement.projectOrder == [Self.a, Self.c])
        #expect(arrangement.collapsedProjects == [Self.c])
        arrangement.setCollapsed(false, Self.c)
        #expect(arrangement.collapsedProjects.isEmpty)
        #expect(arrangement.projectOrder == [Self.a, Self.c])
    }

    @Test func movingAProject_laysTheOthersOutInTheWindowsOrderFirst() {
        var arrangement = SidebarArrangement(projectOrder: [Self.c])
        arrangement.move(Self.b, by: -1, among: [Self.a, Self.b, Self.c])
        #expect(arrangement.projectOrder == [Self.c, Self.b, Self.a])
        arrangement.moveToTop(Self.a, among: [Self.a, Self.b, Self.c])
        #expect(arrangement.projectOrder == [Self.a, Self.c, Self.b])
        arrangement.drop(Self.a, on: Self.b, isAfter: true, among: [Self.a, Self.b, Self.c])
        #expect(arrangement.projectOrder == [Self.c, Self.b, Self.a])
    }

    /// ⌥-click folds or opens every header; Collapse Others folds every one
    /// but its own, which opens.
    @Test func foldingAll_andFoldingTheOthers() {
        var arrangement = SidebarArrangement(projectOrder: [Self.b], collapsedProjects: [Self.b])
        arrangement.setAllCollapsed(true, among: [Self.a, Self.b, Self.c])
        #expect(arrangement.collapsedProjects == [Self.a, Self.b, Self.c])
        #expect(arrangement.projectOrder == [Self.b, Self.a, Self.c])
        arrangement.setAllCollapsed(false, among: [Self.a, Self.b, Self.c])
        #expect(arrangement.collapsedProjects.isEmpty)
        arrangement.collapseOthers(than: Self.b, among: [Self.a, Self.b, Self.c])
        #expect(arrangement.collapsedProjects == [Self.a, Self.c])
    }

    /// Each project's folded sections open on their own; the working rows
    /// have no fold.
    @Test func eachProjectsSections_openOnTheirOwn() {
        var arrangement = SidebarArrangement()
        arrangement.setOpen(true, .other, of: Self.a)
        arrangement.setOpen(true, .working, of: Self.a)
        #expect(arrangement.isOpen(.other, of: Self.a))
        #expect(!arrangement.isOpen(.other, of: Self.b))
        #expect(!arrangement.isOpen(.cleanable, of: Self.a))
        #expect(arrangement.isOpen(.working, of: Self.b))
        #expect(arrangement.openSections == [.init(project: Self.a, section: .other)])
        arrangement.setOpen(false, .other, of: Self.a)
        #expect(arrangement.openSections.isEmpty)
    }

    @Test func removingAProject_takesItsPlaceAndFoldsWithIt() {
        let arrangement = SidebarArrangement(
            projectOrder: [Self.a, Self.b],
            collapsedProjects: [Self.a],
            openSections: [.init(project: Self.a, section: .other)]
        ).removing(Self.a)
        #expect(arrangement == SidebarArrangement(projectOrder: [Self.b]))
    }

    /// The saved form: the sections by name, as `state.json` holds
    /// them.
    @Test func theSavedForm_namesTheSections_andReadsBack() throws {
        let arrangement = SidebarArrangement(
            projectOrder: [Self.a, Self.b],
            collapsedProjects: [Self.b],
            openSections: [
                .init(project: Self.a, section: .cleanable),
                .init(project: Self.b, section: .other),
                .init(project: Self.b, section: .missing)
            ]
        )
        let data = try JSONEncoder().encode(arrangement)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let sections = try #require(object["openSections"] as? [[String: String]])
        #expect(Set(sections.compactMap { $0["section"] }) == ["cleanable", "other", "missing"])

        #expect(try JSONDecoder().decode(SidebarArrangement.self, from: data) == arrangement)
    }

    /// The working rows have no fold: a key naming them is refused on its
    /// own, and an arrangement holding one leaves it out rather than write
    /// it as another section or fail the save.
    @Test func aKeyForTheWorkingRows_isRefused_andLeftOutOfTheSave() throws {
        let working = SidebarArrangement.SectionKey(project: Self.a, section: .working)
        #expect(throws: EncodingError.self) { try JSONEncoder().encode(working) }

        let arrangement = SidebarArrangement(openSections: [working, .init(project: Self.a, section: .other)])
        let read = try JSONDecoder().decode(SidebarArrangement.self, from: JSONEncoder().encode(arrangement))
        #expect(read.openSections == [.init(project: Self.a, section: .other)])
    }

    /// The same arrangement is written the same way each time, whatever
    /// order its sets hold their members in.
    @Test func theSavedForm_isTheSameEachTime() throws {
        let ids = (0..<8).map { _ in UUID() }
        let arrangement = SidebarArrangement(
            projectOrder: ids,
            collapsedProjects: Set(ids),
            openSections: Set(ids.flatMap { [
                SidebarArrangement.SectionKey(project: $0, section: .cleanable),
                .init(project: $0, section: .other)
            ] })
        )
        let rebuilt = SidebarArrangement(
            projectOrder: ids,
            collapsedProjects: Set(ids.reversed()),
            openSections: Set(ids.reversed().flatMap { [
                SidebarArrangement.SectionKey(project: $0, section: .other),
                .init(project: $0, section: .cleanable)
            ] })
        )
        // The object's own keys sorted, so only the sets' order is tried.
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        #expect(try encoder.encode(arrangement) == encoder.encode(rebuilt))
        let object = try #require(JSONSerialization.jsonObject(with: encoder.encode(arrangement)) as? [String: Any])
        let collapsed = try #require(object["collapsedProjects"] as? [String])
        #expect(collapsed == collapsed.sorted())
    }

    @Test func anEmptyObject_readsAsTheDefault() throws {
        let read = try JSONDecoder().decode(SidebarArrangement.self, from: Data("{}".utf8))
        #expect(read == SidebarArrangement())
    }
}
