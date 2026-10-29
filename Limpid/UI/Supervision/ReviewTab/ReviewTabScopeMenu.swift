// ReviewTabScopeMenu.swift
// Limpid — "Review Scope": the one menu that chooses what the review tab reads, and whose turns.

import AppKit
import SwiftUI

/// "Review Scope": the menu that chooses what the tab reads, the
/// conversation with it. It lists the worktree's unviewed turns, then each
/// conversation's under a heading with its badge, name, and state, then the
/// uncommitted changes and the branch (`ReviewScopeMenu`), and holds no
/// turn rows, line, or receipts: the changes panel has those. An AppKit
/// menu (`PopUpMenuButton`), whose items carry a second line and whose
/// headings carry the badge.
struct ReviewTabScopeMenu: View {
    let tab: ReviewTabState
    let handler: ReviewTabHandler
    var isEnabled = true
    @Environment(\.locale) private var locale

    var body: some View {
        let context = handler.context(tab)
        let menu = ReviewScopeMenu.make(tab, context)
        let selection = ReviewTabModel.shown(tab.selection, context)
        ReviewTabScopePicker(
            current: ReviewTabText.option(selection, counts: menu.counts(of: selection), locale: locale),
            spoken: ReviewTabText.scope(
                selection, conversation: menu.labelConversation, counts: menu.counts(of: selection), locale: locale
            ),
            conversation: menu.labelConversation,
            isEnabled: isEnabled
        ) {
            entries(menu)
        }
    }

    /// The worktree's unviewed turns under their heading; each listed
    /// conversation under its own, its unviewed turns and then its single
    /// turns in a submenu; the rest with turns to read, then the viewed
    /// ones, each folded into one entry under a heading; then what no
    /// conversation owns. A worktree of one conversation lists its choices
    /// as they are, with no headings.
    private func entries(_ menu: ReviewScopeMenu) -> [PopUpMenuEntry] {
        var entries: [PopUpMenuEntry] = []
        if let worktree = menu.worktree {
            entries.append(.header(ReviewTabText.worktreeHeading(locale: locale)))
            let viewed = ReviewTabText.includesViewedTurns(menu.worktreeCounts?.viewedTurns ?? 0, locale: locale)
            entries.append(.item(item(worktree, counts: menu.worktreeCounts, subtitle: viewed)))
        }
        for section in menu.sections {
            guard let agent = section.conversation else {
                entries += section.choices.map { .item(item($0)) }
                continue
            }
            entries.append(.heading(heading(agent)))
            if let lead = section.lead {
                entries.append(.item(item(lead, of: agent)))
            }
            if let turns = turnsSubmenu(section.turns, of: agent) {
                entries.append(turns)
            }
        }
        folded(menu.more, under: ReviewTabText.moreConversationsHeading(locale: locale), into: &entries)
        folded(menu.folded, under: ConversationText.section(.viewed, locale: locale), into: &entries)
        if !entries.isEmpty, !menu.tail.isEmpty {
            entries.append(.separator)
        }
        entries += menu.tail.map { .item(item($0)) }
        return entries
    }

    /// "Turns ▸": a conversation's single turns, newest first, in a
    /// submenu, checked while the tab reads one of them. `nil` for none.
    private func turnsSubmenu(_ turns: [ReviewScopeMenu.Choice], of agent: ConversationChoice) -> PopUpMenuEntry? {
        guard !turns.isEmpty else { return nil }
        let title = ReviewTabText.turnsSubmenu(locale: locale)
        let opener = PopUpMenuItem(
            verbatim: title,
            isChecked: turns.contains(where: \.isChecked),
            accessibilityLabel: ReviewTabText.conversationsChoice(title, conversation: agent, locale: locale)
        ) {}
        return .submenu(opener, turns.map { .item(item($0, of: agent)) })
    }

    /// `sections` under `heading`, each one entry with the conversation's
    /// badge, name, and line, opening its choices: its unviewed turns, then
    /// its single turns.
    private func folded(_ sections: [ReviewScopeMenu.Section], under heading: String, into entries: inout [PopUpMenuEntry]) {
        guard !sections.isEmpty else { return }
        let locale = locale
        entries.append(.header(heading))
        for section in sections {
            guard let agent = section.conversation else { continue }
            let opener = ConversationMenuItem.make(
                choice: agent,
                isChecked: section.choices.contains(where: \.isChecked),
                locale: locale,
                perform: {}
            )
            entries.append(.submenu(opener, section.choices.map { .item(item($0, of: agent)) }))
        }
    }

