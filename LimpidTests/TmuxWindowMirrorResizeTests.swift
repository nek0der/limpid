// TmuxWindowMirrorResizeTests.swift
// Limpid — checks that a divider drag keeps one resize outstanding and only the newest one waiting.

import Foundation
import Testing
@testable import Limpid

/// A real tmux would answer the first request before the test could send
/// the next, so the connection runs a client that reads commands and never
/// replies: the attach block never closes, every command stays held, and
/// the first resize stays unanswered for as long as the test needs.
@MainActor
@Suite("tmux window mirror resize")
struct TmuxWindowMirrorResizeTests {
    private static let binding = TmuxBinding(socketPath: "/tmp/limpid-none/sock", sessionID: "$0", sessionName: "t")

    @Test("requests sent while one is unanswered collapse into the newest, which goes out once the first is answered")
    func unansweredResize_keepsOnlyTheNewestWaiting() async throws {
        try await withTempDir { directory in
            let silentClient = directory.appendingPathComponent("tmux-silent")
            try "#!/bin/sh\nexec cat >/dev/null\n".write(to: silentClient, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: silentClient.path)

            let (session, tab, leafID) = WindowSessionFixture.withLooseTab()
            session.update(tab.id) { t in
                t.kind = .tmuxMirror
                t.paneSources = [leafID: .tmux(TmuxPaneRef(binding: Self.binding, windowID: "@1", paneID: "%0"))]
            }
            let connection = TmuxSessionConnection(
                executable: silentClient.path,
                target: .init(socketPath: Self.binding.socketPath, sessionID: Self.binding.sessionID)
            )
            try connection.start()
            defer { connection.stop() }
            let mirror = TmuxWindowMirror(
                tabID: tab.id,
                windowID: "@1",
                binding: Self.binding,
                sessionName: "t",
                windowName: "w",
                connection: connection,
                isNewTab: true,
                session: session,
                registry: RecordingSurfaceRegistry(),
                secureInput: nil,
                channelForPane: { _ in try? TmuxPaneChannel { _ in } },
                surfaceReports: { TmuxSurfaceReports() }
            )
            mirror.start()
            try #require(mirror.tmuxPane(for: leafID) == "%0")

            mirror.resize(paneID: leafID, direction: .horizontal, cells: 30)
            #expect(mirror.isResizeInFlight)
            #expect(mirror.queuedResize == nil)

            mirror.resize(paneID: leafID, direction: .horizontal, cells: 20)
            mirror.resize(paneID: leafID, direction: .vertical, cells: 25)
            #expect(mirror.isResizeInFlight)
            #expect(mirror.queuedResize?.cells == 25)
            #expect(mirror.queuedResize?.direction == .vertical)

            // Ending the client answers every held command with an error.
            // The first answer sends the waiting request, whose own answer
            // leaves nothing outstanding and nothing waiting.
            connection.stop()
            #expect(await waitUntil { !mirror.isResizeInFlight && mirror.queuedResize == nil })
        }
    }
}
