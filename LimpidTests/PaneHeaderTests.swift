// PaneHeaderTests.swift
// Limpid — which panes carry a header, what the header calls its pane and marks it with, and how a rename is written.

import Foundation
import Testing
@testable import Limpid

@MainActor
@Suite("Pane header")
struct PaneHeaderTests {

    // MARK: - Fixtures

    /// A loose tab split into `panes` leaves through the same action the
    /// UI uses, with the session's id for the tab and its leaves in order.
    private static func splitTab(panes: Int = 2) throws -> (session: WorkspaceSession, tab: Tab) {
        let (session, tab, _) = WorkspaceSessionFixture.withLooseTab()
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
            runStartedAt: state == .running ? updatedAt : nil,
            updatedAt: updatedAt,
            firstPrompt: firstPrompt,
            conversationID: conversationID,
            providerSessionTitle: sessionTitle,
            providerGeneratedTitle: generatedTitle
        )
    }

    // MARK: - Visibility

    /// Every pane of a split tab carries a header, and an agent's pane
    /// carries one alone; a shell alone in its tab is named by its tab row.
    @Test(arguments: [
        (1, false, false),
        (1, true, true),
        (2, false, true),
        (4, true, true)
    ])
    func showsHeader_onASplitOrForAnAgent(leafCount: Int, isAgent: Bool, shows: Bool) {
        #expect(PaneHeaderRules.showsHeader(leafCount: leafCount, isAgent: isAgent) == shows)
    }

    @Test func showsHeaderInTab_aLoneAgentPaneKeepsItsHeaderUntilItsRunIsGone() throws {
        let (session, single, _) = WorkspaceSessionFixture.withLooseTab()
        let lone = try #require(single.splitTree.allLeafIDs().first)
        #expect(!PaneHeaderRules.showsHeader(paneID: lone, in: single))
        #expect(!PaneHeaderRules.showsHeader(paneID: lone, in: nil))

        // An agent in front before its record already counts.
        session.update(single.id) { $0.agentsInFront[lone] = PaneAgentInFront(kind: .codex, isStaged: false) }
        #expect(try PaneHeaderRules.showsHeader(paneID: lone, in: #require(session.tab(single.id))))
        session.update(single.id) { $0.agentsInFront[lone] = nil }

        // The tab wears the agent from its first record, and the pane shows
        // the header from then on; once the run is retired it goes again.
        session.update(single.id) { $0.agentBadges[.claude] = [lone: Self.badge()] }
        #expect(try PaneHeaderRules.showsHeader(paneID: lone, in: #require(session.tab(single.id))))
        session.update(single.id) { $0.agentBadges[.claude] = [:] }
        #expect(try !PaneHeaderRules.showsHeader(paneID: lone, in: #require(session.tab(single.id))))

        // A split's panes all carry one, zoomed or not.
        let (splitSession, tab) = try Self.splitTab()
        let leaves = tab.splitTree.allLeafIDs()
        #expect(leaves.allSatisfy { PaneHeaderRules.showsHeader(paneID: $0, in: tab) })
        let zoomed = try #require(leaves.first)
        splitSession.update(tab.id) { $0.zoomedLeafID = zoomed }
        #expect(try PaneHeaderRules.showsHeader(paneID: zoomed, in: #require(splitSession.tab(tab.id))))
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
        #expect(!PaneHeaderRules.isZoomed(zoomed, in: nil))

        // A zoom id that no longer names a leaf renders the split.
        session.update(tab.id) { $0.zoomedLeafID = UUID() }
        let staleTab = try #require(session.tab(tab.id))
        #expect(!PaneHeaderRules.isZoomed(zoomed, in: staleTab))
    }

    @Test func zoomAction_flipsWhileZoomed() {
        #expect(PaneHeaderRules.zoomAction(isZoomed: false) == .zoom)
        #expect(PaneHeaderRules.zoomAction(isZoomed: true) == .unzoom)
    }

    @Test func menuZoomAction_flipsWhileZoomedAndHidesOnASinglePane() throws {
        let single = WorkspaceSessionFixture.withLooseTab().tab
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
        let plain = PaneHeaderMetrics.inlineRenameMinimumWidth(showsPromptCacheClock: false, showsWarning: false, isZoomed: false)
        let zoomed = PaneHeaderMetrics.inlineRenameMinimumWidth(showsPromptCacheClock: false, showsWarning: false, isZoomed: true)
        #expect(zoomed - plain == PaneHeaderMetrics.itemSpacing + PaneHeaderMetrics.menuSlot)
        #expect(plain == PaneHeaderMetrics.inlineRenameMinimumWidth)
    }

    @Test func metrics_theCacheClockKeepsAUsableRenameFieldBesideIt() {
        let plain = PaneHeaderMetrics.inlineRenameMinimumWidth(showsPromptCacheClock: false, showsWarning: false, isZoomed: false)
        let withClock = PaneHeaderMetrics.inlineRenameMinimumWidth(showsPromptCacheClock: true, showsWarning: false, isZoomed: false)
        #expect(withClock - plain == PaneHeaderMetrics.itemSpacing + PaneHeaderMetrics.markSlot)
        // Everything but the field, with the clock, still leaves the field
        // its minimum.
        let fixedParts = PaneHeaderMetrics.minimumWidth
            + PaneHeaderMetrics.itemSpacing + PaneHeaderMetrics.markSlot // state mark
            + PaneHeaderMetrics.itemSpacing + PaneHeaderMetrics.markSlot // clock
            + PaneHeaderMetrics.itemSpacing // glyph to field
        #expect(withClock - fixedParts >= PaneHeaderMetrics.inlineRenameFieldMinimumWidth)
    }

    @Test func metrics_theWarningKeepsAUsableRenameFieldBesideIt() {
        let plain = PaneHeaderMetrics.inlineRenameMinimumWidth(showsPromptCacheClock: false, showsWarning: false, isZoomed: false)
        let warned = PaneHeaderMetrics.inlineRenameMinimumWidth(showsPromptCacheClock: false, showsWarning: true, isZoomed: false)
        #expect(warned - plain == PaneHeaderMetrics.itemSpacing + PaneHeaderMetrics.warningSlot)
    }

    @Test func inlineRename_endsWhenTheHeaderNarrowsBelowAUsableField() {
        let threshold = PaneHeaderMetrics.inlineRenameMinimumWidth(showsPromptCacheClock: true, showsWarning: false, isZoomed: false)
        #expect(PaneHeaderRules.shouldEndInlineRename(isEditing: true, headerWidth: threshold - 1, threshold: threshold))
        #expect(!PaneHeaderRules.shouldEndInlineRename(isEditing: true, headerWidth: threshold, threshold: threshold))
        #expect(!PaneHeaderRules.shouldEndInlineRename(isEditing: false, headerWidth: 40, threshold: threshold))
        #expect(
            !PaneHeaderRules.shouldEndInlineRename(isEditing: true, headerWidth: 0, threshold: threshold),
            "a header not measured yet is not narrow"
        )
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

    @Test func label_carriesTheAgentsModelAndMode() {
        let label = PaneHeaderRules.label(
            customName: nil,
            agent: PaneHeaderAgent(providerName: "Claude", title: "Fix", model: " Opus 5.5 ", permissionMode: .plan),
            workingDirectory: "/tmp/project",
            fallbackName: "Terminal"
        )
        #expect(label.model == "Opus 5.5")
        #expect(label.permissionMode == .plan)
        #expect(!label.runsWithoutAsking)
    }

    // swiftlint:disable:next large_tuple
    typealias SettingsCase = (model: String?, mode: AgentPermissionMode?, text: String?)

    /// The row says the model and any mode but the default; the mode that
    /// runs without asking is the warning's to name, not the row's.
    @Test(arguments: [
        ("Opus 5.5", AgentPermissionMode?.some(.plan), "Opus 5.5 · Plan"),
        ("Opus 5.5", .some(.default), "Opus 5.5"),
        ("gpt-6.1-sol", .some(.bypassPermissions), "gpt-6.1-sol"),
        (nil, .some(.auto), "Auto"),
        (nil, .some(.default), nil),
        (nil, nil, nil)
    ] as [Self.SettingsCase])
    func settingsText_namesTheModelAndAnyModeButTheDefault(model: String?, mode: AgentPermissionMode?, text: String?) {
        let label = PaneHeaderLabel(name: "x", detail: nil, isAgent: true, agentName: "Claude", model: model, permissionMode: mode)
        #expect(label.settingsText(locale: Locale(identifier: "en")) == text)
        #expect(label.runsWithoutAsking == (mode == .bypassPermissions))
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

    @Test func agentTitle_followsTabTitlePrecedence() {
        let all = Self.badge(
            conversationID: "c1",
            sessionTitle: "Session title",
            generatedTitle: "Generated title",
            firstPrompt: "First prompt"
        )
        #expect(PaneHeaderRules.agentTitle(for: all) == "Session title")

        let generated = Self.badge(conversationID: "c1", generatedTitle: "Generated title", firstPrompt: "First prompt")
        #expect(PaneHeaderRules.agentTitle(for: generated) == "Generated title")

        let prompt = Self.badge(conversationID: "c1", firstPrompt: "  First\nprompt ")
        #expect(PaneHeaderRules.agentTitle(for: prompt) == "First prompt")
    }

    @Test func agentTitle_withoutConversation_hasNoTitle() {
        let stale = Self.badge(sessionTitle: "Left over", generatedTitle: "Also left", firstPrompt: "Old prompt")
        #expect(PaneHeaderRules.agentTitle(for: stale) == nil)
        #expect(PaneHeaderRules.agentTitle(for: Self.badge(conversationID: "c1")) == nil)
    }

    // MARK: - State mark

    private static func run(
        _ kind: AgentKind,
        _ runID: String,
        _ state: AgentState,
        detail: String? = nil,
        panes: [UUID]
    ) -> AgentRuntimePresentation {
        var badge = Self.badge(state: state)
        badge.detail = detail
        return AgentRuntimePresentation.test(kind: kind, runID: runID, badge: badge, paneIDs: Set(panes))
    }

    /// One item about `run`, placed in `pane` as the attention list places it.
    private static func item(_ kind: AttentionItemKind, about run: AgentRuntimePresentation, in pane: UUID) -> AttentionItem {
        var queue = AttentionQueue()
        queue.insert(
            id: .stop(EpisodeKey(origin: .runtime(run.id), episodeToken: "1")),
            kind: kind,
            subject: .runtime(id: run.id, provider: run.kind, paneID: pane, tabID: nil, projectID: nil),
            arrivedAt: Date(timeIntervalSince1970: 0)
        )
        return queue.items[0]
    }

    /// Two runs in one pane are weighed as the row weighs them: a finished
    /// Claude beside a running Codex runs, in Codex's words; a pane with no
    /// run has no mark.
    @Test func mark_twoRunsInAPane_areWeighedAsTheRowWeighsThem() throws {
        let (session, tab) = try Self.splitTab()
        let leaves = tab.splitTree.allLeafIDs()
        let claude = Self.run(.claude, "c", .finished, detail: "done", panes: [leaves[0]])
        let codex = Self.run(.codex, "x", .running, detail: "Bash: swift test", panes: [leaves[0]])

        let mark = PaneHeaderRules.mark(paneID: leaves[0], items: [], runtimes: [claude, codex], session: session)
        #expect(mark == PaneHeaderMark(glyph: .running, detail: "Bash: swift test"))
        #expect(PaneHeaderRules.mark(paneID: leaves[1], items: [], runtimes: [claude, codex], session: session) == nil)
    }

    /// A wait or a stop outranks a running run, in the words of the run
    /// it is about; a running run outranks an unread turn, in its own.
    @Test func mark_aStopOutranksARun_andARunOutranksAnUnreadTurn() throws {
        let (session, tab) = try Self.splitTab()
        let pane = tab.splitTree.allLeafIDs()[0]
        let claude = Self.run(.claude, "c", .finished, detail: "done", panes: [pane])
        let codex = Self.run(.codex, "x", .running, detail: "Bash: swift test", panes: [pane])
        let unread = AttentionItemKind.unread(UnreadTurn(turnID: TurnID("t"), changes: .unknown))

        let stopped = PaneHeaderRules.mark(
            paneID: pane,
            items: [Self.item(.stop(.processExited), about: claude, in: pane)],
            runtimes: [claude, codex],
            session: session
        )
        #expect(stopped == PaneHeaderMark(glyph: .stopped, detail: "done"))

        let running = PaneHeaderRules.mark(
            paneID: pane,
            items: [Self.item(unread, about: claude, in: pane)],
            runtimes: [claude, codex],
            session: session
        )
        #expect(running == PaneHeaderMark(glyph: .running, detail: "Bash: swift test"))
    }

    /// A run shown in two panes marks the one the list places it in, as its
    /// items do, not both.
    @Test func mark_aRunInTwoPanes_marksThePaneItIsPlacedIn() throws {
        let (session, tab) = try Self.splitTab()
        let leaves = tab.splitTree.allLeafIDs()
        let codex = Self.run(.codex, "x", .running, panes: leaves)
        let placed = try #require(AttentionState.shownPane(of: codex, in: session))

        for leaf in leaves {
            let mark = PaneHeaderRules.mark(paneID: leaf, items: [], runtimes: [codex], session: session)
            #expect((mark != nil) == (leaf == placed))
        }
    }

    /// At rest and before the agent is matched, the header stays quiet.
    @Test(arguments: [AgentState.idle, .finished, .unknown])
    func mark_atRest_isNone(state: AgentState) throws {
        let (session, tab) = try Self.splitTab()
        let pane = tab.splitTree.allLeafIDs()[0]
        let run = Self.run(.claude, "c", state, panes: [pane])
        #expect(PaneHeaderRules.mark(paneID: pane, items: [], runtimes: [run], session: session) == nil)
    }

    @Test func headerRuntime_prefersMostRecentKnownRuntimeInPane() {
        let attention = AttentionState()
        let paneID = UUID()
        let older = AgentRuntimePresentation.test(
            runID: "older",
            badge: Self.badge(state: .finished, updatedAt: Date(timeIntervalSinceNow: -60)),
            paneIDs: [paneID]
        )
        let newer = AgentRuntimePresentation.test(
            kind: .codex,
            runID: "newer",
            badge: Self.badge(state: .running, updatedAt: Date()),
            paneIDs: [paneID]
        )
        let unknown = AgentRuntimePresentation.test(
            runID: "unknown",
            badge: Self.badge(state: .unknown, updatedAt: Date(timeIntervalSinceNow: 60)),
            paneIDs: [paneID]
        )
        attention.replaceRuntimes([older, unknown], kind: .claude)
        attention.replaceRuntimes([newer], kind: .codex)

        #expect(attention.headerRuntime(inPane: paneID)?.runID == "newer")
        #expect(attention.headerRuntime(inPane: UUID()) == nil)
    }

    // MARK: - Forms

    /// Narrowing drops the directory first, then the model and mode, then
    /// the name; the warning stays while the state mark does, in words only
    /// while the model and mode still show.
    @Test func forms_dropDetailThenSettingsThenNameThenMark() {
        let forms = PaneHeaderRules.forms(isEditing: false, showsPromptCacheClock: false)
        #expect(forms == [.all, .withSettings, .withName, .withMark, .glyphAndMenu])
        #expect(forms.map(\.showsDetail) == [true, false, false, false, false])
        #expect(forms.map(\.showsSettings) == [true, true, false, false, false])
        #expect(forms.map(\.showsName) == [true, true, true, false, false])
        #expect(forms.map(\.showsMark) == [true, true, true, true, false])
    }

    @Test func forms_withACacheClock_dropTheMarkBeforeTheClock() {
        let forms = PaneHeaderRules.forms(isEditing: false, showsPromptCacheClock: true)
        #expect(forms == [.all, .withSettings, .withName, .withMark, .withClock, .glyphAndMenu])
        #expect(forms.map(\.showsDetail) == [true, false, false, false, false, false])
        #expect(forms.map(\.showsSettings) == [true, true, false, false, false, false])
        #expect(forms.map(\.showsName) == [true, true, true, false, false, false])
        #expect(forms.map(\.showsMark) == [true, true, true, true, false, false])
        #expect(forms.map(\.showsPromptCacheClock) == [true, true, true, true, true, false])
    }

    @Test func metrics_theClockForm_is78PointsWide() {
        #expect(PaneHeaderMetrics.clockFormWidth == 78)
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

    /// The header's state mark is `AgentStateMark` in its row placement,
    /// which sizes itself to the tab row's trailing slot; the inline-rename
    /// threshold counts it as `markSlot`.
    @Test func metrics_markSlotMatchesTheStateMark() {
        #expect(PaneHeaderMetrics.markSlot == LimpidLayout.stateMarkSlot)
    }

    // MARK: - Rename

    /// In place at or above the threshold, and while the header is not
    /// measured yet; floating below it.
    @Test(arguments: [
        (CGFloat(200), PaneRenameStyle.inline),
        (180, .inline),
        (179, .floating),
        (0, .inline)
    ])
    func renameStyle_inPlaceFromTheThreshold_orUnmeasured(headerWidth: CGFloat, style: PaneRenameStyle) {
        #expect(PaneHeaderRules.renameStyle(headerWidth: headerWidth, threshold: 180) == style)
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

    /// What a submitted rename writes: nothing for the name the field
    /// opened with while the pane has none of its own, nor for the name it
    /// has; a new name, trimmed; and a clear for an empty submit of a stored
    /// name. When the agent retitled the pane while the field was open, the
    /// untouched submit carries the old title, the one the field opened
    /// with: compared against that it writes nothing, where comparing
    /// against the new title would pin the old one.
    @Test(arguments: [
        ("Fix the build", String?.none, "Fix the build", PaneNameChange?.none),
        ("  server ", nil, "src", .set("server")),
        ("logs", "server", "server", .set("logs")),
        ("  ", "server", "server", .clear),
        ("", nil, "src", nil),
        ("server", "server", "server", nil),
        ("Fix the build", nil, "Ship the fix", .set("Fix the build"))
    ])
    func nameChange_writesOnlyAChangeOfThePanesOwnName(
        submitted: String,
        stored: String?,
        shown: String,
        change: PaneNameChange?
    ) {
        #expect(PaneHeaderRules.nameChange(submitted: submitted, stored: stored, shown: shown) == change)
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

    @Test func renamePane_survivesTheTabsRoundTrip() throws {
        let (session, tab) = try Self.splitTab()
        let paneID = try #require(tab.splitTree.allLeafIDs().last)
        session.update(tab.id) { $0.paneStates[paneID] = PaneState(unreadCount: 1) }
        session.renamePane(paneID, to: "watcher")

        let live = try #require(session.tab(tab.id))
        let restored = try JSONDecoder().decode(Tab.self, from: JSONEncoder().encode(live))
        #expect(restored.paneStates[paneID] == PaneState(unreadCount: 1, name: "watcher"))
    }
}
