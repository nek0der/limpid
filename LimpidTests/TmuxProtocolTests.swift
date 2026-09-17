// TmuxProtocolTests.swift
// Limpid — pins the control-mode wire rules against traffic recorded from a real tmux server.

import Foundation
import Testing
@testable import Limpid

@Suite("tmux control-mode protocol")
struct TmuxProtocolTests {
    /// Every line of `control.raw`, without newlines, in order.
    private func recordedLines(_ fixtureCase: String) throws -> [[UInt8]] {
        let root = try #require(RepoFixture.limpidRoot)
        let url = root.appendingPathComponent("LimpidTests/Fixtures/tmux/2026-09/\(fixtureCase)/control.raw")
        let bytes = try Array(Data(contentsOf: url))
        var lines = bytes.split(separator: 0x0A, omittingEmptySubsequences: false).map(Array.init)
        if lines.last?.isEmpty == true {
            lines.removeLast()
        }
        return lines
    }

    // MARK: - Line classification (session-basic)

    @Test("the attach block, notifications, and the final %exit are classified from a real recording")
    func sessionBasic_classifiesEveryLineKind() throws {
        let lines = try recordedLines("session-basic").map { TmuxProtocol.parseLine($0[...]) }

        #expect(lines[0] == .begin(TmuxReplyMarker(timestamp: 1_789_549_529, number: 299, flags: 0)))
        #expect(lines[1] == .end(TmuxReplyMarker(timestamp: 1_789_549_529, number: 299, flags: 0)))
        #expect(lines.contains(.sessionChanged(session: "$0", name: "fx")))
        #expect(lines.contains(.windowRenamed(window: "@0", name: "bash")))
        #expect(lines.contains(.windowPaneChanged(window: "@0", pane: "%1")))
        #expect(lines.contains(.text("3.7c|/dev/ttys019|2 0 0")))
        #expect(lines.contains(.error(TmuxReplyMarker(timestamp: 1_789_549_534, number: 331, flags: 1))))
        #expect(lines.last == .exit(reason: nil))
    }

    @Test("%layout-change carries the window, both layout strings, and the flags field")
    func sessionBasic_layoutChangeFields() throws {
        let lines = try recordedLines("session-basic").map { TmuxProtocol.parseLine($0[...]) }
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

    @Test("%output unescapes \\ooo for control bytes and for the backslash itself, and nothing else")
    func sessionBasic_outputBytesAreUnescaped() throws {
        let lines = try recordedLines("session-basic").map { TmuxProtocol.parseLine($0[...]) }
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

    @Test("inside a reply block a line starting with % is the command's output, and only the terminators are markers")
    func parseLine_insideBlock_keepsPercentLinesAsText() {
        let paneID = Array("%0".utf8)[...]
        #expect(TmuxProtocol.parseLine(paneID, insideReplyBlock: true) == .text("%0"))
        #expect(TmuxProtocol.parseLine(paneID, insideReplyBlock: false) == .notification(name: "0", arguments: ""))

        let layoutChange = Array("%layout-change @0 a87d,100x30,0,0,0 a87d,100x30,0,0,0 *".utf8)[...]
        #expect(TmuxProtocol.parseLine(layoutChange, insideReplyBlock: true) == .text(TmuxProtocol.lossyText(layoutChange)))

        let end = Array("%end 1789549530 305 1".utf8)[...]
        #expect(TmuxProtocol.parseLine(end, insideReplyBlock: true) == .end(TmuxReplyMarker(
            timestamp: 1_789_549_530,
            number: 305,
            flags: 1
        )))
        let error = Array("%error 1789549534 331 1".utf8)[...]
        #expect(TmuxProtocol.parseLine(error, insideReplyBlock: true) == .error(TmuxReplyMarker(
            timestamp: 1_789_549_534,
            number: 331,
            flags: 1
        )))
    }

    @Test("a backslash without three octal digits is passed through untouched")
    func unescape_leavesMalformedEscapesAlone() {
        #expect(TmuxProtocol.unescapeOutput(Array("a\\12".utf8)[...]) == Data("a\\12".utf8))
        #expect(TmuxProtocol.unescapeOutput(Array("\\9ab".utf8)[...]) == Data("\\9ab".utf8))
        #expect(TmuxProtocol.unescapeOutput(Array("\\".utf8)[...]) == Data("\\".utf8))
        #expect(TmuxProtocol.unescapeOutput(Array("\\000\\177".utf8)[...]) == Data([0x00, 0x7F]))
    }

    // MARK: - Reply assembly

    @Test("the attach block is not a reply; every later block pairs with one command in order")
    func sessionBasic_repliesPairWithCommandsInOrder() throws {
        let lines = try recordedLines("session-basic").map { TmuxProtocol.parseLine($0[...]) }
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
        // commands.txt lists eleven commands; tmux answered each once.
        #expect(replies.count == 11)
        #expect(replies[0].lines == ["3.7c|/dev/ttys019|2 0 0"])
        #expect(replies[0].isError == false)
        #expect(replies.map(\.number) == [305, 306, 309, 318, 321, 322, 323, 330, 331, 332, 336])
        #expect(replies[5].lines == ["77dd,100x30,0,0{50x30,0,0,0,49x30,51,0[49x15,51,0,1,49x14,51,16,2]}"])
        #expect(replies[8].isError == true)
        #expect(replies[8].lines == ["parse error: unknown command: bogus-command-for-error"])
        #expect(assembler.isInsideBlock == false)
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
        #expect(assembler.isInsideBlock == false)
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
        #expect(TmuxProtocol.parseLine(row, insideReplyBlock: true) == .text("%output %0 injected"))
        #expect(TmuxProtocol.parseLine(row, insideReplyBlock: false) == .output(pane: "%0", bytes: Data("injected".utf8)))
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

    /// Always a decode check: every `%output` line of the recording must
    /// unescape to the byte count an independent decoder of `control.raw`
    /// gives (902,195 bytes over 636 lines). The speed half is a
    /// measurement, not a gate: wall-clock time in a shared, parallel Debug
    /// test process depends on the machine and its load, so the floor is
    /// asserted only when a measurement is asked for. xcodebuild forwards
    /// only `TEST_RUNNER_`-prefixed variables to the test process, with the
    /// prefix removed:
    ///
    ///     TEST_RUNNER_LIMPID_MEASURE_OUT=/tmp/decode.txt xcodebuild test \
    ///       -project Limpid.xcodeproj -scheme Limpid -destination 'platform=macOS' \
    ///       -only-testing:LimpidTests/TmuxProtocolTests/bulkOutput_decodeThroughput
    @Test("a recorded bulk stream decodes to its exact byte count; its speed is checked only when measuring")
    func bulkOutput_decodeThroughput() throws {
        let lines = try recordedLines("bulk-output")
        let inputBytes = lines.reduce(0) { $0 + $1.count + 1 }
        let clock = ContinuousClock()
        var decodedBytes = 0
        let passes = 5
        let elapsed = clock.measure {
            for _ in 0..<passes {
                for line in lines {
                    if case let .output(_, bytes) = TmuxProtocol.parseLine(line[...]) {
                        decodedBytes += bytes.count
                    }
                }
            }
        }
        #expect(decodedBytes == 902_195 * passes)

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
