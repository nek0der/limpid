// TmuxMirrorInputIntegrationTests.swift
// Limpid — a mirror pane's keys, text, pastes, and colors sent through a real tmux server, checked as the bytes its program receives.

import Foundation
import GhosttyKit
import Testing
@testable import Limpid

/// Terminal modes a pane's program can ask tmux for before input arrives.
/// Internal only because a parameterized test takes it as an argument.
enum PaneModes: String {
    case none = ""
    case application = #"\033[?1h\033="#
    case modifyOtherKeys2 = #"\033[>4;2m"#
}

/// A pane whose program switches the modes on, puts its tty in raw mode,
/// and copies every byte it receives into a file.
@MainActor
private struct RawPane {
    let paneID: String
    let output: URL

    static func open(in server: TmuxServerFixture, modes: PaneModes, window: String = "t") async throws -> RawPane {
        let output = server.directory.appendingPathComponent("raw-\(UUID().uuidString.prefix(8))")
        let script = #"printf '%b' "$1"; stty raw -echo; exec cat > "$2""#
        let paneID = try #require(server.run([
            "new-window", "-d", "-t", window, "-P", "-F", "#{pane_id}",
            "sh", "-c", script, "sh", modes.rawValue, output.path
        ]))
        let pane = RawPane(paneID: paneID, output: output)
        #expect(await waitUntil { (try? server.format("#{pane_current_command}", target: paneID)) == "cat" })
        return pane
    }

    /// What the program has received up to and including `marker`.
    func received(until marker: String) async -> Data {
        var data = Data()
        _ = await waitUntil(.seconds(30)) {
            data = (try? Data(contentsOf: output)) ?? Data()
            return data.range(of: Data(marker.utf8)) != nil
        }
        return data
    }
}

/// Separates the cases in one pane's input. U+2063 is typed by no key.
private func marker(_ index: Int) -> String {
    "\u{2063}\(index)\u{2063}"
}

private let endMarker = "\u{2063}end\u{2063}"

/// Split what the pane received at the markers, one entry per case.
private func segments(_ data: Data, count: Int) -> [Data] {
    (0..<count).map { index in
        guard let start = data.range(of: Data(marker(index).utf8)) else { return Data("<missing>".utf8) }
        let next = index + 1 < count ? marker(index + 1) : endMarker
        let end = data.range(of: Data(next.utf8), in: start.upperBound..<data.endIndex)?.lowerBound ?? data.endIndex
        return data[start.upperBound..<end]
    }
}

private let shift = GHOSTTY_MODS_SHIFT
private let ctrl = GHOSTTY_MODS_CTRL
private let alt = GHOSTTY_MODS_ALT

@Suite(
    "tmux mirror input",
    .tags(.smoke, .slow),
    .serialized,
    .disabled(if: TmuxServerFixture.isUnavailable, "tmux is not installed")
)
@MainActor
struct TmuxMirrorInputIntegrationTests {
    private func connect(_ server: TmuxServerFixture) async throws -> TmuxSessionConnection {
        let connection = try TmuxSessionConnection(
            executable: server.executable,
            target: .init(socketPath: server.socketPath, sessionID: server.format("#{session_id}"))
        )
        try connection.start()
        #expect(await waitUntil { connection.state == .attached })
        return connection
    }

    /// Send every case through the translator and the connection's batch,
    /// each behind its marker, all in one main-actor turn, then read back
    /// what the pane received for each.
    private func deliver(_ cases: [[TmuxInput]], to pane: RawPane, over connection: TmuxSessionConnection) async -> [Data] {
        for (index, inputs) in cases.enumerated() {
            connection.sendInput([.literal(marker(index))] + inputs, pane: pane.paneID)
        }
        connection.sendInput([.literal(endMarker)], pane: pane.paneID)
        return await segments(pane.received(until: endMarker), count: cases.count)
    }

    private struct Expectation {
        let inputs: [TmuxInput]
        let bytes: [UInt8]
        let label: String

