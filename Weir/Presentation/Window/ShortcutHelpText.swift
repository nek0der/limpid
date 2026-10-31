// ShortcutHelpText.swift
// Weir — a control's tooltip: its name and the key that does the same.

import Foundation

/// The tooltip of a control a key also works: its name, and that key when
/// one is bound ("Keyboard Shortcuts (⌘/)"). The rail icons, the
/// palette field, and the Needs Attention list's Next Action share it.
enum ShortcutHelpText {
    static func make(name: LocalizedStringResource, shortcut: String?, locale: Locale) -> String {
        let resolved = name.resolved(in: locale)
        guard let shortcut, !shortcut.isEmpty else { return resolved }
        return LocalizedStringResource(
            "\(resolved) (\(shortcut))",
            comment: "Tooltip of a rail icon: its name, then the key that does the same"
        ).resolved(in: locale)
    }
}
