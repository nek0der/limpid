// IconButtonHelp.swift
// Weir — names a button drawn with an icon alone, in its tooltip and to VoiceOver.

import SwiftUI

extension View {
    /// Names a button that shows only an icon: its tooltip, "Name (⌘X)"
    /// with the key that does the same when one is bound
    /// (`ShortcutHelpText`), and its VoiceOver label, the name alone. One
    /// call for both, so an icon is never named to one and not the other.
    /// `help` replaces the tooltip where it says more than the name and the
    /// key (the history's unread count).
    func iconButtonHelp(_ name: LocalizedStringResource, shortcut: String? = nil, help: String? = nil) -> some View {
        modifier(IconButtonHelp(name: name, shortcut: shortcut, help: help))
    }
}

private struct IconButtonHelp: ViewModifier {
    let name: LocalizedStringResource
    let shortcut: String?
    let help: String?
    @Environment(\.locale) private var locale

    func body(content: Content) -> some View {
        content
            .help(Text(verbatim: help ?? ShortcutHelpText.make(name: name, shortcut: shortcut, locale: locale)))
            .accessibilityLabel(Text(name))
    }
}
