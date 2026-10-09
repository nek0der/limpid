// TerminalLinkPolicy.swift
// Limpid — decides what a ⌘-clicked terminal link may do before anything
// reaches Launch Services.
//
// The character, scheme, and file-safety rules are adapted from Ghostty's
// macOS app (`macos/Sources/Helpers/UntrustedURL.swift`, ghostty-org/ghostty
// 77537c806). Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors.
// MIT License; the full text is in THIRD-PARTY-NOTICES.

import Foundation
import UniformTypeIdentifiers

/// Where the link text came from. The distinction is about who chose the
/// target: a match is text the reader can see, while an OSC 8 hyperlink's
/// target is picked by whatever wrote to the terminal and need not resemble
/// the visible label.
enum TerminalLinkSource: Equatable {
    case matchedText
    case hyperlink
}

/// The one thing a click is allowed to do.
enum TerminalLinkAction: Equatable {
    /// Hand the URL to its default handler. Used for web and mail links and
    /// for folders, which open in Finder.
    case open(URL)
    /// Open a regular file in the reader's file app, at the position when
    /// the link carried one.
    case openFile(URL, FilePosition?)
    /// Show the item in Finder rather than opening it. Used for files that
    /// could execute code, so a click can never launch them.
    case reveal(URL)
    /// Ask before dispatching a custom scheme to whichever application has
    /// registered it.
    case confirm(URL)
    case reject(TerminalLinkRejection)
}

enum TerminalLinkRejection: Equatable {
    case malformed
    case unsafeCharacters
    case invalidWebURL
    case remoteFile
    case missingFile
    case specialFile

    var message: LocalizedStringResource {
        switch self {
        case .malformed:
            "The link isn’t a valid address."
        case .unsafeCharacters:
            "The link contains invisible or line-breaking characters."
        case .invalidWebURL:
            "The web link has no host."
        case .remoteFile:
            "The link points to a file on another computer."
        case .missingFile:
            "The file doesn’t exist."
        case .specialFile:
            "The link points to something that isn’t a file or folder."
        }
    }
}

/// Every terminal link click goes through
/// `action(for:source:baseDirectories:)`. The file rules apply to both
/// sources: a visible path to an application or script is no safer to
/// launch than a hidden one, because the text on screen was still written
/// by the program in the pane.
enum TerminalLinkPolicy {
    /// Schemes the reader can reasonably expect to open in a browser or mail
    /// client without side effects beyond showing something.
    private static let webSchemes: Set<String> = ["http", "https"]

    /// The schemes libghostty's link matcher recognizes in plain text
    /// (`url_schemes` in `vendor/ghostty/src/config/url.zig`). Anything else
    /// in matched text only looks like a scheme — `notes.txt:12` parses as
    /// the scheme `notes.txt` — and is read as a path.
    private static let matchedSchemes: Set<String> = [
        "http", "https", "mailto", "ftp", "file", "ssh", "git", "tel",
        "magnet", "ipfs", "ipns", "gemini", "gopher", "news"
    ]

    /// `baseDirectories` are where a relative path is looked up, in order.
    static func action(
        for text: String,
        source: TerminalLinkSource,
        baseDirectories: [URL] = []
    ) -> TerminalLinkAction {
        guard !text.isEmpty else { return .reject(.malformed) }

        // Foundation accepts control and formatting characters that AppKit
        // would render as extra lines, zero-width text, or reordered text, so
        // they are rejected before parsing can change their representation.
        guard !text.unicodeScalars.contains(where: isUnsafeCharacter) else {
            return .reject(.unsafeCharacters)
        }

        guard let url = URL(string: text),
              let scheme = url.scheme?.lowercased(),
              !scheme.isEmpty,
              source == .hyperlink || matchedSchemes.contains(scheme)
        else {
            return pathAction(for: text, source: source, baseDirectories: baseDirectories)
        }

        if webSchemes.contains(scheme) {
            // "https:relative" has a scheme but no authority, and consumers
            // resolve it against different bases.
            guard let host = url.host, !host.isEmpty else { return .reject(.invalidWebURL) }
            return .open(url)
        }

        switch scheme {
        case "mailto":
            // A bare "mailto:" would open an empty draft.
            guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  !components.path.isEmpty
            else { return .reject(.malformed) }
            return .open(url)
        case "file":
            return fileURLAction(for: url)
        default:
            // A matched link's scheme is one of libghostty's and is spelled
            // out on screen. A hyperlink's can name any handler.
            return source == .matchedText ? .open(url) : .confirm(url)
        }
    }

