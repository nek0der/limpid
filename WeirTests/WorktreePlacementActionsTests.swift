// WorktreePlacementActionsTests.swift
// Weir — the placement choices the project settings and the new workspace sheet share, and what each sets.

import Foundation
import Testing
@testable import Weir

@MainActor
struct WorktreePlacementActionsTests {
    @Test func theSiblingAndInsideChoices_setTheirPlacement_whateverFolderIsRemembered() {
        #expect(WorktreePlacementActions.placement(for: .siblingPrefixed, customParent: "") == .siblingPrefixed)
        #expect(WorktreePlacementActions.placement(for: .insideHidden, customParent: "") == .insideHidden)
        #expect(WorktreePlacementActions.placement(for: .siblingPrefixed, customParent: "/tmp/wt") == .siblingPrefixed)
        #expect(WorktreePlacementActions.placement(for: .insideHidden, customParent: "/tmp/wt") == .insideHidden)
    }

    @Test func theCustomChoice_needsAFolder_whichThePanelAsksForOtherwise() {
        #expect(WorktreePlacementActions.placement(for: .custom, customParent: "") == nil)
        #expect(WorktreePlacementActions.placement(for: .custom, customParent: "  \n") == nil)
        #expect(WorktreePlacementActions.placement(for: .custom, customParent: " /tmp/wt ") == .custom(URL(fileURLWithPath: "/tmp/wt")))
        let home = ("~/wt" as NSString).expandingTildeInPath
        #expect(WorktreePlacementActions.placement(for: .custom, customParent: "~/wt") == .custom(URL(fileURLWithPath: home)))
    }

    @Test func eachPlacement_isTheChoiceThatSetsIt() {
        let custom = WorktreePlacement.custom(URL(fileURLWithPath: "/tmp/wt"))
        for placement in [WorktreePlacement.siblingPrefixed, .insideHidden, custom] {
            let choice = WorktreePlacementActions.choice(of: placement)
            let parent = WorktreePlacementActions.customParent(of: placement)
            #expect(WorktreePlacementActions.placement(for: choice, customParent: parent) == placement)
        }
        #expect(WorktreePlacementActions.customParent(of: .siblingPrefixed).isEmpty)
        #expect(WorktreePlacementActions.customParent(of: custom) == "/tmp/wt")
    }

    @Test func theMenusFace_namesThePlacementShort_andAChosenFolderByItsName() {
        let en = Locale(identifier: "en")
        let ja = Locale(identifier: "ja")
        #expect(WorktreePlacementActions.shortTitle(of: .siblingPrefixed).resolved(in: en) == "Next to the Project")
        #expect(WorktreePlacementActions.shortTitle(of: .siblingPrefixed).resolved(in: ja) == "プロジェクトと同じ階層")
        #expect(WorktreePlacementActions.shortTitle(of: .insideHidden).resolved(in: en) == "Inside the Project")
        #expect(WorktreePlacementActions.shortTitle(of: .insideHidden).resolved(in: ja) == "プロジェクト内")
        let custom = WorktreePlacement.custom(URL(fileURLWithPath: "/tmp/worktrees"))
        #expect(WorktreePlacementActions.shortTitle(of: custom) == .verbatim("worktrees"))
    }

    @Test func theInsidePlacement_hasOneNameInBothSheets_andBothLanguages() {
        #expect(WorktreePlacementActions.insideTitle.resolved(in: Locale(identifier: "en")) == "Inside the Project (.worktrees/)")
        #expect(WorktreePlacementActions.insideTitle.resolved(in: Locale(identifier: "ja")) == "プロジェクト内（.worktrees/）")
    }

    @Test func theSiblingPreview_namesTheRepositorysFolder() {
        let (_, project) = WorkspaceSessionFixture.withProject(rootURL: URL(fileURLWithPath: "/tmp/myapp"))
        #expect(WorktreePlacementActions.siblingPreview(of: project) == "myapp-<branch>")
        #expect(WorktreePlacementActions.siblingPreview(of: nil) == "<repo>-<branch>")
    }

    @Test func applyingAChoice_changesTheProjectsPlacement() {
        let (session, project) = WorkspaceSessionFixture.withProject()
        WorktreePlacementActions.apply(.insideHidden, customParent: "", to: project.id, in: session, attachedTo: nil)
        #expect(session.project(project.id)?.worktreePlacement == .insideHidden)
        WorktreePlacementActions.apply(.custom, customParent: "/tmp/wt", to: project.id, in: session, attachedTo: nil)
        #expect(session.project(project.id)?.worktreePlacement == .custom(URL(fileURLWithPath: "/tmp/wt")))
        WorktreePlacementActions.apply(.siblingPrefixed, customParent: "/tmp/wt", to: project.id, in: session, attachedTo: nil)
        #expect(session.project(project.id)?.worktreePlacement == .siblingPrefixed)
    }
}
