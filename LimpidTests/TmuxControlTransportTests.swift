// TmuxControlTransportTests.swift
// Limpid — drives the control transport through a pipe: line splitting, reply pairing, and pane routing without tmux.

import Darwin
import Foundation
import Testing
@testable import Limpid

/// What the transport delivered to the main actor, in order.
@MainActor
private final class DeliveryLog {
    var lines: [TmuxControlLine] = []
    var linesAtEOF: Int?
    var attach: (lines: [String], isError: Bool)?
    var replies: [Reply] = []

    struct Reply {
        let lines: [String]
        let isError: Bool
        let isMainThread: Bool
    }

    func events() -> TmuxControlTransport.Events {
        .init(
            attachFinished: { lines, isError in self.attach = (lines, isError) },
            notification: { line in self.lines.append(line) },
            endOfStream: { self.linesAtEOF = self.lines.count }
        )
    }

    func recordReply() -> TmuxControlTransport.Completion {
        .onMain { lines, isError in self.replies.append(Reply(lines: lines, isError: isError, isMainThread: Thread.isMainThread)) }
    }
}

/// Resumes `sink` with `bytes` from the reply's place in the stream, the
/// way a mirror's capture reply does. Built outside the main actor so
/// Dispatch can run it on the routing queue.
private func resumeInStream(_ sink: TmuxPaneSink, injecting bytes: Data) -> TmuxControlTransport.Completion {
    .inStream { _, _ in sink.resumeInOrder(injecting: bytes, rebuild: 1) }
}

/// What an in-stream resume answered. Written on the routing queue, read
/// on the main actor once the reply has been routed.
private final class ResumeOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Bool?

    var value: Bool? {
        lock.withLock { stored }
    }

    func set(_ value: Bool) {
        lock.withLock { stored = value }
    }
}

/// Resumes `sink` for `rebuild` at the reply's place in the stream, the way
/// a mirror's capture reply does, and records whether the sink took it.
private func resumeInStream(
    _ sink: TmuxPaneSink,
    injecting bytes: Data,
    rebuild: Int,
    into outcome: ResumeOutcome
) -> TmuxControlTransport.Completion {
    .inStream { _, _ in outcome.set(sink.resumeInOrder(injecting: bytes, rebuild: rebuild)) }
}

/// Whatever `fd` holds right now, without waiting for more.
private func readAvailable(_ fd: Int32) -> Data {
    var collected = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
    while poll(&descriptor, 1, 0) > 0, descriptor.revents & Int16(POLLIN) != 0 {
        let n = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
        guard n > 0 else { break }
        collected.append(contentsOf: buffer[0..<n])
    }
    return collected
}

/// Two pipes wired to a started transport: `input` feeds its reader,
/// `output` receives what it writes.
@MainActor
private final class PipedTransport {
    let transport = TmuxControlTransport()
    let log = DeliveryLog()
    private(set) var input: [Int32] = [-1, -1]
    private(set) var output: [Int32] = [-1, -1]

    init() throws {
        try #require(pipe(&input) == 0)
        try #require(pipe(&output) == 0)
        transport.start(readFd: input[0], writeFd: output[1], events: log.events())
    }

    func feed(_ text: String) {
        let bytes = Array(text.utf8)
        _ = bytes.withUnsafeBytes { Darwin.write(input[1], $0.baseAddress, $0.count) }
    }

    func closeInput() {
        close(input[1])
        input[1] = -1
    }

    func closeOutputWriter() {
        close(output[1])
        output[1] = -1
    }

    /// Everything the transport wrote, until `marker` has arrived.
    func written(until marker: String) async -> String {
        let bytes = await readUntil(fd: output[0], contains: marker, timeout: .seconds(2))
        return String(bytes: bytes, encoding: .utf8) ?? ""
    }

    /// Close the attach block, as tmux does first on every connection.
    func attach() async {
        feed("%begin 1 1 0\n%end 1 1 0\n")
        _ = await waitUntil { self.log.attach != nil }
    }

