// ConversationText.swift
// Limpid — a conversation in words, wherever one is named: its name, where it runs, its menu line, and its counts.

import Foundation

/// The words for a conversation (`ConversationChoice`), apart from any one
/// surface: the changes panel's filter and row badges, the review tab's
/// scope menu and destination menu, and the tooltips name a conversation
/// the same way, and none of them reads another surface's words to do it.
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

    /// A conversation's second line in the filter's menu and under its
    /// heading in the review's scope menu: "Save the order setti… ·
    /// 10:31 · 4 unviewed", what its latest turn was asked, when it last
    /// did something, and its count with its unit, so fourteen conversations
    /// named "Claude #1" to "Claude #14" read apart by what each was for.
    /// Where it runs follows only while a pane elsewhere runs it ("Running
    /// in the “claude” tab in beta"). One this session runs is under
    /// "Running", whose heading says so, and its tab, named after its
    /// first prompt, is left out too: said on the line, it widened the
    /// whole menu. An ended one says nothing more either,
    /// as its section already says it is not running. The tooltip keeps
    /// the whole. A count of 0 is left out, as the heading or the absence
    /// of a count says it.
    static func menuLine(
        _ choice: ConversationChoice,
        now: Date = Date(),
        locale: Locale,
        timeZone: TimeZone = .current
    ) -> String {
        AgentStatusText.joined(
            [
                choice.latestPrompt.flatMap { TurnPromptText.shortInstruction($0, characters: promptCharacters, locale: locale) },
                choice.lastActivity.map { activityTime($0, now: now, locale: locale, timeZone: timeZone) },
                choice.section == .viewed || choice.unviewedCount == 0 ? nil : unviewed(choice.unviewedCount, locale: locale),
                choice.liveTab == nil || choice.isRunningHere ? nil : state(choice, locale: locale)
            ].compactMap(\.self),
            locale: locale
        )
    }

    /// How much of a conversation's latest prompt its menu line shows, as
    /// much as the review's scope choices show of a turn's.
    static let promptCharacters = ReviewTabText.promptCharacters

    /// When a conversation last did something, as its menu line says it:
    /// the clock time on the day of `now`, else the date before it, as a
    /// list of conversations over several days needs.
    static func activityTime(_ date: Date, now: Date, locale: Locale, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        guard !calendar.isDate(date, inSameDayAs: now) else { return clock(date, locale: locale, timeZone: timeZone) }
        return date.formatted(Date.FormatStyle(locale: locale, timeZone: timeZone).month(.abbreviated).day().hour().minute())
    }

    /// A conversation's name, wherever one is named: "Claude", or
    /// "Claude #2" beside another Claude conversation. The one source of
    /// the name, for the filter, the review's scope menu, destination menu and band,
    /// and the tooltips. The mark sets the place apart from the unviewed
    /// count beside it: "Claude 2 [2]" read as one number twice.
    static func name(_ choice: ConversationChoice, locale: Locale) -> String {
        name(choice.conversation.provider, ordinal: choice.ordinal, locale: locale)
    }

    /// The same name from its kind and place: a review file tag's
    /// (`ReviewFileTag`), which keeps no more of its conversation.
    static func name(_ provider: AgentKind, ordinal: Int?, locale: Locale) -> String {
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

    /// A conversation's tooltip: "Claude #2 · 2 unviewed · Running in
    /// the “claude” tab", counted as the rail's tooltip counts.
    static func help(_ choice: ConversationChoice, locale: Locale) -> String {
        AgentStatusText.joined(
            [name(choice, locale: locale), unviewed(choice.unviewedCount, locale: locale), state(choice, locale: locale)],
            locale: locale
        )
    }

    /// What VoiceOver reads after an agent's name: its latest prompt in
    /// full, when it last did something, its unviewed turns, and where it
    /// runs or that it ended, the menu line's facts with nothing cut.
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

    /// A count of unviewed turns, as VoiceOver reads a badge of one.
    static func unviewedTurns(_ count: Int, locale: Locale) -> String {
        LocalizedStringResource("\(count) unviewed turns", comment: "VoiceOver: a count of turns not marked viewed").resolved(in: locale)
    }

    /// A clock time, "10:31", as a conversation's menu line and a turn's
    /// row say it.
    static func clock(_ date: Date, locale: Locale, timeZone: TimeZone) -> String {
        var style = Date.FormatStyle(date: .omitted, time: .shortened).locale(locale)
        style.timeZone = timeZone
        return date.formatted(style)
    }
}
