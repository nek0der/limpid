// WeirSettingsTests.swift
// Weir — Codable round-trip + default-value guards for the settings store.
// Breakage here silently corrupts the user's settings.json on the next
// write, so we gate every schema-affecting change with this suite.

import Foundation
import Testing
@testable import Weir
@testable import WeirDomain

@Suite("WeirSettings")
struct WeirSettingsTests {

    // MARK: - Defaults

    @Test("WeirSettings.default stamps the current schema version")
    func default_usesCurrentSchemaVersion() {
        #expect(WeirSettings.default.schemaVersion == WeirSettings.currentSchemaVersion)
    }

    @Test("appearance defaults: transparency enabled, default accent, near-opaque pane background")
    func default_appearanceDefaults() {
        let s = WeirSettings.default.appearance
        #expect(s.transparency == .on)
        #expect(s.accentColor == .default)
        #expect(s.backgroundOpacity == 0.92)
        #expect(s.unfocusedPaneOpacity == 0.7)
    }

    @Test("jumping to a finished agent opens its turn by default")
    func default_jumpOpensTurnReview() {
        #expect(WeirSettings.default.jumpOpensTurnReview)
    }

    @Test("font defaults: nil family lets libghostty pick the system mono")
    func default_fontDefaults() {
        let s = WeirSettings.default.font
        #expect(s.family == nil)
        #expect(s.size == 13)
        #expect(s.ligatures == false)
        #expect(s.lineHeight == 0)
    }

    // MARK: - Codable round-trip

    @Test("encode → decode yields an equivalent value (defaults)")
    func codable_default_roundTrip() throws {
        let original = WeirSettings.default
        let data = try JSONEncoder().encode(original)
        let restored = try JSONDecoder().decode(WeirSettings.self, from: data)
        #expect(restored == original)
    }

    /// Every field touched here is moved *off* its default, so a
    /// dropped `CodingKey` shows up as a mismatch. A field assigned its
    /// own default would round-trip either way and pin nothing.
    @Test("encode → decode yields an equivalent value")
    func codable_customized_roundTrip() throws {
        var settings = WeirSettings.default
        settings.appearance.transparency = .off
        settings.appearance.accentColor = .blue
        settings.appearance.backgroundOpacity = 0.5
        settings.appearance.unfocusedPaneOpacity = 0.45
        settings.font.family = "Fira Code"
        settings.font.size = 15
        settings.font.ligatures = true
        settings.font.lineHeight = 2
        settings.terminal.scrollbackLines = 25000
        settings.terminal.quickTabCwdMode = .fixed
        settings.terminal.quickTabCwdPath = URL(fileURLWithPath: "/tmp/weir-quicktab")
        settings.advanced.hostsAgentsInTmux = true
        settings.advanced.holdsApprovalsWhileHidden = false
        settings.advanced.reviewInstructions = "Fix these."
        settings.advanced.fileApplication = FileApplication(
            bundleIdentifier: "com.example.Editor",
            lastKnownDisplayName: "Example Editor"
        )
        settings.jumpOpensTurnReview = false

        let data = try JSONEncoder().encode(settings)
        let restored = try JSONDecoder().decode(WeirSettings.self, from: data)
        #expect(restored == settings)
    }

    @Test("settings written before turn review default the jump behavior on")
    func decode_missingJumpOpensTurnReview_defaultsToOn() throws {
        let data = try JSONEncoder().encode(WeirSettings.default)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["jumpOpensTurnReview"] = nil
        let legacy = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(WeirSettings.self, from: legacy)

        #expect(decoded.jumpOpensTurnReview)
    }

    @Test func existingAdvancedSettingsDefaultReviewFields() throws {
        let data = Data(#"{"hostsAgentsInTmux":true}"#.utf8)
        let restored = try JSONDecoder().decode(AdvancedSettings.self, from: data)
        #expect(restored.hostsAgentsInTmux)
        #expect(restored.reviewInstructions.isEmpty)
        #expect(restored.fileApplication == nil)
    }

    /// The preference predates its use outside Review; a settings file that
    /// already chose an app must keep it.
    @Test func fileApplication_keepsItsStoredKey() throws {
        let data = Data(#"{"reviewFileApplication":{"bundleIdentifier":"com.example.Editor","lastKnownDisplayName":"Example Editor"}}"#
            .utf8)
        let restored = try JSONDecoder().decode(AdvancedSettings.self, from: data)
        #expect(restored.fileApplication?.bundleIdentifier == "com.example.Editor")

        let encoded = try JSONEncoder().encode(restored)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["reviewFileApplication"] != nil)
    }