    /// The transport reads and writes its own duplicates, so the test's
    /// copies are the test's to close at any time.
    func tearDown() {
        transport.close(failingPendingWith: ["closed"])
        for fd in input + output where fd >= 0 {
            close(fd)
        }
        input = [-1, -1]
        output = [-1, -1]
    }
}

/// How many descriptors of this process refer to the same pipe end as `fd`.
/// A duplicate shares the end's identity; the other end of the pipe does not.
private func openCopies(of fd: Int32) -> Int {
    var target = stat()
    guard fstat(fd, &target) == 0 else { return 0 }
    var count = 0
    for candidate in 0..<getdtablesize() {
        var info = stat()
        if fstat(candidate, &info) == 0, info.st_dev == target.st_dev, info.st_ino == target.st_ino {
            count += 1
        }
    }
    return count
}

/// Reads `fd` until EOF, or gives up after `timeout`. `reachedEOF` is
/// false only when some other copy of the write end stayed open.
private func readToEOF(_ fd: Int32, timeout: Duration) async -> (data: Data, reachedEOF: Bool) {
    await Task.detached {
        var collected = Data()
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        var buffer = [UInt8](repeating: 0, count: 4096)
        while clock.now < deadline {
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&descriptor, 1, 50) > 0 else { continue }
            let n = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            guard n > 0 else { return (collected, n == 0) }
            collected.append(contentsOf: buffer[0..<n])
        }
        return (collected, false)
    }.value
}

/// Write `bytes` in `chunkSize` pieces with a pause between them, so the
/// transport's reads end in the middle of lines. Runs off the main actor so
/// deliveries keep flowing while it writes.
private func writeChunked(_ bytes: [UInt8], to fd: Int32, chunkSize: Int) async {
    await Task.detached {
        var offset = 0
        while offset < bytes.count {
            let end = min(offset + chunkSize, bytes.count)
            let chunk = Array(bytes[offset..<end])
            let written = chunk.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            guard written > 0 else { return }
            offset += written
            usleep(200)
        }
    }.value
}

@Suite("tmux control transport")
@MainActor
struct TmuxControlTransportTests {
    /// The reference the transport must match: each whole line classified
    /// with the block state the lines before it established, minus the
    /// `%output` lines, which go to sinks, and the reply blocks, which are
    /// paired on the routing queue instead of reaching the main actor.
    private func expectedDeliveries(_ bytes: [UInt8]) -> [TmuxControlLine] {
        var lines = bytes.split(separator: 0x0A, omittingEmptySubsequences: false)
        if lines.last?.isEmpty == true {
            lines.removeLast()
        }
        var openBlock: TmuxReplyMarker?
        var delivered: [TmuxControlLine] = []
        for raw in lines {
            let line = TmuxProtocol.parseLine(raw, openBlock: openBlock)
            switch line {
            case let .begin(marker): openBlock = marker
            case .end, .error: openBlock = nil
            default: break
            }
            switch line {
            case .output, .begin, .end, .error, .text: continue
            default: delivered.append(line)
            }
        }
        return delivered
    }

    @Test(
        "lines split across reads are delivered whole, and a reply body that looks like %output never reaches a sink",
        arguments: TmuxRecording.all("session-basic")
    )
    func chunkedStream_deliversLinesAndKeepsReplyBodiesAwayFromSinks(fixture: TmuxRecording) async throws {
        let recording = try fixture.bytes()
        // A `capture-pane` reply whose rows read like protocol lines, then
        // real output for the same pane so the test knows when routing has
        // caught up.
        let synthetic = Array("""
        %begin 1789549600 900 1
        %0
        %output %0 x
        %end 1789549600 900 1
        %output %0 y

        """.utf8)

        let piped = try PipedTransport()
        defer { piped.tearDown() }
        let log = piped.log
        let transport = piped.transport

        let recorded = expectedDeliveries(recording)
        await writeChunked(recording, to: piped.input[1], chunkSize: 7)
        #expect(await waitUntil { log.lines.count >= recorded.count })
        #expect(log.lines == recorded)

        // Registered only now, so the recording's own `%0` output (which is
        // legitimately routed) cannot be mistaken for a leak.
        let sink = try TmuxPaneSink(channel: TmuxPaneChannel { _ in }, queue: transport.queue, onOverflow: {})
        defer { sink.close() }
        transport.setSink(sink, forPane: "%0")

        await writeChunked(synthetic, to: piped.input[1], chunkSize: 7)
        let routed = await readUntil(fd: sink.channel.surfaceFd, contains: Data("y".utf8), timeout: .seconds(2))
        #expect(routed == Data("y".utf8))

        // The reply block itself is consumed by pairing, never delivered.
        try? await Task.sleep(for: .milliseconds(50))
        #expect(log.lines == recorded)

        piped.closeInput()
        #expect(await waitUntil { log.linesAtEOF != nil })
        #expect(log.linesAtEOF == recorded.count)
    }

