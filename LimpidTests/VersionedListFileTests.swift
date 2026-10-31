// VersionedListFileTests.swift
// Limpid — the small versioned list files: what they read, and how they leave the disk.

import Foundation
import OSLog
import Testing
@testable import Limpid

@Suite("VersionedListFile")
struct VersionedListFileTests {
    private let file = VersionedListFile<NamesDocument>(
        schemaVersion: 2,
        label: "test names",
        log: Logger.limpid("test.versioned-list")
    )

    @Test("a list written reads back, under the key its document names")
    func write_readsBackUnderDocumentKey() throws {
        try withTempDir { root in
            let url = root.appendingPathComponent("nested/names.json")
            #expect(file.write(["a", "b"], to: url))
            #expect(file.read(url) == ["a", "b"])
            let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            #expect(object["schemaVersion"] as? Int == 2)
            #expect(object["names"] as? [String] == ["a", "b"])
        }
    }

    @Test("an empty list removes the file")
    func write_emptyRemovesFile() throws {
        try withTempDir { root in
            let url = root.appendingPathComponent("names.json")
            #expect(file.write(["a"], to: url))
            #expect(FileManager.default.fileExists(atPath: url.path))
            #expect(file.write([], to: url))
            #expect(!FileManager.default.fileExists(atPath: url.path))
            #expect(file.write([], to: url), "nothing to remove is not a failure")
        }
    }

    @Test("a missing, unreadable, or other-version file holds nothing")
    func read_unusableFileIsEmpty() throws {
        try withTempDir { root in
            let url = root.appendingPathComponent("names.json")
            #expect(file.read(url).isEmpty)
            try Data("not json".utf8).write(to: url)
            #expect(file.read(url).isEmpty)
            try Data(#"{"schemaVersion": 3, "names": ["a"]}"#.utf8).write(to: url)
            #expect(file.read(url).isEmpty)
        }
    }

    /// The two files already on people's disks: a renamed key would read
    /// every one of them as empty.
    @Test("the hint and deletion files keep the keys they were written with")
    func files_keepTheirKeys() throws {
        try withTempDir { root in
            let hints = root.appendingPathComponent(AgentForgottenHintFile.fileName)
            let pane = UUID()
            try Data(#"""
            {"schemaVersion": 1, "hints": [{"provider": "claude", "pane": "\#(pane.uuidString)", "sessionID": "S"}]}
            """#.utf8).write(to: hints)
            #expect(AgentForgottenHintFile.read(hints) == [AgentForgottenHint(provider: "claude", pane: pane, sessionID: "S")])

            let turns = root.appendingPathComponent(TurnDeletionFile.fileName)
            try Data(#"""
            {"schemaVersion": 1, "turns": [{"turnId": "t1", "directory": "/d"}]}
            """#.utf8).write(to: turns)
            #expect(TurnDeletionFile.read(turns).map(\.turnID) == ["t1"])
        }
    }
}

/// A list file of the tests' own, under a key of its own.
private struct NamesDocument: VersionedListDocument {
    var schemaVersion: Int
    var elements: [String]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case elements = "names"
    }
}