        init(_ event: TmuxKeyEvent, _ bytes: String, _ label: String) {
            inputs = TmuxKeyTranslator.inputs(for: event)
            self.bytes = Array(bytes.utf8)
            self.label = label
        }

        init(text: String, _ bytes: String, _ label: String) {
            inputs = TmuxKeyTranslator.inputs(forText: Array(text.utf8))
            self.bytes = Array(bytes.utf8)
            self.label = label
        }
    }

    private func check(_ expectations: [Expectation], modes: PaneModes, extendedKeys: String) async throws {
        let server = try TmuxServerFixture.launch()
        defer { server.tearDown() }
        server.run(["set-option", "-g", "extended-keys", extendedKeys])
        let pane = try await RawPane.open(in: server, modes: modes)
        let connection = try await connect(server)
        defer { connection.stop() }

        let received = await deliver(expectations.map(\.inputs), to: pane, over: connection)
        for (expectation, bytes) in zip(expectations, received) {
            #expect(Array(bytes) == expectation.bytes, "\(expectation.label) with \(modes) / extended-keys \(extendedKeys)")
        }
    }

    // MARK: - Bytes per mode

    /// What every mode agrees on: text, pastes of control characters, and
    /// the chords that the rules rewrite.
    private var common: [Expectation] {
        [
            Expectation(mirrorKeyEvent(GHOSTTY_KEY_UNIDENTIFIED, text: "日本語"), "日本語", "input method commit"),
            Expectation(text: "-rf it's #{x}; ~\\", "-rf it's #{x}; ~\\", "text with parser syntax"),
            Expectation(text: "\n", "\n", "shift+enter binding"),
            Expectation(text: "a\r\u{7F}b", "a\r\u{7F}b", "text with control characters"),
            Expectation(mirrorKeyEvent(GHOSTTY_KEY_ENTER, [GHOSTTY_MODS_SUPER]), "", "command+enter"),
            Expectation(mirrorKeyEvent(GHOSTTY_KEY_F13), "", "F13"),
            Expectation(mirrorKeyEvent(GHOSTTY_KEY_SHIFT_LEFT, [shift]), "", "shift alone"),
            Expectation(mirrorKeyEvent(GHOSTTY_KEY_E, text: "´", isComposing: true), "", "dead key"),
            Expectation(mirrorKeyEvent(GHOSTTY_KEY_A, [alt], text: "å", unshifted: "a", isAltAlt: false), "å", "option as text"),
            Expectation(mirrorKeyEvent(GHOSTTY_KEY_ARROW_UP, [shift]), "\u{1B}[1;2A", "shift+up"),
            Expectation(mirrorKeyEvent(GHOSTTY_KEY_F5, [shift]), "\u{1B}[15;2~", "shift+F5"),
            Expectation(mirrorKeyEvent(GHOSTTY_KEY_PAGE_DOWN), "\u{1B}[6~", "page down"),
            Expectation(mirrorKeyEvent(GHOSTTY_KEY_DELETE), "\u{1B}[3~", "forward delete"),
            Expectation(mirrorKeyEvent(GHOSTTY_KEY_BACKSPACE), "\u{7F}", "backspace"),
            Expectation(mirrorKeyEvent(GHOSTTY_KEY_ESCAPE), "\u{1B}", "escape"),
            Expectation(mirrorKeyEvent(GHOSTTY_KEY_ENTER), "\r", "enter")
        ]
    }

