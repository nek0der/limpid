// PaneHeaderRules.swift
// Limpid — what each pane's header says, and what it offers.
//
// Kept in Core and free of SwiftUI so the rules can be pinned by tests:
// the header is drawn from several sources (a name the user typed, the
// agent's conversation title, the shell's directory), and the order they
// win in is the part a later change is most likely to get wrong.

import Foundation

/// The agent a header speaks for: `title` names the pane, `providerName` goes
/// only into the hover text and VoiceOver, and the model, effort, and
/// permission mode go on the header's trailing side. Each is nil until the
/// agent has said it: the title until the conversation has produced one, the
/// settings until a hook or the agent's rollout has carried them.
struct PaneHeaderAgent: Equatable {
    /// Which agent it is, for the header's badge.
    var kind: AgentKind
    var providerName: String
    var title: String?
    var model: String?
    var permissionMode: AgentPermissionMode?
    var effort: String?
}

/// What a pane header shows, left to right: the name, then the dimmer
/// detail beside it, the pane's directory. `detail` is nil when there is
/// nothing to add, which includes a detail that would only repeat the name.
/// `agentName` is for the hover text and VoiceOver, not the row: the badge
/// already names the agent, and where it runs is the more useful line.
struct PaneHeaderLabel: Equatable {
    var name: String
    var detail: String?
    /// The agent the pane is for, whose badge leads the header; `nil` for a
    /// shell, which has the shell's mark.
    var agentKind: AgentKind?
    var agentName: String?
    /// The name is one the person gave the pane, rather than one read from
    /// its agent or its folder.
    var isNamedByPerson = false
    /// The model the pane's agent runs, as its adapter names it.
    var model: String?
    /// How freely the pane's agent may act without asking.
    var permissionMode: AgentPermissionMode?
    /// How hard the pane's agent's model reasons, in the provider's own word.
    var effort: String?
    /// What the pane's conversation has used, as the header writes it; only
    /// the header sets it, as the other surfaces that read a label do not
    /// show it.
    var tokens: String?
    /// Whether the run records lack enough evidence to identify the current
    /// settings owner.
    var settingsAreAmbiguous = false
    /// The conversation the pane runs, whose identity color leads the badge
    /// and whose cards the header answers for; `nil` before it has one.
    var conversation: ConversationKey?

    var isAgent: Bool {
        agentKind != nil
    }

    /// Shared by row layout and rename sizing so every warning reserves space.
    var showsWarning: Bool {
        runsWithoutAsking || settingsAreAmbiguous
    }

    static let unavailableSettings = LocalizedStringResource(
        "Agent settings unavailable",
        comment: "Pane header: older run records do not establish which agent settings are current"
    )

    /// Whether the header warns that the agent runs every action without
    /// asking.
    var runsWithoutAsking: Bool {
        permissionMode?.runsWithoutAsking == true
    }

    /// The model, the effort, and the mode's short name, as the header's
    /// trailing text shows them ("Opus 5.5 · high · Plan"), or nil when there
    /// are none, then `tokens`, what the conversation has used, as the caller
    /// wrote it. The effort stays the agent's own word, as the model does. The
    /// default mode is left unsaid, and the mode that runs without asking is
    /// named by the warning instead.
    func settingsText(tokens: String? = nil, locale: Locale) -> String? {
        if settingsAreAmbiguous {
            return nil
        }
        let pieces = [model, effort, permissionMode?.headerName?.resolved(in: locale), tokens].compactMap(\.self)
        return pieces.isEmpty ? nil : pieces.joined(separator: " · ")
    }
}

/// How much of a header a row has room for, widest first. The kind's mark
/// and the "⋯" menu are in every form: the mark says what the pane is and
/// the menu is how to act on it. Between them the detail goes first, then
/// the tokens, then the agent's settings, then the warning's words, then the name, then
/// the state mark with the warning's symbol, then the prompt cache clock,
/// which is what a narrow pane most needs to say while it shows: the next
/// message will cost a re-write, and the clock is the way to deal with it.
enum PaneHeaderForm: CaseIterable, Equatable {
    /// Kind's mark, name, detail, warning, settings, tokens, cache clock,
    /// state mark, menu.
    case all
    /// Kind's mark, name, warning, settings, tokens, cache clock, state mark,
    /// menu.
    case withTokens
    /// Kind's mark, name, warning, settings, cache clock, state mark, menu. A
    /// count that grows with every turn gives way before what the agent runs.
    case withSettings
    /// Kind's mark, name (truncating), warning's symbol, cache clock, state mark,
    /// menu.
    case withName
    /// Kind's mark, warning's symbol, cache clock, state mark, menu.
    case withMark
    /// Kind's mark, cache clock, menu: `PaneHeaderMetrics.clockFormWidth`. Tried
    /// only while the pane has a clock to show.
    case withClock
    /// Kind's mark and menu: `PaneHeaderMetrics.minimumWidth`, or
    /// `zoomedMinimumWidth` with the unzoom button a zoomed pane keeps
    /// beside its menu in every form.
    case kindAndMenu

