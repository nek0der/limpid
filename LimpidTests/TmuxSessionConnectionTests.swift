// TmuxSessionConnectionTests.swift
// Limpid — drives a real tmux server on a private socket through the control-mode connection, end to end.

import Darwin
import Foundation
import Testing
@testable import Limpid

/// A reply handler that resumes `sink` with `bytes` at the reply's place in
/// the stream. Built outside the main actor so Dispatch can run it on the
/// routing queue.
private func resumeInStream(_ sink: TmuxPaneSink, injecting bytes: Data) -> @Sendable ([String], Bool) -> Void {
    { _, _ in sink.resumeInOrder(injecting: bytes, rebuild: 1) }
}

/// Counts overflow reports; a class so the main-actor callback can bump it.
@MainActor
private final class OverflowCount {
    var value = 0
}

/// Every reply one command received, so a test can tell once from twice.
@MainActor
private final class ReplyRecord {
    var replies: [(lines: [String], isError: Bool)] = []

    func handler() -> TmuxSessionConnection.ReplyHandler {
        { lines, isError in self.replies.append((lines, isError)) }
    }
}

/// `wait-for` on a channel nobody signals: tmux holds the reply until the
/// client goes away, so the command is still pending when we stop it.
private let neverAnswered = "wait-for limpid-tests-never-signaled"

/// The text a pending command is failed with for `state`.
@MainActor
private func exitReply(_ state: TmuxSessionConnection.State) -> [String]? {
    guard case let .exited(reason) = state else { return nil }
    return [reason ?? "connection closed"]
}

@Suite(
    "tmux server connection",
    .tags(.smoke, .slow),
    .serialized,
    .disabled(if: TmuxServerFixture.isUnavailable, "tmux is not installed")
)
@MainActor
struct TmuxSessionConnectionTests {
    @Test("attaching closes the attach block, then a command gets exactly its own reply")
    func attach_answersCommandsInOrder() async throws {
        let server = try TmuxServerFixture.launch()
        defer { server.tearDown() }
        let paneID = try server.format("#{pane_id}")
        let sessionID = try server.format("#{session_id}")

        let connection = TmuxSessionConnection(
            executable: server.executable,
            target: .init(socketPath: server.socketPath, sessionID: sessionID)
        )
        defer { connection.stop() }
        // Sent before the attach block closed: must be held, not paired
        // with tmux's own first block.
        var early: [String]?
        connection.send("display-message -p -t \(paneID) '#{pane_id}'") { lines, _ in early = lines }
        try connection.start()

        #expect(await waitUntil { connection.state == .attached })
        #expect(await waitUntil { early != nil })
        #expect(early == [paneID])

        var second: [String]?
        var secondIsError = false
        connection.send("display-message -p -t \(paneID) '#{session_id}'") { lines, isError in
            second = lines
            secondIsError = isError
        }
        #expect(await waitUntil { second != nil })
        #expect(second == [sessionID])
        #expect(!secondIsError)

        var failed: (lines: [String], isError: Bool)?
        connection.send("no-such-command") { lines, isError in failed = (lines, isError) }
        #expect(await waitUntil { failed != nil })
        #expect(failed?.isError == true)
    }

