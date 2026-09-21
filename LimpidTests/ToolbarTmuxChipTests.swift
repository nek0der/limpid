// ToolbarTmuxChipTests.swift
// Limpid — what the toolbar chip says about a mirror tab, which of its actions apply, and when a dropped keystroke is worth a notice.

import Foundation
import Testing
@testable import Limpid

private let supportedTmux = AgentTmuxSupport.supported(
    binary: "/opt/homebrew/bin/tmux",
    version: TmuxMirrorTarget.minimumVersion
)

private func chip(
    connection: TmuxTabConnection?,
    hasMirror: Bool = true,
    issues: TmuxTabIssues? = nil,
    canReconnect: Bool = false,
    tmuxSupport: AgentTmuxSupport = supportedTmux,
    origin: Tab.MirrorOrigin = .user
) -> ToolbarTmuxChipContent {
    ToolbarTmuxChipContent.make(
        connection: connection,
        hasMirror: hasMirror,
        issues: issues,
        canReconnect: canReconnect,
        tmuxSupport: tmuxSupport,
        names: .init(windowName: "editor", sessionName: "work", agentName: "Claude", origin: origin)
    )
}

@Suite("toolbar tmux chip text")
struct ToolbarTmuxChipTextTests {
    /// At rest the chip is identity and nothing else: that the tab mirrors
    /// is said by the chip being there, and the widest form has no state to
    /// add.
    @Test func connected_namesTheWindowAtEveryWidth() {
        let content = chip(connection: .live)
        #expect(content.isAtRest)
        #expect(content.stateText == nil)
        #expect(content.text(.full) == "tmux · work:editor")
        #expect(content.text(.identity) == "tmux · work:editor")
        #expect(content.text(.symbolOnly) == "")
        // The narrowest form draws no words, so the tooltip carries them.
        #expect(content.fullText == "tmux · work:editor")
    }

    @Test func disconnected_addsTheStateToTheWidestFormOnly() {
        let content = chip(connection: .disconnected, canReconnect: true)
        let state = String(localized: TmuxStatePresentation.disconnected.title)
        #expect(content.text(.full) == "tmux · work:editor, \(state)")
        #expect(content.text(.identity) == "tmux · work:editor")
        #expect(content.text(.symbolOnly) == "")
        #expect(content.fullText == content.text(.full))
    }

    /// D6: an agent's user is not told about tmux, and never shown the
    /// session name Limpid made up for the run.
    @Test func agentTab_namesTheAgentAndNotTmux() {
        let content = chip(connection: .live, origin: .agent)
        #expect(content.text(.full) == "Claude")
        #expect(content.text(.identity) == "Claude")
        #expect(!content.showsTmuxPrefix)
    }

    @Test func agentTab_keepsTheStateWhenThereIsOne() {
        let content = chip(connection: .disconnected, canReconnect: true, origin: .agent)
        #expect(content.text(.full) == "Claude, \(String(localized: TmuxStatePresentation.disconnected.title))")
        #expect(content.text(.identity) == "Claude")
    }

    /// What a live tab's mirror warns about reaches the chip the same way it
    /// reaches the tab's row, from one table.
    @Test func liveTabWithAWarning_showsIt() {
        let content = chip(connection: .live, issues: TmuxTabIssues(hasDroppedOutput: true))
        #expect(content.state == .droppedOutput)
        #expect(!content.isAtRest)
        #expect(content.isConnected)
    }

    /// A Mac with no tmux to reconnect with says so rather than saying the
    /// connection merely ended, as the tab's row does.
    @Test func tmuxMissing_saysSoInsteadOfDisconnected() {
        let content = chip(connection: .disconnected, tmuxSupport: .notInstalled)
        #expect(content.state == .tmuxUnavailable(.notInstalled))
    }
}

@Suite("toolbar tmux chip menu")
struct ToolbarTmuxChipMenuTests {
    private let needsConnection: [ToolbarTmuxChipContent.Item] = [.newWindow, .otherClients, .quitWindow]

    @Test func connected_offersEverythingButReconnect() {
        let content = chip(connection: .live)
        for item in needsConnection {
            #expect(content.isEnabled(item), "\(item) should apply while connected")
        }
        #expect(!content.isEnabled(.reconnect))
        #expect(content.obstacle(for: .reconnect) == String(localized: "already connected"))
    }

    @Test func disconnected_offersOnlyReconnectAndClose() {
        let content = chip(connection: .disconnected, canReconnect: true)
        for item in needsConnection {
            #expect(!content.isEnabled(item))
            #expect(content.obstacle(for: item) == String(localized: "not connected"))
        }
        #expect(content.isEnabled(.reconnect))
    }

