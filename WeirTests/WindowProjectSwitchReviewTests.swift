// WindowProjectSwitchReviewTests.swift
// Weir — the review of a scratch pane, which a window keeps as it switches project.

import Foundation
import Testing
@testable import Weir

/// A review of a pane in no project is the window's, not a project's: it
/// stays with the window as it switches, and outlives a project removed
/// meanwhile. What a project's review does is `ParkedReviewTests`'.
extension WindowProjectSwitchTests {
    @Test func removingTheProjectWhileReviewingAScratchPane_keepsTheReviewItsCommentAndItsDiscards() throws {
        let fixture = Fixture()
        let scratch = fixture.scratchTab()
        fixture.choose(scratch, in: fixture.primary)
        _ = try fixture.window(showing: fixture.b)
        _ = try fixture.window(showing: fixture.c)
        let pane = try #require(scratch.splitTree.allLeafIDs().first)
        let tab = try Fixture.windowWritingAComment(fixture.primary, agentPaneID: pane, isOfNoProject: true)
        let hunk = try Fixture.reviewAndHunk().hunk
        fixture.primary.hunkDiscards[hunk] = Fixture.discarded

        // The project the window named goes; the scratch pane it reviews
        // does not.
        fixture.session.removeProject(fixture.a.id)
        fixture.registry.forgetProjectsGone(in: fixture.session)

        #expect(fixture.primary.review?.opening == tab.opening)
        #expect(fixture.primary.reviewHasUnsavedComment)
        #expect(fixture.primary.reviewSession?.composer.text == "Why this?")
        // The review open still reads its worktree: its records stay.
        #expect(fixture.primary.hunkDiscards[hunk] == Fixture.discarded)
        #expect(fixture.registry.parkedReviews.isEmpty)
    }

    @Test func aWindowOfNoProjectSwitching_keepsItsReviewOfAScratchPane() throws {
        let session = WorkspaceSession()
        let scratch = session.openTab(container: .loose)
        let project = session.addOrActivateProject(rootURL: WorkspaceSessionFixture.projectRootURL("only"), suggestedName: "only")
        let projectTab = session.openTab(container: .project(project.id))
        session.setActiveTab(scratch.id)
        session.primarySelection.projectID = nil
        let registry = WindowRegistry(primary: session.primarySelection)
        registry.presenter = RecordingWindowPresenter()
        registry.connectProjectSwitching(of: session)
        let window = registry.primary
        let pane = try #require(scratch.splitTree.allLeafIDs().first)
        let tab = try Fixture.windowWritingAComment(window, agentPaneID: pane, isOfNoProject: true)

        // ⌘J or a notification takes the window to the project.
        session.setActiveTab(projectTab.id, in: window.id, intent: .person)

        #expect(window.selection.shownProjectID == project.id)
        #expect(window.review?.opening == tab.opening)
        #expect(window.reviewHasUnsavedComment)
        #expect(registry.parkedReviews.isEmpty)
    }
}
