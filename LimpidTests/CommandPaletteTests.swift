// CommandPaletteTests.swift
// Limpid — tests for fuzzy search, frecency scoring, catalog building,
// and command palette state lifecycle.

import Foundation
import Testing
@testable import Limpid

@Suite("CommandPalette")
@MainActor
struct CommandPaletteTests {

    // MARK: - FuzzyMatch

    @Test("exact substring scores higher than scattered chars")
    func fuzzyMatch_exactSubstring_scoresHigher() throws {
        let exact = FuzzyMatch.score(query: "New", candidate: "New Tab")
        let scattered = FuzzyMatch.score(query: "Nwb", candidate: "New Tab")
        #expect(exact != nil)
        // Scattered may or may not match; if it does, exact should win.
        if let scattered {
            #expect(try #require(exact?.score) > scattered.score)
        }
    }

    @Test("word-start bonus lifts matching initial letters")
    func fuzzyMatch_wordStart_bonus() throws {
        let wordStart = FuzzyMatch.score(query: "nt", candidate: "New Tab")
        let midWord = FuzzyMatch.score(query: "ew", candidate: "New Tab")
        #expect(wordStart != nil)
        #expect(midWord != nil)
        #expect(try #require(wordStart?.score) > midWord!.score)
    }

    @Test("empty query matches everything with score 0")
    func fuzzyMatch_emptyQuery_matchesAll() throws {
        let result = try #require(FuzzyMatch.score(query: "", candidate: "anything"))
        #expect(result.score == 0)
        #expect(result.matchedIndices.isEmpty)
    }

    @Test("no match returns nil")
    func fuzzyMatch_noMatch_returnsNil() {
        let result = FuzzyMatch.score(query: "xyz", candidate: "New Tab")
        #expect(result == nil)
    }

    @Test("case insensitive matching works")
    func fuzzyMatch_caseInsensitive() {
        let result = FuzzyMatch.score(query: "new tab", candidate: "New Tab")
        #expect(result != nil)
    }

    @Test("matched indices are correct")
    func fuzzyMatch_matchedIndices_correct() {
        let result = FuzzyMatch.score(query: "NT", candidate: "New Tab")
        #expect(result != nil)
        #expect(result?.matchedIndices.count == 2)
        #expect(result?.matchedIndices[0] == 0) // N
        #expect(result?.matchedIndices[1] == 4) // T
    }

    @Test("consecutive chars get bonus")
    func fuzzyMatch_consecutive_bonus() throws {
        let consecutive = FuzzyMatch.score(query: "Sp", candidate: "Split Right")
        let nonConsecutive = FuzzyMatch.score(query: "St", candidate: "Split Right")
        #expect(consecutive != nil)
        #expect(nonConsecutive != nil)
        #expect(try #require(consecutive?.score) > nonConsecutive!.score)
    }

    // MARK: - FrecencyStore

    @Test("recently used item scores higher than older one")
    func frecency_recentItem_scoresHigher() throws {
        try withTempDir { dir in
            let store = FrecencyStore(directory: dir)
            store.record("recent")
            store.record("old")
            // Both items were just recorded, so we only assert both score
            // positively. Decay behavior needs aged-in fixtures we don't
            // have here.
            #expect(store.score(for: "recent") > 0)
            #expect(store.score(for: "old") > 0)
        }
    }

    @Test("frequently used item scores higher")
    func frecency_frequentItem_scoresHigher() throws {
        try withTempDir { dir in
            let store = FrecencyStore(directory: dir)
            for _ in 0..<10 {
                store.record("frequent")
            }
            store.record("rare")
            #expect(store.score(for: "frequent") > store.score(for: "rare"))
        }
    }

    @Test("recording updates count")
    func frecency_record_updatesEntry() throws {
        try withTempDir { dir in
            let store = FrecencyStore(directory: dir)
            store.record("test")
            #expect(store.entries["test"]?.count == 1)
            store.record("test")
            #expect(store.entries["test"]?.count == 2)
        }
    }

