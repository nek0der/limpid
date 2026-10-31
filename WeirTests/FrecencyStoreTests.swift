// FrecencyStoreTests.swift
// Weir — the palette's frecency: how often and how lately a row was used, kept on disk for a month.

import Foundation
import Testing
@testable import Weir

@Suite("FrecencyStore")
@MainActor
struct FrecencyStoreTests {
    /// Writes `entries` where the store in `dir` reads them.
    private static func write(_ entries: [String: FrecencyStore.Entry], to dir: URL) throws {
        let data = try PersistenceCoders.makeEncoder().encode(entries)
        try data.write(to: dir.appendingPathComponent("frecency.json"))
    }

    @Test("demo mode ranks in memory and neither reads nor writes the file")
    func demoMode_touchesNoFile() throws {
        try withTempDir { dir in
            let real = FrecencyStore(directory: dir)
            real.record("mine")
            real.flushSynchronously()
            let file = dir.appendingPathComponent("frecency.json")
            let onDisk = try Data(contentsOf: file)

            let demo = FrecencyStore(directory: dir, writesFiles: false)
            #expect(demo.score(for: "mine") == 0, "the person's ranking stays out of a demo")
            demo.record("demo")
            demo.flushSynchronously()
            #expect(demo.score(for: "demo") > 0)
            #expect(try Data(contentsOf: file) == onDisk)
        }
    }

    @Test("an item used lately scores higher than one used as often, longer ago")
    func recentItem_scoresHigher() throws {
        try withTempDir { dir in
            try Self.write([
                "recent": FrecencyStore.Entry(count: 1, lastUsed: Date().addingTimeInterval(-60 * 60)),
                "old": FrecencyStore.Entry(count: 1, lastUsed: Date().addingTimeInterval(-7 * 24 * 60 * 60))
            ], to: dir)

            let store = FrecencyStore(directory: dir)

            #expect(store.score(for: "old") > 0)
            #expect(store.score(for: "recent") > store.score(for: "old"))
        }
    }

    @Test("frequently used item scores higher")
    func frequentItem_scoresHigher() throws {
        try withTempDir { dir in
            let store = FrecencyStore(directory: dir)
            for _ in 0..<10 {
                store.record("frequent")
            }
            store.record("rare")
            #expect(store.score(for: "frequent") > store.score(for: "rare"))
        }
    }

    @Test("recording updates count")
    func record_updatesEntry() throws {
        try withTempDir { dir in
            let store = FrecencyStore(directory: dir)
            store.record("test")
            #expect(store.entries["test"]?.count == 1)
            store.record("test")
            #expect(store.entries["test"]?.count == 2)
        }
    }

    @Test("persistence round-trip survives")
    func persistence_roundTrip() throws {
        try withTempDir { dir in
            let store1 = FrecencyStore(directory: dir)
            store1.record("x")
            store1.record("x")
            store1.flushSynchronously()

            let store2 = FrecencyStore(directory: dir)
            #expect(store2.entries["x"]?.count == 2)
        }
    }

    @Test("entries unused for a month are dropped on load")
    func load_evictsStaleEntries() throws {
        try withTempDir { dir in
            // Keys are per-object identities that nothing removes when the
            // object goes away, so the store's own age bound is what keeps
            // frecency.json from growing for the life of the install.
            try Self.write([
                "tab.gone": FrecencyStore.Entry(count: 9, lastUsed: Date().addingTimeInterval(-40 * 24 * 60 * 60)),
                "tab.live": FrecencyStore.Entry(count: 1, lastUsed: Date().addingTimeInterval(-24 * 60 * 60))
            ], to: dir)

            let store = FrecencyStore(directory: dir)

            #expect(store.entries["tab.gone"] == nil)
            #expect(store.entries["tab.live"]?.count == 1)
        }
    }
}
