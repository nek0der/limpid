// ClaudeSessionTrackerTests.swift
// Limpid — verifies `bootstrap` reflects on-disk records into the
// right pane of the right tab and prunes orphan files, plus
// `didClosePane` removes a record.

import Foundation
import Testing
@testable import Limpid

@MainActor
@Suite("ClaudeSessionTracker")
struct ClaudeSessionTrackerTests {
    @Test("bootstrap reflects an on-disk record into the matching pane")
    func bootstrap_appliesSessionToMatchingPane() throws {
        try withTempDir { dir in
            let store = ClaudeSessionStore(directory: dir)
            let (session, _, paneID) = WindowSessionFixture.withLooseTab()
            let tabID = session.tabs[0].id

            try store.save(ClaudeSessionRecord(
                schemaVersion: 1,
                paneId: paneID.uuidString,
                sessionId: "session-xyz",
                cwd: "/tmp/repo",
                updatedAt: "2026-05-26T00:00:00Z",
                lastHookEvent: "SessionStart"
            ))

            let tracker = ClaudeSessionTracker(store: store)
            tracker.bootstrap(into: session)

            let info = try #require(session.tab(tabID)?.claudeSessions[paneID])
            #expect(info.sessionId == "session-xyz")
            #expect(info.cwd == "/tmp/repo")
        }
    }

    @Test("bootstrap normalises an empty cwd to nil on the in-memory mirror")
    func bootstrap_normalisesEmptyCwdToNil() throws {
        try withTempDir { dir in
            let store = ClaudeSessionStore(directory: dir)
            let (session, _, paneID) = WindowSessionFixture.withLooseTab()
            let tabID = session.tabs[0].id

            try store.save(ClaudeSessionRecord(
                schemaVersion: 1,
                paneId: paneID.uuidString,
                sessionId: "x",
                cwd: "",
                updatedAt: "2026-05-26T00:00:00Z",
                lastHookEvent: nil
            ))

            ClaudeSessionTracker(store: store).bootstrap(into: session)

            let info = try #require(session.tab(tabID)?.claudeSessions[paneID])
            #expect(info.sessionId == "x")
            #expect(info.cwd == nil)
        }
    }

    @Test("bootstrap deletes records whose pane no longer exists")
    func bootstrap_dropsOrphanRecord() throws {
        try withTempDir { dir in
            let store = ClaudeSessionStore(directory: dir)
            let (session, _, paneID) = WindowSessionFixture.withLooseTab()
            let orphanID = UUID()

            for id in [paneID, orphanID] {
                try store.save(ClaudeSessionRecord(
                    schemaVersion: 1,
                    paneId: id.uuidString,
                    sessionId: "x",
                    cwd: "/tmp",
                    updatedAt: "2026-05-26T00:00:00Z",
                    lastHookEvent: nil
                ))
            }

            ClaudeSessionTracker(store: store).bootstrap(into: session)

            #expect(store.record(forPaneID: paneID) != nil)
            #expect(store.record(forPaneID: orphanID) == nil)
        }
    }

    @Test("bootstrap clears a stale claudeSessions entry when no disk record exists")
    func bootstrap_clearsStaleEntry_whenNoDiskRecord() throws {
        try withTempDir { dir in
            let store = ClaudeSessionStore(directory: dir)
            let (session, _, paneID) = WindowSessionFixture.withLooseTab()
            let tabID = session.tabs[0].id
            // Simulate a tab whose state.json carried an old session
            // for this pane, but whose disk record was deleted by a
            // SessionEnd hook (user explicitly /exit'd Claude).
            // Bootstrap must clear the in-memory mirror so we don't
            // keep auto-resuming a conversation the user already
            // closed out.
            session.update(tabID) {
                $0.claudeSessions[paneID] = ClaudeSessionInfo(
                    sessionId: "stale",
                    cwd: "/tmp/stale"
                )
            }

            ClaudeSessionTracker(store: store).bootstrap(into: session)

            #expect(session.tab(tabID)?.claudeSessions[paneID] == nil)
        }
    }

    @Test("didClosePane drops the on-disk record for that pane")
    func didClosePane_removesRecord() throws {
        try withTempDir { dir in
            let store = ClaudeSessionStore(directory: dir)
            let paneID = UUID()
            try store.save(ClaudeSessionRecord(
                schemaVersion: 1,
                paneId: paneID.uuidString,
                sessionId: "x",
                cwd: "/tmp",
                updatedAt: "2026-05-26T00:00:00Z",
                lastHookEvent: nil
            ))
            #expect(store.record(forPaneID: paneID) != nil)

            ClaudeSessionTracker(store: store).didClosePane(paneID)

            #expect(store.record(forPaneID: paneID) == nil)
        }
    }
}