    @Test("an in-stream completion runs before the %output that follows its %end in the same read")
    func inStreamCompletion_runsBeforeTheNextLine() async throws {
        let piped = try PipedTransport()
        defer { piped.tearDown() }
        await piped.attach()
        let sink = try TmuxPaneSink(channel: TmuxPaneChannel { _ in }, queue: piped.transport.queue, onOverflow: {})
        defer { sink.close() }
        piped.transport.setSink(sink, forPane: "%0")
        sink.pause()

        piped.transport.send("capture-pane -p", completion: resumeInStream(sink, injecting: Data("CAP|".utf8)))
        _ = await piped.written(until: "capture-pane -p\n")
        // One write, so the reply and the live line arrive in one read. A
        // resume that ran any later than the `%end` would find the sink
        // still paused and drop `LIVE`.
        piped.feed("%output %0 STALE\n%begin 2 5 1\nrow\n%end 2 5 1\n%output %0 LIVE\n")

        let seen = await readUntil(fd: sink.channel.surfaceFd, contains: "LIVE", timeout: .seconds(2))
        #expect(seen == Data("CAP|LIVE".utf8))
    }

    @Test("a main-delivered completion runs on the main thread, and a flags-0 block between replies pairs with nothing")
    func onMainCompletion_pairsByFlags() async throws {
        let piped = try PipedTransport()
        defer { piped.tearDown() }
        let log = piped.log

        // Sent before the attach block: held, then written once it closes.
        piped.transport.send("first", completion: log.recordReply())
        await piped.attach()
        piped.transport.send("second", completion: log.recordReply())
        let written = await piped.written(until: "second\n")
        #expect(written == "first\nsecond\n")

        piped.feed("""
        %begin 3 10 1
        one
        %end 3 10 1
        %begin 3 11 0
        hooked
        %end 3 11 0
        %begin 3 12 1
        two
        %error 3 12 1

        """)
        #expect(await waitUntil { log.replies.count == 2 })
        #expect(log.replies.map(\.lines) == [["one"], ["two"]])
        #expect(log.replies.map(\.isError) == [false, true])
        #expect(log.replies.map(\.isMainThread) == [true, true])
        #expect(log.attach?.isError == false)
    }

    @Test("closing fails every unanswered command once, and later commands at once, with the given reply")
    func close_failsPendingOnce() async throws {
        let piped = try PipedTransport()
        defer { piped.tearDown() }
        let log = piped.log
        piped.transport.send("held", completion: log.recordReply())

        piped.transport.close(failingPendingWith: ["gone"])
        piped.transport.close(failingPendingWith: ["again"])
        piped.transport.send("late", completion: log.recordReply())

        #expect(await waitUntil { log.replies.count == 2 })
        try? await Task.sleep(for: .milliseconds(50))
        #expect(log.replies.map(\.lines) == [["gone"], ["gone"]])
        #expect(log.replies.map(\.isError) == [true, true])
    }

