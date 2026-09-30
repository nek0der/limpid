// QuickTerminalTests.swift
// Limpid — coverage for the quick terminal: hotkey mapping, the hotkey
// center's registration state, recorder validation in both directions,
// panel geometry, settings decoding, and the surface being freed after
// its shell exits.

import AppKit
import Carbon.HIToolbox
import Foundation
import Testing
@testable import Limpid

@Suite("QuickTerminal")
@MainActor
struct QuickTerminalTests {

    // MARK: - Hotkey mapping

    /// A US-like layout for the parts the tests touch: letters on their
    /// ANSI keyCodes, the digit 1 on both the top row (18) and the
    /// keypad (83), and `]` on 30.
    private static let usLayout: [UInt16: String] = [
        0: "a", 1: "s", 17: "t", 30: "]", 18: "1", 83: "1", 40: "k"
    ]

    private static func translate(_ layout: [UInt16: String]) -> (UInt16) -> String? {
        { layout[$0] }
    }

    @Test func keyCode_namedKey_usesCaptureTable() {
        #expect(HotKeyMapping.keyCode(for: "escape", translate: { _ in nil }) == 53)
        #expect(HotKeyMapping.keyCode(for: "f1", translate: { _ in nil }) == 122)
        #expect(HotKeyMapping.keyCode(for: "up", translate: { _ in nil }) == 126)
    }

    @Test func keyCode_return_mapsToMainKeyNotKeypadEnter() {
        // `return` is both 36 and the keypad's 76; the lower code wins.
        #expect(HotKeyMapping.keyCode(for: "return", translate: { _ in nil }) == 36)
        #expect(HotKeyMapping.keyCode(for: "enter", translate: { _ in nil }) == 36)
    }

    @Test func keyCode_letterResolvedThroughLayoutScan() {
        let translate = Self.translate(Self.usLayout)
        #expect(HotKeyMapping.keyCode(for: "t", translate: translate) == 17)
        #expect(HotKeyMapping.keyCode(for: "]", translate: translate) == 30)
    }

    @Test func keyCode_digitOnTopRowAndKeypad_takesLowestKeyCode() {
        #expect(HotKeyMapping.keyCode(for: "1", translate: Self.translate(Self.usLayout)) == 18)
    }

    @Test func keyCode_letterFollowsTheLayout() {
        // A layout that moves `t` elsewhere (as switching input sources
        // can) must move the registered keyCode with it.
        let moved: [UInt16: String] = [5: "t"]
        #expect(HotKeyMapping.keyCode(for: "t", translate: Self.translate(moved)) == 5)
    }

    @Test func keyCode_characterMissingFromLayout_returnsNil() {
        #expect(HotKeyMapping.keyCode(for: "ß", translate: Self.translate(Self.usLayout)) == nil)
    }

    @Test func keyCode_layoutScanSkipsNamedKeys() {
        // Named keys never stand for a layout character, even if a
        // translator returns one for them.
        let layout: [UInt16: String] = [36: "x", 7: "x"]
        #expect(HotKeyMapping.keyCode(for: "x", translate: Self.translate(layout)) == 7)
    }