    var showsName: Bool {
        self == .all || self == .withTokens || self == .withSettings || self == .withName
    }

    var showsDetail: Bool {
        self == .all
    }

    /// The settings, and the warning in words rather than its symbol
    /// alone.
    var showsSettings: Bool {
        self == .all || self == .withTokens || self == .withSettings
    }

    /// What the pane's conversation has used, beside the settings.
    var showsTokens: Bool {
        self == .all || self == .withTokens
    }

    /// The state mark, and the warning, which stays as long as the mark
    /// does: as words while the form has room for the settings, else as
    /// its symbol.
    var showsMark: Bool {
        self == .all || self == .withTokens || self == .withSettings || self == .withName || self == .withMark
    }

    /// Whether the kind's mark has its conversation's color before it. It goes
    /// before the narrow forms do, and while renaming so the field keeps its
    /// width: the split floor and the rename threshold count the badge alone.
    func showsIdentity(isEditing: Bool) -> Bool {
        showsMark && !isEditing
    }

    /// Whether the form has a place for the prompt cache clock; the clock
    /// itself shows only while the pane has one.
    var showsPromptCacheClock: Bool {
        self != .kindAndMenu
    }
}

/// Where a rename is edited: in the header itself, or in the floating panel
/// under it when the header is too narrow for a usable field.
enum PaneRenameStyle: Equatable {
    case inline
    case floating
}

/// What the header's zoom item does.
enum PaneZoomAction: Equatable {
    case zoom
    case unzoom
}

/// What committing a pane rename writes.
enum PaneNameChange: Equatable {
    case set(String)
    case clear
}

enum PaneHeaderRules {
    /// The forms a header tries, widest first, the first that fits winning.
    /// While renaming in place only the form with the name will do, since
    /// the field is what the user is working in. The clock's own form is
    /// tried only while there is a clock: without one it would be the
    /// mark-and-menu form under another name.
    static func forms(isEditing: Bool, showsPromptCacheClock: Bool) -> [PaneHeaderForm] {
        if isEditing {
            return [.withName]
        }
        return PaneHeaderForm.allCases.filter { showsPromptCacheClock || $0 != .withClock }
    }

    /// Where a rename opens for a header this wide. Below the threshold the
    /// field would be a few characters wide — at the narrowest the header
    /// shows only its kind's mark and menu — so the rename floats under the header
    /// instead. A header not measured yet (width 0) has no frame to hang a
    /// panel from, so it edits in place.
    static func renameStyle(
        headerWidth: CGFloat,
        threshold: CGFloat = PaneHeaderMetrics.inlineRenameMinimumWidth
    ) -> PaneRenameStyle {
        headerWidth <= 0 || headerWidth >= threshold ? .inline : .floating
    }

    /// Whether an in-place rename should end because the header got too
    /// narrow for it, as when a divider is dragged mid-edit. The header is
    /// not clipped, and while renaming it keeps the form with the name, so a
    /// field left open below the threshold would draw into the neighboring
    /// pane. It ends the way a click elsewhere ends it, committing what was
    /// typed.
    static func shouldEndInlineRename(
        isEditing: Bool,
        headerWidth: CGFloat,
        threshold: CGFloat = PaneHeaderMetrics.inlineRenameMinimumWidth
    ) -> Bool {
        isEditing && renameStyle(headerWidth: headerWidth, threshold: threshold) == .floating
    }

    /// What a submitted rename writes, or nil when it changes nothing.
    /// `shown` is the name the header showed when the edit began, which is
    /// what the field opened with. Submitting it unchanged writes nothing
    /// while the pane has no name of its own: storing it would pin today's
    /// agent title or directory, and the header would stop following the
    /// pane. Comparing against the name at the start rather than the name
    /// now matters when an agent retitles the pane mid-edit: an untouched
    /// submit must not pin the old title. An empty submit clears the name.
    static func nameChange(submitted: String, stored: String?, shown: String) -> PaneNameChange? {
        let submittedName = normalizedName(submitted)
        let storedName = normalizedName(stored)
        if storedName == nil, submittedName == shown {
            return nil
        }
        guard submittedName != storedName else { return nil }
        return submittedName.map(PaneNameChange.set) ?? .clear
    }

