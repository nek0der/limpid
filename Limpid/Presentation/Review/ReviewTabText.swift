// ReviewTabText.swift
// Limpid — the review tab in words: its title, the scope choices, its bar, and the turns it offers to add.

import Foundation

/// The review tab's words, apart from the rules that choose them.
enum ReviewTabText {
    /// How much of a prompt a turn's choice shows.
    static let promptCharacters = 18

    /// "Unviewed Turns": the tab's label in the pane strip, the scope's name
    /// without what its parentheses add. The eye before it says the
    /// tab is the review, so the word "Review" is left to `title`: in a
    /// strip short of room it took the half of the label that named the
    /// scope.
    static func tabName(_ selection: ReviewScopeOption, locale: Locale) -> String {
        switch selection {
        case .unviewedTurns, .worktreeUnviewedTurns:
            LocalizedStringResource("Unviewed Turns", comment: "Review scope: the turns below the viewed line, as the tab names them")
                .resolved(in: locale)
        case .uncommitted:
            uncommitted(locale: locale)
        default:
            option(selection, locale: locale)
        }
    }

    /// "Review · Unviewed Turns": the tab's whole name, as its tooltip
    /// gives it and VoiceOver reads it.
    static func title(_ selection: ReviewScopeOption, locale: Locale) -> String {
        let name = tabName(selection, locale: locale)
        return LocalizedStringResource("Review · \(name)", comment: "Review tab: the tab's label, with the scope it reads")
            .resolved(in: locale)
    }

    /// One choice of "Review Scope", as the dropdown lists it. `counts`
    /// are the worktree's range's (`ReviewScopeCatalog.counts`), which its
    /// entry says; without them it is named alone.
    static func option(_ option: ReviewScopeOption, counts: ReviewScopeCatalog.RangeCounts? = nil, locale: Locale) -> String {
        switch option {
        case .unviewedTurns(.none):
            LocalizedStringResource("Unviewed Turns (None)", comment: "Review scope: the unviewed turns, when every turn is viewed")
                .resolved(in: locale)
        case let .unviewedTurns(.incomplete(numbers)):
            unviewed(numbers, locale: locale)
        case let .unviewedTurns(.range(range)) where range.isAcrossConversations,
             let .worktreeUnviewedTurns(.range(range)) where range.isAcrossConversations:
            // The worktree's unviewed turns: their numbers are each
            // their own conversation's, so the choice counts them instead,
            // the unviewed turns alone, not the viewed ones the range reads
            // through (`includesViewedTurns` says those).
            if let counts {
                LocalizedStringResource(
                    "All Unviewed (\(counts.unviewedTurns) turns · \(counts.unviewedConversations) conversations)",
                    comment: "Review scope: the worktree's unviewed turns across conversations; args: unviewed turns, conversations"
                ).resolved(in: locale)
            } else {
                LocalizedStringResource(
                    "All Unviewed",
                    comment: "Review scope: the worktree's unviewed turns across conversations, where their counts are not at hand"
                ).resolved(in: locale)
            }
        case let .unviewedTurns(.range(range)), let .worktreeUnviewedTurns(.range(range)):
            // The worktree's unviewed turns all in one conversation, with
            // none of another's between them: that conversation's range.
            unviewed(range.numbers, locale: locale)
        case .worktreeUnviewedTurns(.none):
            LocalizedStringResource(
                "Unviewed Turns in the Worktree (None)",
                comment: "Review scope: the worktree's unviewed turns, every conversation's, when every turn is viewed"
            ).resolved(in: locale)
        case .worktreeUnviewedTurns(.incomplete):
            // Across conversations the two ends' numbers are not a run.
            LocalizedStringResource(
                "Unviewed Turns in the Worktree (Incomplete Record)",
                comment: "Review scope: the worktree's unviewed turns, whose first begin or last end snapshot was not taken"
            ).resolved(in: locale)
        case let .turn(range, prompt):
            turns(range.numbers, prompt: prompt, locale: locale)
        case let .incompleteTurn(number):
            "T\(number)"
        case .uncommitted(includesChangesOutsideTurns: true):
            LocalizedStringResource(
                "Uncommitted Changes (Including Outside Turns)",
                comment: "Review scope: uncommitted changes, some made outside any turn"
            ).resolved(in: locale)
        case .uncommitted(includesChangesOutsideTurns: false):
            uncommitted(locale: locale)
        case let .branch(base):
            LocalizedStringResource("Changes from \(base)", comment: "Review scope: the branch against its base, as Changes from main")
                .resolved(in: locale)
        }
    }