    /// One choice, with the menu's checkmark on the one the tab reads.
    /// Under a conversation's heading VoiceOver hears the conversation with
    /// it ("Claude #4: T6 · …"), as the heading is not read with each item.
    private func item(
        _ choice: ReviewScopeMenu.Choice,
        of conversation: ConversationChoice? = nil,
        counts: ReviewScopeCatalog.RangeCounts? = nil,
        subtitle: String? = nil
    ) -> PopUpMenuItem {
        let text = ReviewTabText.option(choice.option, counts: counts, locale: locale)
        return PopUpMenuItem(
            verbatim: text,
            subtitle: subtitle,
            isChecked: choice.isChecked,
            help: subtitle,
            accessibilityLabel: conversation.map { ReviewTabText.scope(choice.option, conversation: $0, locale: locale) },
            accessibilityValue: subtitle
        ) { [handler] in
            handler.select(choice.option, choice.conversation)
        }
    }

    /// A conversation's heading: its identity bar where it has one and its
    /// badge, its name cut as a menu cuts it, and under it the line the
    /// changes panel's filter gives each conversation
    /// (`ConversationText.detail`). VoiceOver reads the whole name with its
    /// agent.
    private func heading(_ agent: ConversationChoice) -> PopUpMenuHeading {
        let locale = locale
        return PopUpMenuHeading(
            title: ConversationText.menuName(agent, locale: locale),
            subtitle: ConversationText.detail(agent, locale: locale),
            image: { AgentBadgeMenuImage.image(for: agent.conversation.provider, size: .row, identity: agent.identity, in: .current) },
            accessibilityLabel: ConversationText.spokenHelp(agent, locale: locale)
        )
    }
}

/// "Review Scope" and its menu, apart from what the menu lists. The label
/// names the choice, and, for a choice of one conversation's turns in a
/// worktree of two or more, the conversation's badge and name before it.
/// Whole while the line has room; in a narrow column the label gives way
/// first, its choice cut at its end, so the line's trailing controls (the
/// comment preview, Refresh) stay inside the column. "Review Scope" itself
/// stays whole.
struct ReviewTabScopePicker: View {
    /// The scope shown, as the menu names it.
    let current: String
    /// The scope with its conversation, as VoiceOver and the tooltip say it.
    var spoken: String?
    /// The conversation the label names, `nil` for none.
    var conversation: ConversationChoice?
    var isEnabled = true
    let entries: () -> [PopUpMenuEntry]
    @Environment(\.locale) private var locale

    private typealias Layout = LimpidLayout.Supervision

    init(
        current: String,
        spoken: String? = nil,
        conversation: ConversationChoice? = nil,
        isEnabled: Bool = true,
        entries: @escaping () -> [PopUpMenuEntry]
    ) {
        self.current = current
        self.spoken = spoken
        self.conversation = conversation
        self.isEnabled = isEnabled
        self.entries = entries
    }

    /// Whole, then the choice cut at its end, then, narrower still, the
    /// conversation by its badge alone, its name kept in the tooltip and
    /// in what VoiceOver reads.
    var body: some View {
        ViewThatFits(in: .horizontal) {
            line { menu(showsName: true).fixedSize() }
                .fixedSize()
            line { menu(showsName: true) }
            line { menu(showsName: false) }
        }
    }

    private func line(@ViewBuilder menu: () -> some View) -> some View {
        HStack(spacing: Layout.reviewTabScopeLabelSpacing) {
            // The menu's name on screen as well as for VoiceOver, which
            // reads it from the menu's own trigger.
            Text("Review Scope")
                .font(.supervision(.row))
                .foregroundStyle(SupervisionTokens.muted.color)
                .fixedSize()
                .accessibilityHidden(true)
            menu()
        }
    }

    private func menu(showsName: Bool) -> some View {
        let said = spoken ?? current
        return PopUpMenuButton(
            verbatim: LocalizedStringResource("Review Scope").resolved(in: locale),
            help: said,
            value: said
        ) {
            entries()
        } label: {
            BorderedMenuTriggerLabel {
                if let conversation {
                    let badge = SessionRowFact.Badge.agent(conversation.conversation.provider)
                    ConversationIdentityLead(identity: conversation.identity) {
                        SessionAgentBadge(badge: badge, text: SessionRowFactText.badge(badge, locale: locale), size: .regular)
                    }
                    if showsName {
                        Text(verbatim: ConversationText.name(conversation, locale: locale))
                            .font(.supervision(.row, weight: .semibold))
                            .foregroundStyle(SupervisionTokens.text.color)
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
                Text(verbatim: current)
                    .font(.supervision(.row))
                    .foregroundStyle(SupervisionTokens.text.color)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .disabled(!isEnabled)
    }
}