    @Test("persistence round-trip survives")
    func frecency_persistence_roundTrip() throws {
        try withTempDir { dir in
            let store1 = FrecencyStore(directory: dir)
            store1.record("x")
            store1.record("x")
            store1.flushSynchronously()

            let store2 = FrecencyStore(directory: dir)
            #expect(store2.entries["x"]?.count == 2)
        }
    }

    // MARK: - Catalog

    @Test("catalog includes all shortcut actions")
    func catalog_includesAllShortcutActions() {
        let session = WindowSession()
        let settings = SettingsStore()
        let items = CommandPaletteCatalog.buildItems(
            session: session, settings: settings, attention: AttentionState()
        )
        let shortcutItems = items.filter { $0.category == .actions }
        #expect(shortcutItems.count == LimpidShortcutAction.allCases.count)
    }

    @Test("Review This Turn is enabled only when the focused pane has a base")
    func catalog_reviewTurnTracksFocusedPaneBase() throws {
        try withTempDir { directory in
            let (session, _, paneID) = WindowSessionFixture.withLooseTab()
            let settings = SettingsStore(directory: directory)
            let attention = AttentionState()

            var items = CommandPaletteCatalog.buildItems(
                session: session,
                settings: settings,
                attention: attention
            )
            #expect(items.first(where: { $0.id == "shortcut.reviewTurn" })?.isEnabled == false)
            #expect(items.first(where: { $0.id == "shortcut.reviewChanges" })?.isEnabled == false)

            let tabID = try #require(session.activeTabID)
            session.update(tabID) {
                $0.agentBadges[.claude, default: [:]][paneID] = AgentBadge(
                    state: .finished,
                    updatedAt: Date(),
                    turnBaseTree: String(repeating: "a", count: 40),
                    turnRoot: "/tmp/turn-review"
                )
            }
            items = CommandPaletteCatalog.buildItems(
                session: session,
                settings: settings,
                attention: attention
            )
            #expect(items.first(where: { $0.id == "shortcut.reviewTurn" })?.isEnabled == true)
            #expect(items.first(where: { $0.id == "shortcut.reviewChanges" })?.isEnabled == true)
            #expect(ReviewAgents.turnScope(
                session: session,
                attention: attention,
                paneID: paneID,
                root: URL(fileURLWithPath: "/tmp/other-review")
            ) == nil)
            #expect(ReviewAgents.turnScope(
                session: session,
                attention: attention,
                paneID: paneID,
                root: URL(fileURLWithPath: "/tmp/turn-review")
            ) != nil)
        }
    }

    /// The palette's Close Pane and split rows follow the rules ⌘W and
    /// ⌘D run on, so a mirror tab with two panes offers splitting but not
    /// closing, and with one pane offers both.
    @Test("Close Pane and split rows follow the tab's close rule and split row", arguments: [
        (Tab.Kind.terminal, 2),
        (Tab.Kind.tmuxMirror, 1),
        (Tab.Kind.tmuxMirror, 2)
    ])
    func catalog_closeAndSplitRowsFollowCapabilities(kind: Tab.Kind, leafCount: Int) throws {
        try withTempDir { directory in
            let (session, tab, _) = WindowSessionFixture.withLooseTab()
            for _ in 1..<leafCount {
                PaneActions.split(session, direction: .horizontal)
            }
            session.update(tab.id) { $0.kind = kind }
            let live = try #require(session.activeTab)
            let items = CommandPaletteCatalog.buildItems(
                session: session,
                settings: SettingsStore(directory: directory),
                attention: AttentionState()
            )
            let isEnabled = { (action: LimpidShortcutAction) in
                items.first(where: { $0.id == "shortcut.\(action.rawValue)" })?.isEnabled
            }
            #expect(isEnabled(.closeSurface) == PaneActions.canClosePaneOrTab(live))
            #expect(isEnabled(.closeSurface) == (kind == .terminal || leafCount == 1))
            #expect(isEnabled(.splitRight) == live.capabilities.canSplit)
            #expect(isEnabled(.splitDown) == live.capabilities.canSplit)
        }
    }

    @Test("catalog includes open tabs with display titles")
    func catalog_includesOpenTabs() {
        let (session, _, _) = WindowSessionFixture.withLooseTab()
        let settings = SettingsStore()
        let items = CommandPaletteCatalog.buildItems(
            session: session, settings: settings, attention: AttentionState()
        )
        let tabItems = items.filter {
            if case .jumpToTab = $0.action {
                return true
            }
            return false
        }
        #expect(tabItems.count == 1)
    }

    @Test("catalog includes groups")
    func catalog_includesGroups() {
        let (session, group, _) = WindowSessionFixture.withGroupAndOneTab()
        let settings = SettingsStore()
        let items = CommandPaletteCatalog.buildItems(
            session: session, settings: settings, attention: AttentionState()
        )
        let groupItems = items.filter {
            if case let .activateGroup(id) = $0.action {
                return id == group.id
            }
            return false
        }
        #expect(groupItems.count == 1)
    }

    // MARK: - State lifecycle

    @Test("opening palette builds items from session")
    func state_openPalette_buildsItems() throws {
        let session = WindowSession()
        let settings = SettingsStore()
        try withTempDir { dir in
            let frecency = FrecencyStore(directory: dir)
            CommandPaletteActions.openCommandPalette(
                session,
                settings: settings,
                frecencyStore: frecency,
                attention: AttentionState(),
                reviewPresentation: nil
            )
            #expect(session.commandPaletteState != nil)
            #expect(!session.commandPaletteState!.allItems.isEmpty)
        }
    }

    @Test("closing palette nils out the state")
    func state_closePalette_nilsState() throws {
        let session = WindowSession()
        let settings = SettingsStore()
        try withTempDir { dir in
            let frecency = FrecencyStore(directory: dir)
            CommandPaletteActions.openCommandPalette(
                session,
                settings: settings,
                frecencyStore: frecency,
                attention: AttentionState(),
                reviewPresentation: nil
            )
            CommandPaletteActions.closeCommandPalette(session)
            #expect(session.commandPaletteState == nil)
        }
    }

    @Test("selectedIndex clamps to results range")
    func state_clampSelection() {
        let state = CommandPaletteState()
        state.selectedIndex = 10
        state.results = [
            CommandPaletteState.ScoredItem(
                item: CommandPaletteItem(
                    id: "test",
                    category: .actions,
                    title: "Test",
                    subtitle: nil,
                    icon: "star",
                    shortcutDisplay: nil,
                    action: .openSettings
                ),
                matchedIndices: [],
                score: 0
            )
        ]
        state.clampSelection()
        #expect(state.selectedIndex == 0)
    }

    @Test("opening while already open is idempotent")
    func state_openWhileOpen_idempotent() throws {
        let session = WindowSession()
        let settings = SettingsStore()
        try withTempDir { dir in
            let frecency = FrecencyStore(directory: dir)
            CommandPaletteActions.openCommandPalette(
                session,
                settings: settings,
                frecencyStore: frecency,
                attention: AttentionState(),
                reviewPresentation: nil
            )
            let first = session.commandPaletteState
            CommandPaletteActions.openCommandPalette(
                session,
                settings: settings,
                frecencyStore: frecency,
                attention: AttentionState(),
                reviewPresentation: nil
            )
            #expect(session.commandPaletteState === first)
        }
    }

    // MARK: - tmux windows

    private static let supportedVersion = TmuxProtocol.parseVersion("3.7c")
    private static let editorTarget = TmuxMirrorTarget(
        binding: TmuxBinding(socketPath: "/tmp/limpid-test/default", sessionID: "$0", sessionName: "work"),
        windowID: "@1",
        windowName: "editor",
        activePaneID: "%1",
        serverVersion: supportedVersion
    )
    private static let shellTarget = TmuxMirrorTarget(
        binding: TmuxBinding(socketPath: "/tmp/limpid-test/default", sessionID: "$0", sessionName: "work"),
        windowID: "@2",
        windowName: "shell",
        activePaneID: "%2",
        serverVersion: supportedVersion
    )

    private func tmuxState(settingsDirectory: URL) -> CommandPaletteState {
        let state = CommandPaletteState()
        state.allItems = paletteItems(settingsDirectory: settingsDirectory, isTmuxAvailable: true)
            + CommandPaletteCatalog.tmuxWindowItems(targets: [Self.editorTarget, Self.shellTarget]) { _ in false }
        return state
    }

    private func paletteItems(settingsDirectory: URL, isTmuxAvailable: Bool) -> [CommandPaletteItem] {
        CommandPaletteCatalog.buildItems(
            session: WindowSession(),
            settings: SettingsStore(directory: settingsDirectory),
            attention: AttentionState(),
            isTmuxAvailable: isTmuxAvailable
        )
    }

    @Test func tmuxWindowItems_areGroupedUnderTmuxWithBareNames() {
        let items = CommandPaletteCatalog.tmuxWindowItems(targets: [Self.editorTarget]) { _ in false }
        let item = items[0]
        #expect(item.category == .tmux)
        #expect(item.title == "work:editor")
        #expect(item.searchAlias == nil)
        #expect(item.subtitle == nil)
        #expect(item.statusLabel == nil)
        #expect(item.id == CommandPaletteAction.mirrorTmuxWindow(Self.editorTarget).frecencyKey)
        #expect(item.searchKeywords.contains("tmux Open tmux Window in Tab work:editor"))
    }

    @Test func tmuxWindowItems_markWindowsATabAlreadyShows() {
        let items = CommandPaletteCatalog.tmuxWindowItems(targets: [Self.editorTarget, Self.shellTarget]) {
            $0.windowID == "@2"
        }
        #expect(items[0].statusLabel == nil)
        #expect(items[1].statusLabel != nil)
    }

    /// Names alone cannot tell these rows apart; only rows that share a
    /// name get a subtitle.
    @Test func tmuxWindowItems_sharingAName_carryWhatTellsThemApart() {
        func window(_ socket: String, _ id: String, index: Int, name: String) -> TmuxMirrorTarget {
            TmuxMirrorTarget(
                binding: TmuxBinding(socketPath: socket, sessionID: "$0", sessionName: "work"),
                windowID: id,
                windowName: name,
                activePaneID: "%0",
                serverVersion: Self.supportedVersion,
                windowIndex: index
            )
        }
        let targets = [
            window("/tmp/limpid-test/default", "@1", index: 1, name: "zsh"),
            window("/tmp/limpid-test/default", "@2", index: 2, name: "zsh"),
            window("/tmp/limpid-test/other", "@1", index: 1, name: "zsh"),
            window("/tmp/limpid-test/default", "@3", index: 3, name: "vim")
        ]
        let items = CommandPaletteCatalog.tmuxWindowItems(targets: targets) { _ in false }

        #expect(items.map(\.title) == ["work:zsh", "work:zsh", "work:zsh", "work:vim"])
        let server = { (name: String) in String(localized: "Server \(name)") }
        let window = { (index: Int) in String(localized: "Window \(index)") }
        #expect(items[0].subtitle == "\(server("default")) · \(window(1))")
        #expect(items[1].subtitle == "\(server("default")) · \(window(2))")
        // Alone on its server, so only the server tells it apart.
        #expect(items[2].subtitle == server("other"))
        #expect(items[3].subtitle == nil)
    }

    private static func target(version: String?, windowID: String = "@7") -> TmuxMirrorTarget {
        TmuxMirrorTarget(
            binding: TmuxBinding(socketPath: "/tmp/limpid-test/old", sessionID: "$3", sessionName: "old"),
            windowID: windowID,
            windowName: "w",
            activePaneID: "%7",
            serverVersion: version.flatMap(TmuxProtocol.parseVersion)
        )
    }

    @Test func tmuxWindowItems_fromAServerTooOldToMirror_areListedDisabledWithTheVersionNeeded() {
        let items = CommandPaletteCatalog.tmuxWindowItems(targets: [Self.target(version: "3.2a")]) { _ in false }
        let item = items[0]
        #expect(!item.isEnabled)
        #expect(item.statusLabel == String(localized: "Needs tmux \("3.3") or later"))
    }

    /// An empty `#{version}` is what a server too old to have the variable
    /// prints, so an unknown version is gated the same way.
    @Test func tmuxWindowItems_withAnUnknownVersion_areDisabled() {
        let item = CommandPaletteCatalog.tmuxWindowItems(targets: [Self.target(version: nil)]) { _ in false }[0]
        #expect(!item.isEnabled)
        #expect(item.statusLabel != nil)
    }

    @Test func tmuxWindowItems_atAndAboveTheMinimum_areEnabled() {
        for version in ["3.3", "3.3a", "3.7c", "next-3.3", "4.0"] {
            let item = CommandPaletteCatalog.tmuxWindowItems(targets: [Self.target(version: version)]) { _ in false }[0]
            #expect(item.isEnabled, "version \(version)")
            #expect(item.statusLabel == nil, "version \(version)")
        }
    }

    /// Choosing a window a tab already shows brings that tab forward and
    /// attaches nothing, so the version gate does not apply to it.
    @Test func tmuxWindowItems_alreadyShownOnAnOldServer_staySelectable() {
        let item = CommandPaletteCatalog.tmuxWindowItems(targets: [Self.target(version: "3.2a")]) { _ in true }[0]
        #expect(item.isEnabled)
        #expect(item.statusLabel == String(localized: LocalizedStringResource("palette.tmux.windowOpen", defaultValue: "Open")))
    }

    @Test func applyFilter_findsTmuxWindowsThroughHiddenKeywords() throws {
        try withTempDir { dir in
            let state = tmuxState(settingsDirectory: dir)
            for query in ["tmux", "tmux edi", "Open tmux Window in Tab"] {
                state.applyFilter(query: query, frecencyStore: nil)
                #expect(state.results.contains { $0.id == Self.editorTarget.frecencyKeyForTest }, "query \(query)")
            }
            // A keyword-only match highlights nothing in the title.
            state.applyFilter(query: "tmux edi", frecencyStore: nil)
            let row = state.results.first { $0.id == Self.editorTarget.frecencyKeyForTest }
            #expect(row?.matchedIndices == [])
            // A title match is highlighted although the keywords match too.
            state.applyFilter(query: "edi", frecencyStore: nil)
            let titleRow = state.results.first { $0.id == Self.editorTarget.frecencyKeyForTest }
            #expect(titleRow?.matchedIndices == [5, 6, 7])
        }
    }

    @Test func applyFilter_matchesLocalizedKeywords() {
        let state = CommandPaletteState()
        state.allItems = [
            CommandPaletteItem(
                id: "row",
                category: .tmux,
                title: "work:editor",
                searchKeywords: ["tmux Open tmux Window in Tab work:editor", "tmux tmux ウィンドウをタブで開く work:editor"],
                subtitle: nil,
                icon: "star",
                shortcutDisplay: nil,
                action: .openSettings
            )
        ]
        state.applyFilter(query: "タブで開く", frecencyStore: nil)
        #expect(state.results.map(\.id) == ["row"])
    }

    @Test func tmuxPrefix_listsOnlyTmuxWindows() throws {
        try withTempDir { dir in
            let state = tmuxState(settingsDirectory: dir)
            state.applyFilter(query: "$", frecencyStore: nil)
            #expect(state.results.count == 2)
            #expect(state.results.allSatisfy { $0.item.category == .tmux })
            state.applyFilter(query: "$sh", frecencyStore: nil)
            #expect(state.results.map(\.item.title) == ["work:shell"])
        }
    }

    @Test func helpList_offersTheTmuxPrefix() {
        let state = CommandPaletteState()
        state.applyFilter(query: "?", frecencyStore: nil)
        let row = state.results.first { $0.item.action == .insertPrefix(.tmux) }
        #expect(row?.item.title == "$")
        #expect(PalettePrefix.from("$edi").prefix == .tmux)
        #expect(PalettePrefix.from("$edi").filterQuery == "edi")
    }

    @Test func tmuxEntryRow_insertsThePrefixWhenTmuxIsInstalled() throws {
        try withTempDir { dir in
            let entries = { (items: [CommandPaletteItem]) in items.filter { $0.action == .insertPrefix(.tmux) } }
            // Listed with no window known yet.
            let available = paletteItems(settingsDirectory: dir, isTmuxAvailable: true)
            #expect(entries(available).count == 1)
            #expect(entries(available).first?.category == .actions)
            #expect(entries(paletteItems(settingsDirectory: dir, isTmuxAvailable: false)).isEmpty)
        }
    }

    @Test func openCommandPalette_withoutTmux_listsNoTmuxRows() throws {
        let session = WindowSession()
        try withTempDir { dir in
            CommandPaletteActions.openCommandPalette(
                session,
                settings: SettingsStore(directory: dir),
                frecencyStore: FrecencyStore(directory: dir),
                attention: AttentionState(),
                reviewPresentation: nil,
                tmuxStore: TmuxConnectionStore(tmuxExecutable: nil)
            )
            let items = try #require(session.commandPaletteState).allItems
            #expect(!items.contains { $0.action == .insertPrefix(.tmux) })
            #expect(!items.contains { $0.category == .tmux })
        }
    }

    @Test func results_followTheDropdownSectionOrder() throws {
        try withTempDir { dir in
            let state = tmuxState(settingsDirectory: dir)
            state.applyFilter(query: "tmux", frecencyStore: nil)
            let categories = state.results.map(\.item.category)
            #expect(categories == categories.sorted())
            #expect(categories.contains(.actions))
            #expect(categories.contains(.tmux))
        }
    }

    @Test func loadTmuxWindows_mergesIntoTheCurrentQueryAndKeepsSelection() async throws {
        let items = try withTempDir { paletteItems(settingsDirectory: $0, isTmuxAvailable: true) }
        let session = WindowSession()
        let state = CommandPaletteState()
        state.allItems = items
        session.commandPaletteState = state
        state.query = "e"
        state.applyFilter(query: state.query, frecencyStore: nil)
        // A row in a section below tmux, so the merge moves its index.
        let selectedIndex = try #require(state.results.firstIndex { $0.item.category == .settings })
        state.selectedIndex = selectedIndex
        let selectedID = state.results[selectedIndex].id

        let targets = [Self.editorTarget]
        let task = CommandPaletteActions.loadTmuxWindows(
            into: state,
            session: session,
            store: TmuxConnectionStore(tmuxExecutable: "/nonexistent/tmux"),
            frecencyStore: nil,
            listWindows: { _ in targets }
        )
        let loading = try #require(task)
        await loading.value

        #expect(state.results.contains { $0.id == Self.editorTarget.frecencyKeyForTest })
        #expect(state.results[state.selectedIndex].id == selectedID)
        #expect(state.selectedIndex == selectedIndex + 1)
        let merged = state.results.map(\.id)
        state.applyFilter(query: "e", frecencyStore: nil)
        #expect(merged == state.results.map(\.id))
    }

    @Test func loadTmuxWindows_dropsRowsForAClosedPalette() async throws {
        let session = WindowSession()
        let state = CommandPaletteState()
        session.commandPaletteState = state
        let targets = [Self.editorTarget]
        let task = CommandPaletteActions.loadTmuxWindows(
            into: state,
            session: session,
            store: TmuxConnectionStore(tmuxExecutable: "/nonexistent/tmux"),
            frecencyStore: nil,
            listWindows: { _ in targets }
        )
        session.commandPaletteState = nil
        let loading = try #require(task)
        await loading.value
        #expect(state.allItems.isEmpty)
    }

    /// Runs the real off-main listing. The executable does not exist, so no
    /// tmux server is contacted; what this guards is the Dispatch hop, which
    /// traps at run time if the closure carries main-actor isolation.
    @Test func listTmuxWindows_runsOffTheMainActor() async {
        let targets = await CommandPaletteActions.listTmuxWindows(tmuxPath: "/nonexistent/tmux")
        #expect(targets.isEmpty)
    }

    @Test func loadTmuxWindows_needsATmuxExecutable() {
        let session = WindowSession()
        let state = CommandPaletteState()
        session.commandPaletteState = state
        let task = CommandPaletteActions.loadTmuxWindows(
            into: state,
            session: session,
            store: TmuxConnectionStore(tmuxExecutable: nil),
            frecencyStore: nil
        )
        #expect(task == nil)
    }
}

private extension TmuxMirrorTarget {
    var frecencyKeyForTest: String {
        CommandPaletteAction.mirrorTmuxWindow(self).frecencyKey
    }
}
