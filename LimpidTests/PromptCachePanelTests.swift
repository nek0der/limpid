// PromptCachePanelTests.swift
// Limpid — the prompt cache panel's rules (what it says, when its commands
// may be typed, when it opens by itself, which pane it names, where its
// arrow points), its presentation's open and close timing and clock
// registry, and how key presses mark an agent's prompt as holding unsent
// input.

import AppKit
import Foundation
import Testing
@testable import Limpid

// MARK: - Rules

struct PromptCacheRulesTests {
    private let anchor = Date(timeIntervalSince1970: 3_000_000)

    private func window(tokens: Int? = 573_000) -> AgentCacheWindow {
        AgentCacheWindow(observedAt: anchor, ttlSeconds: 3600, rewriteTokens: tokens, precision: .estimated)
    }

    @Test func clockStatus_onlyForStatesThatAskForADecision() {
        #expect(PromptCacheRules.clockStatus(.hidden, isAnswered: false) == nil)
        #expect(PromptCacheRules.clockStatus(.valid, isAnswered: false) == nil)
        #expect(PromptCacheRules.clockStatus(.expiringSoon, isAnswered: false) == .expiringSoon)
        #expect(PromptCacheRules.clockStatus(.expired, isAnswered: false) == .expired)
        #expect(PromptCacheRules.clockStatus(.expired, isAnswered: true) == nil, "an answered expiry shows none")
    }

    @Test func panelContent_expiredOffersThreeAnswersAndExpiringNone() throws {
        let expired = try #require(PromptCacheRules.panelContent(
            status: .expired,
            window: window(),
            isAnswered: false,
            commandBlock: nil
        ))
        #expect(expired.isExpired)
        #expect(expired.actions == [.summarize, .newConversation, .continueAsIs])
        #expect(expired.canTypeCommands)

        let soon = try #require(PromptCacheRules.panelContent(
            status: .expiringSoon,
            window: window(),
            isAnswered: false,
            commandBlock: nil
        ))
        #expect(!soon.isExpired)
        #expect(soon.actions.isEmpty)
        #expect(!soon.canTypeCommands, "nothing to type while it only informs")
        #expect(soon.title != expired.title)

        #expect(PromptCacheRules.panelContent(
            status: .valid,
            window: window(),
            isAnswered: false,
            commandBlock: nil
        ) == nil)
        #expect(PromptCacheRules.panelContent(
            status: .expired,
            window: window(),
            isAnswered: true,
            commandBlock: nil
        ) == nil)
    }

    @Test func panelLines_sayWhenThenWhatItCosts() throws {
        let expired = try #require(PromptCacheRules.panelContent(
            status: .expired,
            window: window(),
            isAnswered: false,
            commandBlock: nil
        ))
        let expiredLines = expired.lines(now: anchor.addingTimeInterval(3600 + 56 * 60))
        #expect(expiredLines.count == 2)
        #expect(expiredLines[0].contains(PromptCacheFormatting.duration(56 * 60)))
        #expect(expiredLines[1].contains("573k"))

        let soon = try #require(PromptCacheRules.panelContent(
            status: .expiringSoon,
            window: window(tokens: nil),
            isAnswered: false,
            commandBlock: nil
        ))
        let soonLines = soon.lines(now: anchor.addingTimeInterval(3600 - 120))
        #expect(soonLines == [soon.timeLine(now: anchor.addingTimeInterval(3600 - 120))], "no size, no cost line")
        #expect(soonLines[0].contains(PromptCacheFormatting.duration(120)))
        #expect(soon.costLine == nil)
    }

    @Test func commandBlock_onlyAnEmptyPromptOfTheAgentInFrontTakesCommands() {
        let turnEnded = anchor
        func block(
            atPrompt: Bool = true,
            agentInFront: Bool = true,
            draft: Bool = false,
            lastKey: Date? = nil
        ) -> PromptCacheCommandBlock? {
            PromptCacheRules.commandBlock(
                isAtPromptInFront: atPrompt,
                isAgentInFront: agentInFront,
                hasUnsubmittedInput: draft,
                lastKeyInputAt: lastKey,
                turnEndedAt: turnEnded
            )
        }
        #expect(block() == nil)
        #expect(block(lastKey: turnEnded.addingTimeInterval(-30)) == nil, "keys from before the turn ended")
        #expect(block(atPrompt: false) == .notAtPrompt)
        #expect(block(agentInFront: false) == .notInFront)
        #expect(block(draft: true) == .unsubmittedInput)
        #expect(block(lastKey: turnEnded.addingTimeInterval(1)) == .unsubmittedInput, "a key after the turn ended")
    }

    @Test func autoOpenPlace_isTheHeaderClockWhileHeadersShow() {
        let paneID = UUID()
        let tabID = UUID()
        #expect(PromptCacheRules.autoOpenPlace(paneID: paneID, tabID: tabID, showsPaneHeader: true)
            == .paneHeader(paneID: paneID))
        #expect(PromptCacheRules.autoOpenPlace(paneID: paneID, tabID: tabID, showsPaneHeader: false)
            == .tabRow(tabID: tabID))
    }

    @Test func shouldAutoOpen_onlyWhenEveryConditionHolds() {
        func decide(
            actionable: Bool = true,
            presented: Bool = false,
            anchor: Bool = true,
            other: Bool = false,
            open: Bool = false
        ) -> Bool {
            PromptCacheRules.shouldAutoOpen(
                hasActionableExpiry: actionable,
                hasPresented: presented,
                hasAnchor: anchor,
                isAnotherPanelOpen: other,
                isPanelOpen: open
            )
        }
        #expect(decide())
        #expect(!decide(actionable: false))
        #expect(!decide(presented: true))
        #expect(!decide(anchor: false))
        #expect(!decide(other: true))
        #expect(!decide(open: true))
    }
}

