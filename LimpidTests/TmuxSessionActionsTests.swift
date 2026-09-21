// TmuxSessionActionsTests.swift
// Limpid — the tmux verbs that do not start from a mirror tab: when each one can run, why it cannot, and how the palette says so.

import Foundation
import Testing
@testable import Limpid

@Suite("TmuxSessionActions")
struct TmuxSessionActionsTests {

    // MARK: - New window (D1)

    /// A tab that is not a mirror has no window to open one beside, and the
    /// shortcut is the menu bar's, so it reaches every tab. The reason is
    /// what keeps the keystroke from doing nothing in silence.
    @Test("a tab that is not a mirror says so rather than doing nothing")
    func newWindowObstacle_notAMirrorTab_saysSo() {
        #expect(TmuxSessionActions.newWindowObstacle(
            isMirrorTab: false,
            connection: nil,
            hasLiveMirror: false
        ) == String(localized: "not a tmux tab"))
    }

    @Test("a live mirror can open a window")
    func newWindowObstacle_liveMirror_isEnabled() {
        #expect(TmuxSessionActions.newWindowObstacle(
            isMirrorTab: true,
            connection: .live,
            hasLiveMirror: true
        ) == nil)
    }

    /// The wording the toolbar chip uses for the same item, so a user who
    /// reads one and then the other is not told two things.
    @Test("a mirror without a live connection names the state it is in", arguments: [
        (TmuxTabConnection.connecting, "connecting"),
        (TmuxTabConnection.disconnected, "not connected"),
        (TmuxTabConnection.unreachable, "not connected"),
        (TmuxTabConnection.serverReplaced, "not connected")
    ])
    func newWindowObstacle_notConnected_namesTheState(connection: TmuxTabConnection, expected: String) {
        #expect(TmuxSessionActions.newWindowObstacle(
            isMirrorTab: true,
            connection: connection,
            hasLiveMirror: false
        ) == String(localized: String.LocalizationValue(expected)))
    }

    // MARK: - New session (D2)

    @Test("a tmux a mirror can attach to lets a session be made")
    func newSessionObstacle_supported_isEnabled() {
        let support = AgentTmuxSupport.supported(
            binary: "/opt/homebrew/bin/tmux",
            version: TmuxMirrorTarget.minimumVersion
        )
        #expect(TmuxSessionActions.newSessionObstacle(support: support, hasTmux: true) == nil)
    }

    /// Every answer that rules out mirroring rules out making a session to
    /// mirror, and each one is named apart: a Mac with an old tmux must not
    /// be told it has none.
    @Test("a tmux that cannot be mirrored says which answer it was")
    func newSessionObstacle_unsupported_carriesTheReason() {
        let old = TmuxVersion(major: 2, minor: 8, patch: nil, isDevelopment: false)
        let unsupported = AgentTmuxSupport.unsupported(binary: "/usr/bin/tmux", version: old)
        #expect(TmuxSessionActions.newSessionObstacle(support: unsupported, hasTmux: true)
            == unsupported.reconnectObstacle)
        #expect(TmuxSessionActions.newSessionObstacle(support: .notInstalled, hasTmux: false)
            == String(localized: "no tmux found"))
        // A probe that has not answered yet is no obstacle anywhere else,
        // and a Mac with no tmux at all still has to be told.
        #expect(TmuxSessionActions.newSessionObstacle(support: .pending, hasTmux: false)
            == String(localized: "no tmux found"))
        #expect(TmuxSessionActions.newSessionObstacle(support: .pending, hasTmux: true) == nil)
    }

    @Test("a new session is detached, in the container's directory, in the listing format")
    func newSessionArguments_carryTheDirectoryAndFormat() throws {
        let arguments = TmuxSessionActions.newSessionArguments(
            socketPath: "/tmp/tmux-501/default",
            workingDirectory: URL(fileURLWithPath: "/Users/someone/code")
        )
        #expect(arguments.starts(with: ["-u", "-S", "/tmp/tmux-501/default", "new-session", "-d"]))
        #expect(arguments.contains("-c"))
        #expect(arguments.contains("/Users/someone/code"))
        #expect(try #require(arguments.last) == TmuxMirrorTargetLister.listFormat)
        // Without a directory tmux uses its own default rather than being
        // handed an empty `-c`, which it would refuse.
        let bare = TmuxSessionActions.newSessionArguments(socketPath: "/tmp/s", workingDirectory: nil)
        #expect(!bare.contains("-c"))
    }

    /// The one line either query answers has to parse as a target, or the
    /// tab could not be opened on it.
    @Test("what tmux prints for a new session parses as a target to open")
    func newSessionOutput_parsesAsATarget() throws {
        let line = ["$3", "@7", "%12", "3.5", "4242", "1700000000", "0", "work", "editor"]
            .joined(separator: "\t")
        let target = try #require(TmuxMirrorTargetLister.parse(line, socketPath: "/tmp/s").first)
        #expect(target.binding.sessionID == "$3")
        #expect(target.windowID == "@7")
        #expect(target.activePaneID == "%12")
        #expect(target.displayName == "work:editor")
        #expect(target.isSupported)
    }

    @Test("the session a pane shows is asked for by its id")
    func currentWindowArguments_targetTheSession() {
        let arguments = TmuxSessionActions.currentWindowArguments(socketPath: "/tmp/s", sessionID: "$1")
        #expect(arguments == [
            "-u", "-S", "/tmp/s",
            "display-message", "-p", "-t", "$1", TmuxMirrorTargetLister.listFormat
        ])
    }

    @Test("the default socket is tmux's own")
    func defaultSocketPath_isTheDefaultServer() {
        let path = TmuxSessionActions.defaultSocketPath(
            directory: URL(fileURLWithPath: "/tmp/tmux-501", isDirectory: true)
        )
        #expect(path.hasSuffix("/tmux-501/default"))
    }

    // MARK: - A pane running tmux by hand (D5)

    @Test("only a pane with a resolved client of its own is offered a tab")
    func manualSession_offeredForAResolvedClient() {
        let binding = TmuxBinding(socketPath: "/tmp/s", sessionID: "$1", sessionName: "work")
        #expect(TmuxSessionActions.manualSession(
            isMirrorTab: false,
            isTmuxClient: true,
            binding: binding
        ) == binding)
        // A mirror tab's pane already is a tmux window in a Limpid tab.
        #expect(TmuxSessionActions.manualSession(
            isMirrorTab: true,
            isTmuxClient: true,
            binding: binding
        ) == nil)
        #expect(TmuxSessionActions.manualSession(
            isMirrorTab: false,
            isTmuxClient: false,
            binding: binding
        ) == nil)
        // A client the poll has not placed yet: a tab opened on it could
        // not be filled, so nothing is offered until it answers.
        #expect(TmuxSessionActions.manualSession(
            isMirrorTab: false,
            isTmuxClient: true,
            binding: nil
        ) == nil)
    }
}

