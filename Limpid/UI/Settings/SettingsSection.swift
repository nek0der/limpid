// SettingsSection.swift
// Limpid — left-sidebar entries in the Settings window. macOS 13+
// System Settings sticks to a static enum (not a dynamic list); we
// follow the same pattern so adding a new pane is one case + one
// switch branch in `SettingsScene`.

import Foundation
import SwiftUI

enum SettingsSection: String, CaseIterable, Identifiable {
    case general
    case appearance
    case font
    case terminal
    case tabsAndPanes
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
        case .keyboard: "keyboard"
        case .integrations: "puzzlepiece.extension"
        case .review: "text.document"
        case .advanced: "wrench.and.screwdriver"
        }
    }
}