// MARK: - Panel presentation

@MainActor
struct PromptCachePanelPresentationTests {
    /// Short enough that the suite spends no real time waiting; what is
    /// under test is the order of the transitions, not their durations.
    private static let delay = Duration.milliseconds(20)

    private let place = PromptCacheClockPlace.tabRow(tabID: UUID())
    private let target = PromptCacheTarget(runtimeID: "claude:run", paneID: UUID())
    private let frame = CGRect(x: 100, y: 40, width: 16, height: 16)
    /// The clock the pointer is on in most tests.
    private let clock = UUID()

    private func makePresentation() -> PromptCachePanelPresentation {
        let presentation = PromptCachePanelPresentation(openDelay: Self.delay, dismissDelay: Self.delay)
        presentation.clockMoved(place: place, instance: clock, anchor: frame)
        return presentation
    }

    /// Outwaits a pending open or dismiss and the main-actor turn after it,
    /// with a generous margin so a loaded machine does not turn it flaky.
    private func settle() async throws {
        try await Task.sleep(for: Self.delay * 10)
        await Task.yield()
    }

    @Test func open_needsItsClockOnScreen() {
        let presentation = PromptCachePanelPresentation()
        #expect(!presentation.open(target: target, place: place, trigger: .accessibility))
        presentation.clockMoved(place: place, instance: UUID(), anchor: frame)
        #expect(presentation.open(target: target, place: place, trigger: .accessibility))
        #expect(presentation.request?.anchor == frame)
        #expect(presentation.isOpen(place: place))
    }

    @Test func hover_opensAfterRestingAndClosesAfterLeaving() async throws {
        let presentation = makePresentation()
        presentation.clockEntered(place: place, instance: clock, anchor: frame, target: target)
        #expect(presentation.request == nil, "not before the pointer has rested")
        try await settle()
        #expect(presentation.request?.trigger == .pointer)

        presentation.clockExited(place: place, instance: clock)
        try await settle()
        #expect(presentation.request == nil)
    }

    @Test func hover_passingOverTheClockOpensNothing() async throws {
        let presentation = makePresentation()
        presentation.clockEntered(place: place, instance: clock, anchor: frame, target: target)
        presentation.clockExited(place: place, instance: clock)
        try await settle()
        #expect(presentation.request == nil)
    }

    @Test func panelHover_keepsItOpenAcrossTheGap() async throws {
        let presentation = makePresentation()
        presentation.clockEntered(place: place, instance: clock, anchor: frame, target: target)
        presentation.clockClicked(place: place, instance: clock, anchor: frame, target: target)
        presentation.clockExited(place: place, instance: clock)
        presentation.panelHoverChanged(true)
        try await settle()
        #expect(presentation.request != nil)

        presentation.panelHoverChanged(false)
        try await settle()
        #expect(presentation.request == nil)
    }

