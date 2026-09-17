// TmuxProtocol.swift
// Limpid — the tmux control-mode wire rules as pure functions: no I/O, no state.

import Foundation

/// One `%begin` / `%end` / `%error` marker: the fields tmux prints after the
/// keyword. The number lets a log line name the block it belongs to; the
/// flags tell a reply to our command from a block tmux emitted on its own
/// (see `TmuxReplyAssembler`).
struct TmuxReplyMarker: Equatable {
    let timestamp: Int
    let number: Int
    let flags: Int

    /// The block answers a command this control client wrote. tmux 3.7c
    /// prints 1 for those and 0 for the attach and for hooks; the manual
    /// still calls the field unused, which recorded traffic contradicts.
    var isClientCommand: Bool {
        flags != 0
    }
}

/// One line the control client received, classified. `%output` is the only
/// line that carries raw bytes; everything else is text.
enum TmuxControlLine: Equatable {
    case output(pane: String, bytes: Data)
    case begin(TmuxReplyMarker)
    case end(TmuxReplyMarker)
    case error(TmuxReplyMarker)
    case layoutChange(window: String, layout: String, visibleLayout: String?, flags: String?)
    case windowPaneChanged(window: String, pane: String)
    case windowRenamed(window: String, name: String)
    case sessionChanged(session: String, name: String)
    case exit(reason: String?)
    /// Any other `%name arguments` notification, kept verbatim so a caller
    /// can log what it does not handle instead of dropping it silently.
    case notification(name: String, arguments: String)
    /// A line inside a reply block other than its terminator, or any
    /// other line without a `%` prefix.
    case text(String)
}

/// A tmux version as `#{version}` or `tmux -V` reports it: `3.3a`, `3.5`,
/// `3.7c`, or the development form `next-3.4`. Ordered by major, minor, and
/// patch letter; a development build sorts with the release it precedes,
/// which is what a minimum-version gate needs.
struct TmuxVersion: Equatable, Comparable {
    let major: Int
    let minor: Int
    let patch: Character?
    let isDevelopment: Bool

    static func < (lhs: TmuxVersion, rhs: TmuxVersion) -> Bool {
        if lhs.major != rhs.major {
            return lhs.major < rhs.major
        }
        if lhs.minor != rhs.minor {
            return lhs.minor < rhs.minor
        }
        return (lhs.patch ?? " ") < (rhs.patch ?? " ")
    }

    func meets(major: Int, minor: Int) -> Bool {
        self >= TmuxVersion(major: major, minor: minor, patch: nil, isDevelopment: false)
    }
}

extension TmuxVersion: CustomStringConvertible {
    /// The form tmux prints and `TmuxProtocol.parseVersion` reads back.
    var description: String {
        (isDevelopment ? "next-" : "") + "\(major).\(minor)" + (patch.map { String($0) } ?? "")
    }
}

enum TmuxProtocol {
    /// Classify one line, without its trailing newline. `%output` is matched
    /// on bytes before any text decoding because its payload is arbitrary
    /// terminal output, not UTF-8.
    ///
    /// Inside a reply block tmux prints the command's output verbatim, so a
    /// line there is text even when it starts with `%` — a pane id is the
    /// everyday case, and a `capture-pane` row can read `%output …` — and
    /// only the block's own terminators are markers. That rule is applied
    /// before the `%output` match, or such a row would be routed to a pane
    /// as if the program had printed it. The caller tracks the block state;
    /// this function has none.
    static func parseLine(_ raw: ArraySlice<UInt8>, insideReplyBlock: Bool = false) -> TmuxControlLine {
        var line = raw
        if line.last == 0x0D {
            line = line.dropLast()
        }

        let outputPrefix = Array("%output ".utf8)
        if !insideReplyBlock, line.starts(with: outputPrefix) {
            let rest = line.dropFirst(outputPrefix.count)
            let paneEnd = rest.firstIndex(of: 0x20) ?? rest.endIndex
            let payload = paneEnd < rest.endIndex ? rest[(paneEnd + 1)...] : rest[rest.endIndex...]
            return .output(pane: lossyText(rest[rest.startIndex..<paneEnd]), bytes: unescapeOutput(payload))
        }

        let text = lossyText(line)
        guard text.hasPrefix("%") else { return .text(text) }
        let parts = text.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
        let name = String(parts[0].dropFirst())
        let arguments = parts.count > 1 ? String(parts[1]) : ""
        if insideReplyBlock, name != "end", name != "error" {
            return .text(text)
        }
        return parseNotification(name: name, arguments: arguments)
    }

    /// Text for bytes that are supposed to be UTF-8 but arrive from a
    /// process we do not control. Invalid sequences become U+FFFD instead
    /// of failing the whole line: a malformed pane id or notification is
    /// still worth logging with whatever was readable.
    static func lossyText(_ bytes: ArraySlice<UInt8>) -> String {
        // swiftlint:disable:next optional_data_string_conversion
        String(decoding: bytes, as: UTF8.self)
    }

