// ConversationText.swift
// Weir — a conversation in words, wherever one is named: its name, where it runs, when it last worked, and its counts.

import Foundation

/// The words for a conversation (`ConversationChoice`), apart from any one
/// surface: the changes panel's filter and row badges, the review tab's
/// scope menu and destination menu, and the tooltips name a conversation
/// the same way from here, and every list of conversations describes one
/// under its name with the same line (`detail`).
enum ConversationText {
    /// "1 unviewed", as the panel's head, the filter's menu, and the rail's
    /// tooltip count the turns waiting to be read. "Unviewed" is the
    /// opposite of "Mark as Viewed", the action that clears it; "unreviewed"
    /// read as whether the review had been opened.
    static func unviewed(_ count: Int, locale: Locale) -> String {
        LocalizedStringResource("\(count) unviewed", comment: "Changes panel: turns not marked viewed").resolved(in: locale)
    }

    /// A section of the filter's menu.
    static func section(_ section: ConversationChoice.Section, locale: Locale) -> String {
        let resource = switch section {
        case .running:
            LocalizedStringResource(
                "changes.filterRunning",
                defaultValue: "Running",
                comment: "Changes panel: the filter's section of conversations a pane of this worktree runs"
            )
        case .unviewed:
            LocalizedStringResource(
                "changes.filterUnviewed",
                defaultValue: "Unviewed",
                comment: "Changes panel: the filter's section of conversations with turns still to read"
            )
        case .viewed:
            LocalizedStringResource(
                "changes.filterViewed",
                defaultValue: "Viewed",
                comment: "Changes panel: the filter's section of conversations with every turn viewed"
            )
        }
        return resource.resolved(in: locale)
    }

    /// When a conversation last did something, as its detail line
    /// (`detail`) says it:
    /// the clock time on the day of `now`, else the date before it, as a
    /// list of conversations over several days needs.
    static func activityTime(_ date: Date, now: Date, locale: Locale, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        guard !calendar.isDate(date, inSameDayAs: now) else { return clock(date, locale: locale, timeZone: timeZone) }
        return date.formatted(Date.FormatStyle(locale: locale, timeZone: timeZone).month(.abbreviated).day().hour().minute())
    }

    /// A conversation's name, wherever one is named: its title ("Review the
    /// fork"), with its number where another conversation of its kind has
    /// the title too ("Fix tests #2"); else its kind, "Claude", or "Claude
    /// #2" beside another Claude conversation. The one source of the name,
    /// for the filter, the review's scope menu, destination menu and band,
    /// and the tooltips. The mark sets the place apart from the unviewed
    /// count beside it: "Claude 2 [2]" read as one number twice.
    static func name(_ choice: ConversationChoice, locale: Locale) -> String {
        name(choice.conversation.provider, title: choice.title, ordinal: choice.ordinal, locale: locale)
    }

    /// The same name from its kind, title and place: a review file tag's
    /// (`ReviewFileTag`), which keeps no more of its conversation.
    static func name(_ provider: AgentKind, title: String?, ordinal: Int?, locale: Locale) -> String {
        guard let title else { return kindName(provider, ordinal: ordinal, locale: locale) }
        guard let ordinal else { return title }
        return LocalizedStringResource(
            "changes.titleOrdinal",
            defaultValue: "\(title) #\(ordinal)",
            comment: "Changes panel: one of several conversations with the same title, as in Fix tests #2; arguments: the title, its place"
        ).resolved(in: locale)
    }

    /// The name as a menu shows it: the title cut to
    /// `SupervisionTruncation.menuNameLimit` characters, before its number,
    /// so two conversations of one long title still read apart by their
    /// number ("Fix the flaky snapshot tests in… #2"). The item's tooltip
    /// and VoiceOver say the whole name.
    static func menuName(_ choice: ConversationChoice, locale: Locale) -> String {
        name(
            choice.conversation.provider,
            title: choice.title.map(SupervisionTruncation.menuName),
            ordinal: choice.ordinal,
            locale: locale
        )
    }

    /// The name as VoiceOver says it: a title alone does not say which
    /// agent it is, which the badge beside it shows, so the kind goes
    /// first ("Claude, Review the fork"). A name of the kind already says
    /// it.
    static func spokenName(_ choice: ConversationChoice, locale: Locale) -> String {
        spokenName(choice.conversation.provider, title: choice.title, ordinal: choice.ordinal, locale: locale)
    }

