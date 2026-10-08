// PaneHeaderTests.swift
// Limpid — pins when split panes carry a header, what the header calls
// its pane, and how a pane's name persists and travels with the pane.

import Foundation
import Testing
@testable import Limpid

@MainActor
@Suite("Pane header")
struct PaneHeaderTests {

    // MARK: - Fixtures

    /// A loose tab split into `panes` leaves through the same action the
    /// UI uses, with the session's id for the tab and its leaves in order.
    private static func splitTab(panes: Int = 2) throws -> (session: WindowSession, tab: Tab) {
        let (session, tab, _) = WindowSessionFixture.withLooseTab()
        for _ in 1..<panes {
            PaneActions.split(session, direction: .horizontal)
        }
        return try (session, #require(session.tab(tab.id)))
    }

    private static func badge(
        conversationID: String? = nil,
        sessionTitle: String? = nil,
        generatedTitle: String? = nil,
        firstPrompt: String? = nil,
        state: AgentState = .running,
        updatedAt: Date = Date()
    ) -> AgentBadge {
        AgentBadge(
            state: state,
            updatedAt: updatedAt,
            firstPrompt: firstPrompt,
            conversationID: conversationID,
            providerSessionTitle: sessionTitle,
            providerGeneratedTitle: generatedTitle
        )
    }

    // MARK: - Visibility

    @Test func showsHeaders_singlePane_hidden() {
        #expect(!PaneHeaderRules.showsHeaders(leafCount: 1, isZoomed: false, isEnabled: true))
        // A tab with one pane cannot be zoomed, and its tab row names it.
        #expect(!PaneHeaderRules.showsHeaders(leafCount: 1, isZoomed: true, isEnabled: false))
    }

    @Test func showsHeaders_twoOrMorePanes_shown() {
        #expect(PaneHeaderRules.showsHeaders(leafCount: 2, isZoomed: false, isEnabled: true))
        #expect(PaneHeaderRules.showsHeaders(leafCount: 4, isZoomed: false, isEnabled: true))
    }

    @Test func showsHeaders_settingOff_hiddenUnlessZoomed() {
        #expect(!PaneHeaderRules.showsHeaders(leafCount: 3, isZoomed: false, isEnabled: false))
        #expect(PaneHeaderRules.showsHeaders(leafCount: 3, isZoomed: true, isEnabled: false))
    }

    @Test func showsHeaderInTab_zoomedPaneKeepsItsHeaderWhateverTheSetting() throws {
        let singleTab = WindowSessionFixture.withLooseTab().tab
        #expect(!PaneHeaderRules.showsHeader(in: singleTab, isEnabled: true, isReviewPresented: false))

        let (session, tab) = try Self.splitTab()
        #expect(!PaneHeaderRules.showsHeader(in: tab, isEnabled: false, isReviewPresented: false))

        // Zoomed, the header is the way back to the split, so it shows with
        // the setting off too, and goes again once the tab unzooms.
        let zoomed = try #require(tab.splitTree.allLeafIDs().first)
        session.update(tab.id) { $0.zoomedLeafID = zoomed }
        let zoomedTab = try #require(session.tab(tab.id))
        #expect(PaneHeaderRules.showsHeader(in: zoomedTab, isEnabled: true, isReviewPresented: false))
        #expect(PaneHeaderRules.showsHeader(in: zoomedTab, isEnabled: false, isReviewPresented: false))

        PaneActions.unzoom(session, tabID: tab.id)
        let unzoomedTab = try #require(session.tab(tab.id))
        #expect(!PaneHeaderRules.showsHeader(in: unzoomedTab, isEnabled: false, isReviewPresented: false))
    }

    @Test func showsHeaderInTab_reviewHidesItEvenWhileZoomed() throws {
        let (session, tab) = try Self.splitTab()
        #expect(!PaneHeaderRules.showsHeader(in: tab, isEnabled: true, isReviewPresented: true))

        let zoomed = try #require(tab.splitTree.allLeafIDs().first)
        session.update(tab.id) { $0.zoomedLeafID = zoomed }
        let zoomedTab = try #require(session.tab(tab.id))
        #expect(!PaneHeaderRules.showsHeader(in: zoomedTab, isEnabled: true, isReviewPresented: true))
        #expect(!PaneHeaderRules.showsHeader(in: zoomedTab, isEnabled: false, isReviewPresented: true))
    }

    @Test func showsHeaderInTab_staleZoomIDFollowsTheSetting() throws {
        let (session, tab) = try Self.splitTab()
        // A zoom id that no longer names a leaf renders the split, so the
        // setting decides as it does unzoomed.
        session.update(tab.id) { $0.zoomedLeafID = UUID() }
        let staleTab = try #require(session.tab(tab.id))
        #expect(!PaneHeaderRules.showsHeader(in: staleTab, isEnabled: false, isReviewPresented: false))
    }

    @Test func isZoomed_onlyTheZoomedLeafStillInTheTree() throws {
        let (session, tab) = try Self.splitTab()
        let leaves = tab.splitTree.allLeafIDs()
        let zoomed = try #require(leaves.first)
        let other = try #require(leaves.last)
        #expect(!PaneHeaderRules.isZoomed(zoomed, in: tab))

        session.update(tab.id) { $0.zoomedLeafID = zoomed }
        let zoomedTab = try #require(session.tab(tab.id))
        #expect(PaneHeaderRules.isZoomed(zoomed, in: zoomedTab))
        #expect(!PaneHeaderRules.isZoomed(other, in: zoomedTab))
        #expect(PaneHeaderRules.isZoomed(zoomedTab))
        #expect(!PaneHeaderRules.isZoomed(zoomed, in: nil))

        // A zoom id that no longer names a leaf renders the split.
        session.update(tab.id) { $0.zoomedLeafID = UUID() }
        #expect(try !PaneHeaderRules.isZoomed(#require(session.tab(tab.id))))
    }

    @Test func zoomAction_flipsWhileZoomed() {
        #expect(PaneHeaderRules.zoomAction(isZoomed: false) == .zoom)
        #expect(PaneHeaderRules.zoomAction(isZoomed: true) == .unzoom)
    }

    @Test func menuZoomAction_flipsWhileZoomedAndHidesOnASinglePane() throws {
        let single = WindowSessionFixture.withLooseTab().tab
        let lone = try #require(single.splitTree.allLeafIDs().first)
        #expect(PaneHeaderRules.menuZoomAction(for: lone, in: single) == nil)
        #expect(PaneHeaderRules.menuZoomAction(for: lone, in: nil) == nil)

        let (session, tab) = try Self.splitTab()
        let zoomed = try #require(tab.splitTree.allLeafIDs().first)
        #expect(PaneHeaderRules.menuZoomAction(for: zoomed, in: tab) == .zoom)

        session.update(tab.id) { $0.zoomedLeafID = zoomed }
        let zoomedTab = try #require(session.tab(tab.id))
        #expect(PaneHeaderRules.menuZoomAction(for: zoomed, in: zoomedTab) == .unzoom)
    }

    @Test func headerDrag_picksThePaneUpOnlyWhenNotRenamingOrZoomed() {
        #expect(PaneHeaderRules.dragsPane(isEditing: false, isZoomed: false))
        #expect(!PaneHeaderRules.dragsPane(isEditing: true, isZoomed: false))
        #expect(!PaneHeaderRules.dragsPane(isEditing: false, isZoomed: true))
        #expect(!PaneHeaderRules.dragsPane(isEditing: true, isZoomed: true))
    }

    @Test func metrics_zoomedHeaderKeepsTheUnzoomButtonBesideTheMenu() {
        #expect(
            PaneHeaderMetrics.zoomedMinimumWidth
                == PaneHeaderMetrics.minimumWidth + PaneHeaderMetrics.itemSpacing + PaneHeaderMetrics.menuSlot
        )
        let plain = PaneHeaderMetrics.inlineRenameMinimumWidth(showsPromptCacheClock: false, isZoomed: false)
        let zoomed = PaneHeaderMetrics.inlineRenameMinimumWidth(showsPromptCacheClock: false, isZoomed: true)
        #expect(zoomed - plain == PaneHeaderMetrics.itemSpacing + PaneHeaderMetrics.menuSlot)
        #expect(plain == PaneHeaderMetrics.inlineRenameMinimumWidth)
    }

