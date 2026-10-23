// PaneStripLayoutTests.swift
// Limpid — the pane strip's tabs share its width by cutting the longest titles first, and the selected tab's edge meets the rule.

import AppKit
import SwiftUI
import Testing
@testable import Limpid

@Suite("Pane strip tab widths")
struct PaneStripTabWidthsTests {
    private typealias Tab = PaneStripTabWidths.Tab
    private static let titleMinimum: CGFloat = 56

    private static func widths(_ tabs: [Tab], available: CGFloat, spacing: CGFloat = 0) -> [CGFloat] {
        PaneStripTabWidths.widths(of: tabs, available: available, spacing: spacing, titleMinimum: titleMinimum)
    }

    @Test func tabsWithRoom_takeTheirIdealWidths() {
        let tabs = [Tab(ideal: 120, bare: 60), Tab(ideal: 240, bare: 70)]
        #expect(Self.widths(tabs, available: 600, spacing: 2) == [120, 240])
        // Exactly enough is room enough.
        #expect(Self.widths(tabs, available: 362, spacing: 2) == [120, 240])
    }

    /// The widest tabs are held to one width; a tab under it keeps its own.
    @Test func shortOfRoom_theWidestTabsGiveWayFirst() {
        let tabs = [Tab(ideal: 100, bare: 60), Tab(ideal: 300, bare: 60), Tab(ideal: 300, bare: 60)]
        #expect(Self.widths(tabs, available: 500) == [100, 200, 200])
        // Tighter, the wide tabs go on giving way; the short one, under
        // the cap, keeps its own width.
        let tight = Self.widths(tabs, available: 340)
        #expect(tight[0] == 100)
        #expect(tight[1] == 120)
        #expect(tight[2] == 120)
        // A shell, Claude, and the review, of different lengths: the
        // longest gives way most.
        let (shell, claude, review) = (Tab(ideal: 232, bare: 62), Tab(ideal: 214, bare: 72), Tab(ideal: 330, bare: 76))
        let mixed = Self.widths([shell, claude, review], available: 520, spacing: 2)
        #expect(review.ideal - mixed[2] >= claude.ideal - mixed[1])
    }

    @Test func shortOfRoom_theTabsFillTheWidth_spacingIncluded() {
        let tabs = [Tab(ideal: 230, bare: 64), Tab(ideal: 210, bare: 70), Tab(ideal: 320, bare: 60)]
        let widths = Self.widths(tabs, available: 520, spacing: 2)
        let total: CGFloat = widths.reduce(0, +) + 4
        #expect(abs(total - 520) < 0.001)
    }

    /// Past every minimum the tabs stop shrinking, and the strip scrolls.
    @Test func pastEveryMinimum_theTabsKeepTheirMinimums() {
        let tabs = [Tab(ideal: 250, bare: 60), Tab(ideal: 250, bare: 80), Tab(ideal: 90, bare: 60)]
        #expect(Self.widths(tabs, available: 200, spacing: 2) == [116, 136, 90])
    }

    /// A tab whose whole title is under the minimum is never widened to it.
    @Test func aTabShorterThanTheMinimum_keepsItsOwnWidth() {
        let tabs = [Tab(ideal: 80, bare: 60), Tab(ideal: 400, bare: 60)]
        #expect(Self.widths(tabs, available: 10)[0] == 80)
        #expect(Self.widths(tabs, available: 300)[0] == 80)
    }

    /// From two tabs to eight, at strip widths from a narrow window's to a
    /// wide one's: each tab between its minimum and its ideal, a wider tab
    /// never drawn narrower than a shorter one with the same marks, and the
    /// tabs past the strip's edge only when every one is at its minimum.
    @Test(arguments: 2...8)
    func anyNumberOfTabs_atAnyWidth_stayInTheirBounds(count: Int) {
        let tabs = (0..<count).map { index in
            Tab(ideal: 90 + CGFloat((index * 73) % 170), bare: 62)
        }
        let minimums = tabs.map { $0.minimum(titleMinimum: Self.titleMinimum) }
        let spacing: CGFloat = 2
        for available in stride(from: CGFloat(160), through: 1600, by: 37) {
            let widths = Self.widths(tabs, available: available, spacing: spacing)
            let total = widths.reduce(0, +) + spacing * CGFloat(count - 1)
            for (index, width) in widths.enumerated() {
                #expect(width >= minimums[index] - 0.001)
                #expect(width <= tabs[index].ideal + 0.001)
            }
            for (left, right) in zip(tabs.indices, tabs.indices.dropFirst()) where tabs[left].ideal >= tabs[right].ideal {
                #expect(widths[left] >= widths[right] - 0.001)
            }
            if total > available + 0.001 {
                #expect(widths == minimums, "available \(available)")
            }
        }
    }