    /// The same spoken name from its kind, title and place: a review file
    /// tag's (`ReviewFileTag`).
    static func spokenName(_ provider: AgentKind, title: String?, ordinal: Int?, locale: Locale) -> String {
        let name = name(provider, title: title, ordinal: ordinal, locale: locale)
        guard title != nil else { return name }
        let kind = SessionRowFactText.agentName(.agent(provider), locale: locale)
        return LocalizedStringResource(
            "changes.spokenName",
            defaultValue: "\(kind), \(name)",
            comment: "VoiceOver: a titled conversation after its agent, as in Claude, Review the fork; arguments: the agent, its name"
        ).resolved(in: locale)
    }

    /// "Claude", or "Claude #2" beside another conversation of the kind.
    private static func kindName(_ provider: AgentKind, ordinal: Int?, locale: Locale) -> String {
        let name = SessionRowFactText.agentName(.agent(provider), locale: locale)
        guard let ordinal else { return name }
        return LocalizedStringResource(
            "changes.agentOrdinal",
            defaultValue: "\(name) #\(ordinal)",
            comment: "Changes panel: one of several agents of a kind, as in Claude #2; arguments: the agent, its place among them"
        ).resolved(in: locale)
    }

    /// Where the conversation runs: "Running in the “claude” tab", naming
    /// the tab as the pane strip does; with its workspace where the tab is
    /// not in the session the panel reads ("Running in the “claude” tab in
    /// Scratch"); or "Ended" once no pane of the app runs it
    /// (`ChangesPanelModel.liveTabs`).
    static func state(_ choice: ConversationChoice, locale: Locale) -> String {
        guard let tab = choice.liveTab else {
            return LocalizedStringResource(
                "changes.agentEnded",
                defaultValue: "Ended",
                comment: "Changes panel: no pane of the app runs this conversation any more"
            ).resolved(in: locale)
        }
        // A tab with no title yet still runs it; we say so without a name.
        guard !tab.title.isEmpty else {
            return LocalizedStringResource(
                "changes.agentRunning",
                defaultValue: "Running",
                comment: "Changes panel: a pane runs this conversation, in a tab with no title yet"
            ).resolved(in: locale)
        }
        let title = tab.title
        // In the session, or in a worktree with no name left to say (its
        // project is gone): the tab alone.
        switch tab.isInSession ? nil : tab.checkoutPlace {
        case nil:
            return LocalizedStringResource(
                "Running in the “\(title)” tab",
                comment: "Changes panel: the tab whose pane runs this conversation; argument: the tab's title"
            ).resolved(in: locale)
        case .scratch:
            return LocalizedStringResource(
                "Running in the “\(title)” tab in Scratch",
                comment: "Changes panel: a scratch tab's pane runs this conversation; argument: the tab's title"
            ).resolved(in: locale)
        case let .named(placeName):
            return LocalizedStringResource(
                "Running in the “\(title)” tab in \(placeName)",
                comment: "Changes panel: another worktree's pane runs this conversation; arguments: the tab's title, the worktree's name"
            ).resolved(in: locale)
        }
    }

    /// A conversation's second line in the filter's menu, under its
    /// heading in the review's scope menu, and under its section's name in
    /// the changes panel's list grouped by conversation, the one source for
    /// every list of conversations: "Tab 3 · 9:06 PM · 3 unviewed", the
    /// tab that runs it as the pane strip counts the tabs, when it last did
    /// something, and its count with its unit. The name above it tells the
    /// conversation apart (`name`), so the line says where to find it. A tab
    /// outside the session is named with its workspace
    /// ("Running in the “claude” tab in beta"), as a place in the strip
    /// would point at another strip; an ended conversation leads with "No
    /// tab". A part with nothing to say is left out: no time before its
    /// first turn, and no count of 0: a missing count already says none
    /// waits. The tooltip keeps the whole.
    static func detail(
        _ choice: ConversationChoice,
        now: Date = Date(),
        locale: Locale,
        timeZone: TimeZone = .current
    ) -> String {
        AgentStatusText.joined(
            [
                detailTab(choice, locale: locale),
                choice.lastActivity.map { activityTime($0, now: now, locale: locale, timeZone: timeZone) },
                choice.unviewedCount == 0 ? nil : unviewed(choice.unviewedCount, locale: locale)
            ].compactMap(\.self),
            locale: locale
        )
    }