    /// What the tab says in place of a diff when its scope has nothing to
    /// read: no changes, or a record that lost a snapshot, which is not
    /// guessed at.
    static func emptyScope(_ selection: ReviewScopeOption) -> EmptyState {
        switch selection {
        case .unviewedTurns(.incomplete), .worktreeUnviewedTurns(.incomplete), .incompleteTurn:
            .incompleteRecord
        default:
            .noChangesInScope
        }
    }

    /// "T8 finished", or "T8–T9 finished", over "Add to Scope": the turns
    /// that ended after the fixed range.
    static func followingTurns(_ turns: [TurnSummary], locale: Locale) -> String? {
        guard let first = turns.first?.displayNumber, let last = turns.last?.displayNumber else { return nil }
        let resource = first == last
            ? LocalizedStringResource("T\(last) finished", comment: "Review: a turn that ended after the range on screen was fixed")
            : LocalizedStringResource(
                "T\(first)–T\(last) finished",
                comment: "Review: turns that ended after the range on screen was fixed, first to last"
            )
        return resource.resolved(in: locale)
    }

    /// The tag the tab's bar leads with: the region's own name, as the
    /// decision bar's tag names what it is on.
    static func bandTag(locale: Locale) -> String {
        LocalizedStringResource("Review").resolved(in: locale)
    }

    /// The left part of the tab's bar.
    static func band(_ status: ReviewTabModel.BandStatus, locale: Locale) -> String {
        switch status {
        case let .unviewedFiles(count):
            LocalizedStringResource("\(count) unviewed files", comment: "Review bar: files not yet marked read").resolved(in: locale)
        case .allFilesViewed:
            LocalizedStringResource("All files viewed", comment: "Review bar: every file is marked read").resolved(in: locale)
        case .noChanges:
            LocalizedStringResource("No changes", comment: "Review bar: the scope read has no changes").resolved(in: locale)
        case .incompleteRecord:
            incompleteRecord(locale: locale)
        }
    }

    private static let oneLineHelp = LocalizedStringResource(
        "Moves the viewed line to the end of this scope (⌘⏎)",
        comment: "Review bar: Mark as Viewed's tooltip for a range of turns"
    )

    /// "Mark as Viewed"'s tooltip, which says how far the line moves.
    /// ⌘⏎ runs it, as on the decision bar.
    static func markViewedHelp(_ action: ReviewTabModel.MarkViewed, locale: Locale) -> String {
        let resource = switch action {
        case .throughTurn:
            oneLineHelp
        // The worktree's range of one conversation moves one line, though
        // through the worktree's history.
        case let .throughTurns(turns) where turns.count == 1:
            oneLineHelp
        case .throughTurns:
            LocalizedStringResource(
                "Moves every conversation’s viewed line to the end of this scope (⌘⏎)",
                comment: "Review bar: Mark as Viewed's tooltip for a range of turns across conversations"
            )
        case .includingChangesOutsideTurns:
            LocalizedStringResource(
                "Also marks changes outside turns as viewed (⌘⏎)",
                comment: "Review bar: Mark as Viewed's tooltip for uncommitted changes"
            )
        }
        return resource.resolved(in: locale)
    }

    /// The pane named in the band's "Review Destination", or why there is
    /// none.
    static func destinationName(_ status: ReviewTabModel.DestinationStatus, locale: Locale) -> String {
        if case let .ready(destination) = status {
            return destination.title
        }
        let resource = switch status {
        case .ready, .resolving:
            LocalizedStringResource("Checking…")
        case .noTerminal:
            LocalizedStringResource("No terminal")
        case let .conversationPaneClosed(agent):
            LocalizedStringResource(
                "\(ConversationText.name(agent, locale: locale))’s pane is closed",
                comment: "Review bar: the scope's conversation has no pane to insert into; argument: the agent, as Claude #2"
            )
        case .paneClosed:
            LocalizedStringResource(
                "The destination pane is closed",
                comment: "Review bar: the pane picked to insert into was closed, and other panes are open"
            )
        case .unchosen:
            // Nothing closed: what the button's tooltip and VoiceOver value
            // say is what to do.
            chooseHelp
        case .noPane:
            LocalizedStringResource("No pane to insert into", comment: "Review bar: no pane of the worktree has a terminal to insert into")
        }
        return resource.resolved(in: locale)
    }

    private static var chooseHelp: LocalizedStringResource {
        LocalizedStringResource(
            "Choose a destination to insert into",
            comment: "Review bar: Insert's tooltip while it is off for want of a pane to insert into"
        )
    }

