// TmuxDirectoryTests.swift
// Limpid — what the sidebar's tmux directory lists, and which of its actions are offered.

import Foundation
import Testing
@testable import Limpid

/// What a test's lister answers with, so one test can change the answer
/// between two passes. Unchecked because the test drives both sides on the
/// main actor and the closure only reads what the test has written.
private final class Listing: @unchecked Sendable {
    var targets: [TmuxMirrorTarget]

    init(targets: [TmuxMirrorTarget]) {
        self.targets = targets
    }
}

struct TmuxDirectoryTests {
    private static let serverDirectory = URL(fileURLWithPath: "/tmp/tmux-501", isDirectory: true)

    private static func target(
        session: String = "work",
        sessionID: String = "$0",
        window: String,
        windowID: String,
        index: Int? = 0,
        socket: String = "/tmp/tmux-501/default"
    ) -> TmuxMirrorTarget {
        TmuxMirrorTarget(
            binding: TmuxBinding(socketPath: socket, sessionID: sessionID, sessionName: session),
            windowID: windowID,
            windowName: window,
            activePaneID: "%0",
            serverVersion: TmuxProtocol.parseVersion("3.5"),
            windowIndex: index
        )
    }

    // MARK: - Grouping

    @Test func sessions_groupWindowsBySocketAndSessionID() throws {
        let sessions = TmuxDirectory.sessions(
            from: [
                Self.target(session: "work", sessionID: "$0", window: "editor", windowID: "@0", index: 0),
                Self.target(session: "work", sessionID: "$0", window: "server", windowID: "@1", index: 1),
                Self.target(session: "notes", sessionID: "$1", window: "zsh", windowID: "@2", index: 0)
            ],
            serverDirectory: Self.serverDirectory
        )

        #expect(sessions.count == 2)
        // By name: "notes" before "work".
        #expect(sessions.map(\.name) == ["notes", "work"])
        let work = try #require(sessions.last)
        #expect(work.key == TmuxConnectionStore.Key(socketPath: "/tmp/tmux-501/default", sessionID: "$0"))
        #expect(work.windows.map(\.label) == ["work:editor", "work:server"])
        #expect(work.serverLabel == nil)
    }

    /// One session id per server, so the same id on two sockets is two
    /// sessions rather than one with both servers' windows.
    @Test func sessions_tellTwoServersApartByTheirSocket() {
        let sessions = TmuxDirectory.sessions(
            from: [
                Self.target(session: "work", sessionID: "$0", window: "editor", windowID: "@0"),
                Self.target(session: "work", sessionID: "$0", window: "editor", windowID: "@0", socket: "/tmp/tmux-501/build")
            ],
            serverDirectory: Self.serverDirectory
        )

        #expect(sessions.count == 2)
        #expect(Set(sessions.compactMap(\.serverLabel)) == ["build"])
    }

    @Test func sessions_orderWindowsByTheirTmuxIndex() {
        let sessions = TmuxDirectory.sessions(
            from: [
                Self.target(window: "third", windowID: "@9", index: 3),
                Self.target(window: "first", windowID: "@2", index: 1),
                Self.target(window: "second", windowID: "@5", index: 2)
            ],
            serverDirectory: Self.serverDirectory
        )

        #expect(sessions.first?.windows.map(\.label) == ["work:first", "work:second", "work:third"])
    }

    // MARK: - Agent servers (D6)

    @Test func sessions_leaveLimpidsOwnAgentServersOut() {
        let agentSocket = "/tmp/tmux-501/\(PaneShellEnvironment.defaultAgentSocketName())"
        let sessions = TmuxDirectory.sessions(
            from: [
                Self.target(session: "limpid-agent", window: "claude", windowID: "@0", socket: agentSocket),
                Self.target(session: "work", window: "editor", windowID: "@1")
            ],
            serverDirectory: Self.serverDirectory
        )

        #expect(sessions.map(\.name) == ["work"])
    }

    // MARK: - Duplicate window names (D9)

    @Test func sessions_numberWindowsThatShareAName() {
        let sessions = TmuxDirectory.sessions(
            from: [
                Self.target(window: "zsh", windowID: "@0", index: 0),
                Self.target(window: "zsh", windowID: "@1", index: 4),
                Self.target(window: "editor", windowID: "@2", index: 5)
            ],
            serverDirectory: Self.serverDirectory
        )

        #expect(sessions.first?.windows.map(\.label) == ["work:zsh (0)", "work:zsh (4)", "work:editor"])
    }

    /// A window tmux listed without a number keeps its name alone: the
    /// number is what would tell it apart, and there is none to add.
    @Test func sessions_leaveANamelessDuplicateAsItIs() {
        let sessions = TmuxDirectory.sessions(
            from: [
                Self.target(window: "zsh", windowID: "@0", index: nil),
                Self.target(window: "zsh", windowID: "@1", index: nil)
            ],
            serverDirectory: Self.serverDirectory
        )

        #expect(sessions.first?.windows.map(\.label) == ["work:zsh", "work:zsh"])
    }

    // MARK: - Server labels (decision M7)

