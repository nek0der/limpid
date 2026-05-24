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
    case advanced

    var id: String {
        rawValue
    }

    var title: LocalizedStringKey {
        switch self {
        case .general: "General"
        case .appearance: "Appearance"
        case .font: "Font"
        case .terminal: "Terminal"
        case .advanced: "Advanced"
        }
    }

    var icon: String {
        switch self {
        case .general: "gearshape"
        case .appearance: "paintbrush"
        case .font: "textformat"
        case .terminal: "terminal"
        case .advanced: "wrench.and.screwdriver"
        }
    }
}
