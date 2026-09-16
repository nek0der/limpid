// TmuxServerConnectionTests.swift
// Limpid — drives a real tmux server on a private socket through the control-mode connection, end to end.

import Darwin
import Foundation
import Testing
@testable import Limpid

/// A throwaway tmux server on a socket under a temp directory, so the
/// user's own server is never touched and two tests cannot share state.
private struct TmuxServerFixture {
    let executable: String
    let directory: URL
    let socketPath: String

    static func launch() throws -> TmuxServerFixture {
        let executable = try #require(TmuxClientProbe.locateTmux())
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("limpid-tmux-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fixture = TmuxServerFixture(
            executable: executable,
            directory: directory,
            socketPath: directory.appendingPathComponent("sock").path
        )
        _ = fixture.run(["new-session", "-d", "-s", "t", "-x", "80", "-y", "24", "sh", "-c", "PS1='$ ' exec sh"])
        _ = fixture.run(["set-option", "-g", "status", "off"])
        return fixture
    }

    @discardableResult
    func run(_ arguments: [String]) -> String? {
        if case let .success(output) = TmuxCommand().run(executable: executable, arguments: ["-S", socketPath] + arguments) {
            return output.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    func format(_ format: String) throws -> String {
        try #require(run(["display-message", "-p", "-t", "t", format]))
    }

    func tearDown() {
        _ = run(["kill-server"])
        try? FileManager.default.removeItem(at: directory)
    }
}

@MainActor
private func waitUntil(_ timeout: Duration = .seconds(3), _ condition: () -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        if condition() {
            return true
        }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}

/// Read from `fd` until `marker` shows up or `timeout` passes. Runs off the
/// main actor so a blocked read never stalls the connection's deliveries.
private func readUntil(fd: Int32, contains marker: String, timeout: Duration) async -> Data {
    await Task.detached {
        var collected = Data()
        let needle = Data(marker.utf8)
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        var buffer = [UInt8](repeating: 0, count: 65536)
        while clock.now < deadline, collected.range(of: needle) == nil {
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&descriptor, 1, 100) > 0 else { continue }
            let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n > 0 {
                collected.append(contentsOf: buffer[0..<n])
            } else {
                break
            }
        }
        return collected
    }.value
}

@Suite("tmux server connection", .serialized, .disabled(if: TmuxClientProbe.locateTmux() == nil, "tmux is not installed"))
@MainActor
struct TmuxServerConnectionTests {
    @Test("attaching closes the attach block, then a command gets exactly its own reply")
    func attach_answersCommandsInOrder() async throws {
        let server = try TmuxServerFixture.launch()
        defer { server.tearDown() }
        let paneID = try server.format("#{pane_id}")
        let sessionID = try server.format("#{session_id}")

        let connection = TmuxServerConnection(
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

    @Test("a window resize comes back as a %layout-change notification with the new size")
    func layoutChange_isDelivered() async throws {
        let server = try TmuxServerFixture.launch()
        defer { server.tearDown() }
        let windowID = try server.format("#{window_id}")
        let sessionID = try server.format("#{session_id}")

        let connection = TmuxServerConnection(
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

        let connection = TmuxServerConnection(
            executable: server.executable,
            target: .init(socketPath: server.socketPath, sessionID: sessionID)
        )
        defer { connection.stop() }
        try connection.start()
        #expect(await waitUntil { connection.state == .attached })
        let sink = try connection.attachPane(paneID)

        // Typed through the surface end, as libghostty would encode a
        // keystroke; tmux runs it in the pane and the echo comes back.
        let typed = Data("printf limpid-e2e-ok\n".utf8)
        _ = typed.withUnsafeBytes { write(sink.surfaceFd, $0.baseAddress, $0.count) }

        let seen = await readUntil(fd: sink.surfaceFd, contains: "limpid-e2e-ok", timeout: .seconds(5))
        #expect(seen.range(of: Data("limpid-e2e-ok".utf8)) != nil)
        connection.detachPane(paneID)
        #expect(connection.sinks[paneID] == nil)
    }

    @Test("a stalled surface fills the sink to its limit, the overflow is reported once, and reading drains it")
    func overflow_isReportedOnceAndDrains() async throws {
        let server = try TmuxServerFixture.launch()
        defer { server.tearDown() }
        let paneID = try server.format("#{pane_id}")
        let sessionID = try server.format("#{session_id}")
        let payload = server.directory.appendingPathComponent("payload.txt")
        let line = String(repeating: "x", count: 100) + "\n"
        try String(repeating: line, count: 4000).write(to: payload, atomically: true, encoding: .utf8)

        let connection = TmuxServerConnection(
            executable: server.executable,
            target: .init(socketPath: server.socketPath, sessionID: sessionID)
        )
        defer { connection.stop() }
        var overflows = 0
        connection.onPaneOverflow = { _ in overflows += 1 }
        try connection.start()
        #expect(await waitUntil { connection.state == .attached })
        let sink = try connection.attachPane(paneID, limit: 32 * 1024)

        // Nobody reads the surface end, so 400 KB has nowhere to go.
        connection.send("send-keys -t \(paneID) 'cat \(payload.path)' Enter")
        #expect(await waitUntil(.seconds(5)) { overflows >= 1 })
        #expect(overflows == 1)

        // Reading the surface end lets the sink drain what it still holds.
        let drained = await readUntil(fd: sink.surfaceFd, contains: "\u{1}never", timeout: .seconds(1))
        #expect(!drained.isEmpty)
    }

    @Test("stop terminates the client process and flips the state")
    func stop_terminatesTheClient() async throws {
        let server = try TmuxServerFixture.launch()
        defer { server.tearDown() }
        let sessionID = try server.format("#{session_id}")

        let connection = TmuxServerConnection(
            executable: server.executable,
            target: .init(socketPath: server.socketPath, sessionID: sessionID)
        )
        try connection.start()
        #expect(await waitUntil { connection.state == .attached })
        #expect(server.run(["list-clients"])?.isEmpty == false)

        connection.stop()
        #expect(connection.state == .exited(reason: nil))
        #expect(await waitUntil { server.run(["list-clients"])?.isEmpty == true })
    }

    @Test("a killed server ends the connection with %exit")
    func killServer_endsWithExit() async throws {
        let server = try TmuxServerFixture.launch()
        defer { server.tearDown() }
        let sessionID = try server.format("#{session_id}")

        let connection = TmuxServerConnection(
            executable: server.executable,
            target: .init(socketPath: server.socketPath, sessionID: sessionID)
        )
        defer { connection.stop() }
        try connection.start()
        #expect(await waitUntil { connection.state == .attached })

        server.run(["kill-server"])
        #expect(await waitUntil {
            if case .exited = connection.state {
                return true
            }
            return false
        })
    }
}