    @Test func serverLabel_namesOnlyWhatTheUserNamed() {
        #expect(TmuxDirectory.serverLabel(
            socketPath: "/tmp/tmux-501/default",
            serverDirectory: Self.serverDirectory
        ) == nil)
        #expect(TmuxDirectory.serverLabel(
            socketPath: "/tmp/tmux-501/build",
            serverDirectory: Self.serverDirectory
        ) == "build")
        #expect(TmuxDirectory.serverLabel(
            socketPath: "/var/folders/xyz/limpid.sock",
            serverDirectory: Self.serverDirectory
        ) == "/var/folders/xyz/limpid.sock")
    }

    // MARK: - The window limit

    @MainActor
    @Test func visibleWindows_holdBackEverythingPastTheLimitUntilAsked() async throws {
        let targets = (0..<11).map { number in
            Self.target(window: "w\(number)", windowID: "@\(number)", index: number)
        }
        let model = TmuxDirectoryModel(tmuxPath: "/usr/bin/tmux") { _ in targets }
        await model.refresh()
        let session = try #require(model.sessions.first)

        #expect(model.visibleWindows(of: session).count == TmuxDirectory.windowLimit)
        #expect(model.hiddenWindowCount(of: session) == 3)

        model.showEveryWindow(session)
        #expect(model.visibleWindows(of: session).count == 11)
        #expect(model.hiddenWindowCount(of: session) == 0)
    }

    @MainActor
    @Test func refresh_forgetsTheOpenStateOfASessionThatIsGone() async throws {
        let listing = Listing(targets: [Self.target(window: "editor", windowID: "@0")])
        let model = TmuxDirectoryModel(tmuxPath: "/usr/bin/tmux") { _ in listing.targets }
        await model.refresh()
        let session = try #require(model.sessions.first)
        model.toggleExpanded(session)
        #expect(model.isExpanded(session))

        listing.targets = []
        await model.refresh()
        #expect(model.sessions.isEmpty)
        #expect(model.expandedSessionIDs.isEmpty)
    }

    @MainActor
    @Test func refresh_withoutATmuxListsNothingAndSaysSo() async {
        let model = TmuxDirectoryModel(tmuxPath: nil) { _ in [Self.target(window: "editor", windowID: "@0")] }
        await model.refresh()

        #expect(!model.hasTmux)
        #expect(!model.hasListed)
        #expect(model.sessions.isEmpty)
    }
}

/// What the directory offers on a session row. The row is a value, so each
/// rule is checked without a store or a tmux.
struct TmuxDirectorySessionRowTests {
    private static func row(
        state: TmuxStatePresentation? = nil,
        windowCount: Int = 3,
        shownWindowCount: Int = 0,
        tabCount: Int = 0,
        canReconnect: Bool = false,
        tmuxObstacle: String? = nil
    ) -> TmuxDirectorySessionRow {
        TmuxDirectorySessionRow(
            state: state,
            windowCount: windowCount,
            shownWindowCount: shownWindowCount,
            tabCount: tabCount,
            canReconnect: canReconnect,
            tmuxObstacle: tmuxObstacle
        )
    }

    @Test func sessionNoTabShows_offersOnlyWhatTmuxCanDo() {
        let row = Self.row()

        #expect(row.isEnabled(.newWindow))
        #expect(row.isEnabled(.openAll))
        #expect(row.isEnabled(.quitSession))
        #expect(!row.isEnabled(.reconnect))
        #expect(!row.isEnabled(.closeTabs))
        #expect(row.obstacle(for: .closeTabs) == row.obstacle(for: .reconnect))
    }

    @Test func everyWindowOpen_rulesOutOpeningThemAgain() {
        let row = Self.row(windowCount: 2, shownWindowCount: 2, tabCount: 2)

        #expect(!row.isEnabled(.openAll))
        #expect(row.isEnabled(.closeTabs))
    }

    @Test func aTabThatCanConnectAgain_offersReconnect() {
        let row = Self.row(state: .disconnected, shownWindowCount: 1, tabCount: 1, canReconnect: true)

        #expect(row.isEnabled(.reconnect))
        #expect(row.needsAttention)
    }

    @Test func aLiveTab_hasNothingToReconnectAndNoStateToShow() {
        let row = Self.row(shownWindowCount: 1, tabCount: 1)

        #expect(!row.isEnabled(.reconnect))
        #expect(row.obstacle(for: .reconnect) == String(localized: "nothing to reconnect"))
        #expect(!row.needsAttention)
    }

    /// A Mac whose tmux cannot be used says so on every item that would
    /// have to ask tmux, rather than offering them and failing.
    @Test func anUnusableTmux_disablesEveryItemThatWouldAskIt() {
        let row = Self.row(tabCount: 1, canReconnect: true, tmuxObstacle: "no tmux found")

        for item in TmuxDirectorySessionRow.Item.allCases where item != .closeTabs {
            #expect(row.obstacle(for: item) == "no tmux found")
        }
        // Closing tabs is Limpid's own doing and needs no tmux.
        #expect(row.isEnabled(.closeTabs))
    }
}

/// The generation guard on the two commands that destroy something in
/// tmux.
@MainActor
struct TmuxDirectoryKillTests {
    @Test func guarded_checksTheServerRunTheDirectoryListed() {
        var binding = TmuxBinding(socketPath: "/tmp/s", sessionID: "$3", sessionName: "work")
        binding.serverPID = "4242"
        binding.serverStartedAt = "1789000000"

        let arguments = TmuxMirrorActions.guarded("kill-session", target: "$3", binding: binding)

        #expect(arguments.prefix(4) == ["if-shell", "-F", "-t", "$3"])
        #expect(arguments[4] == "#{&&:#{==:#{pid},4242},#{==:#{start_time},1789000000}}")
        #expect(arguments[5] == "kill-session -t '$3'")
    }

    /// A server too old to report `#{pid}` is asked plainly, which is what
    /// every other path does with such a server.
    @Test func guarded_withoutARecordedGeneration_runsTheCommandAsItIs() {
        let binding = TmuxBinding(socketPath: "/tmp/s", sessionID: "$3", sessionName: "work")

        #expect(TmuxMirrorActions.guarded("kill-window", target: "@7", binding: binding) == ["kill-window", "-t", "@7"])
    }
}
