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

    @Test func writeAtomic_overAWorldReadableFile_leavesItUserOnly() throws {
        try withTempDir { dir in
            let file = dir.appendingPathComponent("state.json")
            try Data("old".utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
            try SecureFileWrite.writeAtomic(Data("new".utf8), to: file)
            let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
            #expect(mode == 0o600)
            #expect(try Data(contentsOf: file) == Data("new".utf8))
        }
    }
}
