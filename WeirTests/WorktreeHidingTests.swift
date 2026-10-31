// WorktreeHidingTests.swift
// Weir — Move to Other Worktrees moves a row at once, and its Undo brings it back.

import Foundation
import Testing
@testable import Weir

@MainActor
struct WorktreeHidingTests {
    /// Move to Other Worktrees moves the row at once with the pointer still on
    /// the sidebar, and the toast's Undo brings it back as it was.
    @Test func removeFromWorking_movesTheRowAtOnce_andUndoBringsItBack() throws {
        let (session, project) = WorkspaceSessionFixture.withProject()
        let worktree = try WorkspaceSessionFixture.appendWorktree(to: project.id, in: session, admission: .created)
        let row = ContainerID.worktree(projectID: project.id, worktreeID: worktree.id)
        let window = ProjectWindowState(selection: session.primarySelection)
        let toasts = ToastCenter()
        toasts.frontWindow = { window.id }
        window.present(SidebarPresentedSections(sections: [row: .working]))
        window.isPointerInSidebar = true
        @MainActor func shown() throws -> SidebarSection {
            let current = try #require(session.project(project.id))
            let computed = SidebarPresentedSections.computed(
                project: current,
                session: session,
                window: window.id,
                queue: AttentionQueue(),
                pullRequest: { _ in nil },
                gitFacts: { _ in nil }
            )
            return window.presentedSections(computed: computed, isDragging: false).section(of: row)
        }

        WorktreeHiding.removeFromWorking(
            session: session,
            windows: [window],
            toastCenter: toasts,
            projectID: project.id,
            worktree: worktree
        )

        #expect(try shown() == .other)
        let message = toasts.current(in: window.id)?.message
        #expect(message?.resolved(in: Locale(identifier: "ja")) == "「\(worktree.workingDirectory.lastPathComponent)」を「ほかのワークツリー」に移動しました。")
        window.present(SidebarPresentedSections(sections: [row: .other]))

        toasts.undo(in: window.id)

        #expect(session.worktree(projectID: project.id, worktreeID: worktree.id)?.admission == .created)
        #expect(try shown() == .working)
    }
}