    @Test func splitPaneHeadersSetting_defaultsOnAndDecodesWithoutKey() throws {
        #expect(TerminalSettings().showsSplitPaneHeaders)
        let decoded = try JSONDecoder().decode(TerminalSettings.self, from: Data("{}".utf8))
        #expect(decoded.showsSplitPaneHeaders)

        var off = TerminalSettings()
        off.showsSplitPaneHeaders = false
        let roundTripped = try JSONDecoder().decode(
            TerminalSettings.self,
            from: JSONEncoder().encode(off)
        )
        #expect(!roundTripped.showsSplitPaneHeaders)
    }

    // MARK: - Name resolution

    @Test func label_customNameWinsOverEverything() {
        let label = PaneHeaderRules.label(
            customName: "server",
            agent: PaneHeaderAgent(providerName: "Claude", title: "Fix the build"),
            workingDirectory: "/tmp/project",
            fallbackName: "Terminal"
        )
        #expect(label.name == "server")
        #expect(label.detail == "/tmp/project")
        #expect(label.agentName == "Claude")
        #expect(label.isAgent)
    }

    @Test func label_agentTitleWinsOverDirectory() {
        let label = PaneHeaderRules.label(
            customName: nil,
            agent: PaneHeaderAgent(providerName: "Codex", title: "Fix the build"),
            workingDirectory: "/tmp/project",
            fallbackName: "Terminal"
        )
        #expect(label.name == "Fix the build")
        #expect(label.detail == "/tmp/project")
        #expect(label.agentName == "Codex")
    }