    @Test("a command sent after close fails at once and is never written, and close releases the write end")
    func sendAfterClose_neverWrites() async throws {
        let piped = try PipedTransport()
        defer { piped.tearDown() }
        let log = piped.log
        await piped.attach()
        piped.transport.send("before", completion: nil)
        _ = await piped.written(until: "before\n")

        piped.transport.close(failingPendingWith: ["gone"])
        piped.transport.send("late", completion: log.recordReply())
        #expect(await waitUntil { log.replies.count == 1 })
        #expect(log.replies.first?.lines == ["gone"])
        #expect(log.replies.first?.isError == true)

        // With our own write end closed, EOF can only come once the
        // transport has closed its duplicate, after anything it had queued.
        piped.closeOutputWriter()
        let (rest, reachedEOF) = await readToEOF(piped.output[0], timeout: .seconds(2))
        #expect(reachedEOF)
        #expect(rest.isEmpty)
    }

    @Test("the transport closes only its own duplicates, and the descriptors it was given stay usable")
    func close_releasesOnlyItsOwnDescriptors() async throws {
        let piped = try PipedTransport()
        defer { piped.tearDown() }
        await piped.attach()
        #expect(openCopies(of: piped.input[0]) == 2)
        #expect(openCopies(of: piped.output[1]) == 2)

        piped.transport.close(failingPendingWith: ["gone"])
        #expect(await waitUntil { openCopies(of: piped.input[0]) == 1 && openCopies(of: piped.output[1]) == 1 })

        // The test's read end still works, and nothing else reads it.
        piped.feed("still ours\n")
        let seen = await readUntil(fd: piped.input[0], contains: "still ours\n", timeout: .seconds(2))
        #expect(seen == Data("still ours\n".utf8))
    }

    // MARK: - Input bound

    @Test("a line that grows past the limit ends the stream after the lines before it, and nothing after it is read")
    func overlongLine_endsTheStream() async throws {
        let piped = try PipedTransport()
        defer { piped.tearDown() }
        let log = piped.log
        piped.feed("%window-add @1\n")
        #expect(await waitUntil { log.lines.count == 1 })

        let endless = [UInt8](repeating: UInt8(ascii: "x"), count: TmuxControlTransport.lineLimit + 1)
        await writeChunked(endless, to: piped.input[1], chunkSize: 1 << 16)

        #expect(await waitUntil(.seconds(5)) { log.linesAtEOF != nil })
        #expect(log.linesAtEOF == 1)
        piped.feed("\n%window-add @2\n")
        try? await Task.sleep(for: .milliseconds(100))
        #expect(log.lines == [.windowAdd(window: "@1")])
    }

    @Test("a long line that stays under the limit arrives whole across many reads, with the stream still open")
    func longLineInPieces_isDeliveredWhole() async throws {
        let piped = try PipedTransport()
        defer { piped.tearDown() }
        let log = piped.log
        let name = String(repeating: "n", count: 1 << 20)
        let line = Array("%window-renamed @1 \(name)\n".utf8)

        await writeChunked(line, to: piped.input[1], chunkSize: 4096)
        piped.feed("%window-add @2\n")

        #expect(await waitUntil(.seconds(5)) { log.lines.count == 2 })
        #expect(log.lines == [.windowRenamed(window: "@1", name: name), .windowAdd(window: "@2")])
        #expect(log.linesAtEOF == nil)
    }

    // MARK: - Layout pauses

    /// `%0 | %1`, recorded by `record_tmux.py` (tmux 3.7c, 100x30 window).
    private static let sideBySide = "6b8b,100x30,0,0{50x30,0,0,0,49x30,51,0,1}"
    private static let layoutWithPane0 = "%layout-change @1 \(sideBySide) \(sideBySide) *"

    /// A paused, attached transport with a sink on `%0`, and the rebuild
    /// the pause started, read on the routing queue as a mirror reads it.
    private func pausedSink(_ piped: PipedTransport) async throws -> (sink: TmuxPaneSink, rebuild: Int) {
        await piped.attach()
        let sink = try TmuxPaneSink(channel: TmuxPaneChannel { _ in }, queue: piped.transport.queue, onOverflow: {})
        piped.transport.setSink(sink, forPane: "%0")
        sink.pause()
        let rebuild = piped.transport.queue.sync { sink.latestRebuild }
        return (sink, rebuild)
    }

