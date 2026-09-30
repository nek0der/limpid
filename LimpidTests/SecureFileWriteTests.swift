// SecureFileWriteTests.swift
// Limpid — pins where an unreadable file is moved and that its bytes
// survive the move.

import Foundation
import Testing
@testable import Limpid

struct SecureFileWriteTests {
    @Test func quarantine_movesTheFileAsideWithReasonAndTime() throws {
        try withTempDir { dir in
            let file = dir.appendingPathComponent("state.json")
            try Data("not json".utf8).write(to: file)
            let backup = SecureFileWrite.quarantine(
                file,
                reason: "decode-failed",
                now: Date(timeIntervalSince1970: 1_790_000_000)
            )
            #expect(backup?.lastPathComponent == "state.json.bak-decode-failed-1790000000")
            #expect(!FileManager.default.fileExists(atPath: file.path))
            let moved = try #require(backup)
            let bytes = try Data(contentsOf: moved)
            #expect(bytes == Data("not json".utf8))
        }
    }

    @Test func quarantine_missingFile_doesNothing() throws {
        try withTempDir { dir in
            let file = dir.appendingPathComponent("settings.json")
            #expect(SecureFileWrite.quarantine(file, reason: "init-failure") == nil)
            let entries = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            #expect(entries.isEmpty)
        }
    }

    @MainActor @Test func moveSettingsFileAside_leavesNoSettingsFileBehind() throws {
        try withTempDir { dir in
            let file = dir.appendingPathComponent("settings.json")
            try Data("{}".utf8).write(to: file)
            SettingsStore.moveSettingsFileAside(at: file)
            let entries = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            #expect(entries.count == 1)
            #expect(entries.first?.hasPrefix("settings.json.bak-init-failure-") == true)
        }
    }
}
