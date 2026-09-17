// TmuxPaneSinkTests.swift
// Limpid — the pane sink's contract without tmux: pauses drop output, a repaint leads live output, overflow pauses, close ends writing.

import Darwin
import Foundation
import Testing
@testable import Limpid

/// What the sink reported to the main actor.
@MainActor
private final class CallbackLog {
    var overflows = 0
    var activity = 0
    var activityTimes: [ContinuousClock.Instant] = []
}

/// A sink on a private queue writing into its own channel, fed the way the
/// transport feeds it. `surfaceFd` is what the surface would read. Not
/// main-actor: the sink asserts it is written off the main queue, and a
/// `sync` from the main thread would still count as the main queue.
private struct SinkHarness {
    let sink: TmuxPaneSink
    let queue: DispatchQueue
    let log: CallbackLog

    var surfaceFd: Int32 {
        sink.channel.surfaceFd
    }

    init(limit: Int = TmuxPaneSink.defaultLimit, activityInterval: Duration = TmuxPaneSink.defaultActivityInterval) throws {
        let log = CallbackLog()
        let queue = DispatchQueue(label: "dev.limpid.tests.sink")
        sink = try TmuxPaneSink(
            channel: TmuxPaneChannel { _ in },
            queue: queue,
            limit: limit,
            activityInterval: activityInterval,
            onOverflow: { log.overflows += 1 }
        )
        self.queue = queue
        self.log = log
    }

    func write(_ bytes: Data) {
        queue.sync { sink.write(bytes) }
    }

    func write(_ text: String) {
        write(Data(text.utf8))
    }

    /// Resume the way the transport does: on the queue, at the reply's
    /// place among the writes.
    func resume(injecting text: String?) {
        queue.sync { _ = sink.resumeInOrder(injecting: text.map { Data($0.utf8) }, rebuild: 1) }
    }

    /// Write `total` bytes of `byte` in 16 KiB pieces with nobody reading.
    func flood(_ total: Int, with byte: UInt8 = UInt8(ascii: "x")) {
        let chunk = Data(repeating: byte, count: 16 * 1024)
        var written = 0
        while written < total {
            write(chunk)
            written += chunk.count
        }
    }

    /// Let everything already handed to the queue run.
    func settle() {
        queue.sync {}
    }

    /// The storage behind the sink's held output. Read through reflection
    /// so the sink exposes nothing for the test's sake; `startIndex` is how
    /// far into its storage the live bytes begin.
    func pendingStorage() -> Data? {
        queue.sync {
            Swift.Mirror(reflecting: sink).children.first { $0.label == "pending" }?.value as? Data
        }
    }
}

private func eventually(_ timeout: Duration = .seconds(3), _ condition: () async -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        if await condition() {
            return true
        }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

/// Read exactly `count` bytes, or whatever arrived before `timeout`.
private func readBytes(_ count: Int, from fd: Int32, timeout: Duration = .seconds(5)) -> Data {
    var collected = Data()
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    var buffer = [UInt8](repeating: 0, count: 65536)
    while collected.count < count, clock.now < deadline {
        var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&descriptor, 1, 50) > 0 else { continue }
        let wanted = min(buffer.count, count - collected.count)
        let n = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, wanted) }
        guard n > 0 else { break }
        collected.append(contentsOf: buffer[0..<n])
    }
    return collected
}

/// `data` is some run of `filler` followed by exactly `tail`.
private func isFiller(_ filler: UInt8, thenExactly tail: String, _ data: Data) -> Bool {
    let tailBytes = Data(tail.utf8)
    guard data.count >= tailBytes.count, data.suffix(tailBytes.count) == tailBytes else { return false }
    return data.dropLast(tailBytes.count).allSatisfy { $0 == filler }
}