    // MARK: - The selected tab and the rule

    @Test func theRule_opensUnderTheSelectedTab_onlyWhereTheTabCanBeSeen() {
        func opening(_ gap: CGRect?, visible: ClosedRange<CGFloat>? = 10...300) -> ClosedRange<CGFloat>? {
            PaneStripRuleLayout.opening(gap: gap, visible: visible, lineWidth: 1)
        }
        let tall: CGFloat = 30
        #expect(opening(nil) == nil, "no selected tab: the rule is whole")
        // In view: the rule stops at the tab's outer edge, where its sides
        // take over.
        #expect(opening(CGRect(x: 50, y: 0, width: 100, height: tall)) == 50...150)
        // Scrolled out under the review tab or "+", or off the leading
        // edge: the rule stays whole rather than opening there.
        #expect(opening(CGRect(x: 320, y: 0, width: 80, height: tall)) == nil)
        #expect(opening(CGRect(x: -60, y: 0, width: 50, height: tall)) == nil)
        // Half in view: the rule opens only over what can be seen.
        #expect(opening(CGRect(x: 280, y: 0, width: 80, height: tall)) == 280...300)
        #expect(opening(CGRect(x: 0, y: 0, width: 40, height: tall)) == 10...40)
        // A tab no wider than its two sides opens nothing.
        #expect(opening(CGRect(x: 50, y: 0, width: 2, height: tall)) == nil)
        // A tab that never scrolls opens where it is.
        #expect(opening(CGRect(x: 320, y: 0, width: 60, height: tall), visible: nil) == 320...380)
        #expect(opening(CGRect(x: -10, y: 0, width: 60, height: tall), visible: nil) == 0...50)
    }

    @Test func theSelectedTabsEdge_staysInsideTheTab_andRunsDownToTheRule() {
        let rect = CGRect(x: 0, y: 0, width: 100, height: 30)
        let path = FolderTabEdge(cornerRadius: 7).path(in: rect)
        // The end point of each element: the last of the points it carries.
        var points: [CGPoint] = []
        path.cgPath.applyWithBlock { element in
            let count = switch element.pointee.type {
            case .moveToPoint, .addLineToPoint: 1
            case .addQuadCurveToPoint: 2
            case .addCurveToPoint: 3
            case .closeSubpath: 0
            @unknown default: 0
            }
            if count > 0 {
                points.append(element.pointee.points[count - 1])
            }
        }
        // Half a line in from the sides and the top, so the whole 1pt
        // stroke lands inside the tab.
        let bounds = path.boundingRect
        #expect(abs(bounds.minX - 0.5) < 0.001)
        #expect(abs(bounds.maxX - 99.5) < 0.001)
        #expect(abs(bounds.minY - 0.5) < 0.001)
        #expect(abs(bounds.maxY - 30) < 0.001)
        // Both sides reach the bottom edge, where the strip's rule meets
        // them, and the edge stays open along the bottom.
        #expect(points.first == CGPoint(x: 0.5, y: 30))
        #expect(points.last == CGPoint(x: 99.5, y: 30))
        // The stroke's middle turns at 6.5, so its outer side has the
        // tab's 7pt corner radius.
        #expect(points.contains(CGPoint(x: 0.5, y: 0.5 + 6.5)))
        #expect(points.contains(CGPoint(x: 99.5 - 6.5, y: 0.5)))
    }
}

