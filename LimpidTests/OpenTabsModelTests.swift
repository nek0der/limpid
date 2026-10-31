// OpenTabsModelTests.swift
// Limpid — Open Tabs: the session's tabs in the strip's order, their lines, and the search that narrows them.

import Foundation
import Testing
@testable import Limpid

@MainActor
struct OpenTabsModelTests {
    private static let english = Locale(identifier: "en")

    private static func input(
        id: UUID = UUID(),
        title: String,
        agent: AgentKind? = nil,
        paneGlyphs: [SessionRowFact.Glyph] = [],
        paneItems: [AttentionItem] = [],
        paneCount: Int = 1
    ) -> PaneStripModel.ItemInput {
        PaneStripModel.ItemInput(
            id: id,
            title: title,
            agents: agent.map { [PaneStripModel.AgentInput(kind: $0)] } ?? [],
            paneGlyphs: paneGlyphs,
            paneItems: paneItems,
            hasUnread: false,
            isInTmux: false,
            exitCodes: [],
            paneCount: paneCount
        )
    }

    private static func model(
        _ inputs: [PaneStripModel.ItemInput],
        active: UUID? = nil,
        reviewTab: PaneStripModel.ReviewTab = .none,
        query: String = ""
    ) -> OpenTabsModel {
        OpenTabsModel(
            strip: PaneStripModel(items: inputs, activeTabID: active, reviewTab: reviewTab),
            reviewTitle: reviewTab == .none ? nil : "T12",
            query: query,
            locale: english
        )
    }

    @Test func theRows_followTheStrip_withTheReviewLast_andTheShownTabChecked() {
        let first = UUID()
        let second = UUID()
        let model = Self.model(
            [Self.input(id: first, title: "Add the tab list"), Self.input(id: second, title: "zsh")],
            active: second,
            reviewTab: .behind
        )
        #expect(model.terminalRows.map(\.id) == [.terminal(first), .terminal(second)])
        #expect(model.terminalRows.map(\.isCurrent) == [false, true])
        #expect(model.reviewRow?.title == "T12")
        #expect(model.reviewRow?.isCurrent == false)
        #expect(model.rows.map(\.id) == [.terminal(first), .terminal(second), .review])
    }

    /// The review in front is the tab the window shows, so its row is the
    /// checked one and no terminal tab's is.
    @Test func aReviewInFront_isTheCheckedRow() {
        let tab = UUID()
        let model = Self.model([Self.input(id: tab, title: "zsh")], active: tab, reviewTab: .inFront)
        #expect(model.terminalRows.map(\.isCurrent) == [false])
        #expect(model.reviewRow?.isCurrent == true)
    }

    @Test func noReview_meansNoReviewRow() {
        #expect(Self.model([Self.input(title: "zsh")]).reviewRow == nil)
    }

    @Test func aRowsLine_saysWhoRunsInIt_itsState_andTheSplitTabsPanes() {
        let pane = UUID()
        let waiting = AttentionItem.testList([.approval(ApprovalFact.test())], pane: pane)
        let model = Self.model([
            Self.input(title: "zsh"),
            Self.input(title: "Two shells", paneCount: 2),
            Self.input(title: "Fix the tests", agent: .claude, paneGlyphs: [.needsApproval], paneItems: waiting)
        ])
        #expect(model.terminalRows.map(\.detail) == ["Shell", "Shell · 2 panes", "Claude · Needs approval"])
    }

    @Test func theLine_isInThePersonsLanguage() {
        let item = PaneStripModel(
            items: [Self.input(title: "zsh", paneCount: 3)],
            activeTabID: nil,
            reviewTab: .none
        ).items[0]
        #expect(OpenTabsModel.detail(of: item, locale: Locale(identifier: "ja")) == "シェル · 3 ペイン")
    }

    /// VoiceOver hears what the strip's tab says, then the panes the line
    /// shows; the review's row, its scope and that it is the review.
    @Test func aRowsSpokenLabel_isTheTabs_withTheSplitTabsPanes() {
        let model = Self.model([Self.input(title: "Two shells", paneCount: 2)], reviewTab: .behind)
        let item = model.terminalRows[0].item
        let tabs = item.map { $0.spokenLabel(locale: Self.english) } ?? ""
        #expect(model.terminalRows[0].spokenLabel.hasPrefix(tabs))
        #expect(model.terminalRows[0].spokenLabel.hasSuffix("2 panes"))
        #expect(model.reviewRow?.spokenLabel.hasPrefix("T12") == true)
        #expect(model.reviewRow?.spokenLabel.hasSuffix("Review") == true)
    }

    /// Every word typed must be in the title or the line, in any case: a
    /// state finds the tabs in it, and two words narrow further than one.
    @Test func theSearch_keepsTheRowsWithEveryWord_inTheirTitleOrLine() {
        let pane = UUID()
        let waiting = AttentionItem.testList([.approval(ApprovalFact.test())], pane: pane)
        let rows = [
            Self.input(title: "Fix the tests", agent: .claude, paneGlyphs: [.needsApproval], paneItems: waiting),
            Self.input(title: "Review the tests", agent: .codex),
            Self.input(title: "zsh")
        ]
        func titles(_ query: String) -> [String] {
            Self.model(rows, reviewTab: .behind, query: query).rows.map(\.title)
        }
        #expect(titles("") == ["Fix the tests", "Review the tests", "zsh", "T12"])
        #expect(titles("APPROVAL") == ["Fix the tests"])
        #expect(titles("tests") == ["Fix the tests", "Review the tests"])
        #expect(titles("codex tests") == ["Review the tests"])
        #expect(titles("review") == ["Review the tests", "T12"])
        #expect(titles("nothing like it") == [])
    }

    /// Read from the session, a split tab counts its panes, which the
    /// list's line says and the strip does not.
    @Test func theStripFromTheSession_countsASplitTabsPanes() throws {
        let (session, tab, _) = WorkspaceSessionFixture.withLooseTab()
        func paneCount() throws -> Int {
            let split = try #require(session.tab(tab.id))
            return try #require(PaneStripModel(
                container: split.container,
                session: session,
                window: session.primaryWindowID,
                queue: AttentionQueue(),
                mountedTmuxPaneIDs: [],
                reviewTab: .none
            ).item(for: tab)).paneCount
        }
        #expect(try paneCount() == 1)
        PaneActions.split(session, direction: .horizontal)
        #expect(try paneCount() == 2)
    }
}
