// TmuxRecording.swift
// Limpid — one recorded case under `LimpidTests/Fixtures/tmux`, for the suites that replay real control-mode traffic.

import Foundation
import Testing

/// A case (`session-basic`, `bulk-output`) as one dated directory holds it.
/// Suites take `TmuxRecording.all(_:)` as their arguments, so a recording
/// added under a new date is read by every test of its case, and the older
/// ones keep being read: users update tmux and Limpid at different times.
struct TmuxRecording: Sendable, CustomTestStringConvertible {
    /// `<schema-date>/<case>`, relative to the fixtures directory.
    let name: String
    let directory: URL

    /// What the recorder wrote next to `control.raw`. The values tmux
    /// chooses per run (the version, and for `bulk-output` how much of the
    /// stream is kept) are read from here rather than pinned in a test,
    /// so recording the case again does not break the tests.
    struct Manifest: Decodable {
        let tmuxVersion: String
        /// `bulk-output` only: what an independent decoder of `control.raw`
        /// counted, the `%output` lines and their unescaped payload bytes.
        let outputLines: Int?
        let decodedBytes: Int?

        /// `3.7c` for `tmux 3.7c`: the form `#{version}` prints.
        var version: String {
            String(tmuxVersion.split(separator: " ").last ?? "")
        }
    }

    var testDescription: String {
        name
    }

    /// Every dated recording of `fixtureCase`, oldest first. Empty outside
    /// a checkout; the suites that read these are not meaningful there.
    static func all(_ fixtureCase: String) -> [TmuxRecording] {
        guard let root = RepoFixture.limpidRoot?.appendingPathComponent("LimpidTests/Fixtures/tmux", isDirectory: true),
              let dates = try? FileManager.default.contentsOfDirectory(atPath: root.path)
        else { return [] }
        return dates.sorted().compactMap { date in
            let directory = root.appendingPathComponent(date, isDirectory: true)
                .appendingPathComponent(fixtureCase, isDirectory: true)
            let raw = directory.appendingPathComponent("control.raw")
            guard FileManager.default.fileExists(atPath: raw.path) else { return nil }
            return TmuxRecording(name: "\(date)/\(fixtureCase)", directory: directory)
        }
    }

    func bytes() throws -> [UInt8] {
        try Array(Data(contentsOf: directory.appendingPathComponent("control.raw")))
    }

    /// Every line of `control.raw`, without newlines, in order.
    func lines() throws -> [[UInt8]] {
        var lines = try bytes().split(separator: 0x0A, omittingEmptySubsequences: false).map(Array.init)
        if lines.last?.isEmpty == true {
            lines.removeLast()
        }
        return lines
    }

    /// The recorders write snake_case keys (`tmux_version`).
    func manifest() throws -> Manifest {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Manifest.self, from: Data(contentsOf: directory.appendingPathComponent("manifest.json")))
    }
}