/// The strip's real tabs, the review's among them, in the strip's own
/// scroll view (`PaneStripScrollingTabs`), which measures the width they
/// share and keeps the selected tab in view, at a few widths.
@Suite("Pane strip tab layout")
@MainActor
struct PaneStripTabsLayoutTests {
    private static let longTitles = [
        "~/projects/sample-reviews/demo-repro-with-a-long-folder",
        "wip-review-the-approval-flow-on-a-long-branch"
    ]

    private static func items(_ titles: [String], selected: Int? = nil) -> [PaneStripModel.Item] {
        titles.enumerated().map { index, title in
            PaneStripModel.Item(
                id: UUID(),
                title: title,
                paletteIndex: nil,
                isActive: index == selected,
                agent: index == 1 ? .claude : nil,
                stateGlyph: nil,
                hasUnread: false,
                isInTmux: false,
                failedExitCode: nil
            )
        }
    }

    /// A window with a review tab open on turn T7 with a long prompt, so its
    /// label runs to its maximum.
    private static func windowWithReview() throws -> ProjectWindowState {
        var review = try ProjectWindowsFixture.review()
        guard case let .turn(range, _) = review.selection else { throw CancellationError() }
        review.selection = .turn(range, prompt: TurnPrompt(head: "new-approval4.txt and the rest of it"))
        let window = ProjectWindowState(selection: WindowSelection())
        window.review = review
        return window
    }

    private static func environment(_ view: some View, settings: SettingsStore, window: ProjectWindowState) -> some View {
        view
            .environment(settings)
            .environment(LimpidDragState())
            .environment(window)
            .environment(\.locale, Locale(identifier: "en"))
    }

    private static func tab(_ item: PaneStripModel.Item) -> some View {
        PaneStripTab(item: item, onActivate: {}, onClose: {}, onRename: { _ in }, onEditingChanged: { _ in })
    }

    /// The frames the tabs land on in a strip `width` wide, in its space:
    /// the terminal tabs in order, then the review's when `window` has one.
    private static func frames(
        of items: [PaneStripModel.Item],
        width: CGFloat,
        selected: PaneStripSelectedTab?,
        settings: SettingsStore,
        window: ProjectWindowState
    ) async throws -> [CGRect] {
        let strip = Self.hosted(items, width: width, selected: selected, settings: settings, window: window)
        defer { strip.window.close() }
        return try #require(await strip.settledFrames())
    }

    /// Hosts a strip `width` wide in a window, with `selected` picked: the
    /// selection can be changed after, and the tabs' frames and the
    /// overflow are read from it.
    private static func hosted(
        _ items: [PaneStripModel.Item],
        width: CGFloat,
        selected: PaneStripSelectedTab?,
        settings: SettingsStore,
        window: ProjectWindowState
    ) -> HostedStrip {
        let recorder = TabFrames()
        let selection = StripSelection(selected)
        let view = environment(
            StripHost(items: items, showsReview: window.review != nil, selection: selection, recorder: recorder)
                .frame(width: width, height: LimpidLayout.Supervision.paneStripHeight),
            settings: settings,
            window: window
        )
        let (nsWindow, host) = hostedInWindow(view, width: width, height: 60)
        return HostedStrip(
            window: nsWindow,
            host: host,
            selection: selection,
            recorder: recorder,
            count: items.count + (window.review == nil ? 0 : 1)
        )
    }

    /// What one tab asks of the strip: its width with its whole title, and
    /// with none. Offered no width (`fixedSize`) for the first, since a
    /// title offered more than it needs would take up to its maximum; and
    /// offered zero for the second.
    private static func measure(_ view: some View, settings: SettingsStore, window: ProjectWindowState) -> PaneStripTabWidths.Tab {
        let height = LimpidLayout.Supervision.paneStripHeight
        let ideal = NSHostingController(rootView: environment(view.fixedSize(), settings: settings, window: window))
            .sizeThatFits(in: CGSize(width: 2000, height: height)).width
        let bare = NSHostingController(rootView: environment(view, settings: settings, window: window))
            .sizeThatFits(in: CGSize(width: 0, height: height)).width
        return PaneStripTabWidths.Tab(ideal: ideal, bare: bare)
    }