// MARK: - The palette's tmux rows

@Suite("TmuxPaletteRows")
@MainActor
struct TmuxPaletteRowTests {
    private static let liveTmux = TmuxPaletteContext(
        hasTmux: true,
        newWindowObstacle: nil,
        newSessionObstacle: nil
    )

    private func items(_ tmux: TmuxPaletteContext, directory: URL) -> [CommandPaletteItem] {
        let (session, _, _) = WindowSessionFixture.withLooseTab()
        return CommandPaletteCatalog.buildItems(
            session: session,
            settings: SettingsStore(directory: directory),
            attention: AttentionState(),
            tmux: tmux
        )
    }

    private func row(_ items: [CommandPaletteItem], _ action: CommandPaletteAction) -> CommandPaletteItem? {
        items.first { $0.id == action.frecencyKey }
    }

    @Test("a Mac with no tmux is offered none of the tmux verbs")
    func rows_withoutTmux_areNotListed() throws {
        try withTempDir { directory in
            let listed = items(.unavailable, directory: directory)
            #expect(row(listed, .newTmuxSession) == nil)
            #expect(row(listed, .showPaneTmuxSession(UUID())) == nil)
            // The window row is a shortcut of the user's, so it stays in the
            // list; what it gains is the reason it cannot run.
            let window = try #require(row(listed, .shortcutAction(.newTmuxWindow)))
            #expect(!window.isEnabled)
            #expect(window.statusLabel == String(localized: "no tmux found"))
        }
    }