    @Test func click_withNoEnterReported_staysUntilARealDeparture() async throws {
        let presentation = makePresentation()
        presentation.clockClicked(place: place, instance: clock, anchor: frame, target: target)
        // A clock whose arrival was never reported: neither a stray exit nor
        // the panel losing a pointer it never had closes the panel.
        presentation.clockExited(place: place, instance: clock)
        presentation.panelHoverChanged(false)
        try await settle()
        #expect(presentation.request != nil)

        // Once the pointer is seen arriving, leaving closes it.
        presentation.clockEntered(place: place, instance: clock, anchor: frame, target: target)
        presentation.clockExited(place: place, instance: clock)
        try await settle()
        #expect(presentation.request == nil)
    }

    @Test func click_underARestingPointer_staysOpen() async throws {
        let presentation = makePresentation()
        presentation.clockEntered(place: place, instance: clock, anchor: frame, target: target)
        presentation.clockClicked(place: place, instance: clock, anchor: frame, target: target)
        try await settle()
        #expect(presentation.request != nil, "the pointer is still on the clock")
    }

    @Test func hover_handsOverToTheClockThatReplacesIt() async throws {
        let presentation = makePresentation()
        let replacement = UUID()
        presentation.clockEntered(place: place, instance: clock, anchor: frame, target: target)
        try await settle()
        #expect(presentation.request != nil)

        // A row swapping layouts: its new clock reports the pointer before
        // the old one reports it leaving.
        presentation.clockEntered(place: place, instance: replacement, anchor: frame, target: target)
        presentation.clockExited(place: place, instance: clock)
        presentation.clockDisappeared(place: place, instance: clock)
        try await settle()
        #expect(presentation.request?.clock.instance == replacement)

        presentation.clockExited(place: place, instance: replacement)
        try await settle()
        #expect(presentation.request == nil)
    }

    @Test func click_opensAtOnceAndAgainKeepsTheSamePanel() throws {
        let presentation = makePresentation()
        presentation.clockClicked(place: place, instance: clock, anchor: frame, target: target)
        let first = try #require(presentation.request)
        presentation.clockClicked(place: place, instance: clock, anchor: frame, target: target)
        #expect(presentation.request?.id == first.id)
    }

    @Test func automaticPanel_waitsForThePointerBeforeClosingOnLeave() async throws {
        let presentation = makePresentation()
        #expect(presentation.open(target: target, place: place, trigger: .automatic))
        presentation.panelHoverChanged(false)
        try await settle()
        #expect(presentation.request != nil, "the pointer was never there to leave")

        presentation.panelHoverChanged(true)
        presentation.panelHoverChanged(false)
        try await settle()
        #expect(presentation.request == nil)
    }

    @Test func keys_closeThePanelAndOnlyEscapeIsSpent() {
        let presentation = makePresentation()
        #expect(!presentation.keyPressed(isEscape: true), "nothing open, nothing spent")

        presentation.open(target: target, place: place, trigger: .automatic)
        #expect(presentation.keyPressed(isEscape: true))
        #expect(presentation.request == nil)

        presentation.open(target: target, place: place, trigger: .automatic)
        #expect(!presentation.keyPressed(isEscape: false), "a typed key still reaches the prompt")
        #expect(presentation.request == nil)
    }

    @Test func click_outsideClosesAndOnThePanelDoesNot() {
        let presentation = makePresentation()
        presentation.open(target: target, place: place, trigger: .automatic)
        presentation.panelHoverChanged(true)
        presentation.pointerPressed()
        #expect(presentation.request != nil)

        presentation.panelHoverChanged(false)
        presentation.pointerPressed()
        #expect(presentation.request == nil)
    }

    @Test func clockDisappearing_closesItsPanelUnlessAReplacementTookOver() async throws {
        let presentation = PromptCachePanelPresentation()
        let old = UUID()
        let new = UUID()
        presentation.clockMoved(place: place, instance: old, anchor: frame)
        presentation.open(target: target, place: place, trigger: .accessibility)

        // A row swapping layouts reports its new clock before the old one
        // leaves.
        let moved = frame.offsetBy(dx: 30, dy: 0)
        presentation.clockMoved(place: place, instance: new, anchor: moved)
        presentation.clockDisappeared(place: place, instance: old)
        #expect(presentation.request?.anchor == moved)
        #expect(presentation.anchor(for: place) == moved)

        presentation.clockDisappeared(place: place, instance: new)
        try await settle()
        #expect(presentation.request == nil)
        #expect(presentation.anchor(for: place) == nil)
    }