    /// Each tab's measure, in the order `frames(of:)` reports them.
    private static func measures(
        of items: [PaneStripModel.Item],
        settings: SettingsStore,
        window: ProjectWindowState
    ) -> [PaneStripTabWidths.Tab] {
        var measures = items.map { measure(tab($0), settings: settings, window: window) }
        if window.review != nil {
            measures.append(measure(ReviewStripTab(), settings: settings, window: window))
        }
        return measures
    }

    /// A shell, Claude, and the review, short of room:
    /// every tab is drawn whole inside the strip, side by side, each
    /// narrower than its whole title would make it and no narrower than its
    /// minimum. The title is cut inside the tab, not by the strip's edge or
    /// the next tab.
    @Test(arguments: [CGFloat(420), 500, 600])
    func shortOfRoom_everyTabIsWholeInsideTheStrip(width: CGFloat) async throws {
        try await withTempDir { directory in
            let settings = SettingsStore(directory: directory)
            let window = try Self.windowWithReview()
            let items = Self.items(Self.longTitles, selected: 1)
            let frames = try await Self.frames(
                of: items,
                width: width,
                selected: .terminal(items[1].id),
                settings: settings,
                window: window
            )
            let measures = Self.measures(of: items, settings: settings, window: window)
            #expect(frames.count == 3)
            for frame in frames {
                #expect(frame.minX >= -0.5, "\(frame)")
                #expect(frame.maxX <= width + 0.5, "\(frame) in \(width)")
            }
            for (left, right) in zip(frames, frames.dropFirst()) {
                #expect(left.maxX <= right.minX + 0.5, "\(left) overlaps \(right)")
            }
            for (index, (measure, frame)) in zip(measures, frames).enumerated() {
                let minimum = measure.minimum(titleMinimum: LimpidLayout.Supervision.paneStripTitleMinWidth)
                #expect(frame.width < measure.ideal, "tab \(index) was not cut")
                #expect(frame.width >= minimum - 0.5, "tab \(index) below its minimum")
            }
        }
    }

    /// An agent's state lies on its badge's corner: the tab is as wide with
    /// it as at rest, so neither the tab nor its title moves as the agent
    /// starts, waits, and stops.
    @Test func anAgentsState_takesNoWidth() throws {
        try withTempDir { directory in
            let settings = SettingsStore(directory: directory)
            let window = ProjectWindowState(selection: WindowSelection())
            func item(_ glyph: SessionRowFact.Glyph?) -> PaneStripModel.Item {
                PaneStripModel.Item(
                    id: UUID(), title: "claude", paletteIndex: nil, isActive: true, agent: .claude,
                    stateGlyph: glyph, hasUnread: false, isInTmux: false, failedExitCode: nil
                )
            }
            let atRest = Self.measure(Self.tab(item(nil)), settings: settings, window: window)
            for glyph in [SessionRowFact.Glyph.running, .needsAnswer, .needsApproval, .stopped] {
                let shown = Self.measure(Self.tab(item(glyph)), settings: settings, window: window)
                #expect(shown == atRest, "\(glyph)")
            }
        }
    }

    /// With room, each tab, the review's too, is as wide as its whole title.
    @Test func withRoom_eachTabTakesItsWholeTitle() async throws {
        try await withTempDir { directory in
            let settings = SettingsStore(directory: directory)
            let window = try Self.windowWithReview()
            let items = Self.items(["zsh", "web", "build"], selected: 0)
            let frames = try await Self.frames(of: items, width: 1200, selected: .terminal(items[0].id), settings: settings, window: window)
            for (index, (measure, frame)) in zip(Self.measures(of: items, settings: settings, window: window), frames).enumerated() {
                // Within a point: the window rounds frames to its pixels.
                #expect(abs(frame.width - measure.ideal) <= 1, "tab \(index)")
            }
        }
    }