    @Test func label_agentWithoutTitle_fallsToDirectoryName() {
        let label = PaneHeaderRules.label(
            customName: nil,
            agent: PaneHeaderAgent(providerName: "Claude", title: nil),
            workingDirectory: "/tmp/project",
            fallbackName: "Terminal"
        )
        #expect(label.name == "project")
        #expect(label.detail == "/tmp/project")
        #expect(label.agentName == "Claude")
    }

    @Test func label_shell_namesDirectoryAndShowsItsPath() {
        let label = PaneHeaderRules.label(
            customName: "   ",
            agent: nil,
            workingDirectory: "/tmp/project/src",
            fallbackName: "Terminal"
        )
        #expect(label.name == "src")
        #expect(label.detail == "/tmp/project/src")
        #expect(!label.isAgent)
    }

    @Test func label_shellInHome_abbreviatesAndDropsRepeatedDetail() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let atHome = PaneHeaderRules.label(customName: nil, agent: nil, workingDirectory: home, fallbackName: "Terminal")
        #expect(atHome.name == "~")
        #expect(atHome.detail == nil)

        let below = PaneHeaderRules.label(
            customName: nil,
            agent: nil,
            workingDirectory: home + "/code/limpid",
            fallbackName: "Terminal"
        )
        #expect(below.name == "limpid")
        #expect(below.detail == "~/code/limpid")
    }

    @Test func label_nothingKnown_usesFallback() {
        let label = PaneHeaderRules.label(customName: nil, agent: nil, workingDirectory: nil, fallbackName: "Terminal")
        #expect(label.name == "Terminal")
        #expect(label.detail == nil)
    }

    @Test func normalizedName_trimsAndJoinsLinesAndClearsBlank() {
        #expect(PaneHeaderRules.normalizedName("  build  ") == "build")
        #expect(PaneHeaderRules.normalizedName("dev\nserver") == "dev server")
        #expect(PaneHeaderRules.normalizedName(" \n\t ") == nil)
        #expect(PaneHeaderRules.normalizedName("") == nil)
        #expect(PaneHeaderRules.normalizedName(nil) == nil)
    }

    // MARK: - Agent title

    @Test func agentTitle_titledProvider_followsTabTitlePrecedence() {
        let all = Self.badge(
            conversationID: "c1",
            sessionTitle: "Session title",
            generatedTitle: "Generated title",
            firstPrompt: "First prompt"
        )
        #expect(PaneHeaderRules.agentTitle(for: all, hasSessionTitles: true) == "Session title")

        let generated = Self.badge(conversationID: "c1", generatedTitle: "Generated title", firstPrompt: "First prompt")
        #expect(PaneHeaderRules.agentTitle(for: generated, hasSessionTitles: true) == "Generated title")

        let prompt = Self.badge(conversationID: "c1", firstPrompt: "  First\nprompt ")
        #expect(PaneHeaderRules.agentTitle(for: prompt, hasSessionTitles: true) == "First prompt")
    }

    @Test func agentTitle_titledProviderWithoutConversation_hasNoTitle() {
        let stale = Self.badge(sessionTitle: "Left over", firstPrompt: "Old prompt")
        #expect(PaneHeaderRules.agentTitle(for: stale, hasSessionTitles: true) == nil)
    }

    @Test func agentTitle_untitledProvider_usesFirstPromptOnly() {
        let badge = Self.badge(sessionTitle: "Ignored", firstPrompt: "Refactor the store")
        #expect(PaneHeaderRules.agentTitle(for: badge, hasSessionTitles: false) == "Refactor the store")
        #expect(PaneHeaderRules.agentTitle(for: Self.badge(), hasSessionTitles: false) == nil)
    }

    @Test func providerRegistry_sessionTitleCapabilityMatchesProviders() {
        #expect(AgentProviderRegistry.hasSessionTitles(.claude))
        #expect(!AgentProviderRegistry.hasSessionTitles(.codex))
    }

    @Test func headerRuntime_prefersMostRecentKnownRuntimeInPane() {
        let attention = AttentionState()
        let paneID = UUID()
        let older = AgentRuntimePresentation(
            kind: .claude, runID: "older", revision: 1,
            badge: Self.badge(state: .finished, updatedAt: Date(timeIntervalSinceNow: -60)),
            paneIDs: [paneID], tmuxLocations: [:]
        )
        let newer = AgentRuntimePresentation(
            kind: .codex, runID: "newer", revision: 1,
            badge: Self.badge(state: .running, updatedAt: Date()),
            paneIDs: [paneID], tmuxLocations: [:]
        )
        let unknown = AgentRuntimePresentation(
            kind: .claude, runID: "unknown", revision: 1,
            badge: Self.badge(state: .unknown, updatedAt: Date(timeIntervalSinceNow: 60)),
            paneIDs: [paneID], tmuxLocations: [:]
        )
        attention.replaceRuntimes([older, unknown], kind: .claude)
        attention.replaceRuntimes([newer], kind: .codex)

        #expect(attention.headerRuntime(inPane: paneID)?.runID == "newer")
        #expect(attention.headerRuntime(inPane: UUID()) == nil)
        #expect(attention.aggregateAgentStateSummary(inPane: paneID)?.state == .finished)
    }

    // MARK: - On screen

    @Test func showsHeader_followsTabSettingAndReview() throws {
        let (_, tab) = try Self.splitTab()
        #expect(PaneHeaderRules.showsHeader(in: tab, isEnabled: true, isReviewPresented: false))
        #expect(!PaneHeaderRules.showsHeader(in: tab, isEnabled: false, isReviewPresented: false))
        // Review replaces the split and docks one pane under its own heading.
        #expect(!PaneHeaderRules.showsHeader(in: tab, isEnabled: true, isReviewPresented: true))
        #expect(!PaneHeaderRules.showsHeader(in: nil, isEnabled: true, isReviewPresented: false))
    }

    // MARK: - Forms

    @Test func forms_dropDetailThenNameThenMark() {
        let forms = PaneHeaderRules.forms(isEditing: false, showsPromptCacheClock: false)
        #expect(forms == [.all, .withName, .withMark, .glyphAndMenu])
        #expect(forms.map(\.showsDetail) == [true, false, false, false])
        #expect(forms.map(\.showsName) == [true, true, false, false])
        #expect(forms.map(\.showsMark) == [true, true, true, false])
    }

    @Test func forms_withACacheClock_dropTheMarkBeforeTheClock() {
        let forms = PaneHeaderRules.forms(isEditing: false, showsPromptCacheClock: true)
        #expect(forms == [.all, .withName, .withMark, .withClock, .glyphAndMenu])
        #expect(forms.map(\.showsDetail) == [true, false, false, false, false])
        #expect(forms.map(\.showsName) == [true, true, false, false, false])
        #expect(forms.map(\.showsMark) == [true, true, true, false, false])
        #expect(forms.map(\.showsPromptCacheClock) == [true, true, true, true, false])
    }

    @Test func forms_clockFormOnlyWhileThereIsAClock() {
        #expect(!PaneHeaderRules.forms(isEditing: false, showsPromptCacheClock: false).contains(.withClock))
        #expect(PaneHeaderRules.forms(isEditing: false, showsPromptCacheClock: true).contains(.withClock))
    }

    @Test func metrics_clockFormIsTheNarrowestFormAndTheClock() {
        #expect(
            PaneHeaderMetrics.clockFormWidth
                == PaneHeaderMetrics.minimumWidth + PaneHeaderMetrics.itemSpacing + PaneHeaderMetrics.markSlot
        )
        #expect(PaneHeaderMetrics.clockFormWidth == 78)
        // The split floor does not grow for the clock.
        #expect(PaneHeaderMetrics.minimumWidth < PaneHeaderMetrics.clockFormWidth)
    }

    @Test func forms_whileEditing_keepTheName() {
        for showsClock in [false, true] {
            let forms = PaneHeaderRules.forms(isEditing: true, showsPromptCacheClock: showsClock)
            #expect(forms == [.withName])
            let keepsTheName = forms.allSatisfy(\.showsName)
            #expect(keepsTheName)
            let keepsTheClock = forms.allSatisfy(\.showsPromptCacheClock)
            #expect(keepsTheClock, "the rename threshold counts the clock")
        }
    }

    @Test func metrics_minimumWidthIsGlyphAndMenuWithTheirGaps() {
        let parts = PaneHeaderMetrics.horizontalPadding * 2
            + PaneHeaderMetrics.glyphSlot
            + PaneHeaderMetrics.itemSpacing * 3
            + PaneHeaderMetrics.menuSlot
        #expect(PaneHeaderMetrics.minimumWidth == parts)
        #expect(LimpidLayout.paneHeaderHeight == PaneHeaderMetrics.height)
    }

    /// The header's state mark is `AgentStateMark` in its row placement,
    /// which sizes itself to the tab row's trailing slot; the inline-rename
    /// threshold counts it as `markSlot`.
    @Test func metrics_markSlotMatchesTheStateMark() {
        #expect(PaneHeaderMetrics.markSlot == LimpidLayout.containerColumnTrailingSlot)
    }

    // MARK: - Rename

    @Test func renameStyle_inlineAtOrAboveThreshold() {
        #expect(PaneHeaderRules.renameStyle(headerWidth: 200, threshold: 180) == .inline)
        #expect(PaneHeaderRules.renameStyle(headerWidth: 180, threshold: 180) == .inline)
        #expect(PaneHeaderRules.renameStyle(headerWidth: 179, threshold: 180) == .floating)
    }

    @Test func renameStyle_unmeasuredHeaderEditsInPlace() {
        #expect(PaneHeaderRules.renameStyle(headerWidth: 0) == .inline)
    }

    @Test func renameStyle_narrowestHeaderFloats() {
        // The narrowest header shows only its glyph and menu, so there is no
        // name to edit in place.
        #expect(PaneHeaderRules.renameStyle(headerWidth: PaneHeaderMetrics.minimumWidth) == .floating)
        #expect(
            PaneHeaderMetrics.inlineRenameMinimumWidth
                >= PaneHeaderMetrics.minimumWidth + PaneHeaderMetrics.inlineRenameFieldMinimumWidth
        )
    }

    @Test func nameChange_unchangedDerivedNameWritesNothing() {
        #expect(PaneHeaderRules.nameChange(submitted: "Fix the build", stored: nil, shown: "Fix the build") == nil)
    }

    @Test func nameChange_newNameIsSetTrimmed() {
        #expect(PaneHeaderRules.nameChange(submitted: "  server ", stored: nil, shown: "src") == .set("server"))
        #expect(PaneHeaderRules.nameChange(submitted: "logs", stored: "server", shown: "server") == .set("logs"))
    }

    @Test func nameChange_emptyClearsAStoredName() {
        #expect(PaneHeaderRules.nameChange(submitted: "  ", stored: "server", shown: "server") == .clear)
        #expect(PaneHeaderRules.nameChange(submitted: "", stored: nil, shown: "src") == nil)
    }

    @Test func nameChange_sameAsStoredWritesNothing() {
        #expect(PaneHeaderRules.nameChange(submitted: "server", stored: "server", shown: "server") == nil)
    }

    /// The agent retitled the pane while the field was open. The untouched
    /// submit carries the old title, which is what the field opened with;
    /// compared against the name shown at the start it writes nothing, where
    /// comparing against the new title would pin the old one.
    @Test func nameChange_staleTitleSubmittedUnchangedWritesNothing() {
        let openedWith = "Fix the build"
        #expect(PaneHeaderRules.nameChange(submitted: openedWith, stored: nil, shown: openedWith) == nil)
        #expect(PaneHeaderRules.nameChange(submitted: openedWith, stored: nil, shown: "Ship the fix") == .set(openedWith))
    }

    @Test func commitPaneRename_appliesTheRule() throws {
        let (session, tab) = try Self.splitTab()
        let paneID = try #require(tab.splitTree.allLeafIDs().first)

        session.commitPaneRename(paneID, submitted: "src", shownName: "src")
        #expect(session.paneState(paneID).name == nil)

        session.commitPaneRename(paneID, submitted: "server", shownName: "src")
        #expect(session.paneState(paneID).name == "server")

        session.commitPaneRename(paneID, submitted: "", shownName: "server")
        #expect(session.paneState(paneID).name == nil)
    }

    // MARK: - Persistence

    @Test func paneState_decodesWithoutName() throws {
        let decoded = try JSONDecoder().decode(PaneState.self, from: Data(#"{"unreadCount":2}"#.utf8))
        #expect(decoded.unreadCount == 2)
        #expect(decoded.name == nil)
    }

    @Test func paneState_roundTripsName() throws {
        let state = PaneState(unreadCount: 1, name: "server")
        let decoded = try JSONDecoder().decode(PaneState.self, from: JSONEncoder().encode(state))
        #expect(decoded == state)
    }

    @Test func renamePane_trimsStoresAndClears() throws {
        let (session, tab) = try Self.splitTab()
        let paneID = try #require(tab.splitTree.allLeafIDs().first)

        session.renamePane(paneID, to: "  api server \n")
        #expect(session.paneState(paneID).name == "api server")
        #expect(session.tab(tab.id)?.paneStates[paneID]?.name == "api server")

        session.renamePane(paneID, to: "   ")
        #expect(session.paneState(paneID).name == nil)

        session.renamePane(paneID, to: "logs")
        session.renamePane(paneID, to: nil)
        #expect(session.paneState(paneID).name == nil)
    }

    @Test func renamePane_survivesSnapshotRoundTrip() throws {
        let (session, tab) = try Self.splitTab()
        let paneID = try #require(tab.splitTree.allLeafIDs().last)
        session.renamePane(paneID, to: "watcher")

        let live = try #require(session.tab(tab.id))
        let restored = try JSONDecoder().decode(Tab.self, from: JSONEncoder().encode(live))
        #expect(restored.paneStates[paneID]?.name == "watcher")
    }

    // MARK: - Moving panes

    @Test func movePaneToNewTab_namedPane_namesNewTab() throws {
        let (session, source) = try Self.splitTab()
        let paneID = try #require(source.splitTree.allLeafIDs().last)
        session.renamePane(paneID, to: "server")

        TabActions.movePaneToNewTab(session, paneID: paneID)

        let moved = try #require(session.tab(containing: paneID))
        #expect(moved.id != source.id)
        #expect(moved.displayTitle == "server")
        #expect(moved.titleOverride == "server")
        #expect(moved.paneStates[paneID]?.name == "server")
        #expect(session.tab(source.id)?.paneStates[paneID] == nil)
    }

    @Test func movePaneToNewTab_unnamedPane_keepsSourceTitle() throws {
        let (session, source) = try Self.splitTab()
        session.update(source.id) { $0.title = "source title" }
        let paneID = try #require(source.splitTree.allLeafIDs().last)

        TabActions.movePaneToNewTab(session, paneID: paneID)

        let moved = try #require(session.tab(containing: paneID))
        #expect(moved.title == "source title")
        #expect(moved.titleOverride == nil)
    }

    @Test func mergePaneIntoTab_keepsName() throws {
        let (session, source) = try Self.splitTab()
        let target = session.openTab(container: .loose)
        let paneID = try #require(source.splitTree.allLeafIDs().last)
        session.renamePane(paneID, to: "tests")

        TabActions.mergePaneIntoTab(session, paneID: paneID, into: target.id)

        let merged = try #require(session.tab(target.id))
        #expect(merged.splitTree.contains(leafID: paneID))
        #expect(merged.paneStates[paneID]?.name == "tests")
        #expect(session.paneState(paneID).name == "tests")
    }
}