    /// The bordered menu the band offers where the tab writes nowhere
    /// (`DestinationStatus.offersChoice`): the destination menu, under a
    /// name that says it can be pressed.
    static func chooseDestination(locale: Locale) -> String {
        LocalizedStringResource(
            "Choose Destination…",
            comment: "Review bar: opens the menu of panes to insert the comments into"
        ).resolved(in: locale)
    }

    /// A pane in the destination menu, with what runs in front there as
    /// the band shows it for the chosen one ("review-demo · zsh"): the
    /// pane's name alone where that is its agent, or before the first probe
    /// answers.
    static func destinationChoice(_ choice: ReviewTabModel.DestinationChoice, foreground: String?, locale: Locale) -> String {
        let label = destinationLabel(choice, locale: locale)
        guard let foreground, foreground != choice.destination.title else { return label }
        return "\(label) · \(foreground)"
    }

    /// A pane's name in the menu and the band: its conversation's, as the
    /// changes panel names it ("Claude #2"), told apart from another pane of
    /// the conversation by its tab ("Claude #2 · “first”") or its place
    /// ("Claude #2 (2)"), else the pane's own, with its place where
    /// another pane has the name too ("zsh (2)").
    static func destinationLabel(_ choice: ReviewTabModel.DestinationChoice, locale: Locale) -> String {
        guard let agent = choice.agent else {
            return choice.place.map { place(of: choice.label, $0, locale: locale) } ?? choice.label
        }
        let name = ConversationText.name(agent, locale: locale)
        switch choice.agentDistinction {
        case nil:
            return name
        case let .tab(title):
            return LocalizedStringResource(
                "review.destinationAgentTab",
                defaultValue: "\(name) · “\(title)”",
                comment: "Review destination: one of two panes of a conversation, by its tab; args: the conversation, the tab title"
            ).resolved(in: locale)
        case let .place(place):
            return Self.place(of: name, place, locale: locale)
        }
    }

    /// One of two panes of one name, by its place: "Claude #1 (2)", "zsh
    /// (2)", set off as the language sets a number apart from a name.
    private static func place(of name: String, _ place: Int, locale: Locale) -> String {
        LocalizedStringResource(
            "review.destinationAgentPlace",
            defaultValue: "\(name) (\(place))",
            comment: "Review destination: one of two panes of one name (a conversation, or a shell), by place; args: the name, its place"
        ).resolved(in: locale)
    }

    /// What runs in front of the destination's terminal, when it adds to
    /// the pane's name: an agent's pane is named after its agent, and
    /// "Claude Code · Claude Code" says one thing twice. The dash stands in
    /// for a command not resolved yet, which is no word to translate.
    static func destinationForeground(_ status: ReviewTabModel.DestinationStatus) -> String? {
        guard case let .ready(destination) = status else { return nil }
        guard let foreground = destination.foreground else { return "—" }
        return foreground == destination.title ? nil : foreground
    }

    /// "Insert n Comments"' tooltip: where they go, or, while it is off for
    /// want of a pane to write to that the menu could give it, that one is
    /// to be chosen. None while the band is still looking, or where there is
    /// no pane to choose; the band says so beside it.
    static func insertHelp(_ status: ReviewTabModel.DestinationStatus, locale: Locale) -> String? {
        let resource: LocalizedStringResource
        switch status {
        case let .ready(destination):
            resource = LocalizedStringResource(
                "Inserts the comments into \(destination.title)’s input",
                comment: "Review bar: Insert's tooltip; argument: the pane the comments go to"
            )
        case .noTerminal(hasOtherPanes: true), .conversationPaneClosed, .paneClosed, .unchosen:
            resource = chooseHelp
        case .resolving, .noTerminal(hasOtherPanes: false), .noPane:
            return nil
        }
        return resource.resolved(in: locale)
    }

    /// What the toast says after an insert: that it worked, and what stayed
    /// behind.
    static func inserted(held: Int) -> LocalizedStringResource {
        if held == 0 {
            return "Review inserted. Press Return to send it."
        }
        return "Review inserted. \(held) comments no longer match the current diff and stay in this review."
    }