    /// A `%name arguments` line. Anything we recognize but cannot parse
    /// falls back to `.notification` with the text intact, so a malformed
    /// line is logged rather than silently reshaped.
    private static func parseNotification(name: String, arguments: String) -> TmuxControlLine {
        let fields = arguments.split(separator: " ").map(String.init)
        let parsed: TmuxControlLine? = switch name {
        case "begin", "end", "error":
            parseReplyMarker(fields).map { replyLine(name, $0) }
        case "layout-change":
            parseLayoutChange(fields)
        case "window-pane-changed":
            fields.count >= 2 ? .windowPaneChanged(window: fields[0], pane: fields[1]) : nil
        case "window-renamed":
            // The name may contain spaces, so split off the id only.
            splitFirstField(arguments).map { .windowRenamed(window: $0.0, name: $0.1) }
        case "session-changed":
            splitFirstField(arguments).map { .sessionChanged(session: $0.0, name: $0.1) }
        case "exit":
            .exit(reason: arguments.isEmpty ? nil : arguments)
        default:
            nil
        }
        return parsed ?? .notification(name: name, arguments: arguments)
    }

    private static func replyLine(_ name: String, _ marker: TmuxReplyMarker) -> TmuxControlLine {
        switch name {
        case "begin": .begin(marker)
        case "end": .end(marker)
        default: .error(marker)
        }
    }

    /// The `display-message` format whose reply reads like the arguments of
    /// `%layout-change` after the window id: tmux prints `#{window_flags}`
    /// in the same form (`*Z`, or nothing) as that line's last field.
    static let layoutFormat = "#{window_layout} #{window_visible_layout} #{window_flags}"

    /// A reply to `layoutFormat` for `window`, read as the `%layout-change`
    /// it restates so a fetched layout and an announced one take one path.
    static func layoutChange(window: String, reply: String) -> TmuxControlLine? {
        parseLayoutChange([window] + reply.split(separator: " ").map(String.init))
    }

    /// `%layout-change @window layout [visible-layout [flags]]`; the last two
    /// arrived with tmux 2.9, so a 3.3 server always sends them, but we do
    /// not depend on it.
    private static func parseLayoutChange(_ fields: [String]) -> TmuxControlLine? {
        guard fields.count >= 2 else { return nil }
        return .layoutChange(
            window: fields[0],
            layout: fields[1],
            visibleLayout: fields.count > 2 ? fields[2] : nil,
            flags: fields.count > 3 ? fields[3] : nil
        )
    }

    private static func parseReplyMarker(_ fields: [String]) -> TmuxReplyMarker? {
        guard fields.count >= 3,
              let timestamp = Int(fields[0]), let number = Int(fields[1]), let flags = Int(fields[2])
        else { return nil }
        return TmuxReplyMarker(timestamp: timestamp, number: number, flags: flags)
    }

    /// The first space-separated field and everything after it, for a line
    /// whose last field is a name that may contain spaces.
    static func splitFirstField(_ arguments: String) -> (String, String)? {
        let split = arguments.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
        guard split.count == 2 else { return nil }
        return (String(split[0]), String(split[1]))
    }

    /// Undo control mode's escaping of `%output` payloads: every byte below
    /// 0x20 and the backslash itself arrive as `\ooo`, three octal digits.
    /// Bytes 0x7f and above pass through raw, which is why this works on
    /// bytes and not on a decoded string. A backslash that is not followed
    /// by three octal digits is kept as is; tmux never emits one, but the
    /// stream is not ours to trust.
    static func unescapeOutput(_ bytes: ArraySlice<UInt8>) -> Data {
        var out = Data()
        out.reserveCapacity(bytes.count)
        var index = bytes.startIndex
        while index < bytes.endIndex {
            let byte = bytes[index]
            if byte == 0x5C, index + 3 < bytes.endIndex {
                let d0 = bytes[index + 1], d1 = bytes[index + 2], d2 = bytes[index + 3]
                if isOctal(d0), isOctal(d1), isOctal(d2) {
                    let value = (Int(d0 - 0x30) << 6) | (Int(d1 - 0x30) << 3) | Int(d2 - 0x30)
                    out.append(UInt8(truncatingIfNeeded: value))
                    index += 4
                    continue
                }
            }
            out.append(byte)
            index += 1
        }
        return out
    }

    private static func isOctal(_ byte: UInt8) -> Bool {
        byte >= 0x30 && byte <= 0x37
    }

    /// Bytes as the `send-keys -H` argument list: one two-digit hex token per
    /// byte. Hex avoids every quoting problem a raw keystroke would have on
    /// tmux's command parser, and tmux writes the bytes to the pane as is.
    static func hexKeyArguments(_ bytes: Data) -> String {
        bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
    }

    /// Quote one argument for tmux's command parser. Single quotes make every
    /// byte literal; an embedded single quote is closed, escaped, and reopened,
    /// which is the one form tmux accepts for it.
    static func quote(_ argument: String) -> String {
        "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Parse `#{version}` or `tmux -V` output. Accepts `3.3a`, `3.5`, `3.7c`,
    /// `next-3.4`, and the same with a leading `tmux `.
    static func parseVersion(_ text: String) -> TmuxVersion? {
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.hasPrefix("tmux ") {
            body.removeFirst("tmux ".count)
        }
        var isDevelopment = false
        if body.hasPrefix("next-") {
            isDevelopment = true
            body.removeFirst("next-".count)
        }
        let parts = body.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, let major = Int(parts[0]) else { return nil }
        var minorText = Substring(parts[1])
        var patch: Character?
        if let last = minorText.last, last.isLetter {
            patch = last
            minorText = minorText.dropLast()
        }
        guard let minor = Int(minorText) else { return nil }
        return TmuxVersion(major: major, minor: minor, patch: patch, isDevelopment: isDevelopment)
    }
}
