// NotificationHistoryStoreTests.swift
// Weir — the notification history store: ordering, unread bookkeeping,
// pane-scoped mark-read, capacity ceiling, per-id delete, and what a row
// keeps on disk. Each test injects an isolated temporary directory via
// `init(directory:)`: the app's `init(writesFiles:)` uses Weir's data
// folder rather than one of the test's own, and `clearAll()` would empty it.

import Foundation
import Testing
@testable import Weir
@testable import WeirDomain

@Suite("NotificationHistoryStore")
@MainActor
struct NotificationHistoryStoreTests {

    // MARK: - Demo mode

    @Test("demo mode neither reads nor writes the history")
    func demoMode_readsAndWritesNothing() throws {
        try withTempDir { dir in
            let file = dir.appendingPathComponent("notifications.json")
            let real = NotificationHistoryStore(directory: dir)
            real.record(NotificationEntry.test(title: "real"))
            real.flushSynchronously()
            let onDisk = try Data(contentsOf: file)

            let demo = NotificationHistoryStore(directory: dir, writesFiles: false)
            #expect(demo.entries.isEmpty, "a demo's screenshot shows none of the person's rows")
            demo.record(NotificationEntry.test(title: "demo"))
            demo.markAllRead()
            demo.flushSynchronously()
            #expect(try Data(contentsOf: file) == onDisk)
        }
    }

    // MARK: - record / ordering

    @Test("record prepends entries so the newest is at index 0")
    func record_putsNewestEntryFirst() throws {
        try withTempDir { dir in
            let store = NotificationHistoryStore(directory: dir)
            let first = NotificationEntry.test(title: "first")
            let second = NotificationEntry.test(title: "second")
            store.record(first)
            store.record(second)
            #expect(store.entries.first?.title == "second")
            #expect(store.entries.last?.title == "first")
        }
    }

