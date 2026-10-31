// GhosttyConfigBridgeTests.swift
// Weir — covers the WeirSettings → libghostty `key = value` translation.
// The bridge is the seam where every settings UI change becomes a
// runtime change in libghostty; a quiet regression here flips terminal
// behavior without any user-visible UI difference, so we keep these
// tests dense and focused on the contract (which keys appear, in what
// order, and with what derived value).

import Foundation
import GhosttyKit
import Testing
@testable import Weir

@Suite("GhosttyConfigBridge")
@MainActor
struct GhosttyConfigBridgeTests {

    // MARK: - Helpers

    /// Convenience to inspect config that does not need a bundled theme.
    private func generate(_ settings: WeirSettings) -> String {
        GhosttyConfigBridge.makeConfigString(settings: settings, resourcesDir: nil)
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

    // MARK: - Padding

    /// The quick terminal insets its text with the padding it expects
    /// libghostty to apply, so the generated layer has to carry both values
    /// and win over a user's own config file loaded before it.
    @Test("window padding is emitted on both axes")
    func makeConfig_windowPadding_isEmittedOnBothAxes() {
        let config = generate(.default)
        #expect(value(of: "window-padding-x", in: config) == "\(GhosttyConfigBridge.windowPaddingX)")
        #expect(value(of: "window-padding-y", in: config) == "\(GhosttyConfigBridge.windowPaddingY)")
    }

    // MARK: - Font

    @Test("font-family is omitted when the user hasn't picked one")
    func makeConfig_defaultFontFamily_isOmitted() {
        let config = generate(.default)
        #expect(value(of: "font-family", in: config) == nil)
    }

    @Test("font-family is emitted when set in settings")
    func makeConfig_customFontFamily_isEmitted() {
        var settings = WeirSettings.default
        settings.font.family = "JetBrains Mono"
        let config = generate(settings)
        #expect(value(of: "font-family", in: config) == "JetBrains Mono")
    }

    @Test("font-size always emits the user's chosen size")
    func makeConfig_fontSize_isAlwaysEmitted() {
        var settings = WeirSettings.default
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
        var settings = WeirSettings.default
        settings.font.ligatures = ligatures
        let config = generate(settings)
        #expect(value(of: "font-feature", in: config) == expected)
    }

    @Test("adjust-cell-height appears only when lineHeight is non-zero", arguments: [(Double(0), String?.none), (4, "4")])
    func makeConfig_lineHeight_emittedOnlyWhenNonZero(lineHeight: Double, expected: String?) {
        var settings = WeirSettings.default
        settings.font.lineHeight = lineHeight
        #expect(value(of: "adjust-cell-height", in: generate(settings)) == expected)
    }

    // MARK: - Terminal

    @Test("scrollback uses the selected line count without an earlier byte ceiling")
    func makeConfig_scrollbackLines_isForwarded() {
        var settings = WeirSettings.default
        settings.terminal.scrollbackLines = 12345
        let config = generate(settings)
        #expect(value(of: "scrollback-limit-lines", in: config) == "12345")
        #expect(value(of: "scrollback-limit-bytes", in: config) == "unlimited")
        #expect(value(of: "scrollback-limit", in: config) == nil)
    }

    @Test("the finalized scrollbar preference controls the native indicator")
    func finalizedConfig_scrollbarNeverDisablesIndicator() throws {
        try withTempDir { directory in
            let path = directory.appendingPathComponent("ghostty-config")
            try "scrollbar = never\n".write(to: path, atomically: true, encoding: .utf8)
            let config = try #require(ghostty_config_new())
            defer { ghostty_config_free(config) }
            path.path.withCString { ghostty_config_load_file(config, $0) }
            ghostty_config_finalize(config)

            #expect(!GhosttyApp.scrollbarEnabled(in: config))
        }
    }

    @Test("cursor-style-blink toggle is forwarded as a bool")
    func makeConfig_cursorBlink_isForwarded() {
        var settings = WeirSettings.default
        settings.terminal.cursorBlink = .on
        #expect(value(of: "cursor-style-blink", in: generate(settings)) == "true")
    }

    // MARK: - Forced overrides

    @Test("background-opacity is forced to 0 regardless of user settings")
    func makeConfig_backgroundOpacity_isForcedToZero() {
        var settings = WeirSettings.default
        settings.appearance.backgroundOpacity = 0.5
        #expect(value(of: "background-opacity", in: generate(settings)) == "0")
    }

    @Test("term falls back when no bundled database is available")
    func makeConfig_term_fallsBackWithoutResources() {
        #expect(value(of: "term", in: generate(.default)) == "xterm-256color")
        #expect(GhosttyConfigBridge.resolvedTerm(resourcesDir: "/missing/share/ghostty") == "xterm-256color")
    }

    @Test("term names the compiled database shipped beside Ghostty resources")
    func makeConfig_term_usesBundledXtermGhostty() throws {
        let resourcesDir = try #require(GhosttyApp.resolveResourcesDir())
        let config = GhosttyConfigBridge.makeConfigString(
            settings: .default,
            resourcesDir: resourcesDir
        )
        #expect(value(of: "term", in: config) == "xterm-ghostty")
        let database = URL(fileURLWithPath: resourcesDir)
            .deletingLastPathComponent()
            .appendingPathComponent("terminfo/78/xterm-ghostty")
        #expect(FileManager.default.fileExists(atPath: database.path))
    }

    @Test("bundled terminfo is readable and advertises extended underline capabilities")
    func bundledTerminfo_isReadableByNcurses() throws {
        let resourcesDir = try #require(GhosttyApp.resolveResourcesDir())
        let database = URL(fileURLWithPath: resourcesDir)
            .deletingLastPathComponent()
            .appendingPathComponent("terminfo")
        let output = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/infocmp")
        process.arguments = ["-x", "-A", database.path, "xterm-ghostty"]
        process.standardOutput = output
        process.standardError = output
        try process.run()
        #expect(process.waitUntilExit(within: 10), "infocmp did not finish")
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let text = try #require(String(bytes: data, encoding: .utf8))

        #expect(process.terminationStatus == 0)
        #expect(text.contains("Smulx="))
        #expect(text.contains("Setulc="))
    }

    @Test("confirm-close-surface is disabled (Weir owns the confirm UI)")
    func makeConfig_confirmCloseSurface_isDisabled() {
        #expect(value(of: "confirm-close-surface", in: generate(.default)) == "false")
    }

    @Test("shell integration preserves local terminfo without exporting it to SSH hosts")
    func makeConfig_shellIntegrationFeatures_preserveLocalTerminfo() {
        #expect(
            value(of: "shell-integration-features", in: generate(.default)) ==
                "no-cursor,sudo,ssh-env"
        )
    }

