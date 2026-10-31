// ConversationMenuItem.swift
// Weir — one conversation as a pop-up menu item: its badge, its name, and its line.

import AppKit

/// This makes a conversation an item of an AppKit pop-up menu: its identity
/// bar where it has one and the agent's badge, drawn as one image,
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
        PopUpMenuItem(
            // Cut, as a menu is as wide as its widest item; the tooltip
            // and VoiceOver say the whole name.
            verbatim: ConversationText.menuName(choice, locale: locale),
            subtitle: ConversationText.detail(choice, locale: locale),
            isChecked: isChecked,
            help: ConversationText.help(choice, locale: locale),
            accessibilityLabel: ConversationText.spokenName(choice, locale: locale),
            accessibilityValue: ConversationText.value(choice, locale: locale),
            image: {
                AgentBadgeMenuImage.image(for: choice.conversation.provider, size: .row, identity: choice.identity, in: .current)
            },
            perform: perform
        )
    }
}