    @Test("malformed JSON throws a DecodingError rather than crashing")
    func decode_malformedJSON_throws() {
        let garbage = Data("{schemaVersion: 1}".utf8) // unquoted key — invalid JSON
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(WeirSettings.self, from: garbage)
        }
    }

    // MARK: - Forward compatibility (unknown enum cases / missing fields)

    /// A file that holds only the schema version is not settings, and is
    /// refused rather than read as every default.
    @Test("a file without its sections does not decode")
    func decode_missingSections_throws() throws {
        let partial = Data(#"{"schemaVersion": 1}"#.utf8)
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(WeirSettings.self, from: partial)
        }
    }

    @Test("unknown `accentColor` raw value falls back to `.default`")
    func decode_unknownAccentRaw_fallsBackToDefault() throws {
        // `AccentColor` ships its own `init(from:)` that maps any
        // unknown rawValue (e.g. `graphite` written by a pre-release
        // build, or a future case rolled back) to `.default` instead
        // of throwing a `DecodingError` that would poison the whole
        // `AppearanceSettings` decode.
        let data = Data(#"""
        {"schemaVersion":1,
         "appearance":{"accentColor":"graphite","backgroundOpacity":0.92,"transparency":"on"},
         "font":{"size":13,"ligatures":false,"lineHeight":0},
         "terminal":{},
         "advanced":{"ghosttyConfig":"off"}}
        """#.utf8)
        let decoded = try JSONDecoder().decode(WeirSettings.self, from: data)
        #expect(decoded.appearance.accentColor == .default)
    }

    @Test("terminal section without quickTab keys decodes with cwd defaults")
    func decode_terminalMissingQuickTabKeys_defaults() throws {
        let data = Data(#"""
        {"schemaVersion":1,
         "appearance":{"accentColor":"default","backgroundOpacity":0.92,"transparency":"on"},
         "font":{"size":13,"ligatures":false,"lineHeight":0},
         "terminal":{"scrollbackLines":10000,"bellAction":"visual","cursorStyle":"block","cursorBlink":"on"},
         "advanced":{"ghosttyConfig":"off"}}
        """#.utf8)
        let decoded = try JSONDecoder().decode(WeirSettings.self, from: data)
        #expect(decoded.terminal.quickTabCwdMode == .inheritPrevious)
        #expect(decoded.terminal.quickTabCwdPath == nil)
    }

    /// The pane header setting is gone: panes show their header by the
    /// rule alone. A file an earlier build wrote still decodes, and its
    /// value is kept as written for that build to read again.
    @Test func retiredPaneHeaderSetting_decodesAndIsKeptForEarlierBuilds() throws {
        let decoded = try JSONDecoder().decode(
            TerminalSettings.self,
            from: Data(#"{"showsSplitPaneHeaders":false}"#.utf8)
        )
        #expect(decoded.unknownFields["showsSplitPaneHeaders"] == .bool(false))
        let written = try JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? [String: Any]
        #expect(written?["showsSplitPaneHeaders"] as? Bool == false)
    }

    /// A pane minimum saved under the old 40pt floor is raised to 60, the
    /// range's lower bound.
    @Test(
        "terminal pane minimum is clamped to the supported settings range",
        arguments: [(1, 60), (40, 60), (1000, 300)] as [(Int, Double)]
    )
    func decode_terminalPaneMinimum_clampsToSupportedRange(written: Int, read: Double) throws {
        let decoded = try JSONDecoder().decode(
            TerminalSettings.self,
            from: Data(#"{"minPaneSize":\#(written)}"#.utf8)
        )
        #expect(decoded.minPaneSize == read)
    }

    @Test("unfocused pane opacity is clamped to its supported range")
    func decode_unfocusedPaneOpacity_clampsToSupportedRange() throws {
        let belowRange = try JSONDecoder().decode(
            AppearanceSettings.self,
            from: Data(#"{"unfocusedPaneOpacity":0}"#.utf8)
        )
        let aboveRange = try JSONDecoder().decode(
            AppearanceSettings.self,
            from: Data(#"{"unfocusedPaneOpacity":2}"#.utf8)
        )

        #expect(belowRange.unfocusedPaneOpacity == 0.15)
        #expect(aboveRange.unfocusedPaneOpacity == 1.0)
    }

    /// Holding is the default, so the key is written only when someone
    /// turned it off; a file that never had it keeps holding.
    @Test func approvalHold_isWrittenOnlyWhenTurnedOff() throws {
        var advanced = AdvancedSettings()
        let untouched = try JSONSerialization.jsonObject(with: JSONEncoder().encode(advanced)) as? [String: Any]
        #expect(untouched?["approvalHoldWhileHidden"] == nil)

        advanced.holdsApprovalsWhileHidden = false
        let written = try JSONSerialization.jsonObject(with: JSONEncoder().encode(advanced)) as? [String: Any]
        #expect(written?["approvalHoldWhileHidden"] as? Bool == false)

        let legacy = try JSONDecoder().decode(AdvancedSettings.self, from: Data("{}".utf8))
        #expect(legacy.holdsApprovalsWhileHidden)
    }

    /// A key a newer build added survives a round trip through this one,
    /// next to the hold setting.
    @Test func approvalHold_keepsUnknownAdvancedKeys() throws {
        let data = Data(#"{"approvalHoldWhileHidden":false,"futureKey":1}"#.utf8)
        let decoded = try JSONDecoder().decode(AdvancedSettings.self, from: data)
        let written = try JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? [String: Any]

        #expect(decoded.holdsApprovalsWhileHidden == false)
        #expect(written?["futureKey"] as? Int == 1)
    }

    /// Earlier builds wrote both pull-request switches into every
    /// settings file. This build reads neither (pull requests show
    /// wherever `gh` or `glab` can read them), and writes both back as
    /// they were, so a build that still reads them finds the person's
    /// value after a rollback.
    @Test func removedPRToggles_areKeptInUnknownFieldsAndIgnored() throws {
        func file(schemaVersion: Int) -> Data {
            Data("""
            {"schemaVersion":\(schemaVersion),
             "appearance":{"accentColor":"default","backgroundOpacity":0.92,"transparency":"on"},
             "font":{"size":13,"ligatures":false,"lineHeight":0},
             "terminal":{},
             "advanced":{"ghosttyConfig":"off",
                         "showPRStatusInSidebar":true,
                         "showPRStatusOnlyWhenAttention":false}}
            """.utf8)
        }
        let data = file(schemaVersion: 2)
        let decoded = try JSONDecoder().decode(WeirSettings.self, from: data)

        // Ignored: they are only carried, and every setting the type reads
        // is its default.
        #expect(decoded.advanced.unknownFields == [
            "showPRStatusInSidebar": .bool(true),
            "showPRStatusOnlyWhenAttention": .bool(false)
        ])
        var typed = decoded.advanced
        typed.unknownFields = [:]
        #expect(typed == AdvancedSettings())

        // Written back unchanged.
        let written = try JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? [String: Any]
        let advanced = try #require(written?["advanced"] as? [String: Any])
        #expect(advanced["showPRStatusInSidebar"] as? Bool == true)
        #expect(advanced["showPRStatusOnlyWhenAttention"] as? Bool == false)

        // An existing person's file is schema 1, which reaches this build
        // through the migration; the keys come out of it as they went in.
        guard case let .migrated(from, migrated) = try VersionedDocumentMigrator.settings.migrate(file(schemaVersion: 1)) else {
            Issue.record("a schema 1 file is migrated")
            return
        }
        #expect(from == 1)
        let migratedFile = try JSONSerialization.jsonObject(with: migrated) as? [String: Any]
        #expect(migratedFile?["schemaVersion"] as? Int == WeirSettings.currentSchemaVersion)
        let migratedAdvanced = try #require(migratedFile?["advanced"] as? [String: Any])
        #expect(migratedAdvanced["showPRStatusInSidebar"] as? Bool == true)
        #expect(migratedAdvanced["showPRStatusOnlyWhenAttention"] as? Bool == false)

        // A file that never had them does not grow them.
        let fresh = try JSONSerialization.jsonObject(with: JSONEncoder().encode(WeirSettings.default)) as? [String: Any]
        let freshAdvanced = try #require(fresh?["advanced"] as? [String: Any])
        #expect(freshAdvanced["showPRStatusInSidebar"] == nil)
        #expect(freshAdvanced["showPRStatusOnlyWhenAttention"] == nil)
    }

    // MARK: - Forward-compat decoders

    @Test("ConfirmPolicy with an unknown raw value falls back to .onlyWhenAgent")
    func confirmPolicy_unknownRaw_fallsBackToOnlyWhenAgent() throws {
        // Synthesised `String` decoding would throw on this raw value;
        // the custom `init(from:)` we ship instead routes it to the
        // configured fallback so a newer build's added case can't
        // brick the older build's settings.json read.
        let json = Data("\"future-case-not-yet-added\"".utf8)
        let decoded = try JSONDecoder().decode(ConfirmPolicy.self, from: json)
        #expect(decoded == .onlyWhenAgent)
    }

    // MARK: - Sidecar forward-compat round-trip

    @Test("WeirSettings preserves unknown root-level keys across decode → encode")
    func weirSettings_unknownRootKey_roundTrips() throws {
        let raw = Data("""
        {
          "schemaVersion": 1,
          "appearance": {"accentColor": "default", "backgroundOpacity": 0.92,
                         "transparency": "on", "colorScheme": "system"},
          "font": {"size": 13, "ligatures": false, "lineHeight": 0},
          "terminal": {"scrollbackLines": 10000, "bellAction": "visual",
                       "cursorStyle": "block", "cursorBlink": "on",
                       "quickTabCwdMode": "inheritPrevious"},
          "advanced": {"ghosttyConfig": "off"},
          "futurePluginSection": {"enabled": true, "label": "plug-A"}
        }
        """.utf8)

        let decoded = try JSONDecoder().decode(WeirSettings.self, from: raw)
        #expect(decoded.unknownFields["futurePluginSection"] != nil)

        let reencoded = try JSONEncoder().encode(decoded)
        let asAny = try JSONSerialization.jsonObject(with: reencoded) as? [String: Any]
        let plugin = try #require(asAny?["futurePluginSection"] as? [String: Any])
        #expect(plugin["enabled"] as? Bool == true)
        #expect(plugin["label"] as? String == "plug-A")
    }

    @Test("Section-level unknown fields survive decode → encode (AppearanceSettings)")
    func appearanceSettings_unknownField_roundTrips() throws {
        let raw = Data("""
        {
          "accentColor": "default",
          "backgroundOpacity": 0.92,
          "transparency": "on",
          "colorScheme": "system",
          "futureDarkModeAccent": "#ff00aa"
        }
        """.utf8)

        let decoded = try JSONDecoder().decode(AppearanceSettings.self, from: raw)
        #expect(decoded.unknownFields["futureDarkModeAccent"] == .string("#ff00aa"))

        let reencoded = try JSONEncoder().encode(decoded)
        let asAny = try JSONSerialization.jsonObject(with: reencoded) as? [String: Any]
        #expect(asAny?["futureDarkModeAccent"] as? String == "#ff00aa")
    }

    // MARK: - Review

    @Test func theReviewSection_isOptional_andRoundTrips_keepingWhatANewerBuildWrote() throws {
        #expect(WeirSettings().review.externalDiffCommand.isEmpty)
        // A file from before the section reads with its default.
        var withoutReview = try JSONSerialization.jsonObject(with: JSONEncoder().encode(WeirSettings())) as? [String: Any] ?? [:]
        withoutReview.removeValue(forKey: "review")
        let older = try JSONDecoder().decode(WeirSettings.self, from: JSONSerialization.data(withJSONObject: withoutReview))
        #expect(older.review == ReviewSettings())

        var settings = WeirSettings()
        settings.review.externalDiffCommand = "tig --all"
        let decoded = try JSONDecoder().decode(WeirSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded.review.externalDiffCommand == "tig --all")

        let later = try JSONDecoder().decode(ReviewSettings.self, from: Data(#"{"externalDiffCommand":"tig","fromLater":1}"#.utf8))
        let again = try JSONDecoder().decode(ReviewSettings.self, from: JSONEncoder().encode(later))
        #expect(again == later)
        #expect(again.unknownFields["fromLater"] != nil)
    }

    // MARK: - General, new session, and retention sections

    @Test func theNewSettings_startAtTheirDefaults() {
        let settings = WeirSettings.default

        #expect(settings.general.showMenuBarExtra)
        #expect(!settings.general.notifyOnUsageLimitReset)
        #expect(settings.newSession.lastAgent == nil)
        #expect(settings.advanced.turnRetention.days == 14)
        #expect(settings.advanced.turnRetention.turns == 200)
        #expect(settings.advanced.turnRetention.limits == TurnRetentionLimits.standard)
    }

    @Test func aFileWrittenBeforeThem_readsTheDefaults() throws {
        var object = try WeirSettingsJSON.object(.default)
        object.removeValue(forKey: "general")
        object.removeValue(forKey: "newSession")
        var advanced = try #require(object["advanced"] as? [String: Any])
        advanced.removeValue(forKey: "turnRetention")
        object["advanced"] = advanced

        let settings = try WeirSettingsJSON.decode(object)

        #expect(settings.general == GeneralSettings())
        #expect(settings.newSession == NewSessionSettings())
        #expect(settings.advanced.turnRetention == TurnRetentionSettings())
    }

    @Test func theNewSettings_roundTrip() throws {
        var settings = WeirSettings.default
        settings.general.showMenuBarExtra = false
        settings.general.notifyOnUsageLimitReset = true
        settings.newSession.lastAgent = "codex"
        settings.advanced.turnRetention = TurnRetentionSettings(days: 30, turns: 120)

        let decoded = try JSONDecoder().decode(WeirSettings.self, from: JSONEncoder().encode(settings))

        #expect(decoded == settings)
    }

    @Test func keysALaterBuildAdded_toTheNewSections_areWrittenBack() throws {
        var object = try WeirSettingsJSON.object(.default)
        object["general"] = ["showMenuBarExtra": false, "laterKey": 1]
        object["newSession"] = ["laterKey": "x"]
        var advanced = try #require(object["advanced"] as? [String: Any])
        advanced["turnRetention"] = ["days": 20, "turns": 100, "laterKey": true]
        object["advanced"] = advanced

        let written = try WeirSettingsJSON.object(WeirSettingsJSON.decode(object))

        #expect((written["general"] as? [String: Any])?["laterKey"] as? Int == 1)
        #expect((written["newSession"] as? [String: Any])?["laterKey"] as? String == "x")
        let retention = (written["advanced"] as? [String: Any])?["turnRetention"] as? [String: Any]
        #expect(retention?["laterKey"] as? Bool == true)
        #expect(retention?["days"] as? Int == 20)
    }

    /// Settings an earlier build wrote with the moved groups' count still
    /// read, and the count is not written back.
    @Test func settingsWithTheMovedGroups_read_andDropThem() throws {
        let written = Data(#"{"showMenuBarExtra":true,"movedGroups":{"groups":2,"tabs":4},"later":1}"#.utf8)
        let general = try JSONDecoder().decode(GeneralSettings.self, from: written)
        #expect(general.showMenuBarExtra)
        #expect(general.unknownFields == ["later": .int(1)], "a later build's key is still kept")
        let saved = try #require(String(data: JSONEncoder().encode(general), encoding: .utf8))
        #expect(!saved.contains("movedGroups"))
        #expect(saved.contains("later"))
    }

    /// The first-run guide's flag from a build that showed it is carried
    /// as it was, so going back a build does not show the guide again, and
    /// a file this build starts never gains it.
    @Test func theFirstRunGuidesFlag_isCarried_andNeverStarted() throws {
        let written = Data(#"{"showMenuBarExtra":true,"isFirstRunGuideDismissed":true}"#.utf8)
        let general = try JSONDecoder().decode(GeneralSettings.self, from: written)
        #expect(general.unknownFields == ["isFirstRunGuideDismissed": .bool(true)])
        let saved = try #require(String(data: JSONEncoder().encode(general), encoding: .utf8))
        #expect(saved.contains(#""isFirstRunGuideDismissed":true"#))

        let fresh = try #require(String(data: JSONEncoder().encode(GeneralSettings()), encoding: .utf8))
        #expect(!fresh.contains("isFirstRunGuideDismissed"))
    }
}

/// A settings file as the JSON object it is written as, for tests that
/// take a key out or put one in before reading it back.
enum WeirSettingsJSON {
    static func decode(_ object: [String: Any]) throws -> WeirSettings {
        try JSONDecoder().decode(WeirSettings.self, from: JSONSerialization.data(withJSONObject: object))
    }

    static func object(_ settings: WeirSettings) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any])
    }
}