    @Test func keyCode_currentLayout_resolvesLettersWhenAvailable() throws {
        // Runs against the machine's real input source. A layout without
        // Unicode data has no translator; there is nothing to check then.
        guard let translate = StoredShortcut.currentLayoutTranslator() else { return }
        let code = try #require(HotKeyMapping.keyCodeRange.first { code in
            NamedKey(keyCode: code) == nil && translate(code)?.isEmpty == false
        })
        let character = try #require(translate(code))
        let resolved = try #require(HotKeyMapping.keyCode(for: character, translate: translate))
        #expect(translate(resolved)?.lowercased() == character.lowercased())
    }

    @Test func carbonModifiers_mapEachModifier() {
        #expect(HotKeyMapping.carbonModifiers(for: [.command]) == UInt32(cmdKey))
        #expect(HotKeyMapping.carbonModifiers(for: [.shift]) == UInt32(shiftKey))
        #expect(HotKeyMapping.carbonModifiers(for: [.option]) == UInt32(optionKey))
        #expect(HotKeyMapping.carbonModifiers(for: [.control]) == UInt32(controlKey))
        #expect(
            HotKeyMapping.carbonModifiers(for: [.command, .shift, .option, .control])
                == UInt32(cmdKey | shiftKey | optionKey | controlKey)
        )
        #expect(HotKeyMapping.carbonModifiers(for: []) == 0)
    }

    @Test func combination_joinsKeyCodeAndModifiers() {
        let shortcut = StoredShortcut(key: "t", modifiers: [.control, .option])
        let combination = HotKeyMapping.combination(for: shortcut, translate: Self.translate(Self.usLayout))
        #expect(combination == HotKeyCombination(keyCode: 17, carbonModifiers: UInt32(controlKey | optionKey)))
    }

    // MARK: - Recorder validation

    private static let noSystemHotKeys: (StoredShortcut) -> Bool = { _ in false }

    @Test func validateHotKey_requiresCommandOrControl() {
        let settings = QuickTerminalSettings()
        let keyboard = KeyboardSettings()
        #expect(settings.validateHotKey(.init(key: "k", modifiers: [.option]), keyboard: keyboard, isTakenBySystem: Self.noSystemHotKeys)
            == .missingPrimaryModifier)
        #expect(settings.validateHotKey(
            .init(key: "k", modifiers: [.shift, .option]),
            keyboard: keyboard,
            isTakenBySystem: Self.noSystemHotKeys
        )
            == .missingPrimaryModifier)
        #expect(settings.validateHotKey(.init(key: "k", modifiers: []), keyboard: keyboard, isTakenBySystem: Self.noSystemHotKeys)
            == .missingPrimaryModifier)
        #expect(settings.validateHotKey(
            .init(key: "k", modifiers: [.control, .option]),
            keyboard: keyboard,
            isTakenBySystem: Self.noSystemHotKeys
        ) == .ok)
        #expect(settings.validateHotKey(
            .init(key: "k", modifiers: [.command, .option]),
            keyboard: keyboard,
            isTakenBySystem: Self.noSystemHotKeys
        ) == .ok)
    }

    @Test func validateHotKey_rejectsDefaultMenuShortcut() {
        let result = QuickTerminalSettings().validateHotKey(
            .init(key: "t", modifiers: [.command]),
            keyboard: KeyboardSettings(),
            isTakenBySystem: Self.noSystemHotKeys
        )
        #expect(result == .conflictsWithMenu(.newTab))
    }

    @Test func validateHotKey_rejectsOverriddenMenuShortcut() {
        var keyboard = KeyboardSettings()
        let custom = StoredShortcut(key: "k", modifiers: [.control, .option])
        keyboard.setOverride(custom, for: .toggleSidebar)
        #expect(QuickTerminalSettings()
            .validateHotKey(custom, keyboard: keyboard, isTakenBySystem: Self.noSystemHotKeys) == .conflictsWithMenu(.toggleSidebar))
    }

    @Test func validateHotKey_rejectsReservedTrigger() {
        let settings = QuickTerminalSettings()
        #expect(settings
            .validateHotKey(.init(key: "q", modifiers: [.command]), keyboard: .init(), isTakenBySystem: Self.noSystemHotKeys) == .reserved)
        #expect(settings
            .validateHotKey(.init(key: "3", modifiers: [.command]), keyboard: .init(), isTakenBySystem: Self.noSystemHotKeys) == .reserved)
    }

    @Test func keyboardValidate_rejectsQuickTerminalHotKey() {
        let hotKey = StoredShortcut(key: "`", modifiers: [.control])
        let keyboard = KeyboardSettings()
        #expect(keyboard.validate(hotKey, for: .newTab, quickTerminalHotKey: hotKey) == .quickTerminalConflict)
        #expect(keyboard.validate(hotKey, for: .newTab, quickTerminalHotKey: nil) == .ok)
        #expect(
            keyboard.validate(.init(key: "`", modifiers: [.command]), for: .newTab, quickTerminalHotKey: hotKey)
                == .ok
        )
    }

    @Test func validateHotKey_takenBySystem_isRejected() {
        let spotlight = StoredShortcut(key: "space", modifiers: [.command])
        let result = QuickTerminalSettings().validateHotKey(spotlight, keyboard: .init()) { $0 == spotlight }
        #expect(result == .takenBySystem)
    }

    /// Ordinary app commands are warned about in the pane, not rejected.
    @Test func validateHotKey_appCommandNotTakenBySystem_isAccepted() {
        let settings = QuickTerminalSettings()
        #expect(settings.validateHotKey(
            .init(key: "s", modifiers: [.command]),
            keyboard: .init(),
            isTakenBySystem: Self.noSystemHotKeys
        ) == .ok)
        #expect(settings.validateHotKey(
            .init(key: "c", modifiers: [.command]),
            keyboard: .init(),
            isTakenBySystem: Self.noSystemHotKeys
        ) == .ok)
    }

    /// Reserved combinations keep their more specific message even when
    /// macOS also uses them.
    @Test func validateHotKey_reservedWinsOverSystem() {
        let result = QuickTerminalSettings().validateHotKey(
            .init(key: "q", modifiers: [.command]),
            keyboard: .init(),
            isTakenBySystem: { _ in true }
        )
        #expect(result == .reserved)
    }

    // MARK: - System hotkeys

    private static func symbolicEntry(code: Int, modifiers: Int, isEnabled: Bool = true) -> [String: Any] {
        [
            kHISymbolicHotKeyCode as String: NSNumber(value: code),
            kHISymbolicHotKeyModifiers as String: NSNumber(value: modifiers),
            kHISymbolicHotKeyEnabled as String: isEnabled
        ]
    }

    /// The entry mask is Carbon's, so a system entry and the combination
    /// we would register for the same keys compare equal. Values are the
    /// ones macOS 27 reports for Spotlight (⌘Space) and the ⌘⇧3 screenshot.
    @Test func systemHotKeys_modifiersMatchRegisteredCarbonFormat() {
        let parsed = SystemHotKeys.combinations(from: [
            Self.symbolicEntry(code: 49, modifiers: 0x100),
            Self.symbolicEntry(code: 20, modifiers: 0x300)
        ])
        let spotlight = HotKeyMapping.combination(
            for: .init(key: "space", modifiers: [.command]),
            translate: { _ in nil }
        )
        let screenshot = HotKeyMapping.combination(
            for: .init(key: "3", modifiers: [.command, .shift]),
            translate: Self.translate([20: "3"])
        )
        #expect(parsed == Set([spotlight, screenshot].compactMap(\.self)))
        #expect(parsed.count == 2)
    }

    @Test func systemHotKeys_disabledAndUnassignedEntries_areSkipped() {
        let parsed = SystemHotKeys.combinations(from: [
            Self.symbolicEntry(code: 49, modifiers: 0x100, isEnabled: false),
            Self.symbolicEntry(code: 0xFFFF, modifiers: 0x100),
            ["unexpected": 1]
        ])
        #expect(parsed.isEmpty)
    }

    /// Arrows and F-keys always carry the fn bit, so ⌃↑ (Mission Control,
    /// reported as 0x21000) must still match our ⌃↑.
    @Test func systemHotKeys_fnBitOnFunctionKey_isDropped() {
        let parsed = SystemHotKeys.combinations(from: [Self.symbolicEntry(code: 126, modifiers: 0x21000)])
        #expect(parsed == [HotKeyCombination(keyCode: 126, carbonModifiers: UInt32(controlKey))])
        #expect(SystemHotKeys.contains(.init(key: "up", modifiers: [.control]), in: parsed, translate: { _ in nil }))
    }

    /// On a letter the fn bit means Globe is part of the shortcut (Globe⌃F
    /// fills the window), which our hotkey can never be.
    @Test func systemHotKeys_fnBitOnLetter_isSkipped() {
        let parsed = SystemHotKeys.combinations(from: [Self.symbolicEntry(code: 3, modifiers: 0x21000)])
        #expect(parsed.isEmpty)
    }

    @Test func systemHotKeys_contains_resolvesThroughTheLayout() {
        let system: Set = [HotKeyCombination(keyCode: 40, carbonModifiers: UInt32(controlKey | cmdKey))]
        let translate = Self.translate(Self.usLayout)
        #expect(SystemHotKeys.contains(.init(key: "k", modifiers: [.command, .control]), in: system, translate: translate))
        #expect(!SystemHotKeys.contains(.init(key: "k", modifiers: [.command]), in: system, translate: translate))
        #expect(!SystemHotKeys.contains(.init(key: "ß", modifiers: [.command, .control]), in: system, translate: translate))
    }

    // MARK: - App command warning

    @Test(arguments: [
        (StoredShortcut(key: "s", modifiers: [.command]), true),
        (StoredShortcut(key: "space", modifiers: [.command]), true),
        (StoredShortcut(key: "k", modifiers: [.control]), true),
        (StoredShortcut(key: "k", modifiers: [.command, .control]), false),
        (StoredShortcut(key: "`", modifiers: [.control]), false),
        (StoredShortcut(key: "k", modifiers: [.command, .option]), false),
        (StoredShortcut(key: "k", modifiers: [.control, .shift]), false)
    ])
    func mayOverlapAppCommands(_ shortcut: StoredShortcut, expected: Bool) {
        #expect(QuickTerminalSettings.mayOverlapAppCommands(shortcut) == expected, "\(shortcut.displayString)")
    }

    // MARK: - Hotkey center

    /// The branches below stop before `RegisterEventHotKey`, so they run
    /// without claiming a system-wide hotkey on the test machine.
    private static func makeCenter(
        isTerminalAvailable: Bool = true,
        hotKey: StoredShortcut?,
        layout: [UInt16: String] = usLayout,
        systemHotKeys: @escaping @MainActor () -> Set<HotKeyCombination> = { [] }
    ) -> QuickTerminalHotKeyCenter {
        QuickTerminalHotKeyCenter(
            isTerminalAvailable: isTerminalAvailable,
            hotKeyProvider: { hotKey },
            menuShortcutsProvider: { KeyboardSettings() },
            layoutTranslator: { translate(layout) },
            systemHotKeysProvider: systemHotKeys,
            onPress: {}
        )
    }

    @Test func hotKeyCenter_terminalUnavailable_withHotKey_reportsIt() {
        let center = Self.makeCenter(isTerminalAvailable: false, hotKey: .init(key: "k", modifiers: [.control, .option]))
        center.apply()
        #expect(center.problem == .terminalUnavailable)
    }

    @Test func hotKeyCenter_terminalUnavailable_withoutHotKey_reportsNothing() {
        let center = Self.makeCenter(isTerminalAvailable: false, hotKey: nil)
        center.apply()
        #expect(center.problem == nil)
    }

    @Test func hotKeyCenter_keyMissingFromLayout_reportsKeyNotOnLayout() {
        let center = Self.makeCenter(hotKey: .init(key: "ß", modifiers: [.control, .option]))
        center.apply()
        #expect(center.problem == .keyNotOnLayout)
    }

    /// A system shortcut added after the hotkey was saved keeps it off.
    /// The branch returns before `RegisterEventHotKey`.
    @Test func hotKeyCenter_takenBySystem_staysOff() {
        let hotKey = StoredShortcut(key: "k", modifiers: [.control, .option])
        let center = Self.makeCenter(hotKey: hotKey) {
            [HotKeyCombination(keyCode: 40, carbonModifiers: UInt32(controlKey | optionKey))]
        }
        center.apply()
        #expect(center.problem == .takenBySystem)
    }

    @Test func hotKeyCenter_suspended_clearsTheProblem() {
        let center = Self.makeCenter(hotKey: .init(key: "ß", modifiers: [.control, .option]))
        center.apply()
        #expect(center.problem == .keyNotOnLayout)

        let suspension = center.suspend()
        #expect(center.isSuspended)
        #expect(center.problem == nil)

        center.resume(suspension)
        #expect(!center.isSuspended)
        #expect(center.problem == .keyNotOnLayout)
    }

    /// Both Settings recorders can hold a suspension at once; the hotkey
    /// comes back only when the last one lets go, and releasing a token
    /// twice does not release anyone else's.
    @Test func hotKeyCenter_suspensions_areCountedPerOwner() {
        let center = Self.makeCenter(hotKey: nil)
        let keyboardRecorder = center.suspend()
        let quickTerminalRecorder = center.suspend()
        #expect(keyboardRecorder != quickTerminalRecorder)

        center.resume(keyboardRecorder)
        #expect(center.isSuspended)
        center.resume(keyboardRecorder)
        #expect(center.isSuspended, "a token released twice must not release another owner's hold")

        center.resume(quickTerminalRecorder)
        #expect(!center.isSuspended)
    }

    /// Resetting a menu shortcut to its default bypasses both recorders, so
    /// the hotkey center checks the effective menu bindings itself and
    /// leaves the hotkey unregistered rather than silencing the menu item.
    @Test func hotKeyCenter_menuShortcutResetOntoHotKey_staysOff() {
        let hotKey = StoredShortcut(key: "t", modifiers: [.command])
        var keyboard = KeyboardSettings()
        keyboard.setOverride(.init(key: "t", modifiers: [.command, .option]), for: .newTab)
        var pressCount = 0
        let center = QuickTerminalHotKeyCenter(
            isTerminalAvailable: true,
            hotKeyProvider: { hotKey },
            menuShortcutsProvider: { keyboard },
            layoutTranslator: { Self.translate([17: "t"]) },
            onPress: { pressCount += 1 }
        )

        keyboard.resetOverride(for: .newTab)
        center.apply()

        #expect(center.problem == .conflictsWithMenu(.newTab))
        #expect(pressCount == 0)
    }

    // MARK: - Frame

    private static let visibleFrame = CGRect(x: 0, y: 40, width: 1000, height: 800)

    @Test func targetFrame_top_fullWidthAtTopEdge() {
        let frame = QuickTerminalLayout.targetFrame(position: .top, sizePercent: 50, visibleFrame: Self.visibleFrame)
        #expect(frame == CGRect(x: 0, y: 440, width: 1000, height: 400))
    }

    @Test func targetFrame_bottom_fullWidthAtBottomEdge() {
        let frame = QuickTerminalLayout.targetFrame(position: .bottom, sizePercent: 30, visibleFrame: Self.visibleFrame)
        #expect(frame == CGRect(x: 0, y: 40, width: 1000, height: 240))
    }

    @Test func targetFrame_left_fullHeightAtLeftEdge() {
        let frame = QuickTerminalLayout.targetFrame(position: .left, sizePercent: 40, visibleFrame: Self.visibleFrame)
        #expect(frame == CGRect(x: 0, y: 40, width: 400, height: 800))
    }

    @Test func targetFrame_right_fullHeightAtRightEdge() {
        let frame = QuickTerminalLayout.targetFrame(position: .right, sizePercent: 90, visibleFrame: Self.visibleFrame)
        #expect(frame == CGRect(x: 100, y: 40, width: 900, height: 800))
    }

    @Test func targetFrame_center_sixtyPercentWideAndCentered() {
        let frame = QuickTerminalLayout.targetFrame(position: .center, sizePercent: 50, visibleFrame: Self.visibleFrame)
        #expect(frame == CGRect(x: 200, y: 240, width: 600, height: 400))
    }

    @Test(arguments: QuickTerminalPosition.allCases)
    func targetFrame_everySize_staysInsideVisibleFrame(position: QuickTerminalPosition) {
        for percent in QuickTerminalSettings.allowedSizePercents {
            let frame = QuickTerminalLayout.targetFrame(
                position: position,
                sizePercent: percent,
                visibleFrame: Self.visibleFrame
            )
            #expect(Self.visibleFrame.contains(frame), "\(position) \(percent)%")
        }
    }

    @Test func targetFrame_sizeFollowsPercent() {
        let sizes = QuickTerminalSettings.allowedSizePercents.map {
            QuickTerminalLayout.targetFrame(position: .top, sizePercent: $0, visibleFrame: Self.visibleFrame).height
        }
        #expect(sizes == [240, 320, 400, 480, 560, 640, 720])
    }

    @Test func hiddenFrame_edgesMoveFullyPastTheirEdge() {
        let vf = Self.visibleFrame
        func hidden(_ position: QuickTerminalPosition) -> (target: CGRect, hidden: CGRect) {
            let target = QuickTerminalLayout.targetFrame(position: position, sizePercent: 50, visibleFrame: vf)
            return (target, QuickTerminalLayout.hiddenFrame(position: position, target: target))
        }
        let top = hidden(.top)
        #expect(top.hidden.size == top.target.size)
        #expect(top.hidden.minY == vf.maxY)
        let bottom = hidden(.bottom)
        #expect(bottom.hidden.size == bottom.target.size)
        #expect(bottom.hidden.maxY == vf.minY)
        let left = hidden(.left)
        #expect(left.hidden.size == left.target.size)
        #expect(left.hidden.maxX == vf.minX)
        let right = hidden(.right)
        #expect(right.hidden.size == right.target.size)
        #expect(right.hidden.minX == vf.maxX)
    }

    /// Two displays stacked: the lower one at the origin, the upper one
    /// directly above it. Sliding from the lower display's top edge would
    /// be drawn on the upper display, so the panel fades in place instead.
    @Test func animationFrame_slideIntoDisplayAbove_fadesInPlace() {
        let lower = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let upper = CGRect(x: 0, y: 800, width: 1000, height: 800)
        let target = QuickTerminalLayout.targetFrame(position: .top, sizePercent: 50, visibleFrame: lower)
        let start = QuickTerminalLayout.animationFrame(position: .top, target: target, otherScreenFrames: [upper])
        #expect(start == target)
    }

    @Test func animationFrame_slideIntoDisplayBelow_fadesInPlace() {
        let upper = CGRect(x: 0, y: 800, width: 1000, height: 800)
        let lower = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let target = QuickTerminalLayout.targetFrame(position: .bottom, sizePercent: 50, visibleFrame: upper)
        let start = QuickTerminalLayout.animationFrame(position: .bottom, target: target, otherScreenFrames: [lower])
        #expect(start == target)
    }

    @Test func animationFrame_slideIntoDisplayBeside_fadesInPlace() {
        let left = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let right = CGRect(x: 1000, y: 0, width: 1000, height: 800)
        let target = QuickTerminalLayout.targetFrame(position: .left, sizePercent: 50, visibleFrame: right)
        let start = QuickTerminalLayout.animationFrame(position: .left, target: target, otherScreenFrames: [left])
        #expect(start == target)
    }

    /// A display beside the screen does not lie on the path of a slide
    /// from the top edge, so the slide stays.
    @Test func animationFrame_displayOffThePath_keepsTheSlide() {
        let main = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let beside = CGRect(x: 1000, y: 0, width: 1000, height: 800)
        let target = QuickTerminalLayout.targetFrame(position: .top, sizePercent: 50, visibleFrame: main)
        let start = QuickTerminalLayout.animationFrame(position: .top, target: target, otherScreenFrames: [beside])
        #expect(start == QuickTerminalLayout.hiddenFrame(position: .top, target: target))
        let alone = QuickTerminalLayout.animationFrame(position: .top, target: target, otherScreenFrames: [])
        #expect(alone == start)
    }

    @Test func hiddenFrame_center_isScaledAroundTheSameMiddle() {
        let target = CGRect(x: 200, y: 240, width: 600, height: 400)
        let hidden = QuickTerminalLayout.hiddenFrame(position: .center, target: target)
        #expect(hidden == CGRect(x: 212, y: 248, width: 576, height: 384))
    }

    /// Only the corners away from the attached screen edge are rounded.
    private nonisolated static let exposedCorners: [(QuickTerminalPosition, QuickTerminalCorners)] = [
        (.top, [.bottomLeading, .bottomTrailing]),
        (.bottom, [.topLeading, .topTrailing]),
        (.left, [.topTrailing, .bottomTrailing]),
        (.right, [.topLeading, .bottomLeading]),
        (.center, .all)
    ]

    @Test(arguments: exposedCorners)
    func roundedCorners_roundOnlyTheExposedCorners(
        position: QuickTerminalPosition,
        expected: QuickTerminalCorners
    ) {
        #expect(QuickTerminalLayout.roundedCorners(for: position) == expected)
    }

    // MARK: - Settings decoding

    @Test func decode_settingsWithoutQuickTerminal_usesDefaults() throws {
        let data = try JSONEncoder().encode(LimpidSettings.default)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["quickTerminal"] = nil
        let legacy = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(LimpidSettings.self, from: legacy)

        #expect(decoded.quickTerminal == QuickTerminalSettings())
        #expect(decoded.quickTerminal.hotKey == nil)
        #expect(decoded.quickTerminal.position == .top)
        #expect(decoded.quickTerminal.sizePercent == 50)
        #expect(decoded.quickTerminal.hidesOnFocusLoss)
    }

    @Test func decode_emptySection_usesDefaults() throws {
        let decoded = try JSONDecoder().decode(QuickTerminalSettings.self, from: Data("{}".utf8))
        #expect(decoded == QuickTerminalSettings())
    }

    @Test func decode_partialSection_keepsPresentKeys() throws {
        let json = #"{"position":"left","hotKey":{"key":"`","modifiers":8}}"#
        let decoded = try JSONDecoder().decode(QuickTerminalSettings.self, from: Data(json.utf8))
        #expect(decoded.position == .left)
        #expect(decoded.hotKey == StoredShortcut(key: "`", modifiers: [.control]))
        #expect(decoded.sizePercent == 50)
        #expect(decoded.hidesOnFocusLoss)
    }

    @Test func decode_unknownPosition_fallsBackToTop() throws {
        let decoded = try JSONDecoder().decode(
            QuickTerminalSettings.self,
            from: Data(#"{"position":"diagonal"}"#.utf8)
        )
        #expect(decoded.position == .top)
    }

    @Test func decode_outOfRangeSize_isClampedAndSnapped() throws {
        for (raw, expected) in [(5, 30), (95, 90), (44, 40), (46, 50), (70, 70)] {
            let decoded = try JSONDecoder().decode(
                QuickTerminalSettings.self,
                from: Data(#"{"sizePercent":\#(raw)}"#.utf8)
            )
            #expect(decoded.sizePercent == expected, "\(raw)")
        }
    }

    @Test func codable_roundTrip_preservesEveryField() throws {
        var settings = QuickTerminalSettings()
        settings.hotKey = StoredShortcut(key: "space", modifiers: [.command, .shift])
        settings.position = .center
        settings.sizePercent = 70
        settings.hidesOnFocusLoss = false
        let restored = try JSONDecoder().decode(
            QuickTerminalSettings.self,
            from: JSONEncoder().encode(settings)
        )
        #expect(restored == settings)
    }

    @Test func encode_unboundHotKey_omitsTheKey() throws {
        let data = try JSONEncoder().encode(QuickTerminalSettings())
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["hotKey"] == nil)
    }

    // MARK: - Surface lifecycle

    /// The quick terminal's surface has to be freed after its shell exits:
    /// otherwise every exit leaks a libghostty surface and a
    /// `liveViewsByPointer` entry. The view is retained by the controller,
    /// the hosting view's representable, and the scroll host's subview
    /// list, so dropping only the controller's reference is not enough.
    ///
    /// Needs the host app's `GhosttyApp` (a process-wide singleton); the
    /// surface it mounts starts a real shell, which the view's `deinit`
    /// frees. The panel is never ordered on screen.
    ///
    /// Async on purpose. SwiftUI's update pass, the representable's
    /// deferred `createSurface`, and AppKit's own deferred view work are
    /// main-queue blocks; a synchronous test body occupies the main queue,
    /// so they, and the references they hold, would never run out. Sleeping
    /// hands the main thread back to the app's run loop instead.
    @Test(.tags(.ffi), .enabled("libghostty is unavailable") { await QuickTerminalTests.isGhosttyAvailable() })
    func handleSurfaceExit_releasesTheSurfaceView() async throws {
        try await withTempDir { @Sendable directory in
            try await Self.exerciseSurfaceExit(settingsDirectory: directory)
        }
    }

    /// Whether the host app has a `GhosttyApp`, which only exists when
    /// libghostty started. Read on the main actor, where the box lives.
    nonisolated static func isGhosttyAvailable() async -> Bool {
        await MainActor.run { GhosttyApp.placeholder.target != nil }
    }

    private static func exerciseSurfaceExit(settingsDirectory directory: URL) async throws {
        let ghosttyApp = try #require(GhosttyApp.placeholder.target)
        let controller = QuickTerminalController(
            settingsStore: SettingsStore(directory: directory),
            reduceTransparencyResolver: ReduceTransparencyResolver(),
            clipboard: ClipboardConfirmationCoordinator(),
            secureInputManager: SecureInputManager(),
            surfaceFactory: {
                PaneHostRepresentable.makeSurfaceView(
                    ghosttyApp: ghosttyApp,
                    environment: AppState.quickTerminalEnvironment
                )
            }
        )
        weak var probe: SurfaceView?
        autoreleasepool {
            controller.panel.setFrame(NSRect(x: 0, y: 0, width: 640, height: 400), display: false)
            controller.prepareSurface()
            probe = controller.surfaceView
        }
        #expect(probe != nil)

        // Let SwiftUI mount the representable so the hierarchy holds the
        // view the way it does on screen.
        try await Self.waitUntil { probe?.window != nil }
        try autoreleasepool {
            let view = try #require(probe)
            #expect(view.window === controller.panel, "the surface was never mounted in the panel")
            #expect(view.surface != nil, "libghostty never created the surface")
            #expect(controller.handleSurfaceExit(view))
            #expect(controller.surfaceView == nil)
            #expect(!controller.handleSurfaceExit(view), "a second exit for the same view is not ours")
        }

        try await Self.waitUntil { probe == nil }
        #expect(probe == nil, "the quick terminal's SurfaceView outlived its shell")
        withExtendedLifetime(controller) {}
    }

    /// Poll `condition` every 20 ms for up to ten seconds, yielding the
    /// main thread to the run loop between checks. The ceiling only
    /// matters on a loaded machine; a passing run returns within a few
    /// polls.
    private static func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !autoreleasepool(invoking: condition), Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