    /// Eight tabs in a narrow strip: each keeps its own minimum (its width
    /// without a title, and the least of a title), and the strip scrolls,
    /// rather than squeezing the titles away.
    @Test func manyTabsInANarrowStrip_keepTheirMinimums_andScroll() async throws {
        try await withTempDir { directory in
            let settings = SettingsStore(directory: directory)
            let window = ProjectWindowState(selection: WindowSelection())
            let items = Self.items((0..<8).map { "a-long-tab-title-number-\($0)" }, selected: 0)
            let frames = try await Self.frames(of: items, width: 400, selected: .terminal(items[0].id), settings: settings, window: window)
            let measures = Self.measures(of: items, settings: settings, window: window)
            for (index, (measure, frame)) in zip(measures, frames).enumerated() {
                let minimum = measure.minimum(titleMinimum: LimpidLayout.Supervision.paneStripTitleMinWidth)
                #expect(abs(frame.width - minimum) <= 1, "tab \(index): \(frame.width) against \(minimum)")
            }
            for (left, right) in zip(frames, frames.dropFirst()) {
                #expect(left.maxX <= right.minX + 0.5)
            }
            #expect((frames.last?.maxX ?? 0) > 400)
        }
    }

    /// The selected tab is in view once the strip has settled, though the
    /// strip's first layout, before its width is known, put it elsewhere:
    /// a terminal tab in the middle of eight, and the review's in front
    /// after eight.
    @Test(arguments: [false, true])
    func theSelectedTab_isInView_afterTheStripSettles(reviewInFront: Bool) async throws {
        try await withTempDir { directory in
            let settings = SettingsStore(directory: directory)
            let window = reviewInFront ? try Self.windowWithReview() : ProjectWindowState(selection: WindowSelection())
            let middle = 4
            let items = Self.items((0..<8).map { "a-long-tab-title-number-\($0)" }, selected: reviewInFront ? nil : middle)
            let selected: PaneStripSelectedTab = reviewInFront ? .review : .terminal(items[middle].id)
            let width: CGFloat = 400
            let frames = try await Self.frames(of: items, width: width, selected: selected, settings: settings, window: window)
            let frame = try #require(reviewInFront ? frames.last : frames[middle])
            #expect(frame.minX >= -0.5, "\(frame)")
            #expect(frame.maxX <= width + 0.5, "\(frame) in \(width)")
        }
    }

    /// With the strip at its start and more tabs than fit, picking a tab
    /// already in view clear of the fade, past the strip's middle, leaves
    /// the strip where it is. The first tab stays whole at the strip's edge, and the
    /// strip says nothing continues before it, so its start is not faded.
    /// Centering the tab, as the strip once did, moved the strip in and cut
    /// the first tab under the leading fade.
    @Test func aTabInView_isPicked_andTheStripStaysAtItsStart() async throws {
        try await withTempDir { directory in
            let settings = SettingsStore(directory: directory)
            let window = ProjectWindowState(selection: WindowSelection())
            let items = Self.items((0..<8).map { "a-long-tab-title-number-\($0)" }, selected: 0)
            let width: CGFloat = 600
            let strip = Self.hosted(items, width: width, selected: .terminal(items[0].id), settings: settings, window: window)
            defer { strip.window.close() }
            let before = try #require(await strip.settledFrames())
            // The tab picked lies past the strip's middle and clear of the
            // trailing fade, so only a centering scroll would move.
            let picked = try #require(before.lastIndex {
                $0.maxX <= width - LimpidLayout.Supervision.paneStripEdgeFadeWidth && $0.midX > width / 2
            })
            #expect(strip.recorder.overflow == PaneStripOverflow(hasLeading: false, hasTrailing: true))

