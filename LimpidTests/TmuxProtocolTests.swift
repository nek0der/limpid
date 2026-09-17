// TmuxProtocolTests.swift
// Limpid — pins the control-mode wire rules against traffic recorded from a real tmux server.

import Foundation
import Testing
@testable import Limpid

/// Every suite that replays a recording takes `TmuxRecording.all(_:)` as its
/// arguments, and a case with no recording would run zero of them — a pass
/// that says nothing. This is the one test that fails instead: it runs once,
/// takes no arguments, and reads each case the suites replay.
@Suite("tmux recordings", .tags(.smoke), .disabled(if: !RepoFixture.hasLocalRepo))
struct TmuxRecordingTests {
    /// Both kinds the suites replay: the session transcript
    /// (`TmuxProtocolTests`, `TmuxControlTransportTests`) and the bulk
    /// stream.
    @Test(arguments: ["session-basic", "bulk-output"])
    func everyRecordedCase_isFoundAndReadable(fixtureCase: String) throws {
        let recordings = TmuxRecording.all(fixtureCase)
        #expect(!recordings.isEmpty, "no recording of \(fixtureCase) under LimpidTests/Fixtures/tmux")
        for recording in recordings {
            #expect(try !recording.lines().isEmpty, "\(recording.name) holds no lines")
            // The version every replay reads for its expectations; a
            // manifest that does not decode would otherwise surface as a
            // failure in whichever test happened to read it first.
            #expect(try !recording.manifest().version.isEmpty, "\(recording.name) names no tmux version")
        }
    }

    /// `bulk-output`'s counts come from the manifest rather than the tests,
    /// so a manifest without them would leave those expectations unchecked.
    @Test func bulkOutputManifest_carriesTheCountsTheTestsCompare() throws {
        for recording in TmuxRecording.all("bulk-output") {
            let manifest = try recording.manifest()
            #expect((manifest.outputLines ?? 0) > 0, "\(recording.name) counts no %output lines")
            #expect((manifest.decodedBytes ?? 0) > 0, "\(recording.name) counts no decoded bytes")
        }
    }
}

@Suite("tmux control-mode protocol")
struct TmuxProtocolTests {
    // What these tests pin follows from the commands `record_tmux.py`
    // sends. What tmux picks per run (reply timestamps and numbers, the
    // pane's tty, the version) is checked by shape or read from the
    // manifest, so recording a case again leaves the tests passing.

    /// The first reply of `session-basic`, to
    /// `display-message '#{version}|#{pane_tty}|#{cursor_x} #{cursor_y} #{alternate_on}'`.
    private func isVersionReply(_ line: String, version: String) -> Bool {
        line.wholeMatch(of: /(.+)\|\/dev\/ttys[0-9]+\|2 0 0/)?.output.1 == Substring(version)
    }

    // MARK: - Line classification (session-basic)