    @Test("a pane without extended keys or application modes receives VT10x bytes")
    func vt10x_bytes() async throws {
        try await check(common + [
            Expectation(mirrorKeyEvent(GHOSTTY_KEY_ARROW_UP), "\u{1B}[A", "up"),
            Expectation(mirrorKeyEvent(GHOSTTY_KEY_C, [ctrl], text: "c", unshifted: "c"), "\u{03}", "ctrl+c"),
            Expectation(mirrorKeyEvent(GHOSTTY_KEY_C, [ctrl], text: "с", unshifted: "с"), "\u{03}", "ctrl+c on a Cyrillic layout"),
            Expectation(mirrorKeyEvent(GHOSTTY_KEY_A, [ctrl, shift], text: "A", unshifted: "a"), "\u{01}", "ctrl+shift+a"),
            Expectation(mirrorKeyEvent(GHOSTTY_KEY_A, [alt, shift], text: "A", unshifted: "a"), "\u{1B}A", "alt+shift+a"),
            Expectation(
                mirrorKeyEvent(GHOSTTY_KEY_DIGIT_2, [alt], text: "é", unshifted: "é"),
                "\u{1B}é",
                "alt on a layout's own character"
            ),
            Expectation(mirrorKeyEvent(GHOSTTY_KEY_BACKSPACE, [ctrl]), "\u{08}", "ctrl+backspace"),
            Expectation(mirrorKeyEvent(GHOSTTY_KEY_BACKSPACE, [ctrl, alt, shift]), "\u{1B}\u{08}", "ctrl+alt+shift+backspace"),
            Expectation(mirrorKeyEvent(GHOSTTY_KEY_ESCAPE, [ctrl]), "\u{1B}", "ctrl+escape"),
            Expectation(mirrorKeyEvent(GHOSTTY_KEY_ESCAPE, [ctrl, shift]), "\u{1B}", "ctrl+shift+escape"),
            Expectation(mirrorKeyEvent(GHOSTTY_KEY_ESCAPE, [ctrl, alt]), "\u{1B}\u{1B}", "ctrl+alt+escape"),
            Expectation(mirrorKeyEvent(GHOSTTY_KEY_TAB, [shift]), "\u{1B}[Z", "shift+tab"),
            Expectation(mirrorKeyEvent(GHOSTTY_KEY_TAB, [ctrl, shift]), "\u{1B}[Z", "ctrl+shift+tab"),
            Expectation(mirrorKeyEvent(GHOSTTY_KEY_NUMPAD_5, text: "5"), "5", "keypad 5"),
            Expectation(mirrorKeyEvent(GHOSTTY_KEY_NUMPAD_5, [ctrl, shift], text: "5"), "5", "ctrl+shift+keypad 5"),
            Expectation(mirrorKeyEvent(GHOSTTY_KEY_NUMPAD_5, [alt], text: "5"), "\u{1B}5", "alt+keypad 5"),
            Expectation(mirrorKeyEvent(GHOSTTY_KEY_SPACE, [ctrl], text: " ", unshifted: " "), "\u{00}", "ctrl+space"),
            Expectation(mirrorKeyEvent(GHOSTTY_KEY_NUMPAD_ENTER), "\r", "keypad enter"),
            Expectation(mirrorKeyEvent(GHOSTTY_KEY_MINUS, [ctrl, shift], text: "_", unshifted: "-"), "\u{1F}", "ctrl+shift+minus"),
            Expectation(mirrorKeyEvent(GHOSTTY_KEY_DIGIT_3, [ctrl, shift], text: "#", unshifted: "3"), "#", "ctrl+shift+3")
        ], modes: .none, extendedKeys: "off")
    }

    @Test("application cursor and keypad modes are tmux's to apply")
    func applicationModes_bytes() async throws {
        try await check(common + [
            Expectation(mirrorKeyEvent(GHOSTTY_KEY_ARROW_UP), "\u{1B}OA", "up"),
            Expectation(mirrorKeyEvent(GHOSTTY_KEY_NUMPAD_5, text: "5"), "\u{1B}Ou", "keypad 5"),
            Expectation(mirrorKeyEvent(GHOSTTY_KEY_NUMPAD_5, [ctrl], text: "5"), "\u{1B}Ou", "ctrl+keypad 5"),
            Expectation(mirrorKeyEvent(GHOSTTY_KEY_NUMPAD_ENTER), "\r", "keypad enter")
        ], modes: .application, extendedKeys: "off")
    }

