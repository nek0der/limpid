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

    // MARK: - Zoom

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
        // Everything but the field, with the warning, still leaves the field
        // its minimum.
        let fixedParts = PaneHeaderMetrics.minimumWidth
            + PaneHeaderMetrics.itemSpacing + PaneHeaderMetrics.markSlot // state mark
            + PaneHeaderMetrics.itemSpacing + PaneHeaderMetrics.warningSlot // warning
            + PaneHeaderMetrics.itemSpacing // glyph to field
        #expect(warned - fixedParts >= PaneHeaderMetrics.inlineRenameFieldMinimumWidth)
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
            agent: PaneHeaderAgent(kind: .claude, providerName: "Claude", title: "Fix the build"),
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
            agent: PaneHeaderAgent(kind: .codex, providerName: "Codex", title: "Fix the build"),
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
            agent: PaneHeaderAgent(kind: .claude, providerName: "Claude", title: nil),
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
            agent: PaneHeaderAgent(kind: .claude, providerName: "Claude", title: "Fix", model: " Opus 5.5 ", permissionMode: .plan),
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
        let label = PaneHeaderLabel(name: "x", detail: nil, agentKind: .claude, agentName: "Claude", model: model, permissionMode: mode)
        #expect(label.settingsText(locale: Locale(identifier: "en")) == text)
        #expect(label.runsWithoutAsking == (mode == .bypassPermissions))
    }

    @Test func settingsText_putsTheEffortBetweenTheModelAndTheMode() {
        var label = PaneHeaderLabel(
            name: "x",
            detail: nil,
            agentKind: .claude,
            agentName: "Claude",
            model: "Opus 5.5",
            permissionMode: .plan
        )
        label.effort = "xhigh"
        #expect(label.settingsText(locale: Locale(identifier: "en")) == "Opus 5.5 · xhigh · Plan")
        #expect(label.settingsText(tokens: "31K tok", locale: Locale(identifier: "en")) == "Opus 5.5 · xhigh · Plan · 31K tok")
        label.settingsAreAmbiguous = true
        #expect(label.settingsText(locale: Locale(identifier: "en")) == nil)
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

    /// We keep the conversation selected for Changes while the model and
    /// permission warning follow tmux's active window, without a new hook.
    @Test(arguments: [true, false])
    func paneHeaderLabel_settingsFollowTheActiveTmuxAgent(isBypassActive: Bool) throws {
        let (session, tab, _) = WorkspaceSessionFixture.withLooseTab()
        let pane = try #require(tab.splitTree.allLeafIDs().first)
        let attention = AttentionState()
        var bypassBadge = Self.badge(conversationID: "a", sessionTitle: "Visible work", updatedAt: Date(timeIntervalSince1970: 1))
        bypassBadge.model = "Opus 5.5"
        bypassBadge.permissionMode = "bypassPermissions"
        var defaultBadge = Self.badge(conversationID: "b", sessionTitle: "Latest conversation", updatedAt: Date(timeIntervalSince1970: 2))
        defaultBadge.model = "gpt-6.1-sol"
        defaultBadge.permissionMode = "default"
        let bypass = AgentRuntimePresentation.test(
            runID: "bypass",
            badge: bypassBadge,
            paneIDs: [pane],
            tmuxLocations: [pane: Self.tmuxLocation(window: "@1", pane: "%1", isActive: isBypassActive)]
        )
        let normal = AgentRuntimePresentation.test(
            kind: .codex,
            runID: "normal",
            badge: defaultBadge,
            paneIDs: [pane],
            tmuxLocations: [pane: Self.tmuxLocation(window: "@2", pane: "%2", isActive: !isBypassActive)]
        )
        attention.replaceRuntimes([bypass], kind: .claude)
        attention.replaceRuntimes([normal], kind: .codex)

        let label = attention.paneHeaderLabel(paneID: pane, in: session, locale: Locale(identifier: "en"))
        #expect(label.model == (isBypassActive ? "Opus 5.5" : "gpt-6.1-sol"))
        #expect(label.permissionMode == (isBypassActive ? .bypassPermissions : .default))
        #expect(label.runsWithoutAsking == isBypassActive)
        #expect(label.agentName == AgentProviderRegistry.displayName(for: isBypassActive ? .claude : .codex))
        #expect(label.name == "Latest conversation")
        #expect(attention.headerRuntime(inPane: pane)?.runID == "normal")
    }

    @Test func paneHeaderLabel_hiddenTmuxAgentDoesNotSupplySettings() throws {
        let (session, tab, _) = WorkspaceSessionFixture.withLooseTab()
        let pane = try #require(tab.splitTree.allLeafIDs().first)
        let attention = AttentionState()
        var badge = Self.badge(conversationID: "hidden", sessionTitle: "Hidden conversation")
        badge.model = "Opus 5.5"
        badge.permissionMode = "bypassPermissions"
        let hidden = AgentRuntimePresentation.test(
            badge: badge,
            paneIDs: [pane],
            tmuxLocations: [pane: Self.tmuxLocation(window: "@1", pane: "%1", isActive: false)]
        )
        attention.replaceRuntimes([hidden], kind: .claude)

        let label = attention.paneHeaderLabel(paneID: pane, in: session, locale: Locale(identifier: "en"))
        #expect(label.model == nil)
        #expect(label.permissionMode == nil)
        #expect(!label.runsWithoutAsking)
        #expect(label.name == "Hidden conversation")
    }

    /// A visible split keeps its warning when focus moves to another
    /// agent or to a shell, even if the other agent reported more recently.
    @Test(arguments: [true, false])
    func paneHeaderLabel_visibleUnfocusedBypassKeepsItsWarning(hasFocusedAgent: Bool) throws {
        let (session, tab, _) = WorkspaceSessionFixture.withLooseTab()
        let pane = try #require(tab.splitTree.allLeafIDs().first)
        let attention = AttentionState()
        var bypassBadge = Self.badge(updatedAt: Date(timeIntervalSince1970: 1))
        bypassBadge.model = "Opus 5.5"
        bypassBadge.permissionMode = "bypassPermissions"
        let bypass = AgentRuntimePresentation.test(
            badge: bypassBadge,
            paneIDs: [pane],
            tmuxLocations: [pane: Self.tmuxLocation(window: "@1", pane: "%1", isActive: false, isVisible: true)]
        )
        attention.replaceRuntimes([bypass], kind: .claude)
        if hasFocusedAgent {
            var normalBadge = Self.badge(updatedAt: Date(timeIntervalSince1970: 2))
            normalBadge.model = "gpt-6.1-sol"
            normalBadge.permissionMode = "default"
            let normal = AgentRuntimePresentation.test(
                kind: .codex,
                badge: normalBadge,
                paneIDs: [pane],
                tmuxLocations: [pane: Self.tmuxLocation(window: "@1", pane: "%2", isActive: true, isVisible: true)]
            )
            attention.replaceRuntimes([normal], kind: .codex)
        }

        let label = attention.paneHeaderLabel(paneID: pane, in: session, locale: Locale(identifier: "en"))
        #expect(label.runsWithoutAsking)
        #expect(label.permissionMode == .bypassPermissions)
        #expect(label.model == "Opus 5.5")
        #expect(label.agentName == AgentProviderRegistry.displayName(for: .claude))
    }

    /// A retained record from a crashed run must not supply settings once
    /// another invocation has reported from the same terminal endpoint.
    @Test(arguments: [true, false], [AgentState.running, .unknown])
    func paneHeaderLabel_newInvocationSupersedesAnOldBypassRun(isTmux: Bool, newState: AgentState) throws {
        let (session, tab, _) = WorkspaceSessionFixture.withLooseTab()
        let pane = try #require(tab.splitTree.allLeafIDs().first)
        let attention = AttentionState()
        let locations: [UUID: TmuxPaneLocation] = isTmux
            ? [pane: Self.tmuxLocation(window: "@1", pane: "%1", isActive: true, isVisible: true)]
            : [:]
        var oldBadge = Self.badge(state: .finished, updatedAt: Date(timeIntervalSince1970: isTmux ? 2 : 1))
        oldBadge.sessionStartedAt = isTmux ? Date(timeIntervalSince1970: 1) : nil
        oldBadge.runLaunchOrder = isTmux ? nil : 200
        oldBadge.model = "Opus 5.5"
        oldBadge.permissionMode = "bypassPermissions"
        var newBadge = Self.badge(state: newState, updatedAt: Date(timeIntervalSince1970: 2))
        newBadge.sessionStartedAt = isTmux ? Date(timeIntervalSince1970: 2) : nil
        newBadge.runLaunchOrder = isTmux ? nil : 100
        newBadge.model = "gpt-6.1-sol"
        newBadge.permissionMode = "default"
        let oldRun = AgentRuntimePresentation.test(
            runID: "old", badge: oldBadge, paneIDs: [pane], tmuxLocations: locations
        )
        let newRun = AgentRuntimePresentation.test(
            kind: .codex, runID: "new", badge: newBadge, paneIDs: [pane], tmuxLocations: locations
        )
        attention.replaceRuntimes([oldRun], kind: .claude)
        attention.replaceRuntimes([newRun], kind: .codex)

        let label = attention.paneHeaderLabel(paneID: pane, in: session, locale: Locale(identifier: "en"))
        #expect(!label.runsWithoutAsking)
        #expect(label.model == (newState == .unknown ? nil : "gpt-6.1-sol"))
        #expect(label.permissionMode == (newState == .unknown ? nil : .default))
        if newState != .unknown {
            #expect(label.agentName == AgentProviderRegistry.displayName(for: .codex))
        }
    }

    /// Wall-clock stamps and UUID ordering cannot identify the current run.
    @Test(arguments: [false, true], [false, true])
    func paneHeaderLabel_launchOrderResolvesEqualTimestamps(newBypasses: Bool, oldHasOrder: Bool) throws {
        let (session, tab, _) = WorkspaceSessionFixture.withLooseTab()
        let pane = try #require(tab.splitTree.allLeafIDs().first)
        let attention = AttentionState()
        let location = Self.tmuxLocation(window: "@1", pane: "%1", isActive: true, isVisible: true)
        var old = Self.badge(updatedAt: Date(timeIntervalSince1970: 1))
        old.sessionStartedAt = old.updatedAt
        old.runLaunchOrder = oldHasOrder ? 100 : nil
        old.model = "old"
        old.permissionMode = newBypasses ? "default" : "bypassPermissions"
        var new = old
        new.runLaunchOrder = 101
        new.model = "new"
        new.permissionMode = newBypasses ? "bypassPermissions" : "default"
        attention.replaceRuntimes([
            .test(runID: "ZZZ-old", badge: old, paneIDs: [pane], tmuxLocations: [pane: location]),
            .test(runID: "AAA-new", badge: new, paneIDs: [pane], tmuxLocations: [pane: location])
        ], kind: .claude)
        let label = attention.paneHeaderLabel(paneID: pane, in: session, locale: Locale(identifier: "en"))
        #expect(label.model == "new")
        #expect(label.runsWithoutAsking == newBypasses)
        #expect(!label.settingsAreAmbiguous)
    }

    @Test func paneHeaderLabel_equalLegacyStampsDoNotGuessCurrentSettings() throws {
        let (session, tab, _) = WorkspaceSessionFixture.withLooseTab()
        let pane = try #require(tab.splitTree.allLeafIDs().first)
        let attention = AttentionState()
        var badge = Self.badge(updatedAt: Date(timeIntervalSince1970: 1))
        badge.permissionMode = "bypassPermissions"
        let location = Self.tmuxLocation(window: "@1", pane: "%1", isActive: true, isVisible: true)
        attention.replaceRuntimes([
            .test(runID: "a", badge: badge, paneIDs: [pane], tmuxLocations: [pane: location]),
            .test(runID: "b", badge: badge, paneIDs: [pane], tmuxLocations: [pane: location])
        ], kind: .claude)
        let label = attention.paneHeaderLabel(paneID: pane, in: session, locale: Locale(identifier: "en"))
        #expect(label.settingsAreAmbiguous)
        #expect(label.model == nil)
        #expect(label.permissionMode == nil)
        #expect(label.settingsText(locale: Locale(identifier: "en")) == nil)
        #expect(PaneHeaderLabel.unavailableSettings.resolved(in: Locale(identifier: "en")) == "Agent settings unavailable")
        #expect(PaneHeaderLabel.unavailableSettings.resolved(in: Locale(identifier: "ja")) == "エージェントの設定を特定できません")
    }

    private static func tmuxLocation(window: String, pane: String, isActive: Bool, isVisible: Bool? = nil) -> TmuxPaneLocation {
        TmuxPaneLocation(
            socketPath: "/tmp/tmux-test/default",
            serverPID: "1",
            serverStartedAt: "1",
            sessionID: "$1",
            windowID: window,
            paneID: pane,
            isActive: isActive,
            isVisible: isVisible
        )
    }

    // MARK: - Forms

    /// Narrowing drops the directory first, then the tokens, then the model
    /// and mode, then the name; the warning stays while the state mark does,
    /// in words only while the model and mode still show.
    @Test func forms_dropDetailThenTokensThenSettingsThenNameThenMark() {
        let forms = PaneHeaderRules.forms(isEditing: false, showsPromptCacheClock: false)
        #expect(forms == [.all, .withTokens, .withSettings, .withName, .withMark, .kindAndMenu])
        #expect(forms.map(\.showsDetail) == [true, false, false, false, false, false])
        #expect(forms.map(\.showsTokens) == [true, true, false, false, false, false])
        #expect(forms.map(\.showsSettings) == [true, true, true, false, false, false])
        #expect(forms.map(\.showsName) == [true, true, true, true, false, false])
        #expect(forms.map(\.showsMark) == [true, true, true, true, true, false])
    }

    @Test func forms_withACacheClock_dropTheMarkBeforeTheClock() {
        let forms = PaneHeaderRules.forms(isEditing: false, showsPromptCacheClock: true)
        #expect(forms == [.all, .withTokens, .withSettings, .withName, .withMark, .withClock, .kindAndMenu])
        #expect(forms.map(\.showsDetail) == [true, false, false, false, false, false, false])
        #expect(forms.map(\.showsSettings) == [true, true, true, false, false, false, false])
        #expect(forms.map(\.showsName) == [true, true, true, true, false, false, false])
        #expect(forms.map(\.showsMark) == [true, true, true, true, true, false, false])
        #expect(forms.map(\.showsPromptCacheClock) == [true, true, true, true, true, true, false])
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
        // The narrowest header shows only its kind's mark and menu, so there is no
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

// MARK: - Nested agent ownership

/// The label a run's family gives, through the facts each run reports. Who
/// owns the header in each family shape is `PaneHeaderOwnershipRulesTests`'s.
extension PaneHeaderTests {
    @Test func paneHeaderLabel_activeChildSuppliesItsOwnSettings() throws {
        let fixture = try Self.headerFamilyFixture()
        let session = fixture.session
        let pane = fixture.pane
        let attention = fixture.attention
        let parent = Self.familyRun("parent", launched: 100, observed: 110, pane: pane, bypasses: true)
        let child = Self.familyRun("child", parent: "parent", launched: 101, observed: 120, pane: pane)
        attention.replaceRuntimes([parent, child], kind: .claude)
        let label = attention.paneHeaderLabel(paneID: pane, in: session, locale: Locale(identifier: "en"))
        #expect(label.model == "child")
        #expect(!label.runsWithoutAsking)
    }

    @Test(arguments: [AgentState.running, .finished, .unknown])
    func paneHeaderLabel_parentActivityAfterChildRestoresTheParent(childState: AgentState) throws {
        let fixture = try Self.headerFamilyFixture()
        let session = fixture.session
        let pane = fixture.pane
        let attention = fixture.attention
        let parent = Self.familyRun("parent", launched: 100, observed: 130, pane: pane, bypasses: true)
        let child = Self.familyRun("child", parent: "parent", launched: 101, observed: 120, pane: pane, state: childState)
        attention.replaceRuntimes([child, parent], kind: .claude)
        let label = attention.paneHeaderLabel(paneID: pane, in: session, locale: Locale(identifier: "en"))
        #expect(label.model == "parent")
        #expect(label.runsWithoutAsking)
        #expect(!label.settingsAreAmbiguous)
    }

    @Test func paneHeaderLabel_endedChildReturnsToItsKnownParent() throws {
        let fixture = try Self.headerFamilyFixture()
        let session = fixture.session
        let pane = fixture.pane
        let attention = fixture.attention
        let parent = Self.familyRun("parent", launched: 100, observed: 110, pane: pane, bypasses: true)
        let child = Self.familyRun("child", parent: "parent", launched: 101, observed: 120, pane: pane, state: .unknown)
        attention.replaceRuntimes([parent, child], kind: .claude)
        let label = attention.paneHeaderLabel(paneID: pane, in: session, locale: Locale(identifier: "en"))
        #expect(label.model == "parent")
        #expect(label.runsWithoutAsking)
    }

    @Test func paneHeaderLabel_parentAtAnotherEndpointIsNotAnAncestor() throws {
        let fixture = try Self.headerFamilyFixture()
        let session = fixture.session
        let pane = fixture.pane
        let attention = fixture.attention
        let parent = Self.familyRun("parent", launched: 100, observed: 110, pane: pane, bypasses: true, tmuxPane: "%2")
        let child = Self.familyRun("child", parent: "parent", launched: 101, observed: 120, pane: pane, state: .unknown)
        attention.replaceRuntimes([parent, child], kind: .claude)
        let label = attention.paneHeaderLabel(paneID: pane, in: session, locale: Locale(identifier: "en"))
        #expect(label.model == "parent")
        #expect(label.runsWithoutAsking)
    }

    @Test func ambiguityWarningCountsTowardTheInlineRenameWidth() {
        var label = PaneHeaderLabel(name: "Pane", detail: nil, agentKind: .claude, agentName: "Claude Code")
        label.settingsAreAmbiguous = true
        #expect(label.showsWarning)
        let withoutWarning = PaneHeaderMetrics.inlineRenameMinimumWidth(showsPromptCacheClock: false, showsWarning: false, isZoomed: false)
        let withWarning = PaneHeaderMetrics.inlineRenameMinimumWidth(
            showsPromptCacheClock: false, showsWarning: label.showsWarning, isZoomed: false
        )
        #expect(PaneHeaderRules.renameStyle(headerWidth: withoutWarning, threshold: withWarning) == .floating)
    }

    private struct HeaderFamilyFixture {
        let session: WorkspaceSession
        let pane: UUID
        let attention: AttentionState
    }

    private static func headerFamilyFixture() throws -> HeaderFamilyFixture {
        let (session, tab, _) = WorkspaceSessionFixture.withLooseTab()
        return try HeaderFamilyFixture(session: session, pane: #require(tab.splitTree.allLeafIDs().first), attention: AttentionState())
    }

    private static func familyRun(
        _ id: String,
        parent: String? = nil,
        launched: UInt64,
        observed: UInt64,
        pane: UUID,
        state: AgentState = .running,
        bypasses: Bool = false,
        tmuxPane: String = "%1"
    ) -> AgentRuntimePresentation {
        var badge = Self.badge(state: state, updatedAt: Date(timeIntervalSince1970: 1))
        badge.runLaunchOrder = launched
        badge.runObservedOrder = observed
        badge.parentRunID = parent
        badge.model = id
        badge.permissionMode = bypasses ? "bypassPermissions" : "default"
        return .test(
            runID: id, badge: badge, paneIDs: [pane],
            tmuxLocations: [pane: Self.tmuxLocation(window: "@1", pane: tmuxPane, isActive: true, isVisible: true)]
        )
    }

}
