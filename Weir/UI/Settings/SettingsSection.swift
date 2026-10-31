// SettingsSection.swift
// Weir — left-sidebar entries in the Settings window. macOS 13+
// System Settings sticks to a static enum (not a dynamic list); we
// follow the same pattern so adding a new pane is one case + one
// switch branch in `SettingsScene`.

import Foundation
import SwiftUI

enum SettingsSection: String, CaseIterable, Identifiable {
    /// Opens Settings on the Keyboard pane: the Settings scene reads the
    /// last section from `lastSectionDefaultsKey` when it opens.
    static func openKeyboard() {
        open(.keyboard)
    }

    /// Opens Settings on the General pane, where the notice that saving
    /// stopped is (`SavingSuspendedNotice`).
    static func openGeneral() {
        open(.general)
    }

    private static func open(_ section: Self) {
        UserDefaults.standard.set(section.rawValue, forKey: lastSectionDefaultsKey)
        NotificationCenter.default.post(name: .weirOpenSettings, object: nil)
    }

    /// `UserDefaults` key holding the last visible section's rawValue.
    /// `SettingsScene` reads it to pick the pane it opens on, and any
    /// surface that wants to land on a specific pane writes it before
    /// posting `.weirOpenSettings`.
    static let lastSectionDefaultsKey = "settings.last-section"

    case general
    case appearance
    case font
    case terminal
    case tabsAndPanes
    case quickTerminal
    case keyboard
    case integrations
    case review
    case advanced

    var id: String {
        rawValue
    }

    var title: LocalizedStringResource {
        switch self {
        case .general: "General"
        case .appearance: "Appearance"
        case .font: "Font"
        case .terminal: "Terminal"
        case .tabsAndPanes: "Tabs & Panes"
        case .quickTerminal: "Quick Terminal"
        case .keyboard: "Keyboard"
        case .integrations: "Integrations"
        case .review: "Review"
        case .advanced: "Advanced"
        }
    }

    var icon: String {
        switch self {
        case .general: "gearshape"
        case .appearance: "paintbrush"
        case .font: "textformat"
        case .terminal: "terminal"
        case .tabsAndPanes: "rectangle.split.2x1"
        case .quickTerminal: "apple.terminal.on.rectangle"
        case .keyboard: "keyboard"
        case .integrations: "puzzlepiece.extension"
        case .review: "text.document"
        case .advanced: "wrench.and.screwdriver"
        }
    }
}