    @Test("a program that asked for modifyOtherKeys gets the extended forms")
    func modifyOtherKeys_bytes() async throws {
        try await check(common + [
            Expectation(mirrorKeyEvent(GHOSTTY_KEY_ARROW_UP), "\u{1B}[A", "up"),
            Expectation(mirrorKeyEvent(GHOSTTY_KEY_C, [ctrl], text: "c", unshifted: "c"), "\u{1B}[27;5;99~", "ctrl+c"),
            Expectation(mirrorKeyEvent(GHOSTTY_KEY_BACKSPACE, [ctrl]), "\u{1B}[27;5;104~", "ctrl+backspace"),
            Expectation(mirrorKeyEvent(GHOSTTY_KEY_TAB, [shift]), "\u{1B}[27;2;9~", "shift+tab"),
            Expectation(mirrorKeyEvent(GHOSTTY_KEY_ENTER, [ctrl]), "\u{1B}[27;5;13~", "ctrl+enter")
        ], modes: .modifyOtherKeys2, extendedKeys: "on")
    }

    /// `always` is the server's choice, not ours (decision 6); tmux then
    /// sends extended forms where VT10x has none of its own.
    @Test("extended-keys always is applied by tmux, not by us")
    func extendedKeysAlways_bytes() async throws {
        try await check(common + [
            Expectation(mirrorKeyEvent(GHOSTTY_KEY_C, [ctrl], text: "c", unshifted: "c"), "\u{03}", "ctrl+c"),
            Expectation(mirrorKeyEvent(GHOSTTY_KEY_ENTER, [ctrl]), "\u{1B}[27;5;13~", "ctrl+enter")
        ], modes: .none, extendedKeys: "always")
    }

    /// Every chord the translator can produce reaches the program as bytes,
    /// never as the text of its own name, and never as nothing: the two ways
    /// tmux fails a key name (design m5).
    @Test(
        "no chord the translator produces is typed as its name or lost",
        arguments: [(PaneModes.none, "off"), (.application, "off"), (.modifyOtherKeys2, "on"), (.none, "always")]
    )
    func everyChord_isWritable(modes: PaneModes, extendedKeys: String) async throws {
        var events: [TmuxKeyEvent] = []
        let chords: [[ghostty_input_mods_e]] = [[ctrl], [alt], [ctrl, alt], [ctrl, shift], [alt, shift], [ctrl, alt, shift]]
        for value in 0x20..<0x7F {
            let character = Character(Unicode.Scalar(UInt8(value)))
            for mods in chords {
                events.append(mirrorKeyEvent(GHOSTTY_KEY_UNIDENTIFIED, mods, text: String(character), unshifted: character))
            }
        }
        let named: [ghostty_input_key_e] = [
            GHOSTTY_KEY_ENTER, GHOSTTY_KEY_TAB, GHOSTTY_KEY_BACKSPACE, GHOSTTY_KEY_ESCAPE,
            GHOSTTY_KEY_ARROW_UP, GHOSTTY_KEY_HOME, GHOSTTY_KEY_END, GHOSTTY_KEY_PAGE_UP, GHOSTTY_KEY_INSERT,
            GHOSTTY_KEY_DELETE, GHOSTTY_KEY_F1, GHOSTTY_KEY_F12,
            GHOSTTY_KEY_NUMPAD_0, GHOSTTY_KEY_NUMPAD_DECIMAL, GHOSTTY_KEY_NUMPAD_DIVIDE, GHOSTTY_KEY_NUMPAD_MULTIPLY,
            GHOSTTY_KEY_NUMPAD_SUBTRACT, GHOSTTY_KEY_NUMPAD_ADD, GHOSTTY_KEY_NUMPAD_ENTER
        ]
        for key in named {
            for mods in chords + [[], [shift]] {
                events.append(mirrorKeyEvent(key, mods))
            }
        }
        let cases = events.map(TmuxKeyTranslator.inputs(for:))
        #expect(!cases.contains { $0.isEmpty })

        let server = try TmuxServerFixture.launch()
        defer { server.tearDown() }
        server.run(["set-option", "-g", "extended-keys", extendedKeys])
        let pane = try await RawPane.open(in: server, modes: modes)
        let connection = try await connect(server)
        defer { connection.stop() }

        let received = await deliver(cases, to: pane, over: connection)
        for (inputs, bytes) in zip(cases, received) {
            // Latin-1 decodes any bytes; the names looked for are ASCII.
            let text = String(bytes: bytes, encoding: .isoLatin1) ?? ""
            let isNameTyped = inputs.contains { input in
                guard case let .key(name) = input else { return false }
                return name.count > 1 && text.contains(name)
            }
            #expect(!bytes.isEmpty && !isNameTyped, "\(inputs) received \(Array(bytes))")
        }
    }

