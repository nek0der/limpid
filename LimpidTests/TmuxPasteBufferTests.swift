// TmuxPasteBufferTests.swift
// Limpid — checks the rules and file handling of a mirror pane's paste, and the color report commands.

import Darwin
import Foundation
import Testing
@testable import Limpid

@Suite("tmux paste buffer")
struct TmuxPasteBufferTests {
    /// Stricter than an ordinary pane, which trusts a bracketed paste: we
    /// cannot tell whether the tmux pane has bracketed paste on (design m2).
    @Test("a paste that could run lines asks first", arguments: [
        ("echo hi", false),
        ("", false),
        ("tab\there", false),
        ("one\ntwo", true),
        ("trailing\n", true),
        ("carriage\r", true),
        ("crlf\r\n", true),
        ("end \u{1B}[201~ marker", true)
    ])
    func needsConfirmation_followsNewlinesAndEndMarker(text: String, expected: Bool) {
        #expect(TmuxPasteBuffer.needsConfirmation(text) == expected)
    }

    @Test("buffer names are ours and unique")
    func bufferName_isPrefixedAndUnique() {
        let id = UUID()
        #expect(TmuxPasteBuffer.bufferName(id: id) == "limpid-\(id.uuidString.lowercased())")
        #expect(TmuxPasteBuffer.bufferName() != TmuxPasteBuffer.bufferName())
    }

    @Test("the file is readable by us alone, in a directory only we can list")
    func writeFile_isPrivate() throws {
        try withTempDir { root in
            let directory = root.appendingPathComponent("paste")
            let text = "héllo\nwörld \u{1B}"
            let url = try TmuxPasteBuffer.writeFile(text, in: directory, name: "limpid-a")

            #expect(try Data(contentsOf: url) == Data(text.utf8))
            let fileMode = try #require(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
            #expect(fileMode & 0o777 == 0o600)
            let directoryMode = try #require(
                FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int
            )
            #expect(directoryMode & 0o777 == 0o700)
        }
    }

    /// `O_EXCL`: a file already at the path, or a link planted there, is
    /// never written through.
    @Test("an existing file is not overwritten")
    func writeFile_refusesAnExistingPath() throws {
        try withTempDir { root in
            let existing = root.appendingPathComponent("limpid-b")
            try Data("keep".utf8).write(to: existing)
            #expect(throws: POSIXError.self) {
                try TmuxPasteBuffer.writeFile("new", in: root, name: "limpid-b")
            }
            #expect(try Data(contentsOf: existing) == Data("keep".utf8))
        }
    }

    @Test("an empty paste writes an empty file")
    func writeFile_acceptsEmptyText() throws {
        try withTempDir { root in
            let url = try TmuxPasteBuffer.writeFile("", in: root, name: "limpid-c")
            #expect(try Data(contentsOf: url).isEmpty)
        }
    }

    @Test("the commands quote the buffer, the path, and the pane")
    func commands_areQuoted() {
        let file = URL(fileURLWithPath: "/tmp/it's here/limpid-x")
        let commands = TmuxPasteBuffer.commands(bufferName: "limpid-x", file: file, pane: "%3")
        #expect(commands.load == #"load-buffer -b 'limpid-x' '/tmp/it'\''s here/limpid-x'"#)
        #expect(commands.paste == "paste-buffer -p -d -b 'limpid-x' -t '%3'")
        #expect(TmuxPasteBuffer.deleteCommand(bufferName: "limpid-x") == "delete-buffer -b 'limpid-x'")
    }

    @Test("the size cap is 8 MiB")
    func byteLimit_isEightMebibytes() {
        #expect(TmuxPasteBuffer.byteLimit == 8 * 1024 * 1024)
    }
}

@Suite("tmux color report")
struct TmuxColorReportTests {
    private let colors = TerminalColors(
        foreground: .init(red: 0xDD, green: 0x0A, blue: 0xFF),
        background: .init(red: 0x1E, green: 0x00, blue: 0x2E)
    )

    @Test("colors are written the way OSC 10 and 11 replies write them")
    func x11_repeatsEachByte() {
        #expect(colors.foreground.x11 == "rgb:dddd/0a0a/ffff")
        #expect(colors.background.x11 == "rgb:1e1e/0000/2e2e")
    }

    @Test("one report per color, spelled for tmux's double quotes")
    func commands_reportBothColors() {
        #expect(TmuxColorReport.commands(pane: "%4", colors: colors) == [
            #"refresh-client -r "%4:\033]10;rgb:dddd/0a0a/ffff\033\\""#,
            #"refresh-client -r "%4:\033]11;rgb:1e1e/0000/2e2e\033\\""#
        ])
    }

    @Test("only a 3.5 or later server takes the report", arguments: [
        ("3.3a", false), ("3.4", false), ("next-3.5", true), ("3.5", true), ("3.5a", true), ("3.7c", true), ("4.0", true)
    ])
    func isSupported_startsAt35(version: String, expected: Bool) throws {
        let parsed = try #require(TmuxProtocol.parseVersion(version))
        #expect(TmuxColorReport.isSupported(by: parsed) == expected)
    }
}
