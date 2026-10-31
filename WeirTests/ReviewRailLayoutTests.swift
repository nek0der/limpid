// ReviewRailLayoutTests.swift
// Weir — the review's file list: its order and grouping, and its width beside the diff, which adds up to the
// surface's at the cap as below it, and the heading pinned above it as it scrolls.

import AppKit
import SwiftUI
import Testing
@testable import Weir

@Suite("Review file list")
@MainActor
struct ReviewRailLayoutTests {
    /// A list dragged as wide as it goes leaves the diff its floor, at every
    /// width the list is inline at — fractional ones included, which is what
    /// a geometry reader hands the surface.
    @Test func widestList_leavesTheDiffItsFloor_atEveryInlineWidth() throws {
        var failures: [CGFloat] = []
        for whole in 530...1400 {
            for available in [CGFloat(whole), CGFloat(whole) + 0.5] {
                let width = try #require(ReviewRail.width(10000, in: available))
                if width + ReviewRail.diffMinimum > available || width != width.rounded()
                    || width != ReviewRail.maximumWidth(in: available)
                {
                    failures.append(available)
                }
            }
        }
        #expect(failures.isEmpty)
    }

    @Test func listWidth_staysInsideItsRange() {
        #expect(ReviewRail.width(10, in: 900) == ReviewRail.minimum)
        #expect(ReviewRail.width(10000, in: 2000) == ReviewRail.maximum)
        #expect(ReviewRail.width(300, in: 529) == nil)
        #expect(ReviewRail.isInline(in: ReviewRail.inlineMinimumWidth))
        #expect(!ReviewRail.isInline(in: ReviewRail.inlineMinimumWidth - 1))
    }

    /// A drag reports fractional widths; what is stored is whole points,
    /// inside the range the divider allows.
    @Test func draggedWidth_isRoundedAndClamped() {
        #expect(ReviewRail.resized(to: 250.4, in: 900) == 250)
        #expect(ReviewRail.resized(to: 250.6, in: 900) == 251)
        #expect(ReviewRail.resized(to: 10, in: 900) == ReviewRail.minimum)
        #expect(ReviewRail.resized(to: 10000, in: 731.5) == ReviewRail.maximumWidth(in: 731.5))
        #expect(ReviewRail.maximumWidth(in: 731.5) == 371)

        let presentation = ReviewPresentation()
        presentation.resizeRail(to: 300.7, in: 900)
        #expect(presentation.railWidth == 301)
        presentation.resizeRail(to: 10000, in: 700)
        #expect(presentation.railWidth == 700 - ReviewRail.diffMinimum)
    }

    /// The list, its divider and a diff at its floor, laid out as the review
    /// lays them out: at the cap and either side of it, the row is exactly
    /// as wide as the surface. With the divider a sibling it came out a
    /// point wider at the cap, and the chrome above re-centered on it.
    @Test func listAndDiff_areExactlyAsWideAsTheSurface() {
        var failures: [String] = []
        for available: CGFloat in [530, 531, 600, 731.5, 819, 820, 821, 1000, 1400] {
            let cap = ReviewRail.maximumWidth(in: available)
            for requested in [ReviewRail.minimum, cap - 1, cap, cap + 1, 10000] {
                let presentation = ReviewPresentation()
                presentation.railWidth = requested
                let host = NSHostingController(rootView: split(available: available, presentation: presentation))
                let size = host.sizeThatFits(in: CGSize(width: available, height: 400))
                if size.width != available {
                    failures.append("\(available) / \(requested): \(size.width)")
                }
            }
        }
        #expect(failures.isEmpty)
    }

    /// The review's own composition (`ReviewInlineSplit`), so a divider put
    /// back beside the list fails here.
    private func split(available: CGFloat, presentation: ReviewPresentation) -> some View {
        ReviewInlineSplit(available: available, presentation: presentation, showsRail: true) {
            ReviewFileRail(
                root: URL(fileURLWithPath: "/nonexistent/repo", isDirectory: true),
                files: [ReviewFile(path: "a.swift", layer: .unstaged, status: .modified)],
                stats: [:],
                commentCounts: [:],
                viewed: [],
                selection: nil,
                isTree: .constant(false),
                hidesViewed: .constant(false),
                onSelect: { _ in },
                onToggleViewed: { _ in },
                available: available
            )
        } diff: {
            Color.clear
        }
        .environment(presentation)
        .environment(ReviewTabDisplay())
    }