    @Test("recording past the cap drops the oldest entries")
    func record_pastCap_dropsOldestEntries() throws {
        try withTempDir { dir in
            let store = NotificationHistoryStore(directory: dir)
            for i in 0..<600 {
                store.record(NotificationEntry.test(title: "n\(i)"))
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
            let store = NotificationHistoryStore(directory: dir)
            #expect(store.unreadCount == 0)
        }
    }

    @Test("unreadCount tracks freshly-recorded (unread) entries")
    func unreadCount_tracksRecordedEntries() throws {
        try withTempDir { dir in
            let store = NotificationHistoryStore(directory: dir)
            store.record(NotificationEntry.test())
            store.record(NotificationEntry.test())
            #expect(store.unreadCount == 2)
        }
    }

    // MARK: - markRead

    @Test("markRead(_:) on a known id flips that entry to read")
    func markRead_knownID_flipsToRead() throws {
        try withTempDir { dir in
            let store = NotificationHistoryStore(directory: dir)
            let id = UUID()
            store.record(NotificationEntry.test(id: id))
            store.markRead(id)
            #expect(store.entries.first { $0.id == id }?.isRead == true)
            #expect(store.unreadCount == 0)
        }
    }

    @Test("markRead(_:) on an unknown id is a no-op")
    func markRead_unknownID_isNoOp() throws {
        try withTempDir { dir in
            let store = NotificationHistoryStore(directory: dir)
            store.record(NotificationEntry.test())
            let beforeUnread = store.unreadCount
            store.markRead(UUID())
            #expect(store.unreadCount == beforeUnread)
        }
    }

    @Test("markAllRead clears every unread entry in one pass")
    func markAllRead_clearsAllUnread() throws {
        try withTempDir { dir in
            let store = NotificationHistoryStore(directory: dir)
            for _ in 0..<5 {
                store.record(NotificationEntry.test())
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
            let store = NotificationHistoryStore(directory: dir)
            let paneA = UUID()
            let paneB = UUID()
            let paneC = UUID()
            store.record(NotificationEntry.test(paneID: paneA))
            store.record(NotificationEntry.test(paneID: paneB))
            store.record(NotificationEntry.test(paneID: paneC))

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
            let store = NotificationHistoryStore(directory: dir)
            store.record(NotificationEntry.test(paneID: nil))
            store.markRead(forPanes: [UUID()])
            #expect(store.unreadCount == 1)
        }
    }

    @Test("markRead(forPanes:) leaves every agent row to runtime reconciliation")
    func markRead_forPanes_keepsAgentRowsUnread() throws {
        try withTempDir { dir in
            let store = NotificationHistoryStore(directory: dir)
            let paneID = UUID()
            store.record(NotificationEntry.test(kind: .agentFinished, paneID: paneID))
            store.record(NotificationEntry.test(kind: .agentNeedsInput, paneID: paneID))
            store.record(NotificationEntry.test(kind: .agentError, paneID: paneID))

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
            let store = NotificationHistoryStore(directory: dir)
            let id = UUID()
            store.record(NotificationEntry.test(id: id))
            store.record(NotificationEntry.test())
            store.delete(id)
            #expect(store.entries.count == 1)
            #expect(store.entries.contains { $0.id == id } == false)
        }
    }

    @Test("delete on an unknown id is a no-op")
    func delete_unknownID_isNoOp() throws {
        try withTempDir { dir in
            let store = NotificationHistoryStore(directory: dir)
            store.record(NotificationEntry.test())
            let beforeCount = store.entries.count
            store.delete(UUID())
            #expect(store.entries.count == beforeCount)
        }
    }

    @Test("clearAll empties the list and resets unreadCount")
    func clearAll_emptiesEverything() throws {
        try withTempDir { dir in
            let store = NotificationHistoryStore(directory: dir)
            for _ in 0..<3 {
                store.record(NotificationEntry.test())
            }
            store.clearAll()
            #expect(store.entries.isEmpty)
            #expect(store.unreadCount == 0)
        }
    }

    @Test("markRead(where:) flips only the matching unread entries")
    func markReadWhere_flipsMatchingEntries() throws {
        try withTempDir { dir in
            let store = NotificationHistoryStore(directory: dir)
            let keep = UUID()
            store.record(NotificationEntry.test(id: keep, kind: .commandFinished))
            store.record(NotificationEntry.test(kind: .agentNeedsInput))
            store.record(NotificationEntry.test(kind: .agentNeedsInput, isRead: true))

            store.markRead { $0.kind == .agentNeedsInput }

            #expect(store.unreadCount == 1)
            #expect(store.entries.first(where: { $0.id == keep })?.isRead == false)
        }
    }

    @Test("a request key survives a disk round-trip and is absent from older rows")
    func requestKey_roundTripsAndDecodesWhenAbsent() throws {
        let key = ApprovalKey(epoch: UUID(), runID: UUID(), requestID: UUID())
        try withTempDir { dir in
            let store = NotificationHistoryStore(directory: dir)
            store.record(NotificationEntry.test(
                kind: .agentNeedsInput,
                title: "t",
                body: "b",
                runtimeID: "claude:abc",
                requestKey: key
            ))
            store.flushSynchronously()
            #expect(NotificationHistoryStore(directory: dir).entries.first?.requestKey == key)
        }
        try withTempDir { dir in
            let json = """
            [{"id":"\(UUID().uuidString)","kind":"agentNeedsInput","timestamp":"2026-09-12T00:00:00Z",\
            "title":"t","body":"b","isRead":false,"runtimeID":"claude:abc"}]
            """
            try Data(json.utf8).write(to: dir.appendingPathComponent("notifications.json"))
            let legacy = try #require(NotificationHistoryStore(directory: dir).entries.first)
            #expect(legacy.requestKey == nil)
            #expect(legacy.runtimeID == "claude:abc")
        }
    }

    @Test("runtime identity survives a disk round-trip and event tokens are optional on decode")
    func runtimeIdentity_roundTripsAndEventTokenDecodesWhenAbsent() throws {
        try withTempDir { dir in
            let store = NotificationHistoryStore(directory: dir)
            store.record(NotificationEntry.test(
                kind: .agentFinished,
                title: "t",
                body: "b",
                runtimeID: "codex:abc",
                eventToken: "42"
            ))
            store.flushSynchronously()
            let reloaded = NotificationHistoryStore(directory: dir)
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
            let store = NotificationHistoryStore(directory: dir)
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
            let store = NotificationHistoryStore(directory: dir)
            let legacyAgent = try #require(store.entries.first)
            #expect(legacyAgent.runtimeID == "codex:abc")
            #expect(legacyAgent.eventToken == nil)
        }
    }

    // MARK: - Events on disk

    @Test func aHistoryWithAnUnreadableEvent_loadsWhole() throws {
        try withTempDir { dir in
            let rows = [
                #"{"type":"hologram","agent":"claude"}"#,
                #"{"type":"wait","agent":"claude","wait":"approval","fact":"notes.txt"}"#
            ].map { event in
                """
                {"id":"\(UUID().uuidString)","kind":"agentNeedsInput","timestamp":"2026-10-18T00:00:00Z",\
                "title":"t","body":"b","isRead":false,"event":\(event)}
                """
            }
            let file = dir.appendingPathComponent("notifications.json")
            try Data("[\(rows.joined(separator: ","))]".utf8).write(to: file)
            let store = NotificationHistoryStore(directory: dir)
            #expect(store.entries.count == 2)
            #expect(store.entries.map(\.event) == [nil, .wait(agent: .claude, wait: .approval, fact: "notes.txt")])
            // Not set aside: the file is where it was.
            #expect(FileManager.default.fileExists(atPath: file.path))
        }
    }

    @Test func everyEvent_roundTripsThroughDisk() throws {
        let turn = NotificationEvent.Turn(
            number: 4,
            changes: .changed(files: 2, added: 94, removed: 0),
            check: CheckSummary(command: "swift test", isFiltered: true, exitCode: 1, earlierFailures: 2)
        )
        let events: [NotificationEvent] = [
            .wait(agent: .claude, wait: .approval, fact: "notes.txt"),
            .wait(agent: .codex, wait: .response, fact: nil),
            .turnFinished(
                agent: .claude,
                turn: turn,
                prompt: "Add the tests",
                promptKind: .text,
                reply: "Added two tests; one still fails."
            ),
            .turnFinished(
                agent: .codex,
                turn: .init(number: 1, changes: .unavailable(reason: "endMissing"), check: nil),
                prompt: nil,
                promptKind: .subagentMessage,
                reply: nil
            ),
            .stopped(agent: .claude, reason: "Rate limited")
        ]
        try withTempDir { dir in
            let store = NotificationHistoryStore(directory: dir)
            for event in events {
                store.record(NotificationEntry.test(event: event))
            }
            store.flushSynchronously()
            #expect(NotificationHistoryStore(directory: dir).entries.map(\.event) == events.reversed())
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
            let store = NotificationHistoryStore(directory: dir)
            #expect(store.entries.count == 1)
            #expect(store.entries.first?.kind == .desktop)
        }
    }

    @Test("agent kinds round-trip through disk and map to their AgentState")
    func agentKinds_roundTripAndMapToState() throws {
        try withTempDir { dir in
            let store = NotificationHistoryStore(directory: dir)
            store.record(NotificationEntry.test(kind: .agentNeedsInput))
            store.record(NotificationEntry.test(kind: .agentFinished))
            store.record(NotificationEntry.test(kind: .agentError))
            store.flushSynchronously()
            let reloaded = NotificationHistoryStore(directory: dir)
            #expect(reloaded.entries.map(\.kind) == [.agentError, .agentFinished, .agentNeedsInput])
        }
        #expect(NotificationEntry.Kind.agentNeedsInput.agentState == .needsInput)
        #expect(NotificationEntry.Kind.agentFinished.agentState == .finished)
        #expect(NotificationEntry.Kind.agentError.agentState == .error)
        #expect(NotificationEntry.Kind.commandFinished.agentState == nil)
        #expect(NotificationEntry.Kind.desktop.agentState == nil)
    }

    // MARK: - A file that cannot be read

    // The history's own file, read and moved aside as the settings file is
    // (`SettingsStoreMigrationTests`).

    @Test func aHistoryThatCannotBeRead_isMovedAside_notSavedOver() throws {
        try withTempDir { dir in
            let file = dir.appendingPathComponent("notifications.json")
            let original = Data("[]".utf8)
            try original.write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)

            let history = NotificationHistoryStore(directory: dir)
            history.record(NotificationEntry.test(kind: .bell, title: "make", body: ""))
            history.flushSynchronously()

            let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            #expect(names.contains { $0.hasPrefix("notifications.json.bak-read-failed-") })
        }
    }

    @Test func anUnreadableHistory_thatCannotBeMovedAside_isNeverSavedOver() throws {
        try withTempDir { dir in
            let file = dir.appendingPathComponent("notifications.json")
            let garbled = Data(#"[ { "broken": "#.utf8)
            try garbled.write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path) }

            let history = NotificationHistoryStore(directory: dir)
            history.record(NotificationEntry.test(kind: .bell, title: "make", body: ""))
            history.flushSynchronously()
            #expect(try Data(contentsOf: file) == garbled)
        }
    }
}
