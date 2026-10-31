// AttentionQueueJumpTests.swift
// Weir — ⌘J through a store and its windows: where each window's walk
// stands, the item it lands on, and the walk handed to the window that shows
// another project.

import Foundation
import Testing
@testable import Weir

@MainActor
struct AttentionQueueJumpTests {
    @Test func choosingFromTheListIntoAnotherProjectsWindow_handsItTheWalk() throws {
        let store = AttentionQueueStore()
        let navigator = RecordingAttentionNavigator()
        store.navigator = navigator
        store.apply(.init(runtimes: [Self.stop("a"), Self.stop("b")]), announces: false)
        let first = ProjectWindowState(id: WindowID())
        let second = ProjectWindowState(id: WindowID())
        navigator.projectWindow = second

        try store.focus(#require(store.queue.items.first), from: first)

        #expect(second.cursor.current == store.queue.items.first?.id)
        #expect(second.cursor == first.cursor)
    }

    @Test func aNotificationsRuntime_goesThroughItsItem_orStraightToItsPane() {
        let store = AttentionQueueStore()
        let navigator = RecordingAttentionNavigator()
        store.navigator = navigator
        store.apply(.init(runtimes: [Self.stop("a")]), announces: false)
        let window = ProjectWindowState(id: WindowID())

        // Listed: through the item, so ⌘J continues from it.
        #expect(store.focus(runtimeID: "a", from: window))
        #expect(navigator.visited.count == 1)
        #expect(window.cursor.current == store.queue.items.first?.id)

        // Not listed (a turn already read): straight to where it runs.
        #expect(store.focus(runtimeID: "shown", from: window))
        #expect(!store.focus(runtimeID: "gone", from: window))
        #expect(navigator.runtimes == ["shown", "gone"])
    }

    private static func stop(_ name: String) -> RuntimeFact {
        RuntimeFact(
            runtimeID: name, provider: .claude, paneIDs: [UUID()], tabID: nil, projectID: nil,
            state: .error, updatedAt: Date(), episodeToken: "1", isEpisodeRead: false, detail: nil
        )
    }

    @Test func eachWindow_keepsItsOwnPlace() {
        let store = AttentionQueueStore()
        let navigator = RecordingAttentionNavigator()
        store.navigator = navigator
        store.apply(.init(runtimes: [Self.stop("a"), Self.stop("b")]), announces: false)
        let first = ProjectWindowState(id: WindowID())
        let second = ProjectWindowState(id: WindowID())

        store.jump(forward: true, in: first)
        store.jump(forward: true, in: first)
        store.jump(forward: true, in: second)

        let a = AttentionItemID.stop(EpisodeKey(origin: .runtime("a"), episodeToken: "1"))
        let b = AttentionItemID.stop(EpisodeKey(origin: .runtime("b"), episodeToken: "1"))
        #expect(navigator.visited == [a, b, a])
        #expect(first.cursor.current == b)
        #expect(second.cursor.current == a)
    }

    @Test func goingToAnItem_putsItOnItsPanesBar_andEndsAnyDoneLine() throws {
        let store = AttentionQueueStore()
        let navigator = RecordingAttentionNavigator()
        store.navigator = navigator
        store.apply(.init(runtimes: [Self.stop("a"), Self.stop("b")]), announces: false)
        let window = ProjectWindowState(id: WindowID())
        let stale = UUID()
        window.decisionBarDone[stale] = .answeredInTerminal

        // ⌘J names the item it would go to without moving there.
        let peeked = try #require(store.peekNext(from: window))
        #expect(window.cursor.current == nil)

        store.jump(forward: true, in: window)
        let first = try #require(store.queue.items.first)
        #expect(peeked.item.id == first.id)
        #expect(try window.decisionBarSelection[#require(first.subject.paneID)] == first.id)
        #expect(window.decisionBarDone.isEmpty)

        let second = try #require(store.queue.items.last)
        window.decisionBarDone[stale] = .answeredInTerminal
        store.focus(second, from: window)
        #expect(try window.decisionBarSelection[#require(second.subject.paneID)] == second.id)
        #expect(window.decisionBarDone.isEmpty)
        // Only ⌘J opens a turn's review on arrival; choosing from a list
        // does not.
        #expect(navigator.opensTurnReview == [true, false])
    }

    @Test func choosingFromTheList_movesTheCursor() throws {
        let store = AttentionQueueStore()
        let navigator = RecordingAttentionNavigator()
        store.navigator = navigator
        store.apply(.init(runtimes: [Self.stop("a"), Self.stop("b"), Self.stop("c")]), announces: false)
        let window = ProjectWindowState(id: WindowID())

        let chosen = try #require(store.queue.items.dropFirst().first)
        store.focus(chosen, from: window)
        store.jump(forward: true, in: window)

        #expect(navigator.visited.last == store.queue.items.last?.id)
    }
}

/// ⌘J into another project, with a session and windows behind it:
/// the window used switches in place and walks on, or the window that
/// shows the project comes forward and takes the walk.
@MainActor
extension AttentionQueueJumpTests {
    /// Two projects, `here` with one stopped agent (`a`) and `there` with
    /// two (`b1`, `b2`), and the primary on `here`, switching projects in
    /// place through its registry.
    @MainActor
    private struct TwoProjects {
        let session: WorkspaceSession
        let registry: WindowRegistry
        let store = AttentionQueueStore()
        let here: Project
        let there: Project
        let b1: Tab
        let navigator: SessionAttentionNavigator