    /// Why an entry opened nothing, for the toast that says so; the tab, if
    /// one is open, stays as it was.
    static func unavailable(_ reason: ReviewTabUnavailable) -> LocalizedStringResource {
        switch reason {
        case .answerOnly:
            LocalizedStringResource("This turn changed no files.", comment: "Review: a turn opened for review that only answered")
        case .running:
            LocalizedStringResource("This turn is still running.", comment: "Review: a turn opened for review that has not ended")
        case .noTurn:
            LocalizedStringResource("There’s no turn to review.", comment: "Review: Review Latest Turn with no turn that did anything")
        case .changesUnavailable:
            LocalizedStringResource(
                "Couldn’t get this turn’s changes.",
                comment: "Review: a turn whose changes were not taken (not a Git repository, snapshots off, a failure)"
            )
        }
    }

    // MARK: - The scope menu across conversations

    /// "All Conversations", the heading over the worktree's unviewed turns,
    /// every conversation's, at the top of "Review Scope": the word the
    /// changes panel's filter uses for every conversation. Not "Whole
    /// Worktree", which the uncommitted changes and the branch under the
    /// separator are, and this range is not.
    static func worktreeHeading(locale: Locale) -> String {
        LocalizedStringResource(
            "review.scopeAllConversations",
            defaultValue: "All Conversations",
            comment: "Review scope menu: the heading over the worktree's unviewed turns, every conversation's as one range"
        ).resolved(in: locale)
    }

    /// "More Conversations", the heading over the conversations with turns
    /// to read past those listed whole (`ReviewScopeMenu.listedLimit`),
    /// each folded into one entry.
    static func moreConversationsHeading(locale: Locale) -> String {
        LocalizedStringResource(
            "review.scopeMoreConversations",
            defaultValue: "More Conversations",
            comment: "Review scope menu: the heading over further conversations with unviewed turns, each folded into one entry"
        ).resolved(in: locale)
    }

    /// "Turns", the submenu of a conversation's single turns under its
    /// heading.
    static func turnsSubmenu(locale: Locale) -> String {
        LocalizedStringResource(
            "review.scopeTurns",
            defaultValue: "Turns",
            comment: "Review scope menu: the submenu of a conversation's single turns, newest first"
        ).resolved(in: locale)
    }

    /// `text` read with its conversation ("Claude #4: Turns"), as VoiceOver
    /// hears an entry under a heading it does not read with each item.
    static func conversationsChoice(_ text: String, conversation: ConversationChoice, locale: Locale) -> String {
        let name = ConversationText.name(conversation, locale: locale)
        return LocalizedStringResource(
            "review.scopeOfConversation",
            defaultValue: "\(name): \(text)",
            comment: "Review scope: a choice of one conversation's turns, read with its conversation; args: the conversation, the choice"
        ).resolved(in: locale)
    }

    /// "Includes 2 viewed turns": under the worktree's unviewed turns in
    /// the menu, and on the top edge while they are read, when the range
    /// reads through turns already viewed. `nil` for none.
    static func includesViewedTurns(_ count: Int, locale: Locale) -> String? {
        guard count > 0 else { return nil }
        return LocalizedStringResource(
            "Includes \(count) viewed turns",
            comment: "Review scope: the worktree's range reads through turns already viewed; argument: how many"
        ).resolved(in: locale)
    }

    /// What a turn's diff is, said on the top edge of a review of turns in
    /// a worktree of two or more conversations, where another
    /// conversation's edits can fall inside a turn's two snapshots.
    static func turnDiffNote(locale: Locale) -> String {
        LocalizedStringResource(
            "A turn’s diff is what changed in the worktree during the turn.",
            comment: "Review tab: the note under the scope while two or more conversations share the worktree"
        ).resolved(in: locale)
    }

    /// The scope as VoiceOver and the tooltip say it with its conversation
    /// ("Claude #4: Unviewed Turns (T3–T6)"), which the label shows as its
    /// badge and name; the choice alone where none is named.
    static func scope(
        _ option: ReviewScopeOption,
        conversation: ConversationChoice?,
        counts: ReviewScopeCatalog.RangeCounts? = nil,
        locale: Locale
    ) -> String {
        let text = Self.option(option, counts: counts, locale: locale)
        guard let conversation else { return text }
        return conversationsChoice(text, conversation: conversation, locale: locale)
    }

    /// A file tag's words for its tooltip and VoiceOver: "Changed
    /// during Claude #4’s T4, T6". During, not by: a turn's diff holds
    /// whatever changed in the worktree while it ran.
    static func fileTag(_ tag: ReviewFileTag, locale: Locale) -> String {
        let name = ConversationText.name(tag.provider, ordinal: tag.ordinal, locale: locale)
        let turns = turnList(tag.turns, locale: locale)
        return LocalizedStringResource(
            "Changed during \(name)’s \(turns)",
            comment: "Review file tag: the file changed during these turns of a conversation; args: the conversation, its turns"
        ).resolved(in: locale)
    }