    /// A captured screen is printed verbatim inside the reply block, so a
    /// row a program printed can read like a terminator. Taken for one, it
    /// would cut the capture short and hand the rest of the block to the
    /// next command.
    @Test("screen rows that read like %end and %error stay in the capture, and the next reply is still its own")
    func captureOfTerminatorLookalikes_keepsRepliesPaired() async throws {
        let server = try TmuxServerFixture.launch()
        defer { server.tearDown() }
        let paneID = try server.format("#{pane_id}")
        let sessionID = try server.format("#{session_id}")
        let rows = ["%end 1 2 1", "%error 1789549534 331 1", "%end", "%begin 5 6 1", "after"]
        let printf = "printf '" + rows.map { $0.replacingOccurrences(of: "%", with: "%%") }.joined(separator: "\\n") + "\\n'"
        server.run(["send-keys", "-t", paneID, printf, "Enter"])
        #expect(await waitUntil(.seconds(5)) {
            (server.run(["capture-pane", "-p", "-t", paneID]) ?? "").contains("\nafter")
        })

        let connection = TmuxSessionConnection(
            executable: server.executable,
            target: .init(socketPath: server.socketPath, sessionID: sessionID)
        )
        defer { connection.stop() }
        try connection.start()
        #expect(await waitUntil { connection.state == .attached })

        var capture: [String]?
        var next: [String]?
        connection.send("capture-pane -p -t \(paneID)") { lines, _ in capture = lines }
        connection.send("display-message -p next") { lines, _ in next = lines }

        #expect(await waitUntil { next != nil })
        let captured = try #require(capture)
        let start = try #require(captured.firstIndex(of: rows[0]))
        #expect(Array(captured[start..<(start + rows.count)]) == rows)
        #expect(next == ["next"])
        #expect(connection.state == .attached)
    }

    /// tmux runs an `after-<command>` hook as its own command and wraps its
    /// output in a flags-0 block right after our reply. Pairing by arrival
    /// order alone would hand that block to the next command waiting.
    @Test("a hook's block after split-window is not paired with the next command")
    func afterSplitWindowHook_doesNotShiftReplies() async throws {
        let server = try TmuxServerFixture.launch()
        defer { server.tearDown() }
        server.run(["set-hook", "-g", "after-split-window", "display-message -p hooked"])
        let sessionID = try server.format("#{session_id}")

        let connection = TmuxSessionConnection(
            executable: server.executable,
            target: .init(socketPath: server.socketPath, sessionID: sessionID)
        )
        defer { connection.stop() }
        try connection.start()
        #expect(await waitUntil { connection.state == .attached })

        // Both are written before either reply arrives, so the hook's block
        // lands while `next` is still waiting.
        var split: (lines: [String], isError: Bool)?
        var next: (lines: [String], isError: Bool)?
        connection.send("split-window -t \(sessionID)") { lines, isError in split = (lines, isError) }
        connection.send("display-message -p next") { lines, isError in next = (lines, isError) }

        #expect(await waitUntil { next != nil })
        #expect(split?.lines == [])
        #expect(split?.isError == false)
        #expect(next?.lines == ["next"])
        #expect(next?.isError == false)
    }

    @Test("a refused attach ends the connection with tmux's reason and fails the held commands with it")
    func refusedAttach_exitsWithReason() async throws {
        let server = try TmuxServerFixture.launch()
        defer { server.tearDown() }

        let connection = TmuxSessionConnection(
            executable: server.executable,
            target: .init(socketPath: server.socketPath, sessionID: "$99")
        )
        defer { connection.stop() }
        var held: (lines: [String], isError: Bool)?
        connection.send("display-message -p held") { lines, isError in held = (lines, isError) }
        try connection.start()

        #expect(await waitUntil { held != nil })
        #expect(connection.state == .exited(reason: "can't find session: $99"))
        #expect(held?.lines == ["can't find session: $99"])
        #expect(held?.isError == true)
    }

    /// A path that is not a socket fails before the protocol starts. The
    /// client writes its reason to stderr, which we read when it exits; the
    /// read must not hang and the handler must run off the main actor
    /// without trapping.
    @Test("a client that fails before speaking the protocol ends the connection and fails held commands")
    func notASocket_exits() async throws {
        let server = try TmuxServerFixture.launch()
        defer { server.tearDown() }
        let bogus = server.directory.appendingPathComponent("not-a-socket")
        FileManager.default.createFile(atPath: bogus.path, contents: Data())

        let connection = TmuxSessionConnection(
            executable: server.executable,
            target: .init(socketPath: bogus.path, sessionID: "$0")
        )
        defer { connection.stop() }
        var held: (lines: [String], isError: Bool)?
        connection.send("display-message -p held") { lines, isError in held = (lines, isError) }
        try connection.start()

        #expect(await waitUntil { held != nil })
        #expect(connection.state == .exited(reason: nil))
        #expect(held?.isError == true)
    }

    @Test("a window resize comes back as a %layout-change notification with the new size")
    func layoutChange_isDelivered() async throws {
        let server = try TmuxServerFixture.launch()
        defer { server.tearDown() }
        let windowID = try server.format("#{window_id}")
        let sessionID = try server.format("#{session_id}")

        let connection = TmuxSessionConnection(
            executable: server.executable,
            target: .init(socketPath: server.socketPath, sessionID: sessionID)
        )
        defer { connection.stop() }
        var layouts: [String] = []
        connection.onNotification = { line in
            if case let .layoutChange(_, layout, _, _) = line {
                layouts.append(layout)
            }
        }
        try connection.start()
        #expect(await waitUntil { connection.state == .attached })

        connection.send("refresh-client -C '\(windowID):60x20'")
        #expect(await waitUntil { layouts.contains { $0.contains("60x20") } })
    }

    @Test("pane output reaches the sink's surface end, and surface output goes back as keys")
    func paneOutput_roundTripsThroughTheSink() async throws {
        let server = try TmuxServerFixture.launch()
        defer { server.tearDown() }
        let paneID = try server.format("#{pane_id}")
        let sessionID = try server.format("#{session_id}")

        let connection = TmuxSessionConnection(
            executable: server.executable,
            target: .init(socketPath: server.socketPath, sessionID: sessionID)
        )
        defer { connection.stop() }
        try connection.start()
        #expect(await waitUntil { connection.state == .attached })
        // What the surface writes goes back as keys, the way the store
        // routes a leaf's channel to the connection feeding it.
        let channel = try TmuxPaneChannel { [weak connection] data in
            connection?.sendInput([.bytes(Array(data))], pane: paneID)
        }
        let sink = try connection.attachPane(paneID, channel: channel) {}
        #expect(sink.channel === channel)

        // Typed through the surface end, as libghostty would encode a
        // keystroke; tmux runs it in the pane and the echo comes back.
        let typed = Data("printf limpid-e2e-ok\n".utf8)
        _ = typed.withUnsafeBytes { write(channel.surfaceFd, $0.baseAddress, $0.count) }

        let seen = await readUntil(fd: channel.surfaceFd, contains: "limpid-e2e-ok", timeout: .seconds(5))
        #expect(seen.range(of: Data("limpid-e2e-ok".utf8)) != nil)
        connection.detachPane(paneID)
        #expect(connection.sinks[paneID] == nil)
    }

    @Test("a stalled surface fills the sink to its limit, the overflow reaches the pane's owner once, and a repaint resumes it")
    func overflow_isReportedOnceAndResumesWithRepaint() async throws {
        let server = try TmuxServerFixture.launch()
        defer { server.tearDown() }
        let paneID = try server.format("#{pane_id}")
        let sessionID = try server.format("#{session_id}")
        let payload = server.directory.appendingPathComponent("payload.txt")
        let line = String(repeating: "x", count: 100) + "\n"
        try String(repeating: line, count: 4000).write(to: payload, atomically: true, encoding: .utf8)

        let connection = TmuxSessionConnection(
            executable: server.executable,
            target: .init(socketPath: server.socketPath, sessionID: sessionID)
        )
        defer { connection.stop() }
        let overflows = OverflowCount()
        try connection.start()
        #expect(await waitUntil { connection.state == .attached })
        let sink = try connection.attachPane(paneID, channel: TmuxPaneChannel { _ in }, limit: 32 * 1024) { overflows.value += 1 }

        // Nobody reads the surface end, so 400 KB has nowhere to go.
        connection.send("send-keys -t \(paneID) 'cat \(payload.path)' Enter")
        #expect(await waitUntil(.seconds(5)) { overflows.value >= 1 })
        #expect(overflows.value == 1)

        // The sink paused itself; the repaint the mirror asks for, under a
        // pause of its own, is what gets it flowing again.
        sink.pause()
        connection.sendInStream("display-message -p repaint", completion: resumeInStream(sink, injecting: Data("REPAINT".utf8)))
        let drained = await readUntil(fd: sink.channel.surfaceFd, contains: "REPAINT", timeout: .seconds(2))
        #expect(drained.range(of: Data("REPAINT".utf8)) != nil)
    }

    @Test("stop terminates the client process and flips the state")
    func stop_terminatesTheClient() async throws {
        let server = try TmuxServerFixture.launch()
        defer { server.tearDown() }
        let sessionID = try server.format("#{session_id}")

        let connection = TmuxSessionConnection(
            executable: server.executable,
            target: .init(socketPath: server.socketPath, sessionID: sessionID)
        )
        try connection.start()
        #expect(await waitUntil { connection.state == .attached })
        #expect(server.run(["list-clients"])?.isEmpty == false)
        let pending = ReplyRecord()
        connection.send(neverAnswered, completion: pending.handler())

        connection.stop()
        #expect(connection.state == .exited(reason: nil))
        #expect(await waitUntil { server.run(["list-clients"])?.isEmpty == true })
        #expect(await waitUntil { !pending.replies.isEmpty })
        try? await Task.sleep(for: .milliseconds(100))
        #expect(pending.replies.count == 1)
        #expect(pending.replies.first?.lines == ["connection closed"])
        #expect(pending.replies.first?.isError == true)
    }

    @Test("a client that cannot be spawned throws and fails the commands sent before start once")
    func failedSpawn_endsTheConnection() async throws {
        let connection = TmuxSessionConnection(
            executable: "/nonexistent/limpid-tests/tmux",
            target: .init(socketPath: "/nonexistent/limpid-tests/socket", sessionID: "$0")
        )
        let early = ReplyRecord()
        connection.send("display-message -p early", completion: early.handler())

        #expect(throws: (any Error).self) { try connection.start() }
        let reply = try #require(exitReply(connection.state))
        #expect(await waitUntil { !early.replies.isEmpty })
        try? await Task.sleep(for: .milliseconds(100))
        #expect(early.replies.count == 1)
        #expect(early.replies.first?.lines == reply)
        #expect(early.replies.first?.isError == true)
    }

    @Test("a killed server ends the connection with %exit")
    func killServer_endsWithExit() async throws {
        let server = try TmuxServerFixture.launch()
        defer { server.tearDown() }
        let sessionID = try server.format("#{session_id}")

        let connection = TmuxSessionConnection(
            executable: server.executable,
            target: .init(socketPath: server.socketPath, sessionID: sessionID)
        )
        defer { connection.stop() }
        try connection.start()
        #expect(await waitUntil { connection.state == .attached })

        server.run(["kill-server"])
        #expect(await waitUntil { exitReply(connection.state) != nil })
    }

    /// `kill-server` answers every queued command before the server goes,
    /// so the server is stopped first: the command then reaches it and
    /// stays unanswered until the server dies under it.
    @Test("a command pending when the server dies fails once, with the exit reason")
    func killedServer_failsPendingCommandOnce() async throws {
        let server = try TmuxServerFixture.launch()
        defer { server.tearDown() }
        let sessionID = try server.format("#{session_id}")
        let serverPID = try #require(pid_t(server.format("#{pid}")))

        let connection = TmuxSessionConnection(
            executable: server.executable,
            target: .init(socketPath: server.socketPath, sessionID: sessionID)
        )
        defer { connection.stop() }
        try connection.start()
        #expect(await waitUntil { connection.state == .attached })

        try #require(kill(serverPID, SIGSTOP) == 0)
        let pending = ReplyRecord()
        connection.send("display-message -p unanswered", completion: pending.handler())
        try? await Task.sleep(for: .milliseconds(100))
        #expect(pending.replies.isEmpty)
        try #require(kill(serverPID, SIGKILL) == 0)

        #expect(await waitUntil { exitReply(connection.state) != nil })
        #expect(await waitUntil { !pending.replies.isEmpty })
        try? await Task.sleep(for: .milliseconds(100))
        #expect(pending.replies.count == 1)
        #expect(pending.replies.first?.lines == exitReply(connection.state))
        #expect(pending.replies.first?.isError == true)
    }
}
