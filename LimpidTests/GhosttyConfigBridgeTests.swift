// GhosttyConfigBridgeTests.swift
// Covers the LimpidSettings → libghostty `key = value` translation.
// The bridge is the seam where every settings UI change becomes a
// runtime change in libghostty; a quiet regression here flips terminal
// behaviour without any user-visible UI difference, so we keep these
// tests dense and focused on the contract (which keys appear, in what
// order, and with what derived value).

import Foundation
import Testing
@testable import Limpid

@Suite("GhosttyConfigBridge")
@MainActor
struct GhosttyConfigBridgeTests {

    // MARK: - Helpers

    /// Convenience to inspect the generated config without pulling in
    /// the resources-dir noise.
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

    @Test("scrollback-limit forwards the user value")
    func makeConfig_scrollbackLines_isForwarded() {
        var settings = LimpidSettings.default
        settings.terminal.scrollbackLines = 12345
        #expect(value(of: "scrollback-limit", in: generate(settings)) == "12345")
    }

    @Test("cursor-style-blink toggle is forwarded as a bool")
    func makeConfig_cursorBlink_isForwarded() {
        var settings = LimpidSettings.default
        settings.terminal.cursorBlink = true
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

    // MARK: - Resources dir

    @Test("resources-dir is omitted when no path is supplied")
    func makeConfig_nilResourcesDir_omitsLine() {
        let config = GhosttyConfigBridge.makeConfigString(settings: .default, resourcesDir: nil, appearance: .dark)
        #expect(value(of: "resources-dir", in: config) == nil)
    }

    @Test("resources-dir is emitted verbatim when supplied")
    func makeConfig_withResourcesDir_emitsLine() {
        let path = "/tmp/limpid-resources/\(UUID().uuidString)"
        let config = GhosttyConfigBridge.makeConfigString(settings: .default, resourcesDir: path, appearance: .dark)
        #expect(value(of: "resources-dir", in: config) == path)
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
}
