// PaneStripModel.swift
// Limpid — the pane strip's tabs: their titles and marks, in the session's order.

import Foundation

/// What waits on the person in a pane, for the pane's frame. A
/// turn's "unread" is not one: it is not urgent.
enum PaneAttention: Equatable {
    case needsAnswer
    /// An approval, or a wait at the agent's prompt its record says is one
    /// (or, for an older record, in a tool's words).
    case needsApproval
    /// A wait at the agent's prompt we cannot name as an approval or a
    /// question; it ranks with approvals.
    case needsResponse
    case stopped

    /// The one that ranks first among `items`, in the app's one order.
    static func of(_ items: [AttentionItem]) -> PaneAttention? {
        switch PanePriority.dominant(items)?.kind {
        case .question, .prompt(.question): .needsAnswer
        case .approval, .prompt(.approval): .needsApproval
        case .prompt(.unclassified): .needsResponse
        case .stop: .stopped
        case .unread, nil: nil
        }
    }

    /// Both waits are amber; only a stop is red.
    var isWaiting: Bool {
        self != .stopped
    }
}

extension PaneStripModel.Item {
    /// The tab's tooltip: its title, who runs in it with the state
    /// its glyph shows ("Claude · Running"), and, in tmux, that the session
    /// outlives Limpid; one to a line.
    func tooltip(locale: Locale) -> String {
        var lines = [title, agentLine(locale: locale)]
        if isInTmux {
            lines.append(LocalizedStringResource("Running in tmux — the session survives quitting Limpid").resolved(in: locale))
        }
        return lines.joined(separator: "\n")
    }

    /// Returns the failed exit's mark after the title ("exit 1", "終了コード 1"),
    /// in the notification history's words for the same status. It is `nil`
    /// while every pane runs or exited cleanly.
    func exitMark(locale: Locale) -> String? {
        failedExitCode.map { NotificationHistoryRowText.exitCodeText(Int($0), locale: locale) }
    }

    /// Who runs in the tab, then the state its glyph shows, as the tooltip
    /// and VoiceOver say it ("Claude · Running").
    func agentLine(locale: Locale) -> String {
        let name = SessionRowFactText.agentName(agent.map { .agent($0) } ?? .shell, locale: locale)
        guard let stateGlyph else { return name }
        return AgentStatusText.joined([name, SessionRowFactText.stateName(stateGlyph, locale: locale)], locale: locale)
    }

    /// What VoiceOver says for the tab, in the strip and in Open Tabs:
    /// the title, who runs in it (the badge's letters in words) with the
    /// state its glyph shows ("Claude, Running"), then what the marks say,
    /// since a glyph, a dot, and a color are not words.
    func spokenLabel(locale: Locale) -> String {
        var parts = [title, AgentStatusText.spoken(agentLine(locale: locale), locale: locale)]
        if let code = failedExitCode {
            parts.append(LocalizedStringResource("Process exited (code \(code))").resolved(in: locale))
        }
        if hasUnread {
            parts.append(LocalizedStringResource("Unread notifications").resolved(in: locale))
        }
        if isInTmux {
            parts.append(LocalizedStringResource("Running in tmux").resolved(in: locale))
        }
        return AgentStatusText.spokenList(parts, locale: locale)
    }
}

/// The strip under the session header: a tab for each of the
/// session's tabs in its order, the review's tab while one is open, and
/// the "+" that adds a tab. ⌘1…9 and ⇧⌘[ ⇧⌘] walk the same order.
struct PaneStripModel: Equatable {
    struct Item: Identifiable, Equatable {
        let id: UUID
        let title: String
        /// The tab's color (`Tab.paletteIndex`), drawn as a mark at its
        /// leading edge; `nil` for a tab without one.
        let paletteIndex: Int?
        let isActive: Bool
        /// The agent with a session in one of the tab's panes, whose badge
        /// the tab wears; `nil` for a shell.
        let agent: AgentKind?
        /// The state the tab shows before its badge: what ranks first among
        /// its panes (`PaneStripModel.tabGlyph`); `nil` for a tab with
        /// nothing running or waiting.
        let stateGlyph: SessionRowFact.Glyph?
        /// A finished command, a notification (OSC 9/777), or a bell since
        /// the tab was last shown: a dot, which stays until the tab is
        /// shown. Not a turn's unread, which is a ring in another color.
        let hasUnread: Bool
        let isInTmux: Bool
        /// The exit code of a pane whose process failed; `nil` while every
        /// pane runs or exited cleanly.
        let failedExitCode: UInt32?
        /// How many panes the tab is split into. The strip does not show
        /// it; Open Tabs says it for a split tab ("Shell · 2 panes").
        let paneCount: Int
        /// The conversation the tab's title stands for: the one in
        /// `Tab.latestAgentSessionPaneID`'s pane, or with none, the tab's one
        /// conversation (`ConversationTabs`). Optional because a
        /// shell's tab runs none, and a scratch tab's has no worktree whose
        /// cards it could be matched with.
        var conversation: ConversationKey?
        /// That conversation's identity color, as the changes panel hands
        /// it out (`ConversationIdentityStore`), so the tab and the
        /// conversation's cards can be matched. Optional because a
        /// worktree with one active conversation shows none, and a scratch
        /// tab has no worktree to hand one out in.
        var identity: Int?
        /// Every conversation the tab's panes run that holds an identity
        /// color, with it (`ConversationTabs.TabConversations.all`): a card
        /// of any of them outlines the tab, in that conversation's color,
        /// so a split tab answers for its second pane too.
        var runningIdentities: [ConversationKey: Int] = [:]

