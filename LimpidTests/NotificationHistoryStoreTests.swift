// NotificationHistoryStoreTests.swift
// In-memory behavior of the notification history store: ordering,
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

    @Test("visible delivery keeps agent rows unread until runtime handling")
    func initialReadState_agentRowsRequireRuntimeHandling() {
        #expect(LimpidNotificationManager.initialReadState(kind: .desktop, isSourceVisible: true))
        #expect(!LimpidNotificationManager.initialReadState(kind: .agentFinished, isSourceVisible: true))
        #expect(!LimpidNotificationManager.initialReadState(kind: .agentNeedsInput, isSourceVisible: true))
        #expect(!LimpidNotificationManager.initialReadState(kind: .agentError, isSourceVisible: true))
    }

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

    @Test("markRead(forPanes:) leaves every agent row to runtime reconciliation")
    func markRead_forPanes_keepsAgentRowsUnread() throws {
        try withTempDir { dir in
            let store = makeStore(in: dir)
            let paneID = UUID()
            store.record(entry(kind: .agentFinished, paneID: paneID))
            store.record(entry(kind: .agentNeedsInput, paneID: paneID))
            store.record(entry(kind: .agentError, paneID: paneID))

            store.markRead(forPanes: [paneID])

            #expect(store.entries.first { $0.kind == .agentFinished }?.isRead == false)
            #expect(store.entries.first { $0.kind == .agentNeedsInput }?.isRead == false)
            #expect(store.entries.first { $0.kind == .agentError }?.isRead == false)
            #expect(store.unreadCount == 3)
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

    @Test("markRead(where:) flips only the matching unread entries")
    func markReadWhere_flipsMatchingEntries() throws {
        try withTempDir { dir in
            let store = makeStore(in: dir)
            let keep = UUID()
            store.record(entry(id: keep, kind: .commandFinished))
            store.record(entry(kind: .agentNeedsInput))
            store.record(entry(kind: .agentNeedsInput, isRead: true))

            store.markRead { $0.kind == .agentNeedsInput }

            #expect(store.unreadCount == 1)
            #expect(store.entries.first(where: { $0.id == keep })?.isRead == false)
        }
    }

    @Test("runtime identity survives a disk round-trip and event tokens are optional on decode")
    func runtimeIdentity_roundTripsAndEventTokenDecodesWhenAbsent() throws {
        try withTempDir { dir in
            let store = makeStore(in: dir)
            store.record(NotificationEntry(
                kind: .agentFinished,
                paneID: nil,
                tabTitleSnapshot: nil,
                title: "t",
                body: "b",
                runtimeID: "codex:abc",
                eventToken: "42"
            ))
            store.flushSynchronously()
            let reloaded = makeStore(in: dir)
            #expect(reloaded.entries.first?.runtimeID == "codex:abc")
            #expect(reloaded.entries.first?.eventToken == "42")
        }
        try withTempDir { dir in
            // A pre-`runtimeID` file has no such key at all.
            let json = """
            [{"id":"\(UUID().uuidString)","kind":"desktop","timestamp":"2026-09-12T00:00:00Z",\
            "title":"t","body":"b","isRead":false}]
            """
            try Data(json.utf8).write(to: dir.appendingPathComponent("notifications.json"))
            let store = makeStore(in: dir)
            let legacy = try #require(store.entries.first)
            #expect(legacy.runtimeID == nil)
            #expect(legacy.eventToken == nil)
        }
        try withTempDir { dir in
            // Runtime identity shipped before event identity. Keep that
            // intermediate shape readable without guessing which later
            // waiting episode it belongs to.
            let json = """
            [{"id":"\(UUID().uuidString)","kind":"agentNeedsInput","timestamp":"2026-09-12T00:00:00Z",\
            "title":"t","body":"b","isRead":false,"runtimeID":"codex:abc"}]
            """
            try Data(json.utf8).write(to: dir.appendingPathComponent("notifications.json"))
            let store = makeStore(in: dir)
            let legacyAgent = try #require(store.entries.first)
            #expect(legacyAgent.runtimeID == "codex:abc")
            #expect(legacyAgent.eventToken == nil)
        }
    }

    // MARK: - Kind decoding

    @Test("an unknown kind on disk decodes to .desktop instead of quarantining the file")
    func load_unknownKind_fallsBackToDesktop() throws {
        try withTempDir { dir in
            // Shape a newer build might write: one row whose kind this
            // build has never heard of. Without the defensive decoder the
            // whole array fails and `load()` moves the file aside.
            let json = """
            [{"id":"\(UUID().uuidString)","kind":"holographic","timestamp":"2026-09-12T00:00:00Z",\
            "title":"t","body":"b","isRead":false}]
            """
            try Data(json.utf8).write(to: dir.appendingPathComponent("notifications.json"))
            let store = makeStore(in: dir)
            #expect(store.entries.count == 1)
            #expect(store.entries.first?.kind == .desktop)
        }
    }

    @Test("agent kinds round-trip through disk and map to their AgentState")
    func agentKinds_roundTripAndMapToState() throws {
        try withTempDir { dir in
            let store = makeStore(in: dir)
            store.record(entry(kind: .agentNeedsInput))
            store.record(entry(kind: .agentFinished))
            store.record(entry(kind: .agentError))
            store.flushSynchronously()
            let reloaded = makeStore(in: dir)
            #expect(reloaded.entries.map(\.kind) == [.agentError, .agentFinished, .agentNeedsInput])
        }
        #expect(NotificationEntry.Kind.agentNeedsInput.agentState == .needsInput)
        #expect(NotificationEntry.Kind.agentFinished.agentState == .finished)
        #expect(NotificationEntry.Kind.agentError.agentState == .error)
        #expect(NotificationEntry.Kind.commandFinished.agentState == nil)
        #expect(NotificationEntry.Kind.desktop.agentState == nil)
    }
}
