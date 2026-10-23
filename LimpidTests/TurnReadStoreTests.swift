// TurnReadStoreTests.swift
// Limpid — the turns read, kept across launches in turn-reads.json.

import Foundation
import Testing
@testable import Limpid

@MainActor
@Suite("Turn read store")
struct TurnReadStoreTests {
    private static func mark(_ id: String, tree: String? = nil) -> TurnReadStore.Mark {
        TurnReadStore.Mark(turnID: TurnID(id), endTree: tree)
    }

    private func file(in dir: URL) -> URL {
        dir.appendingPathComponent("turn-reads.json")
    }

    @Test func readTurns_stayReadAcrossALaunch() throws {
        try withTempDir { dir in
            let store = TurnReadStore(directory: dir)
            store.markRead([Self.mark("a"), Self.mark("b")])
            store.flushSynchronously()

            let relaunched = TurnReadStore(directory: dir)

            #expect(relaunched.isRead(Self.mark("a")))
            #expect(relaunched.isRead(Self.mark("b")))
            #expect(!relaunched.isRead(Self.mark("c")))
        }
    }

    @Test func aMark_isSavedWithoutAFlush() async throws {
        // The debounced save, as the app relies on between launches.
        try await withTempDir { dir in
            let store = TurnReadStore(directory: dir)
            store.markRead([Self.mark("a")])

            await pollUntil(interval: .milliseconds(20)) { TurnReadStore(directory: dir).isRead(Self.mark("a")) }

            #expect(TurnReadStore(directory: dir).isRead(Self.mark("a")))
        }
    }

    @Test func aMark_lastsUntilItsTurnIsForgotten() throws {
        try withTempDir { dir in
            // However old: a kept record (the newest of a conversation) stays
            // read for as long as it is shown.
            let store = TurnReadStore(directory: dir, now: { Date(timeIntervalSince1970: 0) })
            store.markRead([Self.mark("old"), Self.mark("gone")])
            store.forget([TurnID("gone")])
            store.flushSynchronously()

            let relaunched = TurnReadStore(directory: dir)

            #expect(relaunched.isRead(Self.mark("old")))
            #expect(!relaunched.isRead(Self.mark("gone")))
        }
    }

    @Test func readingATurnAgain_keepsWhenItWasFirstRead() throws {
        try withTempDir { dir in
            var clock = Date(timeIntervalSince1970: 100)
            let store = TurnReadStore(directory: dir, now: { clock })
            store.markRead([Self.mark("a")])
            clock = Date(timeIntervalSince1970: 200)
            store.markRead([Self.mark("a")])

            #expect(store.reads["a"] == Date(timeIntervalSince1970: 100))
        }
    }

    @Test func aRunThatMayNotWrite_keepsReadsInMemoryOnly() throws {
        try withTempDir { dir in
            let store = TurnReadStore(directory: dir, writesFiles: false)
            store.markRead([Self.mark("a")])
            store.flushSynchronously()

            #expect(store.isRead(Self.mark("a")))
            #expect(!FileManager.default.fileExists(atPath: file(in: dir).path))
        }
    }

    @Test func aNewerBuildsFile_isReadButNotRewritten() throws {
        try withTempDir { dir in
            let newer = Data(#"{"schemaVersion":2,"reads":{"a":"2026-10-12T00:00:00Z"},"more":true}"#.utf8)
            try newer.write(to: file(in: dir))
            let store = TurnReadStore(directory: dir)

            store.markRead([Self.mark("b")])
            store.flushSynchronously()

            #expect(store.isRead(Self.mark("a")))
            #expect(try Data(contentsOf: file(in: dir)) == newer)
        }
    }

    @Test func aNewerBuildsFileOfAnotherShape_isLeftAsItIs() throws {
        try withTempDir { dir in
            let newer = Data(#"{"schemaVersion":3,"reads":[{"turn":"a"}]}"#.utf8)
            try newer.write(to: file(in: dir))
            let store = TurnReadStore(directory: dir)

            store.markRead([Self.mark("b")])
            store.flushSynchronously()

            #expect(store.isRead(Self.mark("b")), "marked in memory")
            #expect(try Data(contentsOf: file(in: dir)) == newer)
        }
    }

    @Test func aDamagedFile_costsItsMarksOnly() throws {
        try withTempDir { dir in
            try Data("{".utf8).write(to: file(in: dir))
            let store = TurnReadStore(directory: dir)

            store.markRead([Self.mark("a")])
            store.flushSynchronously()

            #expect(TurnReadStore(directory: dir).isRead(Self.mark("a")), "written afresh")
        }
    }

    @Test func aTurnEndedAgainAtAnotherTree_isNoLongerRead() throws {
        // Work after the stop is folded into the turn under the same ID:
        // what it changed has not been seen.
        try withTempDir { dir in
            let store = TurnReadStore(directory: dir)
            store.markRead([Self.mark("a", tree: "tree-1")])

            #expect(store.isRead(Self.mark("a", tree: "tree-1")))
            #expect(!store.isRead(Self.mark("a", tree: "tree-2")))
            #expect(!store.isRead(Self.mark("a", tree: nil)), "nor at an end not taken")
            store.flushSynchronously()
            #expect(!TurnReadStore(directory: dir).isRead(Self.mark("a", tree: "tree-2")), "and after a relaunch")
        }
    }

    @Test func aTurnReadAgainAtItsNewEnd_isReadAnew() throws {
        try withTempDir { dir in
            var clock = Date(timeIntervalSince1970: 100)
            let store = TurnReadStore(directory: dir, now: { clock })
            store.markRead([Self.mark("a", tree: "tree-1")])
            clock = Date(timeIntervalSince1970: 200)
            store.markRead([Self.mark("a", tree: "tree-2")])

            #expect(store.isRead(Self.mark("a", tree: "tree-2")))
            #expect(!store.isRead(Self.mark("a", tree: "tree-1")))
            #expect(store.reads["a"] == Date(timeIntervalSince1970: 200))
        }
    }

    @Test func aMarkFromAFileWithoutEnds_standsForAnyEnd_untilReadAgain() throws {
        try withTempDir { dir in
            try Data(#"{"schemaVersion":1,"reads":{"a":"2026-10-12T00:00:00Z"}}"#.utf8).write(to: file(in: dir))
            let store = TurnReadStore(directory: dir)

            #expect(store.isRead(Self.mark("a", tree: "tree-1")))
            store.markRead([Self.mark("a", tree: "tree-1")])

            #expect(store.reads["a"] == ISO8601DateFormatter().date(from: "2026-10-12T00:00:00Z"), "keeps when it was read")
            #expect(!store.isRead(Self.mark("a", tree: "tree-2")), "held to the end it was read at from now on")
        }
    }
}