        /// Where the tab's title is cut: a name's end, but a path's start,
        /// as a shell's OSC 2 title for its folder is ("…/projects/alpha").
        /// Three shells in one project differ only at the end, which a cut
        /// at the tail would leave as one "…/projects/al…".
        var titleTruncation: SupervisionTruncation {
            .title(title)
        }
    }

    /// What one tab is read from.
    struct ItemInput {
        let id: UUID
        let title: String
        var paletteIndex: Int?
        let agent: AgentKind?
        /// Each pane's header mark (`PaneHeaderRules.mark`), for the panes
        /// that have one.
        var paneGlyphs: [SessionRowFact.Glyph] = []
        /// The attention items of the tab's panes, which rank its waits
        /// and stops against each other (`tabGlyph`).
        var paneItems: [AttentionItem] = []
        let hasUnread: Bool
        let isInTmux: Bool
        /// Each exited pane's code, in the tab's pane order.
        let exitCodes: [UInt32]
        /// How many panes the tab is split into; one for a tab read without
        /// its split.
        var paneCount = 1
        /// The conversation the tab's title stands for, and its color.
        var conversation: ConversationKey?
        var identity: Int?
        /// Each conversation the tab runs that holds a color, with it.
        var runningIdentities: [ConversationKey: Int] = [:]
    }

    /// Whether the window has a review tab, and whether it is the one in
    /// front.
    enum ReviewTab: Equatable, Sendable {
        case none
        /// Open, behind the terminal tab the person moved to (⇧⌘[ ⇧⌘]).
        case behind
        /// In front: the review stands where the terminal was, so it is the
        /// selected tab.
        case inFront
    }

    let items: [Item]
    /// The review's tab, before the "+".
    let reviewTab: ReviewTab

    var showsReviewTab: Bool {
        reviewTab != .none
    }

    init(items inputs: [ItemInput], activeTabID: UUID?, reviewTab: ReviewTab) {
        items = inputs.map { input in
            Item(
                id: input.id,
                title: input.title,
                paletteIndex: input.paletteIndex,
                isActive: input.id == activeTabID && reviewTab != .inFront,
                agent: input.agent,
                stateGlyph: Self.tabGlyph(input.paneGlyphs, items: input.paneItems),
                hasUnread: input.hasUnread,
                isInTmux: input.isInTmux,
                failedExitCode: input.exitCodes.first { $0 != 0 },
                paneCount: input.paneCount,
                conversation: input.conversation,
                identity: input.identity,
                runningIdentities: input.runningIdentities
            )
        }
        self.reviewTab = reviewTab
    }

    /// The glyph a tab shows: of its panes' waits and stops, the one the
    /// app's one order puts first (`PanePriority`), as the sidebar's row
    /// and each pane's header rank them, so a split tab and its row never
    /// disagree. Among equals, an approval and a wait for a response, the
    /// one that arrived first. With none, a run in any pane, else work an
    /// agent left running after its turn in any pane. A turn's unread is
    /// not shown on a tab, so the work after an unread turn shows as the
    /// work alone, and a tab at rest or with only shells shows nothing.
    static func tabGlyph(_ paneGlyphs: [SessionRowFact.Glyph], items: [AttentionItem]) -> SessionRowFact.Glyph? {
        let shown = items.filter { item in
            guard case .unread = item.kind else { return true }
            return false
        }
        if let item = PanePriority.dominant(shown) {
            return SessionRowFact.glyph(of: item.kind)
        }
        if paneGlyphs.contains(.running) {
            return .running
        }
        return paneGlyphs.contains { $0 == .workingAfterTurn || $0 == .unreadWorkingAfterTurn } ? .workingAfterTurn : nil
    }
}

/// The rule under the pane strip, stopping under the selected tab so
/// the tab opens onto the terminal below it, as a folder tab does.
enum PaneStripRuleLayout {
    /// Where the rule stops, from the strip's leading edge, in the strip's
    /// own space; `nil` when it runs whole. `gap` is the selected tab's
    /// frame; `visible` is what of the strip the tab can be seen in (the
    /// scrolling tabs' view), `nil` for a tab that never scrolls, which is
    /// then taken to lie inside the strip: only its leading edge is held
    /// at 0, and an end past the strip's runs off its trailing side
    /// (`PaneStripRule`). The rule
    /// stops at the tab's outer edge, where its sides start, which run on
    /// to the bottom and so turn the corner square, with no line drawn
    /// twice; and it stops only where the tab can be seen: a tab scrolled
    /// out of view leaves the rule whole, rather than cutting it under "+".
    /// `lineWidth` is the sides' width: a tab narrower than its two sides
    /// opens nothing.
    ///
    /// Only the opening, not the stretches on either side of it: the rule
    /// is drawn as a stretch up to the opening and one after it that fills
    /// the rest of the strip (`PaneStripRule`), so while the strip widens
    /// or narrows with a surface sliding in, the rule runs to the strip's
    /// edge wherever the edge is drawn, rather than to where it will end.
    static func opening(
        gap: CGRect?,
        visible: ClosedRange<CGFloat>?,
        lineWidth: CGFloat
    ) -> ClosedRange<CGFloat>? {
        guard let gap, gap.width > 2 * lineWidth else { return nil }
        var start = max(gap.minX, 0)
        var end = gap.maxX
        if let visible {
            start = max(start, visible.lowerBound)
            end = min(end, visible.upperBound)
        }
        guard start < end else { return nil }
        return start...end
    }
}