            strip.selection.selected = .terminal(items[picked].id)
            let after = try #require(await strip.settledFrames())
            #expect(abs(after[0].minX) <= 0.5, "\(after[0])")
            #expect(after[picked] == before[picked])
            #expect(strip.recorder.overflow == PaneStripOverflow(hasLeading: false, hasTrailing: true))
        }
    }

    /// A tab picked past the trailing edge is brought in clear of the fade
    /// there, not left under it; picking the first tab again takes the
    /// strip back to its start, where nothing is said to continue.
    @Test func aTabPastTheEdge_comesClearOfTheFade_andTheFirstTabReturnsToTheStart() async throws {
        try await withTempDir { directory in
            let settings = SettingsStore(directory: directory)
            let window = ProjectWindowState(selection: WindowSelection())
            let items = Self.items((0..<8).map { "a-long-tab-title-number-\($0)" }, selected: 0)
            let width: CGFloat = 400
            let fade = LimpidLayout.Supervision.paneStripEdgeFadeWidth
            let strip = Self.hosted(items, width: width, selected: .terminal(items[0].id), settings: settings, window: window)
            defer { strip.window.close() }
            _ = try #require(await strip.settledFrames())

            strip.selection.selected = .terminal(items[5].id)
            let scrolled = try #require(await strip.settledFrames())
            #expect(scrolled[5].minX >= fade - 0.5, "\(scrolled[5])")
            #expect(scrolled[5].maxX <= width - fade + 0.5, "\(scrolled[5]) in \(width)")
            #expect(strip.recorder.overflow == PaneStripOverflow(hasLeading: true, hasTrailing: true))

            strip.selection.selected = .terminal(items[0].id)
            let back = try #require(await strip.settledFrames())
            #expect(abs(back[0].minX) <= 0.5, "\(back[0])")
            #expect(strip.recorder.overflow == PaneStripOverflow(hasLeading: false, hasTrailing: true))
        }
    }
}

/// This holds the selection a hosted strip is handed, which a test changes.
@MainActor
@Observable
private final class StripSelection {
    var selected: PaneStripSelectedTab?

    init(_ selected: PaneStripSelectedTab?) {
        self.selected = selected
    }
}

/// This is a strip in a window (`PaneStripTabsLayoutTests.hosted`).
@MainActor
private struct HostedStrip {
    let window: NSWindow
    let host: NSView
    let selection: StripSelection
    let recorder: TabFrames
    /// This is how many tabs report a frame: the terminal tabs and the
    /// review's.
    let count: Int

    /// Returns the tabs' frames once the strip has taken the current
    /// selection and come to rest: unchanged for longer than the strip's
    /// scroll takes, so a scroll still under way, or one not yet begun, is
    /// not taken for its end. We time the rest rather than count checks,
    /// since a loaded machine stretches each check. It returns `nil` if the
    /// frames never rest.
    func settledFrames() async -> [CGRect]? {
        let clock = ContinuousClock()
        var last: [CGRect]?
        var lastChange = clock.now
        var settled: [CGRect]?
        await pollUntil(timeout: .seconds(5), interval: .milliseconds(10)) {
            host.layoutSubtreeIfNeeded()
            let frames = (0..<count).compactMap { recorder.frames[$0] }
            guard frames.count == count, recorder.appliedSelection == selection.selected else {
                lastChange = clock.now
                return false
            }
            if frames != last {
                last = frames
                lastChange = clock.now
            }
            guard clock.now - lastChange >= .milliseconds(300) else { return false }
            settled = frames
            return true
        }
        return settled
    }
}

/// This lays out the strip's tabs as `PaneStripView` puts them in its scroll
/// view, each reporting its frame in the strip's space, and reports the
/// strip's overflow as its scroll view gives it.
private struct StripHost: View {
    let items: [PaneStripModel.Item]
    let showsReview: Bool
    let selection: StripSelection
    let recorder: TabFrames
    @State private var visibleRange: ClosedRange<CGFloat>?

    var body: some View {
        PaneStripScrollingTabs(selected: selection.selected, visibleRange: $visibleRange) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                PaneStripTab(item: item, onActivate: {}, onClose: {}, onRename: { _ in }, onEditingChanged: { _ in })
                    .paneStripScrollTarget(.terminal(item.id))
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(PaneStripView.coordinateSpace)) } action: {
                        recorder.frames[index] = $0
                    }
            }
            if showsReview {
                ReviewStripTab()
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(PaneStripView.coordinateSpace)) } action: {
                        recorder.frames[items.count] = $0
                    }
            }
        }
        // We read the strip's own scroll view as the strip reads it.
        .onScrollGeometryChange(for: PaneStripOverflow.self) { geometry in
            PaneStripOverflow.of(
                offset: geometry.contentOffset.x,
                contentWidth: geometry.contentSize.width,
                visibleWidth: geometry.containerSize.width
            )
        } action: { _, overflow in
            recorder.overflow = overflow
        }
        // We note the selection the strip has been handed, so a wait for it
        // to rest begins only once the strip has seen the change.
        .onChange(of: selection.selected, initial: true) { _, selected in
            recorder.appliedSelection = selected
        }
        .coordinateSpace(.named(PaneStripView.coordinateSpace))
    }
}