    // MARK: - Copy mode

    /// The reason keys are named at all: the raw arrow sequence ends copy
    /// mode, the name moves within it.
    @Test("in copy mode, up moves the cursor and q leaves")
    func copyMode_takesNamedKeys() async throws {
        let server = try TmuxServerFixture.launch()
        defer { server.tearDown() }
        let paneID = try server.format("#{pane_id}")
        server.run(["send-keys", "-t", paneID, "seq 1 50", "Enter"])
        // "49" is printed by seq only; the typed command line reads "50".
        #expect(await waitUntil { (server.run(["capture-pane", "-p", "-t", paneID]) ?? "").contains("49") })
        let connection = try await connect(server)
        defer { connection.stop() }
        server.run(["copy-mode", "-t", paneID])
        let start = try #require(Int(server.format("#{copy_cursor_y}", target: paneID)))

        connection.sendInput(TmuxKeyTranslator.inputs(for: mirrorKeyEvent(GHOSTTY_KEY_ARROW_UP)), pane: paneID)
        #expect(await waitUntil { (try? server.format("#{copy_cursor_y}", target: paneID)) == String(start - 1) })
        #expect(try server.format("#{pane_in_mode}", target: paneID) == "1")

        connection.sendInput(
            TmuxKeyTranslator.inputs(for: mirrorKeyEvent(GHOSTTY_KEY_Q, text: "q", unshifted: "q")),
            pane: paneID
        )
        #expect(await waitUntil { (try? server.format("#{pane_in_mode}", target: paneID)) == "0" })
    }

    // MARK: - Colors

    /// tmux answers a control-mode pane's color query with black unless the
    /// client reports the colors, per pane (design M4).
    @Test("a pane's color query is answered with the reported colors, before and after they change")
    func colorQuery_answersReportedColors() async throws {
        let server = try TmuxServerFixture.launch()
        defer { server.tearDown() }
        let output = server.directory.appendingPathComponent("colors")
        let first = server.directory.appendingPathComponent("go1")
        let second = server.directory.appendingPathComponent("go2")
        let query = #"printf '\033]10;?\033\\\033]11;?\033\\'"#
        let wait = #"while [ ! -e "$1" ]; do sleep 0.05; done"#
        let script = "stty raw -echo; \(wait); \(query); shift; \(wait); \(query); exec cat > \"$2\""
        let paneID = try #require(server.run([
            "new-window", "-d", "-t", "t", "-P", "-F", "#{pane_id}",
            "sh", "-c", script, "sh", first.path, second.path, output.path
        ]))

        let dark = TerminalColors(
            foreground: .init(red: 0xDD, green: 0xDD, blue: 0xDD),
            background: .init(red: 0x1E, green: 0x1E, blue: 0x2E)
        )
        let light = TerminalColors(
            foreground: .init(red: 0x10, green: 0x20, blue: 0x30),
            background: .init(red: 0xFA, green: 0xFB, blue: 0xFC)
        )
        let connection = try TmuxSessionConnection(
            executable: server.executable,
            target: .init(socketPath: server.socketPath, sessionID: server.format("#{session_id}"))
        )
        defer { connection.stop() }
        connection.terminalColors = dark
        try connection.start()
        // Attached before the server's version is known, as a mirror does.
        let channel = try TmuxPaneChannel { _ in }
        _ = try connection.attachPane(paneID, channel: channel) {}
        #expect(await waitUntil { connection.version != nil })
        var isSettled = false
        connection.send("display-message -p ok") { _, _ in isSettled = true }
        #expect(await waitUntil { isSettled })
        FileManager.default.createFile(atPath: first.path, contents: nil)
        // The script polls every 50 ms; the first query has to be answered
        // before the colors change.
        try await Task.sleep(for: .milliseconds(500))

        connection.terminalColors = light
        isSettled = false
        connection.send("display-message -p ok") { _, _ in isSettled = true }
        #expect(await waitUntil { isSettled })
        FileManager.default.createFile(atPath: second.path, contents: nil)

        let expected = "\u{1B}]10;rgb:dddd/dddd/dddd\u{1B}\\\u{1B}]11;rgb:1e1e/1e1e/2e2e\u{1B}\\"
            + "\u{1B}]10;rgb:1010/2020/3030\u{1B}\\\u{1B}]11;rgb:fafa/fbfb/fcfc\u{1B}\\"
        var received = ""
        _ = await waitUntil(.seconds(5)) {
            received = (try? String(contentsOf: output, encoding: .utf8)) ?? ""
            return received == expected
        }
        #expect(received == expected)
    }
}