    /// Whether `paneID` is the pane its tab shows zoomed. Zoom counts only
    /// while the zoomed leaf is still in the tree, because that is when
    /// `PaneAreaView` renders the zoomed pane alone; a stale id falls back
    /// to the split.
    static func isZoomed(_ paneID: UUID, in tab: Tab?) -> Bool {
        guard let tab, tab.zoomedLeafID == paneID else { return false }
        return tab.splitTree.contains(leafID: paneID)
    }

    /// What the header's zoom item, and its VoiceOver action, do: zoom this
    /// pane, or, while it is zoomed, go back to the split.
    static func zoomAction(isZoomed: Bool) -> PaneZoomAction {
        isZoomed ? .unzoom : .zoom
    }

    /// What the terminal's zoom item does for `paneID`, or nil when its tab
    /// has a single pane and there is nothing to zoom out of. The item
    /// follows the header's, so the menu offers the same flip whether or
    /// not a header is on screen.
    static func menuZoomAction(for paneID: UUID, in tab: Tab?) -> PaneZoomAction? {
        guard let tab, tab.splitTree.allLeafIDs().count > 1 else { return nil }
        return zoomAction(isZoomed: isZoomed(paneID, in: tab))
    }

    /// Whether a drag on the header picks the pane up. Not while renaming in
    /// place, where a drag selects text in the field, and not while zoomed,
    /// where the pane is alone on screen and there is no split to drop it
    /// into beside it.
    static func dragsPane(isEditing: Bool, isZoomed: Bool) -> Bool {
        !isEditing && !isZoomed
    }