    @Test func clockDisappearing_beforeItsReplacementReports_keepsThePanel() async throws {
        let presentation = PromptCachePanelPresentation()
        let old = UUID()
        presentation.clockMoved(place: place, instance: old, anchor: frame)
        presentation.open(target: target, place: place, trigger: .accessibility)

        // The other order: the old clock leaves first, and the new one
        // reports within the same turn.
        let moved = frame.offsetBy(dx: 0, dy: 12)
        presentation.clockDisappeared(place: place, instance: old)
        presentation.clockMoved(place: place, instance: UUID(), anchor: moved)
        try await settle()
        #expect(presentation.request?.anchor == moved)
    }

    @Test func pointer_opensBelowTheClockItIsOn_whateverAnotherClockOfThePlaceReported() async throws {
        let presentation = PromptCachePanelPresentation(openDelay: Self.delay, dismissDelay: Self.delay)
        // Two clocks for one place, as two windows on one session draw, with
        // the other one reporting last.
        let here = CGRect(x: 300, y: 60, width: 16, height: 16)
        let elsewhere = CGRect(x: 900, y: 500, width: 16, height: 16)
        let other = UUID()
        presentation.clockMoved(place: place, instance: clock, anchor: here)
        presentation.clockMoved(place: place, instance: other, anchor: elsewhere)

        presentation.clockClicked(place: place, instance: clock, anchor: here, target: target)
        #expect(presentation.request?.anchor == here)

        // The other clock moving does not drag the panel along.
        presentation.clockMoved(place: place, instance: other, anchor: elsewhere.offsetBy(dx: 5, dy: 0))
        #expect(presentation.request?.anchor == here)
        presentation.close()

        presentation.clockEntered(place: place, instance: clock, anchor: here, target: target)
        try await settle()
        #expect(presentation.request?.anchor == here)
    }

    @Test func pointer_opensEvenBeforeTheClocksFrameWasRecorded() {
        let presentation = PromptCachePanelPresentation()
        presentation.clockClicked(place: place, instance: clock, anchor: frame, target: target)
        #expect(presentation.request?.anchor == frame)
    }

    @Test func clockDisappearing_movesThePanelToAnotherClockOfThePlace() {
        let presentation = PromptCachePanelPresentation()
        let elsewhere = frame.offsetBy(dx: 0, dy: 200)
        presentation.clockMoved(place: place, instance: UUID(), anchor: elsewhere)
        presentation.clockClicked(place: place, instance: clock, anchor: frame, target: target)

        presentation.clockDisappeared(place: place, instance: clock)
        #expect(presentation.request?.anchor == elsewhere)
    }
}

// MARK: - Unsent input

struct PromptInputEffectTests {
    private func effect(
        _ key: NamedKey?,
        _ characters: String?,
        _ modifiers: NSEvent.ModifierFlags = []
    ) -> SurfaceView.PromptInputEffect {
        SurfaceView.promptInputEffect(key: key, charactersIgnoringModifiers: characters, modifiers: modifiers)
    }

    @Test func plainReturnAndControlC_submit() {
        #expect(effect(.return, "\r") == .submit)
        #expect(effect(nil, "c", .control) == .submit)
    }

    @Test func lineBreaksAndEverythingElse_leaveADraft() {
        #expect(effect(.return, "\r", .shift) == .draft, "Shift-Return inserts a line break")
        #expect(effect(.return, "\r", .option) == .draft, "so does Option-Return")
        #expect(effect(nil, "a") == .draft)
        #expect(effect(.escape, "\u{1b}") == .draft, "an open picker may still be there")
        #expect(effect(.up, nil) == .draft, "history recall fills the prompt")
        #expect(effect(nil, "d", .control) == .draft)
    }

    @Test func commandShortcuts_doNotReachThePromptExceptPaste() {
        #expect(effect(nil, "k", .command) == .none)
        #expect(effect(nil, "j", .command) == .none)
        #expect(effect(nil, "v", .command) == .draft)
    }
}