// MARK: - Paste

/// A mirror tab on the session's first window, the way
/// `TmuxMirrorActions.open` wires it, without surfaces.
@MainActor
private struct PasteHarness {
    let server: TmuxServerFixture
    let session: WindowSession
    let store: TmuxConnectionStore
    let mirror: TmuxWindowMirror
    let tabID: UUID
    let failures: FailureLog

    @MainActor
    final class FailureLog {
        var messages: [String] = []
    }

    /// `paneCommands` are typed into the window's panes, which are split
    /// until there are as many, before the mirror opens.
    static func make(paneCommands: [String]) async throws -> PasteHarness {
        try await TmuxServerFixture.launch { server in
            let sessionID = try server.format("#{session_id}")
            let windowID = try #require(server.windowIDs().first)
            for _ in 1..<paneCommands.count {
                server.run(["split-window", "-t", windowID, "sh", "-c", "PS1='$ ' exec sh"])
            }
            let panes = try #require(server.run(["list-panes", "-t", windowID, "-F", "#{pane_id}"])).split(separator: "\n")
            for (pane, command) in zip(panes, paneCommands) {
                server.run(["send-keys", "-t", String(pane), command, "Enter"])
            }
            let binding = TmuxBinding(socketPath: server.socketPath, sessionID: sessionID, sessionName: "t")
            let session = WindowSession()
            let tab = session.openTab(container: .loose)
            let leafID = try #require(tab.splitTree.allLeafIDs().first)
            session.update(tab.id) { t in
                t.kind = .tmuxMirror
                t.paneSources[leafID] = .tmux(TmuxPaneRef(binding: binding, windowID: windowID, paneID: String(panes[0])))
            }
            let store = TmuxConnectionStore(registry: RecordingSurfaceRegistry(), secureInput: nil, tmuxExecutable: server.executable)
            let connection = try store.connection(for: binding)
            let mirror = TmuxWindowMirror(
                tabID: tab.id,
                windowID: windowID,
                sessionName: "t",
                windowName: "w",
                connection: connection,
                isNewTab: true,
                session: session,
                registry: RecordingSurfaceRegistry(),
                secureInput: nil,
                channelForPane: { store.channel(paneID: $0) },
                surfaceReports: { store.surfaceReports }
            )
            let failures = FailureLog()
            mirror.onCommandFailed = { failures.messages.append($0) }
            store.register(mirror)
            mirror.start()
            #expect(await waitUntil { connection.state == .attached })
            store.reportTestGrid(columns: 80, rows: 24, tabID: tab.id, leafID: leafID)
            #expect(await waitUntil { mirror.cellLayout != nil && session.tab(tab.id)?.splitTree.allLeafIDs().count == paneCommands.count })
            return PasteHarness(server: server, session: session, store: store, mirror: mirror, tabID: tab.id, failures: failures)
        }
    }

