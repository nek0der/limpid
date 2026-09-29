// EditorLineLaunch.swift
// Limpid — how each known editor is asked to open a file at a line.

import Foundation

/// A 1-based position inside a text file.
struct FilePosition: Equatable {
    let line: Int
    let column: Int?
}

/// macOS has no general way to hand an application a line number, so each
/// editor that accepts one is listed with the entry point it documents. An
/// editor missing from the list still opens the file, just not at the line.
enum EditorLineLaunch: Equatable {
    /// A URL the editor registers, dispatched to that editor's bundle so a
    /// second installed channel cannot take it.
    case url(URL)
    /// A command-line helper inside the editor's bundle, or one it installs.
    /// Arguments are passed as an array, never through a shell, and the path
    /// is always absolute, so no file name can be read as an option.
    case process(executable: URL, arguments: [String])

    static func make(
        bundleIdentifier: String,
        applicationURL: URL,
        file: URL,
        position: FilePosition
    ) -> EditorLineLaunch? {
        let path = file.path
        let suffix = position.column.map { ":\(position.line):\($0)" } ?? ":\(position.line)"
        switch bundleIdentifier {
        // VS Code documents `vscode://file/<path>:line:column`; forks keep
        // the handler under their own scheme.
        case "com.microsoft.VSCode":
            return fileURL(scheme: "vscode", path: path + suffix)
        case "com.microsoft.VSCodeInsiders":
            return fileURL(scheme: "vscode-insiders", path: path + suffix)
        case "com.todesktop.230313mzl4w4u92":
            return fileURL(scheme: "cursor", path: path + suffix)
        case "com.apple.dt.Xcode":
            // `xed` ships with Xcode and takes no column.
            return .process(
                executable: URL(fileURLWithPath: "/usr/bin/xed"),
                arguments: ["--line", String(position.line), path]
            )
        case "dev.zed.Zed", "dev.zed.Zed-Preview":
            return .process(
                executable: applicationURL.appendingPathComponent("Contents/MacOS/cli"),
                arguments: [path + suffix]
            )
        case "com.sublimetext.4", "com.sublimetext.3":
            return .process(
                executable: applicationURL.appendingPathComponent("Contents/SharedSupport/bin/subl"),
                arguments: [path + suffix]
            )
        default:
            return nil
        }
    }

    private static func fileURL(scheme: String, path: String) -> EditorLineLaunch? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "file"
        // `URLComponents` percent-encodes the path, so spaces and non-ASCII
        // names survive.
        components.path = path
        return components.url.map(EditorLineLaunch.url)
    }
}
