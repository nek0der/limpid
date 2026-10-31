// TmuxTopology.swift
// Weir — value snapshots of runtime locations and presentation attachments.

import Foundation

struct TmuxRuntimeEndpoint: Hashable {
    let socketPath: String
    let serverPID: String
    let serverStartedAt: String
    let paneID: String
}

struct TmuxPaneLocation: Equatable {
    let socketPath: String
    let serverPID: String
    /// tmux's own `#{start_time}`. What a tmux format compares, so a command
    /// that checks the server generation inside tmux uses this one.
    let serverStartedAt: String
    let sessionID: String
    let windowID: String
    let paneID: String
    let isActive: Bool
    /// Whether the pane is shown in its session's active window, including
    /// splits that do not have input focus. Nil in older observations that
    /// did not report whether another pane was zoomed.
    var isVisible: Bool?
    /// The second the kernel started the server process
    /// (`TmuxClientProbe.processStartSecond`), which is what a run's record
    /// names: its hook reads `ps -o lstart=`, which reports the same value.
    /// tmux sets `#{start_time}` a moment later, after it forks into the
    /// background, so across a second boundary the two differ by one, and
    /// a record compared with `serverStartedAt` would miss its server for
    /// the server's whole life. `nil` when the probe could not read it
    /// (and in fixtures), where `serverStartedAt` stands in.
    var serverProcessStartedAt: String?

    /// The start a run record's `tmuxServerStartedAt` is matched against.
    var recordedServerStart: String {
        serverProcessStartedAt ?? serverStartedAt
    }
}

struct TmuxTopology: Equatable {
    var clients: [String: TmuxBinding] = [:]
    var panes: [TmuxPaneLocation] = []
    /// Built by the I/O collector, never by a parser or a UI lookup.
    var socketAliases: [String: String] = [:]
    var outcomes: [String: TmuxCommandResult] = [:]
    var observedAt: [String: TimeInterval] = [:]

    func socketKey(_ raw: String) -> String {
        socketAliases[raw] ?? raw
    }

    static let paneArguments = [
        "list-panes", "-a", "-F",
        "#{pid}\t#{start_time}\t#{session_id}\t#{window_id}\t#{pane_id}\t#{window_active}\t#{pane_active}\t#{window_zoomed_flag}"
    ]

    static func parsePanes(_ output: String, socketPath: String) -> [TmuxPaneLocation] {
        output.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 7 || fields.count == 8,
                  Int(fields[0]) != nil, Int(fields[1]) != nil,
                  isID(fields[2], prefix: "$"), isID(fields[3], prefix: "@"),
                  isID(fields[4], prefix: "%")
            else { return nil }
            return TmuxPaneLocation(
                socketPath: socketPath,
                serverPID: fields[0], serverStartedAt: fields[1],
                sessionID: fields[2], windowID: fields[3], paneID: fields[4],
                isActive: fields[5] == "1" && fields[6] == "1",
                isVisible: fields.count == 8 ? fields[5] == "1" && (fields[7] != "1" || fields[6] == "1") : nil
            )
        }
    }

    private static func isID(_ value: String, prefix: Character) -> Bool {
        value.first == prefix && !value.dropFirst().isEmpty && value.dropFirst().allSatisfy(\.isNumber)
    }

    /// A pane can belong to several sessions through linked windows. We
    /// resolve current membership rather than freezing the launch session.
    func locations(for endpoint: TmuxRuntimeEndpoint?) -> [TmuxPaneLocation] {
        guard let endpoint else { return [] }
        let socket = socketKey(endpoint.socketPath)
        return panes.filter {
            $0.socketPath == socket
                && $0.serverPID == endpoint.serverPID && $0.recordedServerStart == endpoint.serverStartedAt
                && $0.paneID == endpoint.paneID
        }
    }

    mutating func merge(_ batch: TmuxTopology, candidates: Set<String>, now: TimeInterval) {
        socketAliases = batch.socketAliases
        let expired = Set(observedAt.compactMap { key, stamp in
            !candidates.contains(key) || now - stamp > TmuxTiming.snapshotLifetime ? key : nil
        })
        let replaced = Set(batch.outcomes.keys).union(expired)
        panes.removeAll { replaced.contains($0.socketPath) }
        clients = clients.filter { !replaced.contains($0.value.socketPath) }
        for path in expired {
            outcomes[path] = nil
            observedAt[path] = nil
        }
        panes += batch.panes
        clients.merge(batch.clients) { _, new in new }
        outcomes.merge(batch.outcomes) { _, new in new }
        observedAt.merge(batch.observedAt) { _, new in new }
    }
}
