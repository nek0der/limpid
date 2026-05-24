// NotificationHistoryStoreTests.swift
// In-memory behaviour of the notification history store: ordering,
// unread bookkeeping, pane-scoped mark-read, capacity ceiling, and
// per-id delete. Each test injects an isolated temporary directory
// via `init(directory:)` so the production `~/Library/Application
// Support/Limpid/notifications.json` is never touched — a previous
// version of these tests called the no-arg `init()` and `clearAll()`,
// which deleted real user history on every test run.

import Foundation
import Testing
@testable import Limpid

@Suite("NotificationHistoryStore")
@MainActor
struct NotificationHistoryStoreTests {

    // MARK: - Helpers

    /// Build a `NotificationEntry` with sensible defaults so each test
    /// can specify only the fields it cares about.
    private func entry(
        id: UUID = UUID(),
        kind: NotificationEntry.Kind = .desktop,
        timestamp: Date = Date(),
        paneID: UUID? = nil,
        tabTitleSnapshot: String? = nil,
        containerLabel: String? = nil,
        title: String = "title",
        body: String = "body",
        exitCode: Int? = nil,
        durationSeconds: Double? = nil,
        isRead: Bool = false
    ) -> NotificationEntry {
        NotificationEntry(
            id: id,
            kind: kind,
            timestamp: timestamp,
            paneID: paneID,
            tabTitleSnapshot: tabTitleSnapshot,
            containerLabel: containerLabel,
            title: title,
            body: body,
            exitCode: exitCode,
            durationSeconds: durationSeconds,
            isRead: isRead
        )
    }

    /// Build a store backed by a fresh temporary directory. Caller
    /// must call this from inside `withTempDir` so the URL is
    /// cleaned up after the test. Returning the store keeps every
    /// test body terse: one line vs. an inner closure each.
    private func makeStore(in dir: URL) -> NotificationHistoryStore {
        NotificationHistoryStore(directory: dir)
    }

    // MARK: - record / ordering

    @Test("record prepends entries so the newest is at index 0")
    func record_putsNewestEntryFirst() throws {
        try withTempDir { dir in
            let store = makeStore(in: dir)
            let first = entry(title: "first")
            let second = entry(title: "second")
            store.record(first)
            store.record(second)
            #expect(store.entries.first?.title == "second")
            #expect(store.entries.last?.title == "first")
        }
    }

    @Test("recording past the cap drops the oldest entries")
    func record_pastCap_dropsOldestEntries() throws {
        try withTempDir { dir in
            let store = makeStore(in: dir)
            for i in 0..<600 {
                store.record(entry(title: "n\(i)"))
            }
            #expect(store.entries.count == 500)
            // Newest first: "n599" is at the head, "n100" at the tail
            // (n0..n99 were trimmed).
            #expect(store.entries.first?.title == "n599")
            #expect(store.entries.last?.title == "n100")
        }
    }

    // MARK: - unreadCount

    @Test("unreadCount starts at zero on an empty store")
    func unreadCount_emptyStore_isZero() throws {
        try withTempDir { dir in
            let store = makeStore(in: dir)
            #expect(store.unreadCount == 0)
        }
    }

    @Test("unreadCount tracks freshly-recorded (unread) entries")
    func unreadCount_tracksRecordedEntries() throws {
        try withTempDir { dir in
            let store = makeStore(in: dir)
            store.record(entry())
            store.record(entry())
            #expect(store.unreadCount == 2)
        }
    }

    // MARK: - markRead

    @Test("markRead(_:) on a known id flips that entry to read")
    func markRead_knownID_flipsToRead() throws {
        try withTempDir { dir in
            let store = makeStore(in: dir)
            let id = UUID()
            store.record(entry(id: id))
            store.markRead(id)
            #expect(store.entries.first { $0.id == id }?.isRead == true)
            #expect(store.unreadCount == 0)
        }
    }

    @Test("markRead(_:) on an unknown id is a no-op")
    func markRead_unknownID_isNoOp() throws {
        try withTempDir { dir in
            let store = makeStore(in: dir)
            store.record(entry())
            let beforeUnread = store.unreadCount
            store.markRead(UUID())
            #expect(store.unreadCount == beforeUnread)
        }
    }

    @Test("markAllRead clears every unread entry in one pass")
    func markAllRead_clearsAllUnread() throws {
        try withTempDir { dir in
            let store = makeStore(in: dir)
            for _ in 0..<5 {
                store.record(entry())
            }
            store.markAllRead()
            #expect(store.unreadCount == 0)
            let allRead = store.entries.allSatisfy(\.isRead)
            #expect(allRead)
        }
    }

    @Test("markRead(forPanes:) only flips entries whose paneID is in the set")
    func markRead_forPanes_onlyAffectsMatchingPanes() throws {
        try withTempDir { dir in
            let store = makeStore(in: dir)
            let paneA = UUID()
            let paneB = UUID()
            let paneC = UUID()
            store.record(entry(paneID: paneA))
            store.record(entry(paneID: paneB))
            store.record(entry(paneID: paneC))

            store.markRead(forPanes: [paneA, paneB])

            let byPane = Dictionary(uniqueKeysWithValues: store.entries.map { ($0.paneID, $0.isRead) })
            #expect(byPane[paneA] == true)
            #expect(byPane[paneB] == true)
            #expect(byPane[paneC] == false)
        }
    }

    @Test("markRead(forPanes:) skips entries with a nil paneID")
    func markRead_forPanes_ignoresEntriesWithoutPaneID() throws {
        try withTempDir { dir in
            let store = makeStore(in: dir)
            store.record(entry(paneID: nil))
            store.markRead(forPanes: [UUID()])
            #expect(store.unreadCount == 1)
        }
    }

    // MARK: - delete / clearAll

    @Test("delete removes the matching entry from the list")
    func delete_knownID_removesEntry() throws {
        try withTempDir { dir in
            let store = makeStore(in: dir)
            let id = UUID()
            store.record(entry(id: id))
            store.record(entry())
            store.delete(id)
            #expect(store.entries.count == 1)
            #expect(store.entries.contains { $0.id == id } == false)
        }
    }

    @Test("delete on an unknown id is a no-op")
    func delete_unknownID_isNoOp() throws {
        try withTempDir { dir in
            let store = makeStore(in: dir)
            store.record(entry())
            let beforeCount = store.entries.count
            store.delete(UUID())
            #expect(store.entries.count == beforeCount)
        }
    }

    @Test("clearAll empties the list and resets unreadCount")
    func clearAll_emptiesEverything() throws {
        try withTempDir { dir in
            let store = makeStore(in: dir)
            for _ in 0..<3 {
                store.record(entry())
            }
            store.clearAll()
            #expect(store.entries.isEmpty)
            #expect(store.unreadCount == 0)
        }
    }
}