@Suite("tmux pane sink")
struct TmuxPaneSinkTests {
    @Test("bytes written while paused are dropped, and output flows again after resume")
    func pause_dropsWhatArrives() async throws {
        let harness = try SinkHarness()
        defer { harness.sink.close() }

        harness.write("BEFORE|")
        harness.sink.pause()
        harness.write("STALE|")
        harness.resume(injecting: nil)
        harness.write("LIVE")

        let seen = await readUntil(fd: harness.surfaceFd, contains: "LIVE", timeout: .seconds(2))
        #expect(seen == Data("BEFORE|LIVE".utf8))
    }

    @Test("output still held for a slow reader when a pause begins never reaches the surface")
    func pause_dropsHeldOutput() async throws {
        let harness = try SinkHarness()
        defer { harness.sink.close() }
        let held = 256 * 1024
        harness.flood(held, with: UInt8(ascii: "y"))

        harness.sink.pause()
        harness.resume(injecting: "CAP")
        harness.write("LIVE")

        // Only what the socket had already taken precedes the repaint.
        let seen = await readUntil(fd: harness.surfaceFd, contains: "LIVE", timeout: .seconds(2))
        #expect(isFiller(UInt8(ascii: "y"), thenExactly: "CAPLIVE", seen))
        #expect(seen.count < held)
    }

    @Test("after an overflow only the injected repaint and later output appear")
    func overflow_thenRepaint_showsOnlyTheRepaint() async throws {
        let harness = try SinkHarness(limit: 64 * 1024)
        defer { harness.sink.close() }

        harness.flood(512 * 1024)
        #expect(await eventually { await harness.log.overflows == 1 })
        // Paused by the overflow itself, before the owner's pause lands.
        harness.write("DROPPED")
        harness.sink.pause()
        harness.resume(injecting: "CAP")
        harness.write("LIVE")

        let seen = await readUntil(fd: harness.surfaceFd, contains: "LIVE", timeout: .seconds(2))
        #expect(isFiller(UInt8(ascii: "x"), thenExactly: "CAPLIVE", seen))
    }

    @Test("an overflow is reported once while paused, and again once a repaint resumed the sink")
    func overflow_isReportedOncePerPause() async throws {
        let harness = try SinkHarness(limit: 32 * 1024)
        defer { harness.sink.close() }
        let fd = harness.surfaceFd

        harness.flood(512 * 1024)
        harness.flood(512 * 1024)
        #expect(await eventually { await harness.log.overflows >= 1 })
        try? await Task.sleep(for: .milliseconds(100))
        #expect(await harness.log.overflows == 1)

        // Drain what the socket took, then repaint the way a mirror does.
        _ = readBytes(Int.max, from: fd, timeout: .milliseconds(200))
        harness.sink.pause()
        harness.resume(injecting: "CAP")
        #expect(readBytes(3, from: fd) == Data("CAP".utf8))

        harness.flood(512 * 1024)
        #expect(await eventually { await harness.log.overflows == 2 })
    }

    @Test("output written in the same queue turn as the resume lands after the injected repaint")
    func resumeInOrder_leadsWritesInTheSameTurn() async throws {
        let harness = try SinkHarness()
        defer { harness.sink.close() }

        harness.sink.pause()
        harness.write("STALE")
        harness.queue.sync {
            harness.sink.resumeInOrder(injecting: Data("CAP|".utf8), rebuild: 1)
            harness.sink.write(Data("LIVE".utf8))
        }

        let seen = await readUntil(fd: harness.surfaceFd, contains: "LIVE", timeout: .seconds(2))
        #expect(seen == Data("CAP|LIVE".utf8))
    }

    @Test("close stops every callback, including the trailing activity report")
    func close_endsCallbacks() async throws {
        let harness = try SinkHarness(limit: 32 * 1024)
        let log = harness.log
        harness.sink.setOnOutputActivity { log.activity += 1 }
        harness.settle()

        harness.write("A")
        harness.sink.close()
        harness.settle()
        // The leading report was posted before the close; let it land.
        #expect(await eventually { await log.activity == 1 })

        harness.flood(512 * 1024)
        try? await Task.sleep(for: harness.sink.activityInterval * 2)
        #expect(await log.activity == 1)
        #expect(await log.overflows == 0)
    }