// MARK: - Which pane

struct PromptCacheArrowTests {
    private let width: CGFloat = 300
    private let height: CGFloat = 140
    private let inset: CGFloat = 30

    private func arrow(clock: CGRect, panelAt origin: CGPoint) -> PromptCachePanelPresentation.ArrowPlacement? {
        PromptCachePanelPresentation.arrowPlacement(
            anchor: clock,
            panelOrigin: origin,
            panelSize: CGSize(width: width, height: height),
            minimumInset: inset
        )
    }

    @Test func belowTheClock_pointsUpAtItsCenter() {
        let clock = CGRect(x: 400, y: 40, width: 16, height: 16)
        let placement = arrow(clock: clock, panelAt: CGPoint(x: 258, y: 66))
        #expect(placement == .init(edge: .top, x: 150))
    }

    @Test func aboveTheClock_pointsDown() {
        let clock = CGRect(x: 400, y: 600, width: 16, height: 16)
        let placement = arrow(clock: clock, panelAt: CGPoint(x: 258, y: 600 - 13 - height))
        #expect(placement?.edge == .bottom)
        #expect(placement?.x == 150)
    }

    @Test func panelClampedToTheWindow_stillPointsAtTheClock() {
        // A clock near the window's right edge: the panel slid left, so the
        // arrow moves right within it.
        let clock = CGRect(x: 772, y: 40, width: 16, height: 16)
        let placement = arrow(clock: clock, panelAt: CGPoint(x: 492, y: 66))
        // The clock's center is 288 into the panel, past the trailing inset.
        #expect(placement == .init(edge: .top, x: width - inset), "kept clear of the corner")
    }

    @Test func clockPastTheLeadingCorner_keepsTheArrowOffTheRounding() {
        let clock = CGRect(x: 0, y: 40, width: 16, height: 16)
        #expect(arrow(clock: clock, panelAt: CGPoint(x: 8, y: 66))?.x == inset)
    }

    @Test func panelOverTheClock_hasNoArrow() {
        let clock = CGRect(x: 400, y: 100, width: 16, height: 16)
        #expect(arrow(clock: clock, panelAt: CGPoint(x: 258, y: 50)) == nil)
    }

    @Test func panelNarrowerThanBothInsets_centersTheArrow() {
        let placement = PromptCachePanelPresentation.arrowPlacement(
            anchor: CGRect(x: 0, y: 0, width: 16, height: 16),
            panelOrigin: CGPoint(x: 0, y: 30),
            panelSize: CGSize(width: 40, height: 50),
            minimumInset: 30
        )
        #expect(placement?.x == 20)
    }
}

@MainActor
struct PromptCachePaneLineTests {
    @Test func paneLine_isTheNameThenTheDirectory() {
        let withDetail = PaneHeaderLabel(name: "review", detail: "~/work/tamurakanto", isAgent: true, agentName: "Claude")
        #expect(PromptCacheRules.paneLine(for: withDetail) == "review · ~/work/tamurakanto")
        let bare = PaneHeaderLabel(name: "Terminal", detail: nil, isAgent: false, agentName: nil)
        #expect(PromptCacheRules.paneLine(for: bare) == "Terminal")
    }

    @Test func paneLine_namesThePaneAsItsHeaderDoes() {
        let (session, tab, paneID) = WindowSessionFixture.withLooseTab()
        let attention = AttentionState()
        let target = PromptCacheTarget(runtimeID: "claude:run", paneID: paneID)
        session.update(tab.id) { $0.pwd = NSHomeDirectory() + "/work/tamurakanto" }
        var badge = AgentBadge(state: .finished, updatedAt: Date())
        badge.conversationID = "c"
        badge.providerSessionTitle = "Fix the parser"
        attention.replaceRuntimes([AgentRuntimePresentation(
            kind: .claude, runID: "run", revision: 1, badge: badge,
            paneIDs: [paneID], tmuxLocations: [:], stateEpisodeToken: "1"
        )], kind: .claude)

        // The same label the header resolves, whichever clock opened it.
        let header = attention.paneHeaderLabel(paneID: paneID, in: session)
        #expect(attention.promptCachePaneLine(for: target, in: session) == PromptCacheRules.paneLine(for: header))
        #expect(attention.promptCachePaneLine(for: target, in: session).hasSuffix(" · ~/work/tamurakanto"))

        // A name the user gave the pane wins over the agent's title.
        session.renamePane(paneID, to: "review")
        #expect(attention.promptCachePaneLine(for: target, in: session) == "review · ~/work/tamurakanto")
    }
}