    @Test("a disabled window row says why, where the row itself is")
    func newWindowRow_disabled_carriesTheReason() throws {
        try withTempDir { directory in
            var tmux = Self.liveTmux
            tmux.newWindowObstacle = String(localized: "not a tmux tab")
            let window = try #require(row(items(tmux, directory: directory), .shortcutAction(.newTmuxWindow)))
            #expect(!window.isEnabled)
            #expect(window.statusLabel == String(localized: "not a tmux tab"))
        }
    }

    @Test("a mirror tab's window row is enabled and says nothing more")
    func newWindowRow_liveMirror_isEnabled() throws {
        try withTempDir { directory in
            let window = try #require(row(items(Self.liveTmux, directory: directory), .shortcutAction(.newTmuxWindow)))
            #expect(window.isEnabled)
            #expect(window.statusLabel == nil)
        }
    }

    @Test("the new-session row is listed with a tmux and disabled with a reason")
    func newSessionRow_followsTheMacsTmux() throws {
        try withTempDir { directory in
            let enabled = try #require(row(items(Self.liveTmux, directory: directory), .newTmuxSession))
            #expect(enabled.isEnabled)
            #expect(enabled.statusLabel == nil)
            #expect(enabled.category == .actions)

            var tmux = Self.liveTmux
            tmux.newSessionObstacle = String(localized: "needs tmux \(TmuxMirrorTarget.minimumVersion.description) or newer")
            let disabled = try #require(row(items(tmux, directory: directory), .newTmuxSession))
            #expect(!disabled.isEnabled)
            #expect(disabled.statusLabel == tmux.newSessionObstacle)
        }
    }

    /// The row exists only for the pane the user is in, and carries that
    /// pane: the palette is built once, and the row has to act on the pane
    /// it was drawn for.
    @Test("the pane's own session is offered only while that pane runs tmux")
    func showSessionRow_followsTheFocusedPane() throws {
        try withTempDir { directory in
            #expect(row(items(Self.liveTmux, directory: directory), .newTmuxSession) != nil)
            #expect(items(Self.liveTmux, directory: directory).contains { $0.id == "tmux.showPaneSession" } == false)

            let paneID = UUID()
            var tmux = Self.liveTmux
            tmux.manualSessionPaneID = paneID
            tmux.manualSessionName = "work"
            let listed = try #require(row(items(tmux, directory: directory), .showPaneTmuxSession(paneID)))
            #expect(listed.isEnabled)
            #expect(listed.subtitle == "work")
            #expect(listed.action == .showPaneTmuxSession(paneID))
        }
    }
}

@Suite("New tmux session naming")
struct TmuxSessionNameTests {
    @Test func sessionName_usesTheDirectoryName() throws {
        let name = try #require(TmuxSessionActions.sessionName(for: URL(fileURLWithPath: "/Users/x/dev/limpid")))
        #expect(name == "limpid")
    }

    /// tmux reads `.` and `:` as the separators of `session:window.pane`,
    /// so a name carrying either could not be addressed.
    @Test(arguments: [("/tmp/my.project", "my-project"), ("/tmp/a:b", "a-b")])
    func sessionName_replacesWhatTmuxReadsAsASeparator(path: String, expected: String) throws {
        let name = try #require(TmuxSessionActions.sessionName(for: URL(fileURLWithPath: path)))
        #expect(name == expected)
    }

    @Test func newSessionArguments_namesTheSessionAfterTheDirectory() {
        let arguments = TmuxSessionActions.newSessionArguments(
            socketPath: "/tmp/tmux-501/default",
            workingDirectory: URL(fileURLWithPath: "/Users/x/dev/limpid")
        )
        #expect(arguments.contains("-s"))
        #expect(arguments.contains("limpid"))
    }

    /// The retry after tmux refuses a name it already has.
    @Test func newSessionArguments_withoutAName_keepsTheDirectory() {
        let arguments = TmuxSessionActions.newSessionArguments(
            socketPath: "/tmp/tmux-501/default",
            workingDirectory: URL(fileURLWithPath: "/Users/x/dev/limpid"),
            isNamed: false
        )
        #expect(!arguments.contains("-s"))
        #expect(arguments.contains("/Users/x/dev/limpid"))
    }
}
