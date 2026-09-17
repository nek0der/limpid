// AgentMirrorRequest.swift
// Limpid — a shim's request to show, as a mirror tab, the agent it started in our tmux server.

import Foundation

/// What a shim leaves behind after starting an agent in a detached session
/// of this build's agent server: which session, window, and pane the agent
/// runs in, and which leaf id it was given. The app opens a mirror tab on it
/// (`TmuxMirrorActions.openAgentMirror`), and `AgentMirrorRequestWatcher`
/// is what reads the files.
///
/// One JSON object per file, in the directory the pane's environment names
/// (`directoryVariable`). The shim writes it under a hidden name in that
/// directory and renames it to `<leafID>.json`, so the watcher only ever
/// sees a complete file; anything hidden or not ending in `.json` is left
/// alone. The file is private to the user (mode 0600, as the shim's umask
/// 077 makes it). Version 1:
///
/// ```json
/// {
///   "version": 1,
///   "socket": "/private/tmp/tmux-501/limpid-dev.limpid.Limpid",
///   "sessionID": "$3",
///   "sessionName": "limpid-1a2b3c4d-4242",
///   "windowID": "@3",
///   "paneID": "%3",
///   "serverPID": "4100",
///   "serverStartedAt": "1758130000",
///   "leafID": "6F1C…",
///   "launchPaneID": "0B7D…",
///   "provider": "claude"
/// }
/// ```
///
/// `socket`, `sessionID`, `windowID`, `paneID`, `serverPID`, and
/// `serverStartedAt` are the six fields of the one tab-separated line
/// `new-session -d -P -F` prints for `#{socket_path}`, `#{session_id}`,
/// `#{window_id}`, `#{pane_id}`, `#{pid}` and `#{start_time}`, all as JSON
/// strings. `sessionName` is the name the shim gave `-s`, which is why it
/// is not read back from tmux. `leafID` is the `LIMPID_PANE_ID` the shim
/// gave the agent with `new-session -e`, and `launchPaneID` the
/// `LIMPID_PANE_ID` of the pane the user typed the command in. `provider` is
/// a provider id (`AgentKind`). Unknown keys are ignored.
struct AgentMirrorRequest: Equatable {
    /// Normalized (`TmuxClientProbe.normalizeSocketPath`), as every binding's
    /// path is, so the tab keys its connection the way the palette and the
    /// presence probe do.
    let socketPath: String
    let sessionID: String
    let sessionName: String
    let windowID: String
    let paneID: String
    let serverPID: String
    let serverStartedAt: String
    /// The id the mirror tab's only leaf takes, the same one the agent's
    /// records carry as their pane.
    let leafID: UUID
    /// The pane the agent was started from. The new tab is placed beside
    /// the tab holding it.
    let launchPaneID: UUID
    let provider: AgentKind

    /// The variable a pane's environment names the directory in. Set only
    /// on panes told to host their agents in tmux.
    static let directoryVariable = "LIMPID_AGENT_MIRROR_REQUESTS_DIR"
    static let formatVersion = 1
    /// A request larger than this is not one a shim wrote.
    static let byteLimit = 16 * 1024

    /// Under the build's own support directory, whose name already differs
    /// between a Release and a Debug build, so each build only ever reads
    /// the requests its own panes wrote. Shared by every provider.
    static func defaultDirectory() -> URL {
        LimpidPaths.applicationSupportDirectory()
            .appendingPathComponent("agent-mirror-requests", isDirectory: true)
    }

    /// The session as a binding records it, with the server run the
    /// request names, so a reconnect after a relaunch can tell the server
    /// is still the one the agent was started on.
    var binding: TmuxBinding {
        var binding = TmuxBinding(socketPath: socketPath, sessionID: sessionID, sessionName: sessionName)
        binding.serverPID = serverPID
        binding.serverStartedAt = serverStartedAt
        return binding
    }

    /// Why a file was not taken as a request.
    enum Rejection: Error, Equatable {
        case notJSON
        case unsupportedVersion(Int)
        /// The socket is not this build's agent server.
        case foreignSocket
        case malformedField(String)
        case unknownProvider(String)
    }

    private struct Wire: Decodable {
        let version: Int
        let socket: String
        let sessionID: String
        let sessionName: String
        let windowID: String
        let paneID: String
        let serverPID: String
        let serverStartedAt: String
        let leafID: String
        let launchPaneID: String
        let provider: String
    }

    /// Reads and checks one request. `ownSocketName` is this build's agent
    /// socket name; a request naming any other socket is refused, because
    /// the file only says where to attach, and attaching a tab to a server
    /// the user did not choose is what the palette's other-clients check
    /// exists to prevent. Every id is checked for the shape tmux gives it,
    /// since they are spliced into tmux commands, and the server run for
    /// being numbers, since the reattach condition splices those into a
    /// format.
    static func parse(_ data: Data, ownSocketName: String) throws(Rejection) -> AgentMirrorRequest {
        let wire: Wire
        do {
            wire = try JSONDecoder().decode(Wire.self, from: data)
        } catch {
            throw .notJSON
        }
        guard wire.version == formatVersion else { throw .unsupportedVersion(wire.version) }
        guard let socket = TmuxSocketPath(wire.socket)?.value else { throw .malformedField("socket") }
        let socketName = URL(fileURLWithPath: socket).lastPathComponent
        guard PaneShellEnvironment.isAgentSocketName(socketName), socketName == ownSocketName else {
            throw .foreignSocket
        }
        try requireID(wire.sessionID, sigil: "$", field: "sessionID")
        try requireID(wire.windowID, sigil: "@", field: "windowID")
        try requireID(wire.paneID, sigil: "%", field: "paneID")
        try requireNumber(wire.serverPID, field: "serverPID")
        try requireNumber(wire.serverStartedAt, field: "serverStartedAt")
        guard !wire.sessionName.isEmpty,
              !wire.sessionName.unicodeScalars.contains(where: { $0.properties.generalCategory == .control })
        else { throw .malformedField("sessionName") }
        guard let leafID = UUID(uuidString: wire.leafID) else { throw .malformedField("leafID") }
        guard let launchPaneID = UUID(uuidString: wire.launchPaneID) else { throw .malformedField("launchPaneID") }
        guard let provider = AgentKind(rawValue: wire.provider) else { throw .unknownProvider(wire.provider) }
        return AgentMirrorRequest(
            socketPath: socket,
            sessionID: wire.sessionID,
            sessionName: wire.sessionName,
            windowID: wire.windowID,
            paneID: wire.paneID,
            serverPID: wire.serverPID,
            serverStartedAt: wire.serverStartedAt,
            leafID: leafID,
            launchPaneID: launchPaneID,
            provider: provider
        )
    }

    /// `$3`, `@12`, `%0`: the sigil, then decimal digits only.
    private static func requireID(_ value: String, sigil: Character, field: String) throws(Rejection) {
        guard value.first == sigil, isDecimal(value.dropFirst()) else { throw .malformedField(field) }
    }

    private static func requireNumber(_ value: String, field: String) throws(Rejection) {
        guard isDecimal(Substring(value)), UInt64(value) != nil else { throw .malformedField(field) }
    }

    private static func isDecimal(_ value: Substring) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { $0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9") }
    }
}