    @Test(
        "the attach block, notifications, and the final %exit are classified from a real recording",
        arguments: TmuxRecording.all("session-basic")
    )
    func sessionBasic_classifiesEveryLineKind(recording: TmuxRecording) throws {
        let lines = try recording.lines().map { TmuxProtocol.parseLine($0[...]) }
        let version = try recording.manifest().version

        guard case let .begin(attach) = lines.first else {
            Issue.record("the recording does not open with the attach block: \(String(describing: lines.first))")
            return
        }
        #expect(attach.flags == 0)
        #expect(lines[1] == .end(attach))
        #expect(lines.contains(.notification(name: "session-changed", arguments: "$0 fx")))
        #expect(lines.contains(.windowRenamed(window: "@0", name: "bash")))
        #expect(lines.contains(.windowPaneChanged(window: "@0", pane: "%1")))
        #expect(lines.contains { line in
            if case let .text(text) = line {
                return isVersionReply(text, version: version)
            }
            return false
        })
        #expect(lines.contains { line in
            if case let .error(marker) = line {
                return marker.flags == 1
            }
            return false
        })
        #expect(lines.last == .exit(reason: nil))
    }

    @Test("%layout-change carries the window, both layout strings, and the flags field", arguments: TmuxRecording.all("session-basic"))
    func sessionBasic_layoutChangeFields(recording: TmuxRecording) throws {
        let lines = try recording.lines().map { TmuxProtocol.parseLine($0[...]) }
        let layouts = lines.compactMap { line -> String? in
            if case let .layoutChange(window, layout, visible, flags) = line {
                #expect(window == "@0")
                #expect(visible == layout)
                #expect(flags == "*")
                return layout
            }
            return nil
        }
        #expect(layouts.first == "a87d,100x30,0,0,0")
        #expect(layouts.contains("14f1,100x30,0,0{33x30,0,0,0,33x30,34,0,1,32x30,68,0,2}"))
        #expect(layouts.last == "7f4b,100x30,0,0{33x30,0,0,0,66x30,34,0,1}")
    }

    @Test("a layout fetch reply reads as the %layout-change it restates, flags included or empty")
    func layoutFetchReply_readsAsLayoutChange() {
        let zoomed = "6b8b,100x30,0,0{50x30,0,0,0,49x30,51,0,1} a87e,100x30,0,0,1 *Z"
        #expect(TmuxProtocol.layoutChange(window: "@0", reply: zoomed) == .layoutChange(
            window: "@0",
            layout: "6b8b,100x30,0,0{50x30,0,0,0,49x30,51,0,1}",
            visibleLayout: "a87e,100x30,0,0,1",
            flags: "*Z"
        ))
        // A window with no flags ends the reply with a space, as tmux 3.7c
        // prints it; the empty field is not a flags value.
        #expect(TmuxProtocol.layoutChange(window: "@1", reply: "a87f,100x30,0,0,2 a87f,100x30,0,0,2 ") == .layoutChange(
            window: "@1",
            layout: "a87f,100x30,0,0,2",
            visibleLayout: "a87f,100x30,0,0,2",
            flags: nil
        ))
        #expect(TmuxProtocol.layoutChange(window: "@1", reply: "") == nil)
        #expect(TmuxProtocol.layoutFormat == "#{window_layout} #{window_visible_layout} #{window_flags}")
    }

    @Test(
        "%output unescapes \\ooo for control bytes and for the backslash itself, and nothing else",
        arguments: TmuxRecording.all("session-basic")
    )
    func sessionBasic_outputBytesAreUnescaped(recording: TmuxRecording) throws {
        let lines = try recording.lines().map { TmuxProtocol.parseLine($0[...]) }
        let outputs = lines.compactMap { line -> (String, Data)? in
            if case let .output(pane, bytes) = line {
                return (pane, bytes)
            }
            return nil
        }
        // The prompt repaint: CR, ESC [ K, "$ ".
        #expect(outputs.first?.0 == "%0")
        #expect(outputs.first?.1 == Data([0x0D, 0x1B, 0x5B, 0x4B, 0x24, 0x20]))
        // The echoed printf: three backslashes (\134 each) around "033[31mhi".
        let echoed = outputs.map { TmuxProtocol.lossyText(Array($0.1)[...]) }
        #expect(echoed.contains("\\\\\\033[31mhi\\\\\\033[0m\\\\\\n"))
    }

    @Test("inside a reply block a line starting with % is the command's output, and only the block's own terminators are markers")
    func parseLine_insideBlock_keepsPercentLinesAsText() {
        let open = TmuxReplyMarker(timestamp: 1_789_549_530, number: 305, flags: 1)
        let paneID = Array("%0".utf8)[...]
        #expect(TmuxProtocol.parseLine(paneID, openBlock: open) == .text("%0"))
        #expect(TmuxProtocol.parseLine(paneID) == .notification(name: "0", arguments: ""))

        let layoutChange = Array("%layout-change @0 a87d,100x30,0,0,0 a87d,100x30,0,0,0 *".utf8)[...]
        #expect(TmuxProtocol.parseLine(layoutChange, openBlock: open) == .text(TmuxProtocol.lossyText(layoutChange)))

        let end = Array("%end 1789549530 305 1".utf8)[...]
        #expect(TmuxProtocol.parseLine(end, openBlock: open) == .end(open))
        let error = Array("%error 1789549530 305 1".utf8)[...]
        #expect(TmuxProtocol.parseLine(error, openBlock: open) == .error(open))
    }

    @Test("inside a reply block a %end or %error that is not the open block's terminator is a row of the reply", arguments: [
        "%end 1789549530 306 1",
        "%end 1789549531 305 1",
        "%end 1789549530 305 0",
        "%error 1789549530 304 1",
        "%end 1789549530 305 1 trailing",
        "%end 1789549530  305 1",
        "%end",
        "%end of the story",
        "%error: disk full",
        "%begin 1789549530 305 1",
    ])
    func parseLine_insideBlock_foreignTerminatorIsText(row: String) {
        let open = TmuxReplyMarker(timestamp: 1_789_549_530, number: 305, flags: 1)
        #expect(TmuxProtocol.parseLine(Array(row.utf8)[...], openBlock: open) == .text(row))
    }

    @Test("a terminator line with a trailing carriage return still ends its block")
    func parseLine_insideBlock_terminatorWithCarriageReturn() {
        let open = TmuxReplyMarker(timestamp: 7, number: 8, flags: 1)
        #expect(TmuxProtocol.parseLine(Array("%end 7 8 1\r".utf8)[...], openBlock: open) == .end(open))
    }

    @Test("rows that read like terminators do not cut a reply short or shift the replies after it")
    func assembler_rowsLookingLikeTerminators_keepRepliesPaired() {
        let capture = TmuxReplyMarker(timestamp: 100, number: 10, flags: 1)
        let next = TmuxReplyMarker(timestamp: 100, number: 11, flags: 1)
        let stream = [
            "%begin 0 9 0", "%end 0 9 0",
            "%begin 100 10 1",
            "$ printf '%end 1 2 1\\n'",
            "%end 1 2 1",
            "%error 100 10 0",
            "%end nothing numeric",
            "%end 100 10 1",
            "%begin 100 11 1",
            "second",
            "%end 100 11 1"
        ]
        var assembler = TmuxReplyAssembler()
        var events: [TmuxReplyAssembler.Event] = []
        for row in stream {
            let line = TmuxProtocol.parseLine(Array(row.utf8)[...], openBlock: assembler.openBlock)
            if let event = assembler.consume(line) {
                events.append(event)
            }
        }

        #expect(events == [
            .attachFinished(lines: [], isError: false),
            .reply(
                lines: ["$ printf '%end 1 2 1\\n'", "%end 1 2 1", "%error 100 10 0", "%end nothing numeric"],
                isError: false,
                marker: capture
            ),
            .reply(lines: ["second"], isError: false, marker: next)
        ])
        #expect(assembler.openBlock == nil)
    }

    @Test("the window notifications a store acts on are typed, both close names alike")
    func parseLine_windowNotifications_areTyped() {
        #expect(TmuxProtocol.parseLine(Array("%window-add @3".utf8)[...]) == .windowAdd(window: "@3"))
        #expect(TmuxProtocol.parseLine(Array("%window-close @3".utf8)[...]) == .windowClose(window: "@3", isUnlinked: false))
        #expect(TmuxProtocol.parseLine(Array("%unlinked-window-close @4".utf8)[...]) == .windowClose(window: "@4", isUnlinked: true))
        // Malformed forms are kept verbatim rather than reshaped.
        #expect(TmuxProtocol.parseLine(Array("%window-add".utf8)[...]) == .notification(name: "window-add", arguments: ""))
        #expect(TmuxProtocol.parseLine(Array("%window-close @3 extra".utf8)[...])
            == .notification(name: "window-close", arguments: "@3 extra"))
    }

    @Test("a backslash without three octal digits is passed through untouched")
    func unescape_leavesMalformedEscapesAlone() {
        #expect(TmuxProtocol.unescapeOutput(Array("a\\12".utf8)[...]) == Data("a\\12".utf8))
        #expect(TmuxProtocol.unescapeOutput(Array("\\9ab".utf8)[...]) == Data("\\9ab".utf8))
        #expect(TmuxProtocol.unescapeOutput(Array("\\".utf8)[...]) == Data("\\".utf8))
        #expect(TmuxProtocol.unescapeOutput(Array("\\000\\177".utf8)[...]) == Data([0x00, 0x7F]))
    }

    // MARK: - Reply assembly

    @Test(
        "the attach block is not a reply; every later block pairs with one command in order",
        arguments: TmuxRecording.all("session-basic")
    )
    func sessionBasic_repliesPairWithCommandsInOrder(recording: TmuxRecording) throws {
        let lines = try recording.lines().map { TmuxProtocol.parseLine($0[...]) }
        let commands = try String(contentsOf: recording.directory.appendingPathComponent("commands.txt"), encoding: .utf8)
            .split(separator: "\n")
        let version = try recording.manifest().version
        var assembler = TmuxReplyAssembler()
        let events = lines.compactMap { assembler.consume($0) }

        #expect(events.first == .attachFinished(lines: [], isError: false))
        struct Reply {
            let lines: [String]
            let isError: Bool
            let number: Int
        }
        let replies = events.dropFirst().compactMap { event -> Reply? in
            if case let .reply(lines, isError, marker) = event {
                return Reply(lines: lines, isError: isError, number: marker.number)
            }
            return nil
        }
        // tmux answered each command once, in the order they were sent.
        try #require(commands.count == 11)
        try #require(replies.count == commands.count)
        #expect(replies[0].lines.count == 1)
        #expect(isVersionReply(replies[0].lines.first ?? "", version: version))
        #expect(replies[0].isError == false)
        #expect(zip(replies, replies.dropFirst()).allSatisfy { $0.number < $1.number })
        #expect(replies[5].lines == ["77dd,100x30,0,0{50x30,0,0,0,49x30,51,0[49x15,51,0,1,49x14,51,16,2]}"])
        #expect(replies[8].isError == true)
        #expect(replies[8].lines == ["parse error: unknown command: bogus-command-for-error"])
        #expect(assembler.openBlock == nil)
    }

    @Test("a flags-0 block after a reply answers no command and yields nothing")
    func assembler_unsolicitedBlockAfterReply_isDropped() {
        var assembler = TmuxReplyAssembler()
        let attach = TmuxReplyMarker(timestamp: 1, number: 286, flags: 0)
        let split = TmuxReplyMarker(timestamp: 1, number: 291, flags: 1)
        let hook = TmuxReplyMarker(timestamp: 1, number: 292, flags: 0)
        let stream: [TmuxControlLine] = [
            .begin(attach), .end(attach),
            .begin(split), .end(split),
            .begin(hook), .text("hooked"), .end(hook)
        ]
        let events = stream.compactMap { assembler.consume($0) }

        #expect(events == [
            .attachFinished(lines: [], isError: false),
            .reply(lines: [], isError: false, marker: split)
        ])
        #expect(assembler.openBlock == nil)
    }

    /// Pairing is FIFO over the blocks, so a stream that opens or closes
    /// them out of order has already shifted which command a reply answers.
    /// The assembler says so rather than answering the oldest command with
    /// a block that is not its own; the transport ends the connection there
    /// (`TmuxControlTransport.handle`).
    @Test("a stream that breaks the block rules is reported as broken, not paired")
    func assembler_brokenBlockStream_isReported() {
        let open = TmuxReplyMarker(timestamp: 1, number: 5, flags: 1)
        let inner = TmuxReplyMarker(timestamp: 1, number: 6, flags: 1)
        let lower = TmuxReplyMarker(timestamp: 1, number: 4, flags: 1)

        var nested = TmuxReplyAssembler()
        #expect([TmuxControlLine.begin(open), .begin(inner)].compactMap { nested.consume($0) }
            == [.broken(.nestedBegin(begin: inner, open: open))])

        var loose = TmuxReplyAssembler()
        #expect([TmuxControlLine.end(open)].compactMap { loose.consume($0) }
            == [.broken(.terminatorWithoutBegin(open))])

        var backwards = TmuxReplyAssembler()
        let stream: [TmuxControlLine] = [.begin(open), .end(open), .begin(lower)]
        #expect(stream.compactMap { backwards.consume($0) } == [
            .reply(lines: [], isError: false, marker: open),
            .broken(.numberNotIncreasing(begin: lower, previous: open.number))
        ])
    }

    @Test("an attach block that ends in %error carries tmux's reason")
    func assembler_refusedAttach_carriesItsLines() {
        var assembler = TmuxReplyAssembler()
        let attach = TmuxReplyMarker(timestamp: 1, number: 299, flags: 0)
        let stream: [TmuxControlLine] = [.begin(attach), .text("can't find session: $99"), .error(attach)]
        let events = stream.compactMap { assembler.consume($0) }

        #expect(events == [.attachFinished(lines: ["can't find session: $99"], isError: true)])
    }

    @Test("inside a reply block a %output line is text, not pane output")
    func parseLine_insideBlock_outputPrefixIsText() {
        let row = Array("%output %0 injected".utf8)[...]
        let open = TmuxReplyMarker(timestamp: 1, number: 2, flags: 1)
        #expect(TmuxProtocol.parseLine(row, openBlock: open) == .text("%output %0 injected"))
        #expect(TmuxProtocol.parseLine(row) == .output(pane: "%0", bytes: Data("injected".utf8)))
    }

    // MARK: - Outbound

    @Test("send-keys -H arguments are one two-digit hex token per byte")
    func hexKeyArguments_matchSendKeysContract() {
        #expect(TmuxProtocol.hexKeyArguments(Data("ls\n".utf8)) == "6c 73 0a")
        #expect(TmuxProtocol.hexKeyArguments(Data([0x1B, 0x5B, 0x41])) == "1b 5b 41")
        #expect(TmuxProtocol.hexKeyArguments(Data()) == "")
    }

    @Test("quoting makes an argument literal, including embedded single quotes and spaces")
    func quote_isSingleQuotedWithEscapedQuote() {
        #expect(TmuxProtocol.quote("plain") == "'plain'")
        #expect(TmuxProtocol.quote("a b") == "'a b'")
        #expect(TmuxProtocol.quote("it's") == "'it'\\''s'")
        #expect(TmuxProtocol.quote("#{pane_id}") == "'#{pane_id}'")
    }

    // MARK: - Version

    @Test("a version prints in the form tmux prints and parses back to itself")
    func versionDescription_roundTripsThroughTheParser() throws {
        for text in ["3.3", "3.3a", "3.7c", "next-3.4", "4.0"] {
            let version = try #require(TmuxProtocol.parseVersion(text))
            #expect(version.description == text)
            #expect(TmuxProtocol.parseVersion(version.description) == version)
        }
    }

    @Test("release, patch-letter, and development version strings all parse and order correctly")
    func parseVersion_handlesTheThreeForms() throws {
        let v33a = try #require(TmuxProtocol.parseVersion("3.3a"))
        let v35 = try #require(TmuxProtocol.parseVersion("3.5"))
        let next34 = try #require(TmuxProtocol.parseVersion("next-3.4"))
        let v37c = try #require(TmuxProtocol.parseVersion("tmux 3.7c\n"))
        let v32a = try #require(TmuxProtocol.parseVersion("3.2a"))

        #expect(v33a == TmuxVersion(major: 3, minor: 3, patch: "a", isDevelopment: false))
        #expect(v35 == TmuxVersion(major: 3, minor: 5, patch: nil, isDevelopment: false))
        #expect(next34 == TmuxVersion(major: 3, minor: 4, patch: nil, isDevelopment: true))
        #expect(v37c == TmuxVersion(major: 3, minor: 7, patch: "c", isDevelopment: false))

        #expect(v33a < next34)
        #expect(next34 < v35)
        #expect(v35 < v37c)
        #expect(v33a.meets(major: 3, minor: 3))
        #expect(!v32a.meets(major: 3, minor: 3))
        #expect(TmuxProtocol.parseVersion("") == nil)
        #expect(TmuxProtocol.parseVersion("three") == nil)
    }

    // MARK: - Decode throughput (design §6)

    /// Always a decode check: the `%output` lines of the recording must
    /// unescape to the line and byte counts an independent decoder of
    /// `control.raw` gave (`record_bulk.py`, into the manifest). The speed half is a
    /// measurement, not a gate: wall-clock time in a shared, parallel Debug
    /// test process depends on the machine and its load, so the floor is
    /// asserted only when a measurement is asked for. xcodebuild forwards
    /// only `TEST_RUNNER_`-prefixed variables to the test process, with the
    /// prefix removed:
    ///
    ///     TEST_RUNNER_LIMPID_MEASURE_OUT=/tmp/decode.txt xcodebuild test \
    ///       -project Limpid.xcodeproj -scheme Limpid -destination 'platform=macOS' \
    ///       -only-testing:'LimpidTests/TmuxProtocolTests/bulkOutput_decodeThroughput(recording:)'
    @Test(
        "a recorded bulk stream decodes to its exact byte count; its speed is checked only when measuring",
        arguments: TmuxRecording.all("bulk-output")
    )
    func bulkOutput_decodeThroughput(recording: TmuxRecording) throws {
        let lines = try recording.lines()
        let manifest = try recording.manifest()
        let expectedBytes = try #require(manifest.decodedBytes)
        let expectedLines = try #require(manifest.outputLines)
        let inputBytes = lines.reduce(0) { $0 + $1.count + 1 }
        let clock = ContinuousClock()
        var decodedBytes = 0
        var outputLines = 0
        let passes = 5
        let elapsed = clock.measure {
            for _ in 0..<passes {
                for line in lines {
                    if case let .output(_, bytes) = TmuxProtocol.parseLine(line[...]) {
                        decodedBytes += bytes.count
                        outputLines += 1
                    }
                }
            }
        }
        #expect(outputLines == expectedLines * passes)
        #expect(decodedBytes == expectedBytes * passes)

        guard let path = ProcessInfo.processInfo.environment["LIMPID_MEASURE_OUT"] else { return }
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        let mebibytesPerSecond = Double(inputBytes * passes) / 1_048_576 / seconds
        // The spike moved 3.44 MiB/s end to end. If decoding alone were
        // near that, moving it to Rust would be worth discussing (design
        // §6); the floor sits well above it.
        #expect(mebibytesPerSecond > 20, "decode ran at \(mebibytesPerSecond) MiB/s")
        let record = "tmux %output decode: \(String(format: "%.1f", mebibytesPerSecond)) MiB/s over \(inputBytes) bytes x \(passes)\n"
        try? record.write(toFile: path, atomically: true, encoding: .utf8)
    }
}
