// GhosttyConfigBridgeTests.swift
// Limpid — covers the LimpidSettings → libghostty `key = value` translation.
// The bridge is the seam where every settings UI change becomes a
// runtime change in libghostty; a quiet regression here flips terminal
// behavior without any user-visible UI difference, so we keep these
// tests dense and focused on the contract (which keys appear, in what
// order, and with what derived value).

import Foundation
import Testing
@testable import Limpid

@Suite("GhosttyConfigBridge")
@MainActor
struct GhosttyConfigBridgeTests {

    // MARK: - Helpers

    /// Convenience to inspect config that does not need a bundled theme.
    private func generate(_ settings: LimpidSettings) -> String {
        GhosttyConfigBridge.makeConfigString(settings: settings, resourcesDir: nil, appearance: .dark)
    }

    /// Look up the first `key = value` line; returns the value with
    /// surrounding whitespace trimmed, or nil when the key is absent.
    private func value(of key: String, in config: String) -> String? {
        for line in config.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, parts[0] == key {
                return parts[1]
            }
        }
        return nil
    }

    // MARK: - Font

    @Test("font-family is omitted when the user hasn't picked one")
    func makeConfig_defaultFontFamily_isOmitted() {
        let config = generate(.default)
        #expect(value(of: "font-family", in: config) == nil)
    }

    @Test("font-family is emitted when set in settings")
    func makeConfig_customFontFamily_isEmitted() {
        var settings = LimpidSettings.default
        settings.font.family = "JetBrains Mono"
        let config = generate(settings)
        #expect(value(of: "font-family", in: config) == "JetBrains Mono")
    }

    @Test("font-size always emits the user's chosen size")
    func makeConfig_fontSize_isAlwaysEmitted() {
        var settings = LimpidSettings.default
        settings.font.size = 14
        let config = generate(settings)
        #expect(value(of: "font-size", in: config) == "14.0")
    }

    @Test(
        "ligatures flag swaps the font-feature line",
        arguments: [
            (true, ""), // ligatures on → clear default "-calt"
            (false, "-calt"), // ligatures off → suppress calt
        ]
    )
    func makeConfig_ligatures_drivesFontFeature(ligatures: Bool, expected: String) {
        var settings = LimpidSettings.default
        settings.font.ligatures = ligatures
        let config = generate(settings)
        #expect(value(of: "font-feature", in: config) == expected)
    }

    @Test("adjust-cell-height appears only when lineHeight is non-zero")
    func makeConfig_lineHeight_omittedWhenZero() {
        var settings = LimpidSettings.default
        settings.font.lineHeight = 0
        #expect(value(of: "adjust-cell-height", in: generate(settings)) == nil)
    }

    @Test("adjust-cell-height appears when lineHeight is non-zero")
    func makeConfig_lineHeight_emittedWhenNonZero() {
        var settings = LimpidSettings.default
        settings.font.lineHeight = 4
        #expect(value(of: "adjust-cell-height", in: generate(settings)) == "4")
    }

    // MARK: - Terminal

    @Test("scrollback uses the selected line count without an earlier byte ceiling")
    func makeConfig_scrollbackLines_isForwarded() {
        var settings = LimpidSettings.default
        settings.terminal.scrollbackLines = 12345
        let config = generate(settings)
        #expect(value(of: "scrollback-limit-lines", in: config) == "12345")
        #expect(value(of: "scrollback-limit-bytes", in: config) == "unlimited")
        #expect(value(of: "scrollback-limit", in: config) == nil)
    }

    @Test("cursor-style-blink toggle is forwarded as a bool")
    func makeConfig_cursorBlink_isForwarded() {
        var settings = LimpidSettings.default
        settings.terminal.cursorBlink = .on
        #expect(value(of: "cursor-style-blink", in: generate(settings)) == "true")
    }

    // MARK: - Forced overrides

    @Test("background-opacity is forced to 0 regardless of user settings")
    func makeConfig_backgroundOpacity_isForcedToZero() {
        var settings = LimpidSettings.default
        settings.appearance.backgroundOpacity = 0.5
        #expect(value(of: "background-opacity", in: generate(settings)) == "0")
    }

    @Test("term is pinned to xterm-256color so terminfo always resolves")
    func makeConfig_term_isPinnedToXterm256() {
        #expect(value(of: "term", in: generate(.default)) == "xterm-256color")
    }

    @Test("confirm-close-surface is disabled (Limpid owns the confirm UI)")
    func makeConfig_confirmCloseSurface_isDisabled() {
        #expect(value(of: "confirm-close-surface", in: generate(.default)) == "false")
    }

    @Test("shell-integration-features disables cursor management")
    func makeConfig_shellIntegrationFeatures_disablesCursor() {
        #expect(value(of: "shell-integration-features", in: generate(.default)) == "no-cursor")
    }

    // MARK: - Bundled theme

    @Test("resources-dir is omitted when no path is supplied")
    func makeConfig_nilResourcesDir_omitsLine() {
        let config = GhosttyConfigBridge.makeConfigString(settings: .default, resourcesDir: nil, appearance: .dark)
        #expect(value(of: "resources-dir", in: config) == nil)
    }

    @Test("resources path selects a bundled theme without emitting a removed config key")
    func makeConfig_withResourcesDir_usesAbsoluteThemeOnly() {
        let path = "/tmp/limpid-resources/\(UUID().uuidString)"
        let config = GhosttyConfigBridge.makeConfigString(settings: .default, resourcesDir: path, appearance: .dark)
        #expect(value(of: "resources-dir", in: config) == nil)
        #expect(value(of: "theme", in: config) == "\(path)/themes/Apple System Colors")
    }

    @Test("generated config is accepted for every Bell choice", arguments: BellAction.allCases)
    func generatedConfig_hasNoDiagnostics(bellAction: BellAction) throws {
        try withTempDir { directory in
            var settings = LimpidSettings.default
            settings.terminal.bellAction = bellAction
            let resourcesDir = try #require(GhosttyApp.resolveResourcesDir())
            let body = GhosttyConfigBridge.makeConfigString(
                settings: settings,
                resourcesDir: resourcesDir,
                appearance: .dark
            )
            let path = directory.appendingPathComponent("generated-ghostty-config")
            try body.write(to: path, atomically: true, encoding: .utf8)

            let diagnostics = try #require(GhosttyConfigBridge.configDiagnostics(at: path.path))
            #expect(diagnostics.isEmpty)
        }
    }

    // MARK: - Ordering guarantee

    @Test("forced overrides appear after the user-facing section so libghostty's last-write-wins keeps them sticky")
    func makeConfig_forcedOverrides_appearAfterUserSettings() {
        let config = generate(.default)
        guard let userIdx = config.range(of: "font-size"),
              let overridesIdx = config.range(of: "background-opacity")
        else {
            Issue.record("expected both font-size and background-opacity lines")
            return
        }
        #expect(userIdx.lowerBound < overridesIdx.lowerBound)
    }

    // MARK: - Menu-owned shortcut guards

    @Test("menu-owned shortcuts emit `=ignore` so a disabled menu item never leaks the keystroke to the terminal")
    func makeConfig_menuOwnedShortcuts_emitIgnore() {
        let config = generate(.default)
        // `nextAttention` (⌘J) and `renameTab` (⌘⇧R) are menu-owned
        // (ghosttyAction == nil) and have printable defaults — the two
        // cases most likely to type "j" / "R" into the terminal when
        // their menu item is disabled. Their defaults must round-trip
        // to `ignore`.
        #expect(config.contains("keybind = super+j=ignore"))
        #expect(config.contains("keybind = super+shift+j=ignore"))
        #expect(config.contains("keybind = super+shift+r=ignore"))
    }

    @Test("libghostty-dispatched actions still emit their real action, not ignore")
    func makeConfig_ghosttyOwnedShortcuts_keepRealAction() {
        let config = generate(.default)
        // `nextPrompt` (⌘↓) has `ghosttyAction == "jump_to_prompt:1"`;
        // the ignore loop must not shadow these.
        #expect(config.contains("jump_to_prompt:1"))
        #expect(!config.contains("keybind = super+down=ignore"))
    }

    @Test("user config diagnostics distinguish invalid and clean files")
    func userConfigDiagnostics_reportOnlyInvalidConfig() throws {
        try withTempDir { directory in
            let path = directory.appendingPathComponent("ghostty-config")
            try "font-siz = 13\n".write(to: path, atomically: true, encoding: .utf8)

            let invalid = try #require(GhosttyConfigBridge.configDiagnostics(at: path.path))
            #expect(invalid.contains { $0.contains("font-siz: unknown field") })

            try "font-size = 13\n".write(to: path, atomically: true, encoding: .utf8)
            let clean = try #require(GhosttyConfigBridge.configDiagnostics(at: path.path))
            #expect(clean.isEmpty)
        }
    }

    @Test func generatedConfigurationsDoNotOverwriteAnotherProcess() throws {
        try withTempDir { directory in
            let first = GhosttyConfigBridge.writeConfigFile(
                settings: .default, resourcesDir: "/resources", appearance: .light,
                directory: directory, processID: 101
            )
            let firstPath = try #require(first)
            let before = try String(contentsOfFile: firstPath, encoding: .utf8)
            let second = GhosttyConfigBridge.writeConfigFile(
                settings: .default, resourcesDir: "/resources", appearance: .dark,
                directory: directory, processID: 202
            )
            let secondPath = try #require(second)
            #expect(firstPath != secondPath)
            let retained = try String(contentsOfFile: firstPath, encoding: .utf8)
            #expect(retained == before)
            #expect(retained.contains("Apple System Colors Light"))
            let dark = try String(contentsOfFile: secondPath, encoding: .utf8)
            #expect(!dark.contains("Apple System Colors Light"))
        }
    }

}
