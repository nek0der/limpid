// TmuxTopology.swift
// Limpid — value snapshots of runtime locations and presentation attachments.

import Foundation

struct TmuxRuntimeEndpoint: Hashable {
    let socketPath: String
    let serverPID: String
    let serverStartedAt: String
    let paneID: String

    /// The same endpoint with its socket in the one spelling we compare.
    ///
    /// The probe's aliases come first because they were resolved off the
    /// main actor; a socket the probe has not seen yet, such as one only a
    /// mirror tab names, is resolved here. Both sides of any comparison go
    /// through this, so `/tmp` and `/private/tmp` meet in one key.
    func canonical(aliases: [String: String]) -> TmuxRuntimeEndpoint {
        TmuxRuntimeEndpoint(
            socketPath: aliases[socketPath] ?? TmuxClientProbe.normalizeSocketPath(socketPath),
            serverPID: serverPID,
            serverStartedAt: serverStartedAt,
            paneID: paneID
        )
    }
}

struct TmuxPaneLocation: Equatable {
    let socketPath: String
    let serverPID: String
    let serverStartedAt: String
    let sessionID: String
    let windowID: String
    let paneID: String
    let isActive: Bool
}

/// What a probe found on one socket, when it found something conclusive.
///
/// A command that fails says nothing by itself: the server may be wedged or
/// the socket unreadable. Only a missing or refused socket says no server
/// runs, and only a full listing says which server run does
/// (`TmuxSessionProbe.isServerAbsent` draws the same line for a client that
/// lost its session).
enum TmuxServerPresence: Equatable {
    case absent
    case running(pid: String, startedAt: String)
}

struct TmuxTopology: Equatable {
    var clients: [String: TmuxBinding] = [:]
    var panes: [TmuxPaneLocation] = []
    /// Built by the I/O collector, never by a parser or a UI lookup.
    var socketAliases: [String: String] = [:]
    var outcomes: [String: TmuxCommandResult] = [:]
    /// Per socket, as the last probe of it concluded. A socket the probe
    /// could not answer for has no entry rather than a guess.
    var servers: [String: TmuxServerPresence] = [:]
    var observedAt: [String: TimeInterval] = [:]

    func socketKey(_ raw: String) -> String {
        socketAliases[raw] ?? raw
    }

    static let paneArguments = [
        "list-panes", "-a", "-F",
        "#{pid}\t#{start_time}\t#{session_id}\t#{window_id}\t#{pane_id}\t#{window_active}\t#{pane_active}"
    ]

    static func parsePanes(_ output: String, socketPath: String) -> [TmuxPaneLocation] {
        output.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 7,
                  Int(fields[0]) != nil, Int(fields[1]) != nil,
                  isID(fields[2], prefix: "$"), isID(fields[3], prefix: "@"),
                  isID(fields[4], prefix: "%")
            else { return nil }
            return TmuxPaneLocation(
                socketPath: socketPath,
                serverPID: fields[0], serverStartedAt: fields[1],
                sessionID: fields[2], windowID: fields[3], paneID: fields[4],
                isActive: fields[5] == "1" && fields[6] == "1"
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
                && $0.serverPID == endpoint.serverPID && $0.serverStartedAt == endpoint.serverStartedAt
                && $0.paneID == endpoint.paneID
        }
    }

    /// Whether the tmux behind `endpoint` is gone, as far as the last probe
    /// of its socket could tell.
    ///
    /// Three findings say so, and nothing else does: no server answers on the
    /// socket, another server run answers there (pane ids start again with
    /// each server, so the endpoint names nothing on it), and the recorded
    /// server no longer listing the pane. A socket the probe could not answer
    /// for says nothing, and an endpoint that records no server run cannot be
    /// told apart from a later one, so neither is called gone.
    func isGone(_ endpoint: TmuxRuntimeEndpoint) -> Bool {
        switch servers[socketKey(endpoint.socketPath)] {
        case .absent:
            true
        case let .running(pid, startedAt):
            if endpoint.serverPID.isEmpty || endpoint.serverStartedAt.isEmpty {
                false
            } else if pid != endpoint.serverPID || startedAt != endpoint.serverStartedAt {
                true
            } else {
                locations(for: endpoint).isEmpty
            }
        case nil:
            false
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
        for path in replaced {
            // Including the sockets this batch visited: what it concluded
            // about them replaces what it concluded before, and a socket it
            // could not answer for this time has no conclusion at all.
            servers[path] = nil
        }
        for path in expired {
            outcomes[path] = nil
            observedAt[path] = nil
        }
        panes += batch.panes
        clients.merge(batch.clients) { _, new in new }
        outcomes.merge(batch.outcomes) { _, new in new }
        servers.merge(batch.servers) { _, new in new }
        observedAt.merge(batch.observedAt) { _, new in new }
    }
}