    /// The detail line's first part: the tab's place in the strip ("Tab 3");
    /// for a tab outside the session, where it runs (`state`); for an ended
    /// conversation, "No tab". `nil` for a tab of the session not yet given
    /// a place, which has none to say.
    private static func detailTab(_ choice: ConversationChoice, locale: Locale) -> String? {
        guard let tab = choice.liveTab else {
            return LocalizedStringResource(
                "changes.menuNoTab",
                defaultValue: "No tab",
                // swiftlint:disable:next line_length
                comment: "Changes panel and review: a conversation's detail line, in a menu or under a section heading, for one no tab runs any more, before its time and count"
            ).resolved(in: locale)
        }
        guard tab.isInSession else { return state(choice, locale: locale) }
        return tab.position.map { position in
            LocalizedStringResource(
                "changes.menuTab",
                defaultValue: "Tab \(position)",
                // swiftlint:disable:next line_length
                comment: "Changes panel and review: a conversation's detail line, in a menu or under a section heading: the tab that runs it, as the pane strip counts the tabs"
            ).resolved(in: locale)
        }
    }

    /// A conversation's tooltip: "Claude #2 · 2 unviewed · Running in
    /// the “claude” tab", counted as the rail's tooltip counts.
    static func help(_ choice: ConversationChoice, locale: Locale) -> String {
        AgentStatusText.joined(
            [name(choice, locale: locale), unviewed(choice.unviewedCount, locale: locale), state(choice, locale: locale)],
            locale: locale
        )
    }

    /// The tooltip's facts as VoiceOver reads them where they are its
    /// label (the review's scope menu heading), led by the spoken name, so
    /// a titled conversation says its agent.
    static func spokenHelp(_ choice: ConversationChoice, locale: Locale) -> String {
        AgentStatusText.joined(
            [spokenName(choice, locale: locale), unviewed(choice.unviewedCount, locale: locale), state(choice, locale: locale)],
            locale: locale
        )
    }

    /// What VoiceOver reads after an agent's name: its latest prompt in
    /// full, when it last did something, its unviewed turns, and where it
    /// runs or that it ended. The detail line's facts, with nothing cut,
    /// and the latest prompt.
    static func value(
        _ choice: ConversationChoice,
        now: Date = Date(),
        locale: Locale,
        timeZone: TimeZone = .current
    ) -> String {
        AgentStatusText.spokenList(
            [
                choice.latestPrompt.flatMap { TurnPromptText.instruction($0, locale: locale) },
                choice.lastActivity.map { activityTime($0, now: now, locale: locale, timeZone: timeZone) },
                unviewedTurns(choice.unviewedCount, locale: locale),
                state(choice, locale: locale)
            ].compactMap(\.self),
            locale: locale
        )
    }

    /// What VoiceOver reads after a section heading's name in the list
    /// grouped by conversation: whether the section is collapsed, then the
    /// facts a menu item of the conversation reads (`value`). In the value
    /// rather than the hint, which VoiceOver can be set not to read and
    /// heading navigation skips, so the unviewed count and where the
    /// conversation runs are always said, as each of its cards says its own.
    static func sectionValue(
        _ choice: ConversationChoice,
        isCollapsed: Bool,
        now: Date = Date(),
        locale: Locale,
        timeZone: TimeZone = .current
    ) -> String {
        AgentStatusText.spokenList(
            [
                (isCollapsed ? LocalizedStringResource("Collapsed") : LocalizedStringResource("Expanded")).resolved(in: locale),
                value(choice, now: now, locale: locale, timeZone: timeZone)
            ],
            locale: locale
        )
    }

    /// A count of unviewed turns, as VoiceOver reads a badge of one.
    static func unviewedTurns(_ count: Int, locale: Locale) -> String {
        LocalizedStringResource("\(count) unviewed turns", comment: "VoiceOver: a count of turns not marked viewed").resolved(in: locale)
    }

    /// A clock time, "10:31", as a conversation's detail line and a turn's
    /// row say it.
    static func clock(_ date: Date, locale: Locale, timeZone: TimeZone) -> String {
        var style = Date.FormatStyle(date: .omitted, time: .shortened).locale(locale)
        style.timeZone = timeZone
        return date.formatted(style)
    }
}
