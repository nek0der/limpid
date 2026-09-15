// AgentRecordFixtures.swift
// Limpid — writes and reads the agent record files the projection watches.
//
// The hooks own the on-disk shape and the Rust rules own its meaning, so
// production carries no Swift model of a record any more. The suites below
// still need to put one on disk to drive a projection pass, and a few need to
// read back what a hook just wrote. These types are that, and only that: a
// test-side transcription of the record the hooks emit, deliberately kept
// outside `Limpid` so nobody mistakes it for a second authority on the shape.

import Foundation
@testable import Limpid

/// One agent lifecycle record, as `limpid-agent-hook` writes it.
///
/// A single type covers both providers: their records were structurally
/// identical, and the fields only one of them populates are optional here the
/// same way they are absent there.
struct AgentStateRecordFixture: Codable, Equatable {
    var schemaVersion: Int = 3
    var runId: String?
    var revision: Int?
    var stateEpisodeToken: String?
    var paneId: String
    var state: String
    var detail: String?
    var runStartedAt: String?
    var updatedAt: String
    var lastHookEvent: String?
    var contextTokens: Int?
    var pid: String?
    var lastPrompt: String?
    var turnBaseTree: String?
    var turnRoot: String?
    var firstPrompt: String?
    var sessionId: String?
    var providerSessionTitle: String?
    var providerGeneratedTitle: String?
    var sessionStartedAt: String?
    var killedByLimpidAt: String?
    var resumeAttemptedAt: String?
    var isTmuxHosted: Bool?
    var tmuxSocketPath: String?
    var tmuxSessionId: String?
    var tmuxPaneId: String?
    var tmuxServerPID: String?
    var tmuxServerStartedAt: String?

    /// The record's file name stem: its run id when it has one, and its launch
    /// pane id otherwise. Matches how the hook names the file and how
    /// `AgentCommandExecutor` addresses it.
    var storageID: String {
        if let runId, UUID(uuidString: runId) != nil {
            return runId.uppercased()
        }
        return paneId.uppercased()
    }

    /// The tmux endpoint this record names, or nil when it is not complete
    /// enough to match a live server against.
    var tmuxEndpoint: TmuxRuntimeEndpoint? {
        guard let socket = tmuxSocketPath, let serverPID = tmuxServerPID,
              let start = tmuxServerStartedAt, !start.isEmpty, let pane = tmuxPaneId
        else { return nil }
        return TmuxRuntimeEndpoint(
            socketPath: socket,
            serverPID: serverPID,
            serverStartedAt: start,
            paneID: pane
        )
    }
}

/// One resume hint, as the hook writes it beside the lifecycle record.
struct AgentSessionHintFixture: Codable, Equatable {
    var schemaVersion: Int = 1
    var paneId: String
    var sessionId: String
    var cwd: String
    var updatedAt: String
    var lastHookEvent: String?
    var runId: String?
}

/// Reads and writes a provider's record directories the way the hooks do.
enum AgentRecordFixtures {

    // MARK: - Lifecycle records

    /// Writes `record` into `directory` under the name its storage id gives
    /// it, creating the directory when it is not there yet.
    static func write(_ record: AgentStateRecordFixture, to directory: URL) throws {
        try ensureDirectory(directory)
        try encoder.encode(record).write(
            to: directory.appendingPathComponent("\(record.storageID).state.json")
        )
    }

    /// Every well-formed record in `directory`. A file whose name does not
    /// parse as `<uuid>.state.json`, or whose payload disagrees with its own
    /// name, is skipped, so a partial write or a misnamed file cannot be read
    /// as a record.
    static func records(in directory: URL) -> [AgentStateRecordFixture] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.compactMap { name in
            guard name.hasSuffix(".state.json"), !name.hasPrefix(".") else { return nil }
            let stem = String(name.dropLast(".state.json".count))
            guard UUID(uuidString: stem) != nil,
                  let data = try? Data(contentsOf: directory.appendingPathComponent(name)),
                  let record = try? decoder.decode(AgentStateRecordFixture.self, from: data),
                  record.storageID == stem
            else { return nil }
            return record
        }
    }

    /// The newest record launched from `paneID`. A pane can own several runs,
    /// so the most recently updated one wins deterministically.
    static func record(forPaneID paneID: UUID, in directory: URL) -> AgentStateRecordFixture? {
        let pane = paneID.uuidString
        return records(in: directory)
            .filter { $0.paneId.caseInsensitiveCompare(pane) == .orderedSame }
            .max { $0.updatedAt < $1.updatedAt }
    }

    // MARK: - Resume hints

    static func write(_ hint: AgentSessionHintFixture, to directory: URL) throws {
        try ensureDirectory(directory)
        try encoder.encode(hint).write(
            to: directory.appendingPathComponent("\(hint.paneId).json")
        )
    }

    static func hint(forPaneID paneID: UUID, in directory: URL) -> AgentSessionHintFixture? {
        let url = directory.appendingPathComponent("\(paneID.uuidString).json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(AgentSessionHintFixture.self, from: data)
    }

    // MARK: - Reading what a hook wrote

    /// Decodes a file at `url` as the record type named, for the cases that
    /// run a real hook and then assert on the fields it produced.
    static func decode<Record: Decodable>(_: Record.Type, at url: URL) throws -> Record {
        try decoder.decode(Record.self, from: Data(contentsOf: url))
    }

    // MARK: - Internal

    private static func ensureDirectory(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private static let decoder = PersistenceCoders.makeDecoder()

    private static let encoder: JSONEncoder = {
        let encoder = PersistenceCoders.makeEncoder()
        encoder.outputFormatting.insert(.sortedKeys)
        return encoder
    }()
}