    /// A name as it is stored: on one line, without surrounding
    /// whitespace, and nil when nothing is left. Nil is what clears a
    /// custom name, so an empty submit hands the header back to the
    /// derived label rather than leaving a blank one.
    static func normalizedName(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let oneLine = raw.components(separatedBy: .newlines).joined(separator: " ")
        let trimmed = oneLine.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The agent title for one pane's badge, chosen the way the projection
    /// chooses a tab's title (`badge_title` in `limpid-agent-core`), so a
    /// pane and the tab it names agree on what the conversation is called.
    ///
    /// A badge names nothing until the run has reported its conversation:
    /// without one the record may be left over from a session that has
    /// ended, its opening prompt with it. `resolve` is the same Rust
    /// resolver the tab rule runs, so the sanitizing and the length limits
    /// stay in one place.
    static func agentTitle(
        for badge: AgentBadge,
        resolve: (String?, String?, String?) -> String? = LimpidRustTitleResolver.resolve
    ) -> String? {
        guard badge.conversationID != nil else { return nil }
        return normalizedName(resolve(
            badge.providerSessionTitle,
            badge.providerGeneratedTitle,
            badge.firstPrompt
        ))
    }

    /// The last component of a directory, or `~` for the home directory
    /// itself, whose last component is only the account name.
    static func directoryName(of path: String) -> String? {
        let abbreviated = PathFormatting.abbreviateHome(path)
        if abbreviated == "~" {
            return abbreviated
        }
        return normalizedName((path as NSString).lastPathComponent)
    }

    /// Resolve what a header shows. The name is the first of: the name the
    /// user gave the pane, the agent's conversation title, the last
    /// component of the pane's directory, and `fallbackName`. The detail is
    /// always the pane's directory, home-abbreviated, because that is what
    /// tells two panes with the same name apart; the agent's provider goes
    /// to the hover text and VoiceOver as `agentName`, and its model and
    /// mode pass through as they are.
    static func label(
        customName: String?,
        agent: PaneHeaderAgent?,
        workingDirectory: String?,
        fallbackName: String
    ) -> PaneHeaderLabel {
        let directory = normalizedName(workingDirectory)
        let personName = normalizedName(customName)
        let name = personName
            ?? normalizedName(agent?.title)
            ?? directory.flatMap(directoryName(of:))
            ?? fallbackName
        let detail = directory.map(PathFormatting.abbreviateHome)
        return PaneHeaderLabel(
            name: name,
            detail: detail == name ? nil : detail,
            agentKind: agent?.kind,
            agentName: agent.flatMap { normalizedName($0.providerName) },
            isNamedByPerson: personName != nil,
            model: normalizedName(agent?.model),
            permissionMode: agent?.permissionMode,
            effort: normalizedName(agent?.effort)
        )
    }
}

/// The panes a zoomed pane's header stands in front of: how many there are,
/// and what most needs the person among them, which the header's chip says and
/// goes to, since nothing else on screen shows that those panes are there.
struct PaneHeaderHiddenPanes: Equatable {
    let count: Int
    /// The pane the chip goes to: the one the glyph is about, else the first.
    let lead: UUID
    /// What ranks first among their waits and stops; `nil` with none. A
    /// turn's unread is not one, as on a tab.
    let glyph: SessionRowFact.Glyph?
}

extension PaneHeaderRules {
    /// `nil` unless `paneID` is what its tab shows zoomed.
    static func hiddenPanes(behind paneID: UUID, in tab: Tab?, items: [AttentionItem]) -> PaneHeaderHiddenPanes? {
        guard let tab, isZoomed(paneID, in: tab) else { return nil }
        let others = tab.splitTree.allLeafIDs().filter { $0 != paneID }
        guard let first = others.first else { return nil }
        let waiting = items.filter { item in
            if case .unread = item.kind {
                return false
            }
            return item.subject.paneID.map(others.contains) ?? false
        }
        let dominant = PanePriority.dominant(waiting)
        return PaneHeaderHiddenPanes(
            count: others.count,
            lead: dominant?.subject.paneID ?? first,
            glyph: dominant.map { SessionRowFact.glyph(of: $0.kind) }
        )
    }
}

/// What a pane header's state mark says: the glyph, and what the agent the
/// glyph stands for reported last, for the hover text.
struct PaneHeaderMark: Equatable {
    let glyph: SessionRowFact.Glyph
    let detail: String?
}

extension PaneHeaderRules {
    /// The header's state mark: the glyph a row holding only this pane
    /// wears, decided by the row's own function (`SessionRowFact.make`).
    ///
    /// The pane takes what the attention list places in it: its items (by
    /// the pane each item names) and the runs shown in it
    /// (`AttentionState.shownPane`), the rule the list and the sidebar
    /// place a run by. So two runs in one pane (a finished Claude beside a
    /// running Codex) are weighed as the row weighs them, and a tmux run
    /// shown in several panes marks only the one it is placed in, as its
    /// items do.
    ///
    /// The detail is the reporting agent's: the run the pane's leading
    /// item (`PanePriority.dominant`) is about. With no item, or when a
    /// run outranks the pane's unread turn, it is the agent the row speaks
    /// for (`leadAgentIndex`).
    ///
    /// `nil` at rest, before the agent is matched, and for a shell, so a
    /// quiet pane's header stays quiet. A rest with work still running
    /// after the turn is not quiet: it has a mark.
    @MainActor
    static func mark(
        paneID: UUID,
        items: [AttentionItem],
        runtimes: [AgentRuntimePresentation],
        session: WorkspaceSession
    ) -> PaneHeaderMark? {
        mark(
            paneItems: items.filter { $0.subject.paneID == paneID },
            shown: runtimes.filter { AttentionState.shownPane(of: $0, in: session) == paneID }
        )
    }

    /// `mark(paneID:items:runtimes:session:)` for a pane whose items and
    /// runs are already picked out: for a caller that marks many panes at
    /// once and places each run once (`PaneStripModel`), rather than once
    /// per pane.
    static func mark(paneItems: [AttentionItem], shown: [AgentRuntimePresentation]) -> PaneHeaderMark? {
        let agents = shown.map(SessionRowFact.Agent.init(runtime:))
        let fact = SessionRowFact.make(.init(items: paneItems, agents: agents))
        switch fact.glyph {
        case .idle, .unknown, .shell:
            return nil
        case .needsAnswer, .needsApproval, .needsResponse, .needsSignIn, .stopped, .unread, .unreadWorkingAfterTurn,
             .running, .workingAfterTurn:
            break
        }
        let speaker: AgentRuntimePresentation? = if fact.glyph != .running,
                                                    case let .runtime(id, _, _, _, _) = PanePriority.dominant(paneItems)?.subject
        {
            shown.first { $0.id == id }
        } else {
            SessionRowFact.leadAgentIndex(of: agents).map { shown[$0] }
        }
        return PaneHeaderMark(glyph: fact.glyph, detail: speaker?.badge.detail.flatMap { $0.isEmpty ? nil : $0 })
    }
}