// MARK: - Review fixes

@MainActor
struct PromptCacheOpeningTests {
    private static let delay = Duration.milliseconds(20)
    private let target = PromptCacheTarget(runtimeID: "claude:run", paneID: UUID())
    private let frame = CGRect(x: 100, y: 40, width: 16, height: 16)

    private func settle() async throws {
        try await Task.sleep(for: Self.delay * 10)
        await Task.yield()
    }

    @Test func hover_opensNothingWhileAnotherPanelIsUp_butAClickStillDoes() async throws {
        let presentation = PromptCachePanelPresentation(openDelay: Self.delay, dismissDelay: Self.delay)
        let place = PromptCacheClockPlace.tabRow(tabID: UUID())
        let clock = UUID()
        presentation.clockMoved(place: place, instance: clock, anchor: frame)
        presentation.isPointerOpenSuppressed = true

        presentation.clockEntered(place: place, instance: clock, anchor: frame, target: target)
        try await settle()
        #expect(presentation.request == nil, "the pointer is on its way to the other panel")

        presentation.clockClicked(place: place, instance: clock, anchor: frame, target: target)
        #expect(presentation.request != nil, "a click asks")
    }

    @Test func hover_armedBeforeAnotherPanelOpens_opensNothing() async throws {
        let presentation = PromptCachePanelPresentation(openDelay: Self.delay, dismissDelay: Self.delay)
        let place = PromptCacheClockPlace.tabRow(tabID: UUID())
        let clock = UUID()
        presentation.clockMoved(place: place, instance: clock, anchor: frame)
        presentation.clockEntered(place: place, instance: clock, anchor: frame, target: target)
        presentation.isPointerOpenSuppressed = true
        try await settle()
        #expect(presentation.request == nil)
    }

    @Test func open_fallsBackToTheNextPlaceWithAClock() {
        let presentation = PromptCachePanelPresentation()
        let paneID = UUID()
        let tabID = UUID()
        // The header's narrowest form draws no clock; the tab row's is on
        // screen.
        presentation.clockMoved(place: .tabRow(tabID: tabID), instance: UUID(), anchor: frame)
        #expect(presentation.open(
            target: target,
            places: [.paneHeader(paneID: paneID), .tabRow(tabID: tabID)],
            trigger: .accessibility
        ))
        #expect(presentation.request?.place == .tabRow(tabID: tabID))
        presentation.close()
        #expect(!presentation.open(target: target, places: [.paneHeader(paneID: paneID)], trigger: .accessibility))
    }

    @Test func clockSpokenStatus_namesTheState() {
        let window = AgentCacheWindow(observedAt: Date(), ttlSeconds: 3600, rewriteTokens: nil, precision: .estimated)
        let expired = PromptCacheMark(status: .expired, window: window, target: target)
        let soon = PromptCacheMark(status: .expiringSoon, window: window, target: target)
        #expect(!expired.spokenStatus.isEmpty)
        #expect(expired.spokenStatus != soon.spokenStatus)
    }
}

struct PromptCacheReasonTests {
    @Test func eachBlockSaysSomethingDifferent() {
        let reasons = [
            PromptCacheCommandBlock.notAtPrompt,
            .notInFront,
            .unsubmittedInput
        ].map(\.reason)
        #expect(Set(reasons).count == 3, "a shell in front is not the agent being busy")
    }

    @Test func unsentInput_pointsAtWhatStillWorks() {
        // The panel cannot type here until the next turn, so the advice is
        // to type the command, not to clear the prompt.
        #expect(PromptCacheCommandBlock.unsubmittedInput.reason.contains("/compact"))
    }
}