@MainActor
private final class TabFrames {
    var frames: [Int: CGRect] = [:]
    var overflow: PaneStripOverflow?
    /// This is the selection the strip last saw (`StripHost`).
    var appliedSelection: PaneStripSelectedTab?
}

/// Which ends of the strip have tabs scrolled out of view, which the
/// strip fades so a cut-off tab is seen to continue.
@Suite("Pane strip overflow")
struct PaneStripOverflowTests {
    @Test func tabsThatFit_overflowNowhere() {
        #expect(PaneStripOverflow.of(offset: 0, contentWidth: 300, visibleWidth: 400) == .none)
        #expect(PaneStripOverflow.of(offset: 0, contentWidth: 400, visibleWidth: 400) == .none)
        // A hair past the edge is layout noise, not a hidden tab.
        #expect(PaneStripOverflow.of(offset: 0, contentWidth: 400.5, visibleWidth: 400) == .none)
    }

    @Test func tabsPastAnEdge_overflowThatEnd() {
        #expect(
            PaneStripOverflow.of(offset: 0, contentWidth: 600, visibleWidth: 400)
                == PaneStripOverflow(hasLeading: false, hasTrailing: true)
        )
        #expect(
            PaneStripOverflow.of(offset: 200, contentWidth: 600, visibleWidth: 400)
                == PaneStripOverflow(hasLeading: true, hasTrailing: false)
        )
        #expect(
            PaneStripOverflow.of(offset: 100, contentWidth: 600, visibleWidth: 400)
                == PaneStripOverflow(hasLeading: true, hasTrailing: true)
        )
    }

    /// A scroll view with a leading inset rests at minus the inset, before
    /// the content's start: nothing is cut there, so the start does not
    /// fade, and scrolling in by less than the inset still cuts nothing.
    @Test func atRestBeforeALeadingInset_overflowsOnlyAtTheTrailingEnd() {
        let trailingOnly = PaneStripOverflow(hasLeading: false, hasTrailing: true)
        #expect(PaneStripOverflow.of(offset: -12, contentWidth: 600, visibleWidth: 400) == trailingOnly)
        #expect(PaneStripOverflow.of(offset: -4, contentWidth: 600, visibleWidth: 400) == trailingOnly)
    }

    /// A fractional offset is what a scroll's last frame or a 2x screen's
    /// half point leaves: within the tolerance it is the start, and past it
    /// a tab is cut, at either end.
    @Test func aFractionalOffset_countsOnlyPastTheTolerance() {
        #expect(PaneStripOverflow.of(offset: 0.5, contentWidth: 600, visibleWidth: 400).hasLeading == false)
        #expect(PaneStripOverflow.of(offset: 1, contentWidth: 600, visibleWidth: 400).hasLeading == false)
        #expect(PaneStripOverflow.of(offset: 1.5, contentWidth: 600, visibleWidth: 400).hasLeading)
        #expect(PaneStripOverflow.of(offset: 199.5, contentWidth: 600, visibleWidth: 400).hasTrailing == false)
        #expect(PaneStripOverflow.of(offset: 198.5, contentWidth: 600, visibleWidth: 400).hasTrailing)
    }

    /// At the trailing end, and past it as a bounce or a trailing inset
    /// leaves it, nothing continues after the last tab.
    @Test func atTheTrailingEnd_overflowsOnlyAtTheStart() {
        let leadingOnly = PaneStripOverflow(hasLeading: true, hasTrailing: false)
        #expect(PaneStripOverflow.of(offset: 200, contentWidth: 600, visibleWidth: 400) == leadingOnly)
        #expect(PaneStripOverflow.of(offset: 212, contentWidth: 600, visibleWidth: 400) == leadingOnly)
    }

    @Test func anUnmeasuredStrip_overflowsNowhere() {
        #expect(PaneStripOverflow.of(offset: 0, contentWidth: 600, visibleWidth: 0) == .none)
    }
}