    // MARK: - Bundled theme

    @Test("resources-dir is omitted when no path is supplied")
    func makeConfig_nilResourcesDir_omitsLine() {
        let config = GhosttyConfigBridge.makeConfigString(settings: .default, resourcesDir: nil)
        #expect(value(of: "resources-dir", in: config) == nil)
    }

    @Test("resources path emits the bundled light and dark theme pair")
    func makeConfig_withResourcesDir_usesAbsoluteThemePair() {
        let path = "/tmp/weir-resources/\(UUID().uuidString)"
        let config = GhosttyConfigBridge.makeConfigString(settings: .default, resourcesDir: path)
        #expect(value(of: "resources-dir", in: config) == nil)
        #expect(
            value(of: "theme", in: config) ==
                "light:\(path)/themes/Apple System Colors Light,dark:\(path)/themes/Apple System Colors"
        )
    }

    /// A fixed appearance wins over the system's; the system one follows
    /// the resolved macOS value.
    @Test("the terminal's color scheme follows the appearance chosen", arguments: [
        (ColorSchemePreference.light, false, false),
        (.light, true, false),
        (.dark, false, true),
        (.dark, true, true),
        (.system, false, false),
        (.system, true, true)
    ])
    func resolvedColorScheme_followsTheAppearanceChosen(preference: ColorSchemePreference, systemIsDark: Bool, isDark: Bool) {
        let expected = isDark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT
        #expect(GhosttyApp.resolvedColorScheme(preference: preference, systemIsDark: systemIsDark) == expected)
    }

    @Test("generated config is accepted for every Bell choice", arguments: BellAction.allCases)
    func generatedConfig_hasNoDiagnostics(bellAction: BellAction) throws {
        try withTempDir { directory in
            var settings = WeirSettings.default
            settings.terminal.bellAction = bellAction
            let resourcesDir = try #require(GhosttyApp.resolveResourcesDir())
            let body = GhosttyConfigBridge.makeConfigString(
                settings: settings,
                resourcesDir: resourcesDir
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

    // MARK: - Keybinds

    /// The bridge emits the person's keybinds after its own `keybind = …`
    /// lines, so libghostty's last-write-wins merging lets the person's
    /// choice beat Ghostty's defaults. The action is one libghostty runs
    /// (font size): a menu-owned action's binding is not emitted as one.
    @Test("User overrides appear after forced-override keybinds")
    func keybinds_overridesAppearLast() throws {
        var settings = WeirSettings.default
        settings.keyboard.setOverride(.init(key: "k", modifiers: [.command, .control]), for: .increaseFontSize)
        let config = generate(settings)
        let forced = try #require(config.range(of: "keybind = super+q=unbind"))
        let user = try #require(config.range(of: "keybind = super+ctrl+k=increase_font_size:1"))
        #expect(forced.lowerBound < user.lowerBound)
    }

    /// `keybind = clear` comes before the bindings, so it wipes libghostty's
    /// built-in macOS defaults without erasing ours on the lines after it.
    @Test("keybind = clear precedes user-effective bindings")
    func keybinds_clearBeforeUserBindings() throws {
        let config = generate(.default)
        let clear = try #require(config.range(of: "keybind = clear"))
        // Font size is one of the few actions libghostty runs, so its
        // default shortcut is in the config.
        let user = try #require(config.range(of: "keybind = super+shift+==increase_font_size:1"))
        #expect(clear.lowerBound < user.lowerBound)
    }

    @Test("Every libghostty-routed action with a default emits its keybind line, never an ignore")
    func keybinds_defaultsEmitEveryGhosttyAction() {
        let config = generate(.default)
        for action in WeirShortcutAction.allCases {
            guard let ghosttyAction = action.ghosttyAction,
                  let shortcut = action.defaultShortcut
            else { continue }
            let expected = "keybind = \(shortcut.ghosttyTrigger)=\(ghosttyAction)"
            #expect(config.contains(expected), "expected default binding for \(action.rawValue): \(expected)")
            #expect(!config.contains("keybind = \(shortcut.ghosttyTrigger)=ignore"), "\(action.rawValue)")
        }
    }

    /// Only actions with no menu item reach libghostty as actions: an
    /// action with a menu Button bound there too would run twice for one
    /// keystroke (two splits per ⌘D, two tab closes per ⌘⌥W). Adding a
    /// `ghosttyAction` fails here until the action is confirmed menu-less.
    @Test("Emitted libghostty actions stay limited to menu-less actions")
    func onlyMenulessActions_reachLibghosttyAsActions() {
        let emitted = Set(WeirShortcutAction.allCases.compactMap(\.ghosttyAction))
        let expected: Set = [
            "increase_font_size:1",
            "decrease_font_size:1",
            "reset_font_size",
            "jump_to_prompt:1",
            "jump_to_prompt:-1"
        ]
        #expect(emitted == expected, """
        `ghosttyAction` names an action that also has a menu Button, which \
        would run twice for one keystroke. See `WeirShortcutAction.ghosttyAction`.
        """)
    }

    /// A menu-owned action reaches libghostty only as `=ignore`: the menu
    /// runs the enabled Button first (`SurfaceView.performKeyEquivalent`
    /// probes it when the event hits a keybind), and the ignore swallows
    /// the keystroke while the item is disabled, so its key is never typed
    /// into the terminal.
    @Test("Menu-owned shortcuts reach libghostty as =ignore, never as a real action")
    func keybinds_menuOwnedShortcuts_emitIgnore() throws {
        let config = generate(.default)
        let menuOwned = WeirShortcutAction.allCases.filter { $0.ghosttyAction == nil && $0.defaultShortcut != nil }
        #expect(!menuOwned.isEmpty)
        for action in menuOwned {
            let trigger = try #require(action.defaultShortcut?.ghosttyTrigger)
            #expect(config.contains("keybind = \(trigger)=ignore"), "menu-owned action \(action.rawValue) missing its =ignore guard")
        }
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
                settings: .default, resourcesDir: "/resources",
                directory: directory, processID: 101
            )
            let firstPath = try #require(first)
            let before = try String(contentsOfFile: firstPath, encoding: .utf8)
            let second = GhosttyConfigBridge.writeConfigFile(
                settings: .default, resourcesDir: "/resources",
                directory: directory, processID: 202
            )
            let secondPath = try #require(second)
            #expect(firstPath != secondPath)
            let retained = try String(contentsOfFile: firstPath, encoding: .utf8)
            #expect(retained == before)
            #expect(retained.contains("light:/resources/themes/Apple System Colors Light"))
            let dark = try String(contentsOfFile: secondPath, encoding: .utf8)
            #expect(dark == before)
        }
    }

    /// Without Weir's own layer the config would lack the forced
    /// overrides (`background-opacity = 0`, `clipboard-paste-protection`),
    /// so a layer that could not be written builds no config at all and the
    /// running one stays.
    @Test func aLayerThatCouldNotBeWritten_buildsNoConfig() {
        let config = GhosttyConfigBridge.makeConfig(path: nil, includeUserConfig: false)
        if let config {
            ghostty_config_free(config)
        }
        #expect(config == nil)
    }

    @Test func aFolderThatCannotBeWritten_givesNoPath() throws {
        try withTempDir { directory in
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
            let path = GhosttyConfigBridge.writeConfigFile(
                settings: .default, resourcesDir: nil, directory: directory, processID: 303
            )
            #expect(path == nil)
        }
    }
}