    /// The interval is the sink's own, and longer than the default: the
    /// test writes inside it and then measures how long the trailing report
    /// waited, and under a full parallel run a 250 ms window is not wide
    /// enough to tell a late write from a leading report.
    @Test("the trailing activity report waits for the output to be quiet since its last write, not since its first", .tags(.slow))
    func trailingActivity_followsTheLastWrite() async throws {
        let interval = Duration.seconds(1)
        let harness = try SinkHarness(activityInterval: interval)
        let log = harness.log
        harness.sink.setOnOutputActivity {
            log.activity += 1
            log.activityTimes.append(ContinuousClock.now)
        }
        harness.settle()

        harness.write("A")
        #expect(await eventually { await log.activity == 1 })
        // Inside the interval: no leading report, and the quiet starts again.
        try? await Task.sleep(for: interval * 0.4)
        harness.write("B")
        let lastWrite = ContinuousClock.now

        #expect(await eventually { await log.activity == 2 })
        let trailing = try #require(await log.activityTimes.last)
        // Dispatch never fires early; the margin only absorbs clock reads.
        #expect(trailing - lastWrite >= interval - .milliseconds(10))
        try? await Task.sleep(for: interval * 2)
        #expect(await log.activity == 2)
        harness.sink.close()
    }

    @Test("held output keeps bounded storage after several MiB pass through a slow reader")
    func pending_storageStaysBounded() async throws {
        let limit = 1024 * 1024
        let harness = try SinkHarness(limit: limit)
        defer { harness.sink.close() }
        let fd = harness.surfaceFd
        let chunk = Data(repeating: UInt8(ascii: "z"), count: 64 * 1024)
        let backlog = 256 * 1024
        var written = 0
        var read = 0
        var largestOffset = 0

        // The reader stays a backlog behind, so the held buffer is never
        // emptied and only compaction can release what was written.
        for _ in 0..<128 {
            harness.write(chunk)
            written += chunk.count
            read += readBytes(max(0, written - backlog - read), from: fd).count
            let storage = try #require(harness.pendingStorage())
            largestOffset = max(largestOffset, storage.startIndex)
        }
        #expect(largestOffset <= limit)
        #expect(await harness.log.overflows == 0)

        // Emptied, the buffer starts over on fresh storage.
        read += readBytes(written - read, from: fd).count
        #expect(read == written)
        #expect(await eventually { harness.pendingStorage()?.startIndex == 0 })
    }

    // MARK: - Rebuild numbers

    @Test("every pause starts a new rebuild, and only the latest one's resume ends it")
    func resumeInOrder_withStaleRebuild_staysPaused() async throws {
        let harness = try SinkHarness()
        defer { harness.sink.close() }
        let sink = harness.sink

        let (initial, first, second) = harness.queue.sync {
            let initial = sink.latestRebuild
            sink.pauseInOrder()
            let first = sink.latestRebuild
            sink.pauseInOrder()
            return (initial, first, sink.latestRebuild)
        }
        #expect(first == initial + 1)
        #expect(second == first + 1)

        // The capture asked for before the second pause is not painted, and
        // the sink goes on dropping.
        let isStaleTaken = harness.queue.sync { sink.resumeInOrder(injecting: Data("OLD|".utf8), rebuild: first) }
        #expect(!isStaleTaken)
        harness.write("DROPPED|")

        let isLatestTaken = harness.queue.sync { sink.resumeInOrder(injecting: Data("CAP|".utf8), rebuild: second) }
        #expect(isLatestTaken)
        harness.write("LIVE")

        let seen = await readUntil(fd: sink.channel.surfaceFd, contains: "LIVE", timeout: .seconds(2))
        #expect(seen == Data("CAP|LIVE".utf8))
    }

