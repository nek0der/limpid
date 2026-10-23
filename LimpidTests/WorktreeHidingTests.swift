// WorktreeHidingTests.swift
// Limpid — Hide All hides the worktrees ready to clean up, and one Undo shows them all again.

import Foundation
import Testing
@testable import Limpid

@MainActor
struct WorktreeHidingTests {
    /// Every row is hidden and none deleted; the toast's Undo shows each
    /// again.
    @Test func hideAll_hidesEveryRow_andOneUndoShowsThemAgain() throws {
        let (session, project) = WorkspaceSessionFixture.withProject()
        let first = try WorkspaceSessionFixture.appendWorktree(to: project.id, in: session, admission: .created)
        let second = try WorkspaceSessionFixture.appendWorktree(to: project.id, in: session, admission: .opened)
        let kept = try WorkspaceSessionFixture.appendWorktree(to: project.id, in: session, admission: .created)
        let toasts = ToastCenter()
        let window = WindowID()
        toasts.frontWindow = { window }

        WorktreeHiding.hideAll(session: session, toastCenter: toasts, projectID: project.id, worktrees: [first, second])

        let rows = try #require(session.project(project.id)).worktrees
        #expect(rows.count == 3)
        #expect(rows.filter(\.isHidden).map(\.id) == [first.id, second.id])
        #expect(rows.first { $0.id == kept.id }?.isHidden == false)
        let message = toasts.current(in: window)?.message
        #expect(message?.resolved(in: Locale(identifier: "en")) == "Hid 2 worktrees.")
        #expect(message?.resolved(in: Locale(identifier: "ja")) == "ワークツリー 2 個を非表示にしました。")

        toasts.undo(in: window)

        #expect(try #require(session.project(project.id)).worktrees.allSatisfy { !$0.isHidden })
    }

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

    /// One row is hidden as Remove from Sidebar hides it: its toast names it.
    @Test func hideAll_ofOneRow_namesIt() throws {
        let (session, project) = WorkspaceSessionFixture.withProject()
        let only = try WorkspaceSessionFixture.appendWorktree(to: project.id, in: session, admission: .created)
        let toasts = ToastCenter()
        let window = WindowID()
        toasts.frontWindow = { window }

        WorktreeHiding.hideAll(session: session, toastCenter: toasts, projectID: project.id, worktrees: [only])

        let message = toasts.current(in: window)?.message
        #expect(message?
            .resolved(in: Locale(identifier: "en")) == "Hid worktree \u{201C}\(only.workingDirectory.lastPathComponent)\u{201D}.")
    }
}