    /// Scheme-less text is only ever a match; OSC 8 requires a URI. A
    /// hyperlink without a scheme could be reinterpreted by a later layer, so
    /// it is refused.
    ///
    /// libghostty joins a relative match onto the pane's working directory
    /// only when that exact file exists, so a match carrying a line number
    /// arrives relative and is looked up here instead.
    private static func pathAction(
        for text: String,
        source: TerminalLinkSource,
        baseDirectories: [URL]
    ) -> TerminalLinkAction {
        guard source == .matchedText else { return .reject(.malformed) }
        for reference in TerminalPathReference.candidates(for: text) {
            let expanded = NSString(string: reference.path).expandingTildeInPath
            let locations = expanded.hasPrefix("/")
                ? [URL(fileURLWithPath: expanded)]
                : baseDirectories.map { $0.appendingPathComponent(expanded) }
            if let found = locations.first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
                return fileAction(for: found, position: reference.position)
            }
        }
        return .reject(.missingFile)
    }

    private static func fileURLAction(for url: URL) -> TerminalLinkAction {
        // A query or fragment does not identify part of a file, and Launch
        // Services handlers read them inconsistently.
        guard url.query == nil, url.fragment == nil else { return .reject(.malformed) }
        // An empty host and localhost both mean this machine; any other host
        // could trigger network access.
        if let host = url.host, !host.isEmpty, host.caseInsensitiveCompare("localhost") != .orderedSame {
            return .reject(.remoteFile)
        }
        return fileAction(for: url)
    }

    /// Classifies the object the path resolves to, not its spelling, so dot
    /// segments and a harmless-looking symlink cannot hide an executable.
    static func fileAction(for url: URL, position: FilePosition? = nil) -> TerminalLinkAction {
        let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
        let values: URLResourceValues
        do {
            values = try canonical.resourceValues(forKeys: [
                .contentTypeKey,
                .isDirectoryKey,
                .isExecutableKey,
                .isRegularFileKey
            ])
        } catch {
            return .reject(.missingFile)
        }
        // Devices, sockets, and FIFOs have no sensible handler.
        guard values.isDirectory == true || values.isRegularFile == true else {
            return .reject(.specialFile)
        }
        if isUnsafeFile(canonical, values: values) {
            return .reveal(canonical)
        }
        return values.isDirectory == true ? .open(canonical) : .openFile(canonical, position)
    }

    private static func isUnsafeFile(_ url: URL, values: URLResourceValues) -> Bool {
        // Launch Services picks a handler by extension, so known executable
        // containers are blocked even when their executable bit is clear.
        if unsafePathExtensions.contains(url.pathExtension.lowercased()) {
            return true
        }
        // The content type catches files whose extension is missing or
        // misleading; the broad types include scripts and app bundles.
        if let type = values.contentType, unsafeContentTypes.contains(where: { type.conforms(to: $0) }) {
            return true
        }
        // A directory's execute bit means "searchable", not "runnable".
        return values.isDirectory != true && values.isExecutable == true
    }

    /// A single-line form of the target for the confirmation prompt. Escaping
    /// happens after normalization so any unsafe scalar left over is shown as
    /// text and cannot start a second line.
    static func displayString(for url: URL) -> String {
        let normalized = url.isFileURL
            ? url.standardizedFileURL.resolvingSymlinksInPath().path
            : url.absoluteString
        var result = ""
        for scalar in normalized.unicodeScalars {
            if isUnsafeCharacter(scalar) {
                result += "\\u{\(String(scalar.value, radix: 16, uppercase: true))}"
            } else {
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    static func isUnsafeCharacter(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        // C0 and C1 controls, including CR, LF, and NEL.
        case 0x00...0x1F, 0x7F...0x9F:
            true
        // Directional marks and zero-width characters can reorder or hide
        // part of the target without changing what the handler receives.
        case 0x061C, 0x200B...0x200F, 0x202A...0x202E, 0x2066...0x2069:
            true
        // Line and paragraph separators start new visual lines in AppKit.
        case 0x2028...0x2029:
            true
        // Word joiner and BOM are invisible padding.
        case 0x2060, 0xFEFF:
            true
        default:
            false
        }
    }

    private static let unsafePathExtensions: Set<String> = [
        "action", "app", "applescript", "class", "command", "desktop", "inetloc",
        "jar", "mobileconfig", "mpkg", "pkg", "scpt", "terminal", "tool", "url",
        "webloc", "workflow"
    ]

    private static let unsafeContentTypes: [UTType] = [.application, .executable, .script]
}