    func leaf(of tmuxPane: String) -> UUID? {
        session.tab(tabID)?.paneSources.first { entry in
            if case let .tmux(ref) = entry.value {
                return ref.paneID == tmuxPane
            }
            return false
        }?.key
    }

    func tearDown() {
        store.stopAll()
        server.tearDown()
    }
}

@Suite(
    "tmux mirror paste",
    .tags(.smoke),
    .serialized,
    .disabled(if: TmuxServerFixture.isUnavailable, "tmux is not installed")
)
@MainActor
struct TmuxMirrorPasteIntegrationTests {
    private func rawCommand(modes: String, output: URL) -> String {
        "printf '\(modes)'; stty raw -echo; exec cat > '\(output.path)'"
    }

    /// Outputs and paste files live in their own directory, removed with the
    /// test; the fixture's directory holds the server socket.
    private func scratchDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("limpid-paste-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func isEmpty(_ directory: URL) -> Bool {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? ["?"]).isEmpty
    }

    @Test("a paste is bracketed exactly when the program asked, and leaves no file or buffer behind")
    func paste_followsThePanesBracketedPasteMode() async throws {
        let root = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("paste")
        let bracketed = root.appendingPathComponent("bracketed")
        let plain = root.appendingPathComponent("plain")
        let harness = try await PasteHarness.make(paneCommands: [
            rawCommand(modes: #"\033[?2004h"#, output: bracketed),
            rawCommand(modes: "", output: plain)
        ])
        defer { harness.tearDown() }
        let panes = harness.server.panes().map { String($0.split(separator: " ")[0]) }
        #expect(await waitUntil {
            panes.allSatisfy { (try? harness.server.format("#{pane_current_command}", target: $0)) == "cat" }
        })
        let first = try #require(harness.leaf(of: panes[0]))
        let second = try #require(harness.leaf(of: panes[1]))

        harness.mirror.paste("-one 'x'\ntwo", paneID: first, directory: directory)
        harness.mirror.paste("-one 'x'\ntwo", paneID: second, directory: directory)