struct PromptCacheHeaderFitTests {
    @Test func inlineRename_keepsAUsableFieldBesideTheClock() {
        let plain = PaneHeaderMetrics.inlineRenameMinimumWidth(showsPromptCacheClock: false)
        let withClock = PaneHeaderMetrics.inlineRenameMinimumWidth(showsPromptCacheClock: true)
        #expect(plain == PaneHeaderMetrics.inlineRenameMinimumWidth)
        #expect(withClock - plain == PaneHeaderMetrics.itemSpacing + PaneHeaderMetrics.markSlot)
        // Everything but the field, with the clock, still leaves the field
        // its minimum.
        let fixedParts = PaneHeaderMetrics.minimumWidth
            + PaneHeaderMetrics.itemSpacing + PaneHeaderMetrics.markSlot // state mark
            + PaneHeaderMetrics.itemSpacing + PaneHeaderMetrics.markSlot // clock
            + PaneHeaderMetrics.itemSpacing // glyph to field
        #expect(withClock - fixedParts >= PaneHeaderMetrics.inlineRenameFieldMinimumWidth)
    }

    @Test func inlineRename_endsWhenTheHeaderNarrowsBelowAUsableField() {
        let threshold = PaneHeaderMetrics.inlineRenameMinimumWidth(showsPromptCacheClock: true)
        #expect(PaneHeaderRules.shouldEndInlineRename(isEditing: true, headerWidth: threshold - 1, threshold: threshold))
        #expect(!PaneHeaderRules.shouldEndInlineRename(isEditing: true, headerWidth: threshold, threshold: threshold))
        #expect(!PaneHeaderRules.shouldEndInlineRename(isEditing: false, headerWidth: 40, threshold: threshold))
        #expect(
            !PaneHeaderRules.shouldEndInlineRename(isEditing: true, headerWidth: 0, threshold: threshold),
            "a header not measured yet is not narrow"
        )
    }
}

struct PromptCacheAnchorTests {
    private let window = CGRect(x: 0, y: 0, width: 1200, height: 800)

    @Test func anchor_countsOnlyInsideTheWindow() {
        #expect(PromptCacheRules.isAnchorVisible(CGRect(x: 40, y: 80, width: 16, height: 16), in: window))
        #expect(!PromptCacheRules.isAnchorVisible(CGRect(x: 40, y: -300, width: 16, height: 16), in: window))
        #expect(!PromptCacheRules.isAnchorVisible(CGRect(x: 40, y: 900, width: 16, height: 16), in: window))
        #expect(!PromptCacheRules.isAnchorVisible(.zero, in: window))
        #expect(!PromptCacheRules.isAnchorVisible(nil, in: window))
    }

    @Test func placement_staysInsideTheWindowForAnAnchorAboveIt() {
        let origin = PaneRenamePresentation.panelOrigin(
            anchor: CGRect(x: 100, y: -400, width: 300, height: 16),
            panelSize: CGSize(width: 300, height: 140),
            container: window.size,
            margin: 8,
            gap: 13
        )
        #expect(origin.y == 8)
    }

    @Test func placement_staysInsideTheWindowForAnAnchorBelowIt() {
        // Below the window, the "above" branch would leave it off the bottom.
        let origin = PaneRenamePresentation.panelOrigin(
            anchor: CGRect(x: 100, y: 1400, width: 300, height: 16),
            panelSize: CGSize(width: 300, height: 140),
            container: window.size,
            margin: 8,
            gap: 13
        )
        let lowest: CGFloat = window.height - 140 - 8
        #expect(abs(origin.y - lowest) < 0.001)
    }
}

/// The clipboard read is how every paste reaches the terminal, so marking
/// there is what keeps review inserts, ⌘V, Edit > Paste and a middle click
/// from leaving unsent text the panel would type after.
@MainActor
struct PromptCacheClipboardTests {
    @Test(.tags(.ffi), .enabled("libghostty is unavailable") { await QuickTerminalTests.isGhosttyAvailable() })
    func clipboardRead_marksUnsentInput_butAListingDoesNot() throws {
        let ghosttyApp = try #require(GhosttyApp.placeholder.target)
        let view = PaneHostRepresentable.makeSurfaceView(ghosttyApp: ghosttyApp, environment: [:])
        view.noteClipboardRead(isListing: true)
        #expect(!view.hasUnsubmittedInput)
        #expect(view.lastKeyInputAt == nil)

        view.noteClipboardRead(isListing: false)
        #expect(view.hasUnsubmittedInput)
        #expect(view.lastKeyInputAt != nil)
    }
}