        init() {
            let (session, here) = WorkspaceSessionFixture.withProject(name: "here")
            there = session.addOrActivateProject(
                rootURL: WorkspaceSessionFixture.projectRootURL("there"),
                suggestedName: "there"
            )
            let a = session.openTab(container: .project(here.id))
            b1 = session.openTab(container: .project(there.id))
            let b2 = session.openTab(container: .project(there.id))
            session.setActiveTab(a.id)
            session.primarySelection.projectID = here.id
            registry = WindowRegistry(primary: session.primarySelection)
            registry.presenter = RecordingWindowPresenter()
            registry.connectProjectSwitching(of: session)
            navigator = SessionAttentionNavigator(session: session, registry: registry)
            store.navigator = navigator
            store.apply(.init(runtimes: [
                RuntimeFact.stopped("a", in: a, of: here),
                RuntimeFact.stopped("b1", in: b1, of: there),
                RuntimeFact.stopped("b2", in: b2, of: there)
            ]), announces: false)
            self.session = session
            self.here = here
        }

        static func id(_ name: String) -> AttentionItemID {
            .stop(EpisodeKey(origin: .runtime(name), episodeToken: "1"))
        }
    }

    @Test func jump_toAnotherProjectsItem_switchesInPlace_andKeepsTheRound() {
        let fixture = TwoProjects()
        let window = fixture.registry.primary

        fixture.store.jump(forward: true, in: window)
        #expect(window.cursor.current == TwoProjects.id("a"))
        fixture.store.jump(forward: true, in: window)

        // The same window shows the other project; none was made.
        #expect(window.cursor.current == TwoProjects.id("b1"))
        #expect(window.selection.shownProjectID == fixture.there.id)
        #expect(window.selection.activeTabID == fixture.b1.id)
        #expect(fixture.registry.windows.count == 1)
        // The switch was ⌘J's, not the person's: the round goes on in the
        // project rather than starting it again from its head.
        fixture.store.jump(forward: true, in: window)
        #expect(window.cursor.current == TwoProjects.id("b2"))
    }

    @Test func jump_toAProjectAnotherWindowShows_handsTheCursorOver() throws {
        let fixture = TwoProjects()
        let primary = fixture.registry.primary
        let other = try #require(fixture.registry.openInNewWindow(project: fixture.there.id, in: fixture.session, from: nil))
        fixture.registry.hide(other.id)

        fixture.store.jump(forward: true, in: primary)
        fixture.store.jump(forward: true, in: primary)

        // The window that shows the project comes back with the item and
        // takes the walk; the one used stays on its project.
        #expect(!other.isHidden)
        #expect(other.selection.activeTabID == fixture.b1.id)
        #expect(other.cursor.current == primary.cursor.current)
        #expect(other.cursor.visited == primary.cursor.visited)
        // The item is chosen on the bar of the window that shows its pane.
        let item = try #require(fixture.store.queue.items.first { $0.id == other.cursor.current })
        let pane = try #require(item.subject.paneID)
        #expect(other.decisionBarSelection[pane] == item.id)
        #expect(primary.decisionBarSelection[pane] == nil)
        #expect(primary.selection.shownProjectID == fixture.here.id)
        #expect(fixture.registry.windows.count == 2)
        fixture.store.jump(forward: true, in: other)
        #expect(other.cursor.current == TwoProjects.id("b2"))
    }
}