        let expectedBracketed = Data("\u{1B}[200~-one 'x'\rtwo\u{1B}[201~".utf8)
        let expectedPlain = Data("-one 'x'\rtwo".utf8)
        var got = (bracketed: Data(), plain: Data())
        _ = await waitUntil(.seconds(5)) {
            got = ((try? Data(contentsOf: bracketed)) ?? Data(), (try? Data(contentsOf: plain)) ?? Data())
            return got.bracketed.count >= expectedBracketed.count && got.plain.count >= expectedPlain.count
        }
        #expect(got.bracketed == expectedBracketed)
        #expect(got.plain == expectedPlain)
        #expect(await waitUntil { isEmpty(directory) })
        #expect(harness.server.run(["list-buffers"]) == "")
        #expect(harness.failures.messages.isEmpty)
    }

    /// A file dropped on a mirror pane types what the same drop types in
    /// an ordinary pane, sent as a tmux paste: bracketed exactly when the
    /// program asked, into the pane it was dropped on and no other.
    @Test("dropped files reach the tmux pane as their quoted paths, through a paste")
    func dropFiles_typesTheQuotedPathsIntoThatPane() async throws {
        let root = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bracketed = root.appendingPathComponent("bracketed")
        let untouched = root.appendingPathComponent("untouched")
        let harness = try await PasteHarness.make(paneCommands: [
            rawCommand(modes: #"\033[?2004h"#, output: bracketed),
            rawCommand(modes: "", output: untouched)
        ])
        defer { harness.tearDown() }
        let panes = harness.server.panes().map { String($0.split(separator: " ")[0]) }
        #expect(await waitUntil {
            panes.allSatisfy { (try? harness.server.format("#{pane_current_command}", target: $0)) == "cat" }
        })
        let first = try #require(harness.leaf(of: panes[0]))
        let files = [
            URL(fileURLWithPath: "/tmp/shot one.png"),
            URL(fileURLWithPath: "/tmp/it's here.txt")
        ]

        TmuxMirrorActions.dropFiles(
            files,
            into: first,
            view: nil,
            session: harness.session,
            store: harness.store,
            toastCenter: nil
        )

        let typed = FileDropText.text(for: files)
        #expect(typed == #"'/tmp/shot one.png' '/tmp/it'\''s here.txt'"#)
        let expected = Data("\u{1B}[200~\(typed)\u{1B}[201~".utf8)
        var got = Data()
        _ = await waitUntil(.seconds(5)) {
            got = (try? Data(contentsOf: bracketed)) ?? Data()
            return got.count >= expected.count
        }
        #expect(got == expected)
        #expect((try? Data(contentsOf: untouched)) ?? Data() == Data())
        #expect(harness.server.run(["list-buffers"]) == "")
        #expect(harness.failures.messages.isEmpty)
    }

    /// Review's text takes the same route as any other paste into a mirror
    /// pane — never libghostty's, which would reach a surface nothing runs
    /// on — and the comments are marked as sent only because it arrived.
    @Test("review's text reaches the tmux pane as a paste, and nothing is taken back")
    func deliverReview_pastesThroughTmux() async throws {
        let root = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bracketed = root.appendingPathComponent("bracketed")
        let harness = try await PasteHarness.make(paneCommands: [
            rawCommand(modes: #"\033[?2004h"#, output: bracketed)
        ])
        defer { harness.tearDown() }
        let panes = harness.server.panes().map { String($0.split(separator: " ")[0]) }
        #expect(await waitUntil { (try? harness.server.format("#{pane_current_command}", target: panes[0])) == "cat" })
        let leaf = try #require(harness.leaf(of: panes[0]))
        let receipt = ReviewPasteReceipt(root: root, commentIDs: [UUID()])
        var refused: [[UUID]] = []
        let observer = NotificationCenter.default.addObserver(
            forName: .limpidReviewPasteDenied,
            object: nil,
            queue: .main
        ) { note in
            guard let denied = note.object as? ReviewPasteReceipt, denied.root == root else { return }
            MainActor.assumeIsolated { refused.append(denied.commentIDs) }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        TmuxMirrorActions.deliverReview(
            "Fix the comment above",
            receipt: receipt,
            into: leaf,
            view: nil,
            session: harness.session,
            store: harness.store,
            toastCenter: nil,
            confirmation: nil
        )

        let expected = Data("\u{1B}[200~Fix the comment above\u{1B}[201~".utf8)
        var got = Data()
        _ = await waitUntil(.seconds(5)) {
            got = (try? Data(contentsOf: bracketed)) ?? Data()
            return got.count >= expected.count
        }
        #expect(got == expected)
        #expect(refused.isEmpty)
        #expect(harness.failures.messages.isEmpty)
    }

    /// A pane tmux no longer has fails the paste after the buffer loaded;
    /// the buffer is deleted and the user is told.
    @Test("a paste tmux refuses deletes its buffer and its file, and is reported")
    func paste_refused_cleansUp() async throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let harness = try await PasteHarness.make(paneCommands: ["true", "true"])
        defer { harness.tearDown() }
        let panes = harness.server.panes().map { String($0.split(separator: " ")[0]) }
        let doomed = try #require(harness.leaf(of: panes[1]))
        // Killed and pasted into in one turn, before the layout change that
        // would take the leaf away can be handled.
        harness.server.run(["kill-pane", "-t", panes[1]])
        harness.mirror.paste("gone", paneID: doomed, directory: directory)

        #expect(await waitUntil { harness.failures.messages == [String(localized: "Couldn't paste into the pane")] })
        #expect(await waitUntil { harness.server.run(["list-buffers"]) == "" })
        #expect(await waitUntil { isEmpty(directory) })
    }
}