    /// The list the rail draws and the list `n` / `p` walk are one list, so
    /// in tree mode the keys go down the rail in directory order, and in the
    /// flat list in the order of its sections.
    @Test func fileOrderIsTheOrderTheRailDraws() {
        let files = [
            ReviewFile(path: "b/two.swift", layer: .unstaged, status: .modified),
            ReviewFile(path: "a/one.swift", layer: .untracked, status: .untracked),
            ReviewFile(path: "a/three.swift", layer: .staged, status: .modified),
            ReviewFile(path: "c/four.swift", layer: .turns, status: .modified)
        ]
        #expect(ReviewFileTree.ordered(files, isTree: true).map(\.path) == [
            "a/one.swift", "a/three.swift", "b/two.swift", "c/four.swift"
        ])
        // Flat is the rail's section order, which is how the layers are
        // declared — not how their raw values sort, which would put "turns"
        // after "staged".
        #expect(ReviewFileTree.ordered(files, isTree: false).map(\.layer) == [
            .turns, .staged, .unstaged, .untracked
        ])
    }

    /// The flat list heads its files with their kind only when there are
    /// kinds to tell apart; the tree always heads its directories.
    @Test func layerHeadings_showOnlyForMoreThanOneKind_orInTheTree() {
        let turns = [
            ReviewFile(path: "a.swift", layer: .turns, status: .modified),
            ReviewFile(path: "b.swift", layer: .turns, status: .added)
        ]
        let mixed = turns + [ReviewFile(path: "c.swift", layer: .unstaged, status: .modified)]

        #expect(!ReviewFileTree.showsLayerHeadings(files: turns, isTree: false), "one kind: nothing to tell apart")
        #expect(ReviewFileTree.showsLayerHeadings(files: mixed, isTree: false))
        #expect(ReviewFileTree.showsLayerHeadings(files: turns, isTree: true), "the tree heads its directories")
        #expect(ReviewFileTree.showsLayerHeadings(files: mixed, isTree: true))
    }

    /// The list goes away rather than pushing the diff out of the window.
    @Test func theFileListYieldsWhenThereIsNoRoomForBoth() {
        #expect(ReviewRail.width(232, in: 900) == 232)
        // Wide enough for both, but not for the width that was asked for.
        #expect(ReviewRail.width(400, in: 640) == 640 - ReviewRail.diffMinimum)
        // Not wide enough for the list and a readable diff together.
        #expect(ReviewRail.width(232, in: 500) == nil)
    }

    /// The tree groups by the directory that holds each file, and the files at
    /// the repository root group under an empty path.
    @Test func fileRailGroupsFilesByTheirDirectory() {
        let files = [
            ReviewFile(path: "README.md", layer: .unstaged, status: .modified),
            ReviewFile(path: "Weir/App/WeirApp.swift", layer: .unstaged, status: .modified),
            ReviewFile(path: "Weir/App/Scene.swift", layer: .staged, status: .modified)
        ]
        let groups = ReviewFileTree.directories(files)
        // Explicit closure rather than a key path: these are labeled tuples,
        // and `\.path` on one compiles but crashes the test host.
        // swiftformat:disable:next preferKeyPath
        #expect(groups.map { $0.path } == ["", "Weir/App"])
        #expect(groups[1].files.count == 2)
        #expect(ReviewFileTree.name("Weir/App/WeirApp.swift") == "WeirApp.swift")
        #expect(ReviewFileTree.parent("Weir/App/WeirApp.swift") == "Weir/App")
        #expect(ReviewFileTree.parent("README.md") == nil)
    }

    // MARK: - The pinned heading

    /// The pinned heading is the last above the top, pushed off by the next
    /// within a heading's height, and nothing at rest.
    @Test func theRailsPin_isTheLastHeadingAboveTheTop_pushedByTheNext() {
        #expect(ReviewRailPin.of([:], headerHeight: 24) == .none)
        #expect(ReviewRailPin.of(["a": 0, "b": 120], headerHeight: 24) == .none)
        #expect(ReviewRailPin.of(["a": -200, "b": -40, "c": 300], headerHeight: 24) == ReviewRailPin(id: "b", offset: 0))
        #expect(ReviewRailPin.of(["a": -200, "b": 10], headerHeight: 24) == ReviewRailPin(id: "a", offset: -14))
    }

    /// Scrolling the rail moves every heading on every frame, and each move
    /// reported its offset. The state the rail draws from changes only when
    /// the pinned heading or its push does: over 600 frames of a scroll
    /// past six sections, a few dozen writes rather than one per heading
    /// per frame.
    @Test func scrollingTheRail_changesThePinOnlyWhenItMoves() {
        let tops: [String: CGFloat] = ["a": 0, "b": 300, "c": 640, "d": 900, "e": 1400, "f": 1800]
        var pin = ReviewRailPin.none
        var pinWrites = 0
        var offsetReports = 0
        // Kept across frames, as the rail keeps them: a heading scrolled
        // away stops reporting and keeps its last offset.
        var offsets: [String: CGFloat] = [:]
        for frame in 0..<600 {
            let scrolled = CGFloat(frame) * 3
            for (id, top) in tops {
                let minY = (top - scrolled).rounded()
                // Only the headings on screen (a 500pt list) report.
                guard minY > -24, minY < 500 else { continue }
                offsets[id] = minY
                offsetReports += 1
            }
            let next = ReviewRailPin.of(offsets, headerHeight: 24)
            if next != pin {
                pin = next
                pinWrites += 1
            }
        }
        #expect(pinWrites < offsetReports / 10)
    }
}
