// ConversationMenuItem.swift
// Limpid — one conversation as a pop-up menu item: its badge, its name, and its line.

import AppKit

/// This makes a conversation an item of an AppKit pop-up menu: the agent's badge,
/// the conversation's name, under it its unviewed turns and where it runs,
/// its help, and what VoiceOver reads. The changes panel's filter and the
/// review's scope menu list conversations alike through it, so a
/// conversation reads the same in either. Which conversations a menu lists,
/// in what order, under which headings, which one is checked, and whether
/// the item opens a submenu stay with the menu.
enum ConversationMenuItem {
    @MainActor
    static func make(
        choice: ConversationChoice,
        isChecked: Bool,
        locale: Locale,
        perform: @escaping @MainActor () -> Void
    ) -> PopUpMenuItem {
        let name = ConversationText.name(choice, locale: locale)
        return PopUpMenuItem(
            verbatim: name,
            subtitle: ConversationText.menuLine(choice, locale: locale),
            isChecked: isChecked,
            help: ConversationText.help(choice, locale: locale),
            accessibilityLabel: name,
            accessibilityValue: ConversationText.value(choice, locale: locale),
            image: { AgentBadgeMenuImage.image(for: choice.conversation.provider, size: .row, in: .current) },
            perform: perform
        )
    }
}