    /// A reconnect on its way is not one to start again, and nothing can be
    /// asked of tmux until it answers.
    @Test func connecting_offersNothingButClose() {
        let content = chip(connection: .connecting)
        for item in ToolbarTmuxChipContent.Item.allCases where item != .closeTab {
            #expect(!content.isEnabled(item))
            #expect(content.obstacle(for: item) == String(localized: "connecting"))
        }
    }

    /// The panes of a replaced server are history: there is nothing left to
    /// connect to, and the reason says so rather than blaming this Mac.
    @Test func serverReplaced_saysThereIsNothingToConnectTo() {
        let content = chip(connection: .serverReplaced)
        #expect(!content.isEnabled(.reconnect))
        #expect(content.obstacle(for: .reconnect) == String(localized: "nothing left to connect to"))
    }

    /// The same rule the Pane menu's item follows: a Mac whose tmux rules a
    /// reconnect out says which of the three answers it gave.
    @Test func tmuxTooOld_trailsReconnectWithTheReason() throws {
        let version = try #require(TmuxProtocol.parseVersion("3.2a"))
        let support = AgentTmuxSupport.unsupported(binary: "/usr/bin/tmux", version: version)
        let content = chip(connection: .disconnected, canReconnect: false, tmuxSupport: support)
        #expect(content.obstacle(for: .reconnect) == support.reconnectObstacle)
    }

    /// Closing the tab is Limpid's own, and never depends on tmux.
    @Test(arguments: [TmuxTabConnection.live, .connecting, .disconnected, .unreachable, .serverReplaced])
    func closeTab_alwaysApplies(connection: TmuxTabConnection) {
        #expect(chip(connection: connection).isEnabled(.closeTab))
    }

    /// The state's own words head the menu whenever the tab is not live, so
    /// the disabled items are read against an explanation.
    @Test func notConnected_carriesTheExplanation() {
        #expect(chip(connection: .disconnected, canReconnect: true).message != nil)
        #expect(chip(connection: .serverReplaced).message != nil)
        #expect(chip(connection: .live).message == nil)
    }
}

/// At launch every restored mirror tab connects at once, so the chip holds a
/// connect back until it has lasted long enough to be news.
@Suite("toolbar tmux chip connecting delay")
struct ToolbarTmuxChipConnectingTests {
    @Test func connecting_isHeldBackUntilTheWaitHasPassed() {
        #expect(ToolbarTmuxChip.visibleState(.connecting, showsConnecting: false) == nil)
        #expect(ToolbarTmuxChip.visibleState(.connecting, showsConnecting: true) == .connecting)
    }

    /// Only connecting waits: every other state is either rare or lasting.
    @Test(arguments: [
        TmuxStatePresentation.disconnected,
        .unreachable,
        .serverReplaced,
        .mirroring(windowName: "editor")
    ])
    func otherStates_appearAtOnce(state: TmuxStatePresentation) {
        #expect(ToolbarTmuxChip.visibleState(state, showsConnecting: false) == state)
    }

    @Test func theWait_isAboutASecond() {
        #expect(ToolbarTmuxChip.connectingDelay == .seconds(1))
    }

    @Test func theNotice_staysAboutThreeSeconds() {
        #expect(TmuxDroppedInputNotice.duration == .seconds(3))
    }
}

/// Typing into a pane whose mirror cannot carry it is dropped without a
/// word, so the store records that it happened and the pane area says so
/// once.
@Suite("tmux dropped input")
@MainActor
struct TmuxDroppedInputTests {
    private func store() -> TmuxConnectionStore {
        TmuxConnectionStore(registry: RecordingSurfaceRegistry(), secureInput: nil, tmuxExecutable: nil)
    }

    @Test func typingWithNoMirror_isRecorded() {
        let store = store()
        let paneID = UUID()
        #expect(store.droppedInput == nil)
        store.sendText(Array("ls".utf8), paneID: paneID)
        #expect(store.droppedInput == TmuxConnectionStore.DroppedInput(paneID: paneID, count: 1))
    }

    /// The count is what a notice already on screen watches: typing on
    /// restarts its wait rather than letting it expire mid-sentence.
    @Test func typingOn_raisesTheCount() {
        let store = store()
        let paneID = UUID()
        store.sendText(Array("l".utf8), paneID: paneID)
        store.sendText(Array("s".utf8), paneID: paneID)
        #expect(store.droppedInput?.count == 2)
    }

    /// Nothing typed, nothing to say: a key event that translates to no
    /// input at all never reached tmux to begin with.
    @Test func emptyInput_saysNothing() {
        let store = store()
        store.sendText([], paneID: UUID())
        #expect(store.droppedInput == nil)
    }
}
