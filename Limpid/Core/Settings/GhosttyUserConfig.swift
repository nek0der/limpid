// GhosttyUserConfig.swift
// Limpid — where the person's own Ghostty config lives and the font it names, as libghostty would read them.

import Foundation

/// The files `ghostty_config_load_default_files` reads when "Use Ghostty
/// config file" is on (Integrations), and the one value Settings shows
/// from them: the font family that a terminal uses while Limpid's own Font
/// pane names none.
enum GhosttyUserConfig {
    /// The family libghostty draws with when no config names one: the font
    /// it embeds (`vendor/ghostty/src/font/embedded.zig`).
    static let builtInFontFamily = "JetBrains Mono"

    /// The files libghostty loads, in its order (`Config.loadDefaultFiles`):
    /// the XDG files, then Application Support under Ghostty's bundle
    /// identifier, each with its name from before Ghostty 1.3 first. A
    /// later file overrides an earlier one.
    static func candidateFiles(home: URL, environment: [String: String]) -> [URL] {
        let xdg = environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? home.appending(path: ".config")
        let appSupport = home.appending(path: "Library/Application Support/com.mitchellh.ghostty")
        return [
            xdg.appending(path: "ghostty/config"),
            xdg.appending(path: "ghostty/config.ghostty"),
            appSupport.appending(path: "config"),
            appSupport.appending(path: "config.ghostty")
        ]
    }

    /// The candidates that exist, in load order.
    static func existingFiles(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [URL] {
        candidateFiles(home: home, environment: environment).filter {
            FileManager.default.fileExists(atPath: $0.path)
        }
    }

    /// The file to open for editing: the last one libghostty reads, which
    /// wins where they overlap; nil when there is none.
    static func fileToEdit(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        existingFiles(home: home, environment: environment).last
    }

    /// The font family the configs name, read the way Ghostty reads a
    /// repeatable key: each `font-family` line adds a fallback after the
    /// first, and an empty value clears the list. The first family of the final list
    /// is the one a terminal draws with. `config-file` includes are not
    /// followed, so a family set only in an included file reads as unset.
    static func fontFamily(in contents: [String]) -> String? {
        var families: [String] = []
        for text in contents {
            for line in text.split(whereSeparator: \.isNewline) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.hasPrefix("#"), let equals = trimmed.firstIndex(of: "=") else { continue }
                let key = trimmed[..<equals].trimmingCharacters(in: .whitespaces)
                guard key == "font-family" else { continue }
                var value = trimmed[trimmed.index(after: equals)...].trimmingCharacters(in: .whitespaces)
                if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                    value = String(value.dropFirst().dropLast())
                }
                if value.isEmpty {
                    families = []
                } else {
                    families.append(value)
                }
            }
        }
        return families.first
    }

    /// The family a terminal uses while the Font pane names none.
    static func defaultFontFamily(readsGhosttyConfig: Bool, contents: () -> [String]) -> String {
        guard readsGhosttyConfig else { return builtInFontFamily }
        return fontFamily(in: contents()) ?? builtInFontFamily
    }
}
