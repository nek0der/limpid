// GhosttyUserConfigTests.swift
// Limpid — the Font pane names the typeface "Default" draws with, read from the Ghostty config as libghostty reads it.

import Foundation
import Testing
@testable import Limpid

struct GhosttyUserConfigTests {
    @Test func theFirstFamily_isTheOneDrawn_andAnEmptyValueClears() {
        let config = """
        # font-family = Commented Out
        font-family = "Iosevka Term"
        font-family = Symbols Nerd Font
        """
        #expect(GhosttyUserConfig.fontFamily(in: [config]) == "Iosevka Term")
        #expect(GhosttyUserConfig.fontFamily(in: [config, "font-family = \"\"\nfont-family = Menlo"]) == "Menlo")
        #expect(GhosttyUserConfig.fontFamily(in: ["font-size = 14"]) == nil)
    }

    @Test func withoutTheGhosttyConfig_theDefaultIsTheEmbeddedFont() {
        let named = GhosttyUserConfig.defaultFontFamily(readsGhosttyConfig: false) { ["font-family = Menlo"] }
        #expect(named == GhosttyUserConfig.builtInFontFamily)
        #expect(GhosttyUserConfig.defaultFontFamily(readsGhosttyConfig: true) { [] } == "JetBrains Mono")
        #expect(GhosttyUserConfig.defaultFontFamily(readsGhosttyConfig: true) { ["font-family = Menlo"] } == "Menlo")
    }

    @Test func theFiles_followXDGThenApplicationSupport() {
        let home = URL(fileURLWithPath: "/Users/someone")
        let files = GhosttyUserConfig.candidateFiles(home: home, environment: ["XDG_CONFIG_HOME": "/x"]).map(\.path)

        #expect(files == [
            "/x/ghostty/config",
            "/x/ghostty/config.ghostty",
            "/Users/someone/Library/Application Support/com.mitchellh.ghostty/config",
            "/Users/someone/Library/Application Support/com.mitchellh.ghostty/config.ghostty"
        ])
        #expect(GhosttyUserConfig.candidateFiles(home: home, environment: [:]).first?.path
            == "/Users/someone/.config/ghostty/config")
    }
}