    /// "2 more": the tags a header leaves out past
    /// `ReviewFileTags.shownLimit`, named with their unit.
    static func moreFileTags(_ count: Int, locale: Locale) -> String {
        LocalizedStringResource(
            "review.fileTagsMore",
            defaultValue: "\(count) more",
            comment: "Review file header: how many conversations' tags are not shown beside the first two; argument: how many"
        ).resolved(in: locale)
    }

    /// What a header's tags say in their tooltip and to VoiceOver: every
    /// tag's sentence, one per line, the ones left out included, then why
    /// a tag may be missing when some turn's files could not be read. `nil`
    /// when there is nothing to say.
    static func fileTagsHelp(_ tags: [ReviewFileTag], unreadable: [ReviewFileTag], locale: Locale) -> String? {
        let lines = tags.map { fileTag($0, locale: locale) } + [unreadableNote(unreadable, locale: locale)].compactMap(\.self)
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    /// "Couldn’t read the files changed during Claude #2’s T3, so a tag
    /// may be missing": a turn whose files Git could not read tags no file,
    /// so any file's tags may lack it; said rather than tagging less
    /// without a word. `nil` when every turn's files were read.
    static func unreadableNote(_ unreadable: [ReviewFileTag], locale: Locale) -> String? {
        guard !unreadable.isEmpty else { return nil }
        let turns = AgentStatusText.joined(unreadable.map { turnsOf($0, locale: locale) }, locale: locale)
        return LocalizedStringResource(
            "Couldn’t read the files changed during \(turns), so a tag may be missing",
            comment: "Review file header, tooltip: some turns' files could not be read; argument: those turns with their conversations"
        ).resolved(in: locale)
    }

    /// "Claude #4’s T4, T6": a conversation's turns, as a tag counts them.
    private static func turnsOf(_ tag: ReviewFileTag, locale: Locale) -> String {
        let name = ConversationText.name(tag.provider, ordinal: tag.ordinal, locale: locale)
        let turns = turnList(tag.turns, locale: locale)
        return LocalizedStringResource(
            "review.fileTagTurnsOf",
            defaultValue: "\(name)’s \(turns)",
            comment: "Review file header: a conversation's turns; arguments: the conversation, its turns as T4, T6"
        ).resolved(in: locale)
    }

    /// "T4, T6".
    private static func turnList(_ numbers: [Int], locale: Locale) -> String {
        let separator = LocalizedStringResource(
            "review.fileTagTurnSeparator",
            defaultValue: ", ",
            comment: "Review file tag: what goes between two turns' numbers, as in T4, T6"
        ).resolved(in: locale)
        return numbers.map { "T\($0)" }.joined(separator: separator)
    }

    /// A file tag's face beside its badge: the conversation's place,
    /// "#4", where the kind alone does not name it; nothing otherwise.
    static func fileTagOrdinal(_ tag: ReviewFileTag) -> String? {
        tag.ordinal.map { "#\($0)" }
    }

    private static func unviewed(_ numbers: ClosedRange<Int>, locale: Locale) -> String {
        let turns = ReceiptText.turns(numbers, locale: locale)
        return LocalizedStringResource("Unviewed Turns (\(turns))", comment: "Review scope: the turns below the viewed line, as T6–T7")
            .resolved(in: locale)
    }

    /// "T7 · {the prompt's first 18 characters}", "T7–T8 · …" once carried
    /// on, or the numbers alone for a turn whose prompt was not kept. A
    /// prompt the harness wrote is worded by its kind (`TurnPromptText`), in
    /// full: those words are already short, and cut they would say less
    /// than the number alone.
    private static func turns(_ numbers: ClosedRange<Int>, prompt: TurnPrompt, locale: Locale) -> String {
        let label = ReceiptText.turns(numbers, locale: locale)
        guard let shown = TurnPromptText.shortInstruction(prompt, characters: promptCharacters, locale: locale) else { return label }
        return AgentStatusText.joined([label, shown], locale: locale)
    }

    private static func uncommitted(locale: Locale) -> String {
        LocalizedStringResource("Uncommitted Changes", comment: "Review scope: staged, unstaged, and untracked changes")
            .resolved(in: locale)
    }

    private static func incompleteRecord(locale: Locale) -> String {
        LocalizedStringResource("Incomplete record", comment: "Review: a turn's record that lost one of its snapshots")
            .resolved(in: locale)
    }
}
