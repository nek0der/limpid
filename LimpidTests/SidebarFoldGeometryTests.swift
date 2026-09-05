// SidebarFoldGeometryTests.swift
// Limpid — the arithmetic the container slab folds sections with.
//
// Sections and projects fold by animating a computed height and
// clipping to it, not by inserting and removing rows, so these numbers
// have to agree with what the stack actually lays out. There is no
// compiler or layout check on that agreement: too small and the last
// row is cut off, too large and the list carries dead space that
// accumulates down the sidebar. The rows themselves are a fixed
// height, so the arithmetic is exact and worth pinning.
//
// What can't be pinned from here is the third party to the agreement —
// the real `VStack` spacing — which needs a render to observe.

import Foundation
import Testing
@testable import Limpid

/// `@MainActor` because the functions under test are statics on
/// `View` types and inherit that isolation. They are pure, so the
/// annotation buys nothing semantically — but without it the calls
/// still compile and then trap at runtime on the isolation check.
@MainActor
@Suite("Sidebar fold geometry")
struct SidebarFoldGeometryTests {

    private func makeWorktree(label: String, isHidden: Bool = false) -> Worktree {
        WorktreeFixture.make(label: label, isHidden: isHidden)
    }

    /// Built directly rather than through `WindowSessionFixture`: both
    /// functions under test take a `Project` value and read nothing
    /// else, so standing up a session would add a dependency on state
    /// they never touch.
    private func makeProject(worktrees: [Worktree], isExpanded: Bool = true) -> Project {
        Project(
            name: "test",
            rootURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("limpid-project-\(UUID().uuidString)"),
            worktrees: worktrees,
            isExpanded: isExpanded
        )
    }

    /// A project with nothing to show below it must claim exactly
    /// zero, or the row above the next project sits on a gap that
    /// belongs to nobody.
    @Test("a project with no visible worktrees claims no stack height")
    func worktreeStackHeight_noVisibleRows_isZero() {
        #expect(ProjectSectionView.worktreeStackHeight(for: makeProject(worktrees: [])) == 0)
        let allHidden = [
            makeWorktree(label: "a", isHidden: true),
            makeWorktree(label: "b", isHidden: true)
        ]
        #expect(ProjectSectionView.worktreeStackHeight(for: makeProject(worktrees: allHidden)) == 0)
    }

    /// One row is the boundary case for the `count - 1` gap term: it
    /// has a gap above it and none between anything.
    @Test("one visible worktree is its own height plus the gap above it")
    func worktreeStackHeight_singleRow_isRowPlusLeadingGap() {
        let project = makeProject(worktrees: [makeWorktree(label: "a")])
        #expect(
            ProjectSectionView.worktreeStackHeight(for: project)
                == LimpidLayout.reorderRowSpacing + LimpidLayout.containerColumnRowHeight
        )
    }

    /// Hidden rows are not laid out, so counting them would leave a
    /// gap under the project that grows with how many the user has
    /// hidden.
    @Test("hidden worktrees are not counted")
    func worktreeStackHeight_ignoresHiddenRows() {
        let mixed = [
            makeWorktree(label: "a"),
            makeWorktree(label: "hidden-1", isHidden: true),
            makeWorktree(label: "b"),
            makeWorktree(label: "hidden-2", isHidden: true),
            makeWorktree(label: "c")
        ]
        let visibleOnly = [
            makeWorktree(label: "a"),
            makeWorktree(label: "b"),
            makeWorktree(label: "c")
        ]
        #expect(
            ProjectSectionView.worktreeStackHeight(for: makeProject(worktrees: mixed))
                == ProjectSectionView.worktreeStackHeight(for: makeProject(worktrees: visibleOnly))
        )
    }

    @Test("consecutive rows are separated by exactly one gap each")
    func worktreeStackHeight_growsByRowPlusGap() {
        let two = makeProject(worktrees: [makeWorktree(label: "a"), makeWorktree(label: "b")])
        let one = makeProject(worktrees: [makeWorktree(label: "a")])
        #expect(
            ProjectSectionView.worktreeStackHeight(for: two)
                - ProjectSectionView.worktreeStackHeight(for: one)
                == LimpidLayout.containerColumnRowHeight + LimpidLayout.reorderRowSpacing
        )
    }

    /// A folded project still draws its header, so its block is one
    /// row tall — not zero, which would overlap it with the project
    /// below, and not the open height, which would leave a hole.
    @Test("a folded project claims its header and nothing more")
    func blockHeight_folded_isHeaderOnly() {
        let project = makeProject(
            worktrees: [makeWorktree(label: "a"), makeWorktree(label: "b")],
            isExpanded: false
        )
        #expect(ProjectSectionView.blockHeight(for: project) == LimpidLayout.containerColumnRowHeight)
    }

    @Test("an open project claims its header plus its worktree stack")
    func blockHeight_expanded_includesStack() {
        let project = makeProject(worktrees: [makeWorktree(label: "a")])
        #expect(
            ProjectSectionView.blockHeight(for: project)
                == LimpidLayout.containerColumnRowHeight
                + ProjectSectionView.worktreeStackHeight(for: project)
        )
    }

    /// The one case where the two functions can disagree: a project
    /// whose every worktree is hidden renders as flat, so an open one
    /// must claim the same height as a folded one.
    @Test("an open project with every worktree hidden is as tall as a folded one")
    func blockHeight_allHidden_matchesFolded() {
        let hidden = [makeWorktree(label: "a", isHidden: true)]
        #expect(
            ProjectSectionView.blockHeight(for: makeProject(worktrees: hidden))
                == ProjectSectionView.blockHeight(for: makeProject(worktrees: hidden, isExpanded: false))
        )
    }

    // MARK: - Section stack

    /// An empty section must claim zero, not one gap. `FoldableSection`
    /// puts the header outside the clip, so a section that claimed a
    /// gap it does not draw would push the next header down by one.
    @Test("an empty section claims nothing below its header")
    func stackedHeight_noBlocks_isZero() {
        #expect(ContainerSlabView.stackedHeight([]) == 0)
    }

    /// The leading term is the half of the agreement that a reader
    /// cannot see from `FoldableSection`: the gap above the first row
    /// is inside the clipped height, so it has to be counted here and
    /// nowhere else. Drop it and the last row is cut off by exactly
    /// one gap.
    @Test("a section's height carries the gap above its first block")
    func stackedHeight_singleBlock_includesLeadingGap() {
        #expect(
            ContainerSlabView.stackedHeight([LimpidLayout.containerColumnRowHeight])
                == LimpidLayout.reorderRowSpacing + LimpidLayout.containerColumnRowHeight
        )
    }

    @Test("blocks are separated by exactly one gap each")
    func stackedHeight_multipleBlocks_countsInteriorGaps() {
        let blocks = [CGFloat(30), 60, 30]
        #expect(
            ContainerSlabView.stackedHeight(blocks)
                == LimpidLayout.reorderRowSpacing + 120 + 2 * LimpidLayout.reorderRowSpacing
        )
    }

    /// The section and the project stack fold the same way, so the two
    /// have to agree on what the leading gap is worth. A single
    /// one-worktree project is the smallest case where both apply.
    @Test("a section of one project agrees with that project's own stack")
    func stackedHeight_matchesProjectStackConvention() {
        let project = makeProject(worktrees: [makeWorktree(label: "a")])
        #expect(
            ContainerSlabView.stackedHeight([ProjectSectionView.blockHeight(for: project)])
                == LimpidLayout.reorderRowSpacing
                + LimpidLayout.containerColumnRowHeight
                + ProjectSectionView.worktreeStackHeight(for: project)
        )
    }
}
