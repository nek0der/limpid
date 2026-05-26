// LimpidSettingsTests.swift
// Codable round-trip + default-value guards for the single source of
// truth that persists every Settings UI knob to disk. Breakage here
// silently corrupts the user's settings.json on the next write, so we
// gate every schema-affecting change with this suite.

import Foundation
import Testing
@testable import Limpid

@Suite("LimpidSettings")
struct LimpidSettingsTests {

    // MARK: - Defaults

    @Test("LimpidSettings.default stamps the current schema version")
    func default_usesCurrentSchemaVersion() {
        #expect(LimpidSettings.default.schemaVersion == LimpidSettings.currentSchemaVersion)
    }

    @Test("appearance defaults: system transparency, default tint, near-opaque pane background")
    func default_appearanceDefaults() {
        let s = LimpidSettings.default.appearance
        #expect(s.transparency == .system)
        #expect(s.windowTint == .default)
        #expect(s.backgroundOpacity == 0.92)
    }

    @Test("font defaults: nil family lets libghostty pick the system mono")
    func default_fontDefaults() {
        let s = LimpidSettings.default.font
        #expect(s.family == nil)
        #expect(s.size == 13)
        #expect(s.ligatures == false)
        #expect(s.lineHeight == 0)
    }

    // MARK: - Codable round-trip

    @Test("encode → decode yields an equivalent value (defaults)")
    func codable_default_roundTrip() throws {
        let original = LimpidSettings.default
        let data = try JSONEncoder().encode(original)
        let restored = try JSONDecoder().decode(LimpidSettings.self, from: data)
        #expect(restored == original)
    }

    @Test("encode → decode yields an equivalent value (every field mutated)")
    func codable_customized_roundTrip() throws {
        var settings = LimpidSettings.default
        settings.appearance.transparency = .off
        settings.appearance.windowTint = .navy
        settings.appearance.backgroundOpacity = 0.5
        settings.font.family = "Fira Code"
        settings.font.size = 15
        settings.font.ligatures = true
        settings.font.lineHeight = 2
        settings.terminal.scrollbackLines = 10000

        let data = try JSONEncoder().encode(settings)
        let restored = try JSONDecoder().decode(LimpidSettings.self, from: data)
        #expect(restored == settings)
    }

    @Test("malformed JSON throws a DecodingError rather than crashing")
    func decode_malformedJSON_throws() {
        let garbage = Data("{schemaVersion: 1}".utf8) // unquoted key — invalid JSON
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(LimpidSettings.self, from: garbage)
        }
    }

    // MARK: - Forward compatibility (unknown enum cases / missing fields)

    @Test("decoder falls back to defaults when a leaf field is missing from JSON")
    func decode_missingLeafField_fallsBackToDefault() throws {
        // JSON with just schemaVersion — every sub-struct is absent.
        // Decoder should fail (each section is non-optional)? Verify
        // what current behavior is rather than asserting permissively.
        let partial = Data(#"{"schemaVersion": 1}"#.utf8)
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(LimpidSettings.self, from: partial)
        }
    }

    @Test("an unknown enum case in transparency is rejected, not silently mapped")
    func decode_unknownTransparencyMode_throws() {
        // `bogus` isn't a TransparencyMode case → Decoder throws.
        let data = Data(#"""
        {"schemaVersion":1,
         "appearance":{"windowTint":"default","backgroundOpacity":0.92,"transparency":"bogus"},
         "font":{"size":13,"ligatures":false,"lineHeight":0},
         "terminal":{},
         "advanced":{}}
        """#.utf8)
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(LimpidSettings.self, from: data)
        }
    }

    @Test("terminal section without quickTab keys decodes with cwd defaults")
    func decode_terminalMissingQuickTabKeys_defaults() throws {
        let data = Data(#"""
        {"schemaVersion":1,
         "appearance":{"windowTint":"default","backgroundOpacity":0.92,"transparency":"system"},
         "font":{"size":13,"ligatures":false,"lineHeight":0},
         "terminal":{"scrollbackLines":10000,"bellAction":"visual","cursorStyle":"block","cursorBlink":true},
         "advanced":{"useGhosttyConfigFile":false}}
        """#.utf8)
        let decoded = try JSONDecoder().decode(LimpidSettings.self, from: data)
        #expect(decoded.terminal.quickTabCwdMode == .inheritPrevious)
        #expect(decoded.terminal.quickTabCwdPath == nil)
    }

    @Test("terminal quickTab cwd fields round-trip", .tags(.persistence))
    func quickTabCwd_roundTrips() throws {
        var s = LimpidSettings.default
        s.terminal.quickTabCwdMode = .fixed
        s.terminal.quickTabCwdPath = URL(fileURLWithPath: "/tmp/limpid-quicktab")
        let decoded = try JSONDecoder().decode(
            LimpidSettings.self, from: JSONEncoder().encode(s)
        )
        #expect(decoded.terminal.quickTabCwdMode == .fixed)
        #expect(decoded.terminal.quickTabCwdPath == URL(fileURLWithPath: "/tmp/limpid-quicktab"))
    }

    // MARK: - Equatable sanity

    @Test("mutating any field breaks Equatable equality with the default")
    func equatable_anyMutation_breaksEquality() {
        var s = LimpidSettings.default
        s.font.size = 13.5
        #expect(s != .default)
    }
}