    /// Let the routing queue finish what it has read, then read what it
    /// wrote to the surface. The sink writes synchronously on the queue, so
    /// nothing is still on its way once a block queued behind it has run.
    private func surfaceBytes(_ piped: PipedTransport, _ sink: TmuxPaneSink) -> Data {
        piped.transport.queue.sync {}
        return readAvailable(sink.channel.surfaceFd)
    }

    @Test("a %layout-change routed before a capture reply makes that reply stand aside, and the sink keeps dropping")
    func layoutChangeBeforeReply_supersedesTheCapture() async throws {
        let piped = try PipedTransport()
        defer { piped.tearDown() }
        let (sink, rebuild) = try await pausedSink(piped)
        defer { sink.close() }
        let outcome = ResumeOutcome()

        piped.transport.send("capture-pane -p", completion: resumeInStream(
            sink, injecting: Data("CAP|".utf8), rebuild: rebuild, into: outcome
        ))
        _ = await piped.written(until: "capture-pane -p\n")
        // One write, so the layout line and the reply are routed in one read.
        piped.feed(Self.layoutWithPane0 + "\n%begin 2 5 1\nrow\n%end 2 5 1\n%output %0 LIVE\n")

        #expect(await waitUntil { outcome.value != nil })
        #expect(outcome.value == false)
        #expect(surfaceBytes(piped, sink).isEmpty)
        #expect(await waitUntil { piped.log.lines.count == 1 })
        #expect(piped.transport.queue.sync { sink.latestRebuild } == rebuild + 1)
    }

    @Test("a %layout-change routed after the capture reply pauses the sink only after the repaint was injected")
    func layoutChangeAfterReply_keepsTheRepaint() async throws {
        let piped = try PipedTransport()
        defer { piped.tearDown() }
        let (sink, rebuild) = try await pausedSink(piped)
        defer { sink.close() }
        let outcome = ResumeOutcome()

        piped.transport.send("capture-pane -p", completion: resumeInStream(
            sink, injecting: Data("CAP|".utf8), rebuild: rebuild, into: outcome
        ))
        _ = await piped.written(until: "capture-pane -p\n")
        piped.feed("%begin 2 5 1\nrow\n%end 2 5 1\n%output %0 BEFORE\n" + Self.layoutWithPane0 + "\n%output %0 AFTER\n")

        #expect(await waitUntil { piped.log.lines.count == 1 })
        #expect(outcome.value == true)
        // Output between the reply and the layout is live; after it, dropped.
        #expect(surfaceBytes(piped, sink) == Data("CAP|BEFORE".utf8))
    }

    @Test("a %layout-change naming panes without sinks pauses nothing and is still delivered")
    func layoutChange_forPanesWithoutSinks_pausesNothing() async throws {
        let piped = try PipedTransport()
        defer { piped.tearDown() }
        await piped.attach()
        // No sink at all yet: the layout is only delivered.
        piped.feed("%layout-change @7 a87d,100x30,0,0,5 a87d,100x30,0,0,5 *\n")
        #expect(await waitUntil { piped.log.lines.count == 1 })

        let sink = try TmuxPaneSink(channel: TmuxPaneChannel { _ in }, queue: piped.transport.queue, onOverflow: {})
        defer { sink.close() }
        piped.transport.setSink(sink, forPane: "%0")
        // Another window's layout, and one tmux could not have sent: neither
        // names `%0`, so its output keeps flowing.
        piped.feed("%layout-change @7 a87d,100x30,0,0,5 a87d,100x30,0,0,5 *\n%layout-change @8 garbage\n%output %0 LIVE\n")

        let seen = await readUntil(fd: sink.channel.surfaceFd, contains: "LIVE", timeout: .seconds(2))
        #expect(seen == Data("LIVE".utf8))
        #expect(await waitUntil { piped.log.lines.count == 3 })
        #expect(piped.transport.queue.sync { sink.latestRebuild } == 0)
    }
}