    @Test("pause() counts like pauseInOrder once it has run on the queue")
    func pause_bumpsTheRebuild() throws {
        let harness = try SinkHarness()
        defer { harness.sink.close() }

        harness.sink.pause()
        harness.sink.pause()
        #expect(harness.queue.sync { harness.sink.latestRebuild } == 2)
    }

    @Test("an overflow pauses without starting a rebuild, so the capture already asked for still ends it")
    func overflow_keepsTheRebuildNumber() async throws {
        let harness = try SinkHarness(limit: 32 * 1024)
        defer { harness.sink.close() }
        let sink = harness.sink
        let fd = sink.channel.surfaceFd

        harness.flood(512 * 1024)
        #expect(await eventually { await harness.log.overflows == 1 })
        #expect(harness.queue.sync { sink.latestRebuild } == 0)
        // Paused by the overflow: nothing more reaches the socket.
        _ = readBytes(Int.max, from: fd, timeout: .milliseconds(200))
        harness.write("DROPPED")

        let isTaken = harness.queue.sync { sink.resumeInOrder(injecting: Data("CAP|".utf8), rebuild: 0) }
        #expect(isTaken)
        harness.write("LIVE")
        #expect(readBytes(8, from: fd) == Data("CAP|LIVE".utf8))
    }

    /// A capture reply can reach a sink that is not paused: the mirror that
    /// asked for it may have detached the pane and attached it again, or
    /// another pause may have been ended first. Nothing can be injected
    /// there without landing on top of output already on screen, and the
    /// caller reads the same answer it reads for a superseded capture.
    @Test("a resume without a pause injects nothing and answers no")
    func resumeInOrder_withoutAPause_returnsFalse() async throws {
        let harness = try SinkHarness()
        defer { harness.sink.close() }
        let sink = harness.sink

        harness.write("LIVE|")
        let rebuild = harness.queue.sync { sink.latestRebuild }
        #expect(!harness.queue.sync { sink.resumeInOrder(injecting: Data("CAP".utf8), rebuild: rebuild) })
        harness.write("MORE")

        let seen = await readUntil(fd: sink.channel.surfaceFd, contains: "MORE", timeout: .seconds(2))
        #expect(seen == Data("LIVE|MORE".utf8))
    }

    /// A write source keeps reporting a descriptor whose write fails for
    /// good as writable, so retrying would spin at full speed for as long
    /// as the sink lives.
    @Test("a write that fails for good stops the sink and is reported once")
    func permanentWriteFailure_stopsTheSink() async throws {
        let harness = try SinkHarness()
        defer { harness.sink.close() }
        let sink = harness.sink
        // Without this the failing write raises SIGPIPE in the test runner;
        // the channel keeps both ends open in the app, so this cannot
        // happen there.
        var isOn: Int32 = 1
        #expect(setsockopt(
            sink.channel.hostFd, SOL_SOCKET, SO_NOSIGPIPE, &isOn, socklen_t(MemoryLayout<Int32>.size)
        ) == 0)
        #expect(shutdown(sink.channel.hostFd, SHUT_WR) == 0)

        harness.write("ONE")
        #expect(await eventually { await harness.log.overflows == 1 })
        // Nothing is held for a retry, and nothing more is reported.
        harness.write("TWO")
        harness.flood(512 * 1024)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(await harness.log.overflows == 1)
        #expect(harness.pendingStorage()?.isEmpty == true)
    }

    @Test("a closed sink refuses a resume")
    func resumeInOrder_afterClose_returnsFalse() throws {
        let harness = try SinkHarness()
        let sink = harness.sink
        sink.pause()
        sink.close()

        let rebuild = harness.queue.sync { sink.latestRebuild }
        #expect(!harness.queue.sync { sink.resumeInOrder(injecting: Data("CAP".utf8), rebuild: rebuild) })
    }
}
