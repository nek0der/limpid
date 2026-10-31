// ChangesPanelModel+Naming.swift
// Weir — the changes panel's conversations: which hold a color, which tab runs each, and each one's name.

import Foundation

extension ChangesPanelModel {
    /// The conversations that hold an identity color: those running in a
    /// pane of the session and those with turns still to read, in the
    /// agents' order (`agents(history:running:root:isRoot:)`), the order
    /// they were created in. A conversation that ended with every turn
    /// viewed has nothing left to match against a tab or a card, and gives
    /// its color back.
    static func activeConversations(_ input: Input) -> [ConversationKey] {
        let counts = unviewedCounts(input)
        let running = Set(input.running)
        var seen: Set<ConversationKey> = []
        var active: [ConversationKey] = []
        for agent in input.agents where seen.insert(agent.conversation).inserted {
            if running.contains(agent.conversation) || counts[agent.conversation, default: 0] > 0 {
                active.append(agent.conversation)
            }
        }
        return active
    }

    /// A pane of the app, as `liveTabs` reads it: the conversation its
    /// agent runs, if any, and the tab it is in.
    struct LivePane: Equatable, Sendable {
        let conversation: ConversationKey?
        let tab: ConversationChoice.LiveTab
    }

    /// The tab that runs each conversation, from every pane of the
    /// app in its tabs' order: the session's own panes first, so a
    /// conversation run both here and in another workspace (a scratch tab)
    /// is named by the tab beside the panel; within those, the first pane
    /// in the tabs' order, for a conversation run in two. A conversation no
    /// pane of the app runs has none, and only that one reads as ended.
    static func liveTabs(_ panes: [LivePane]) -> [ConversationKey: ConversationChoice.LiveTab] {
        var tabs: [ConversationKey: ConversationChoice.LiveTab] = [:]
        for pane in panes.filter(\.tab.isInSession) + panes.filter({ !$0.tab.isInSession }) {
            guard let conversation = pane.conversation, tabs[conversation] == nil else { continue }
            tabs[conversation] = pane.tab
        }
        return tabs
    }

    /// The filter's entries, each named by its title
    /// (`ConversationTitleRule`). Numbered among every conversation of the
    /// kind in the worktree, so a conversation keeps its number ("Claude
    /// #2") as others come and go. The number is said only where the name
    /// does not tell two apart: an untitled one beside another offered
    /// conversation of its kind, or a titled one whose title another
    /// conversation of its kind in the worktree has too. The cards and the
    /// file tags tell conversations apart by their identity colors instead.
    static func choices(
        _ offered: [Agent],
        among agents: [Agent],
        input: Input,
        unviewed: [ConversationKey: Int]
    ) -> [ConversationChoice] {
        var ordinals: [ConversationKey: Int] = [:]
        var counts: [AgentKind: Int] = [:]
        var titles: [ConversationKey: String] = [:]
        struct Title: Hashable {
            let provider: AgentKind
            let title: String
        }
        var titleCounts: [Title: Int] = [:]
        // Each agent's tab looked up once, for its title here and for its
        // entry below: the lookup reads the app's panes. `offered` is among
        // `agents`, so every offered agent's is here.
        var liveTabs: [ConversationKey: ConversationChoice.LiveTab] = [:]
        for agent in agents {
            counts[agent.conversation.provider, default: 0] += 1
            ordinals[agent.conversation] = counts[agent.conversation.provider]
            let liveTab = input.liveTab(agent.conversation)
            liveTabs[agent.conversation] = liveTab
            if let title = title(of: agent, liveTab: liveTab, rememberedTabName: input.tabName(agent.conversation)) {
                titles[agent.conversation] = title
                titleCounts[Title(provider: agent.conversation.provider, title: title), default: 0] += 1
            }
        }
        var offeredCounts: [AgentKind: Int] = [:]
        for agent in offered {
            offeredCounts[agent.conversation.provider, default: 0] += 1
        }
        return offered.map { agent in
            let latest = listed(agent.turns).max { (lastActivity(of: $0) ?? .distantPast) < (lastActivity(of: $1) ?? .distantPast) }
            let liveTab = liveTabs[agent.conversation]
            let provider = agent.conversation.provider
            let title = titles[agent.conversation]
            let hasAnotherOfItsKind = offeredCounts[provider, default: 0] > 1
            let isNumbered = if let title {
                titleCounts[Title(provider: provider, title: title), default: 0] > 1
            } else {
                hasAnotherOfItsKind
            }
            return ConversationChoice(
                conversation: agent.conversation,
                title: title,
                ordinal: isNumbered ? ordinals[agent.conversation] : nil,
                unviewedCount: unviewed[agent.conversation, default: 0],
                liveTab: liveTab,
                latestPrompt: latest?.prompt,
                lastActivity: latest.flatMap(lastActivity),
                identity: input.identities[agent.conversation]
            )
        }
    }

    /// A conversation's title: the name the person gave the tab that runs
    /// it, else one they gave a tab it ran in, else the provider's live
    /// title, else what its newest turn recorded, else its first prompt
    /// (`ConversationTitleRule`).
    static func title(of agent: Agent, liveTab: ConversationChoice.LiveTab?, rememberedTabName: String?) -> String? {
        ConversationTitleRule.title(
            tabName: liveTab?.titleOverride,
            rememberedTabName: rememberedTabName,
            liveTitle: liveTab?.providerTitle,
            // The newest that has one: a record written before the
            // provider named the conversation has none, and does not
            // unname it.
            recordedTitle: agent.turns.last { $0.conversationTitle != nil }?.conversationTitle,
            firstPrompt: listed(agent.turns).first?.prompt
        )
    }

    /// When a turn last did something: its end, or its start while it runs.
    static func lastActivity(of turn: TurnSummary) -> Date? {
        UnreadTurnRules.date(turn.finishedAt) ?? WorktreeTimeline.startDate(turn)
    }

    // MARK: - Every conversation, named

    /// Every conversation of the worktree, named as the panel's filter and
    /// rows name them (its title, or "Claude #2"), with its unviewed turns
    /// and the tab that runs it: the review tab's scope menu heads a section
    /// with each, and its destination menu names a pane after the
    /// conversation it runs. Numbered among every conversation of the kind,
    /// so a conversation keeps its number as others come and go.
    static func conversations(_ input: Input) -> [ConversationChoice] {
        choices(input.agents, among: input.agents, input: input, unviewed: unviewedCounts(input))
    }

    /// What the rail's button says: the session's turns waiting to be
    /// read, every agent's together, for its badge, and for its tooltip's
    /// breakdown the conversations with some to read, named as the panel
    /// names them, while there are two or more to tell apart. Each agent's
    /// turns are counted once, for both.
    static func rail(_ input: Input) -> (unviewed: Int, agents: [ConversationChoice]) {
        let counts = unviewedCounts(input)
        let unviewed = counts.values.reduce(0, +)
        let waiting = input.agents.filter { counts[$0.conversation, default: 0] > 0 }
        guard unviewed > 0, waiting.count > 1 else { return (unviewed, []) }
        return (unviewed, choices(waiting, among: input.agents, input: input, unviewed: counts))
    }
}
