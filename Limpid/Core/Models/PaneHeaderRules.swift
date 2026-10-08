// PaneHeaderRules.swift
// Limpid — when the panes of a tab carry a header, and what each header
// calls its pane.
//
// Kept in Core and free of SwiftUI so the rules can be pinned by tests:
// the header is drawn from several sources (a name the user typed, the
// agent's conversation title, the shell's directory), and the order they
// win in is the part a later change is most likely to get wrong.

import Foundation

/// The agent a header speaks for, reduced to two strings: `title` names the
/// pane, and `providerName` goes only into the hover text and VoiceOver.
/// `title` is nil while the conversation has not produced one yet.
struct PaneHeaderAgent: Equatable {
    var providerName: String
    var title: String?
}

/// What a pane header shows, left to right: the name, then the dimmer
/// detail beside it, the pane's directory. `detail` is nil when there is
/// nothing to add, which includes a detail that would only repeat the name.
/// `agentName` is for the hover text and VoiceOver, not the row: the glyph
/// already marks an agent pane, and where it runs is the more useful line.
struct PaneHeaderLabel: Equatable {
    var name: String
    var detail: String?
    var isAgent: Bool
    var agentName: String?
}

/// How much of a header a row has room for, widest first. The kind glyph
/// and the "⋯" menu are in every form: the glyph says what the pane is and
/// the menu is how to act on it. Between them the detail goes first, then
/// the name, then the state mark, then the prompt cache clock, which is
/// what a narrow pane most needs to say while it shows: the next message
/// will cost a re-write, and the clock is the way to deal with it.
enum PaneHeaderForm: CaseIterable, Equatable {
    /// Glyph, name, detail, cache clock, state mark, menu.
    case all
    /// Glyph, name (truncating), cache clock, state mark, menu.
    case withName
    /// Glyph, cache clock, state mark, menu.
    case withMark
    /// Glyph, cache clock, menu: `PaneHeaderMetrics.clockFormWidth`. Tried
    /// only while the pane has a clock to show.
    case withClock
    /// Glyph and menu: `PaneHeaderMetrics.minimumWidth`, or
    /// `zoomedMinimumWidth` with the unzoom button a zoomed pane keeps
    /// beside its menu in every form.
    case glyphAndMenu

    var showsName: Bool {
        self == .all || self == .withName
    }

    var showsDetail: Bool {
        self == .all
    }

    var showsMark: Bool {
        self == .all || self == .withName || self == .withMark
    }

    /// Whether the form has a place for the prompt cache clock; the clock
    /// itself shows only while the pane has one.
    var showsPromptCacheClock: Bool {
        self != .glyphAndMenu
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
    /// Whether the panes of a tab show headers. A single pane is named by
    /// its tab row already, so the header would repeat it; a split tab's
    /// panes carry one each while the setting is on. A zoomed pane of a
    /// split tab shows its header whatever the setting says: the header's
    /// unzoom button is the way back to the split, and without it a zoomed
    /// pane looks like a tab with one pane.
    static func showsHeaders(leafCount: Int, isZoomed: Bool, isEnabled: Bool) -> Bool {
        leafCount > 1 && (isZoomed || isEnabled)
    }

    /// Whether `paneID`'s header is on screen, zoomed or not: the one
    /// predicate the header itself and the terminal's "Rename Pane…" item
    /// both read, so the item never offers a rename with no header to take
    /// it. Review replaces the split with its own surface and docks the pane
    /// under a heading of its own, so no split header shows while it is up.
    static func showsHeader(in tab: Tab?, isEnabled: Bool, isReviewPresented: Bool) -> Bool {
        guard let tab, !isReviewPresented else { return false }
        return showsHeaders(in: tab, isEnabled: isEnabled)
    }

    /// The forms a header tries, widest first, the first that fits winning.
    /// While renaming in place only the form with the name will do, since
    /// the field is what the user is working in. The clock's own form is
    /// tried only while there is a clock: without one it would be the
    /// glyph-and-menu form under another name.
    static func forms(isEditing: Bool, showsPromptCacheClock: Bool) -> [PaneHeaderForm] {
        if isEditing {
            return [.withName]
        }
        return PaneHeaderForm.allCases.filter { showsPromptCacheClock || $0 != .withClock }
    }

    /// Where a rename opens for a header this wide. Below the threshold the
    /// field would be a few characters wide — at the narrowest the header
    /// shows only its glyph and menu — so the rename floats under the header
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

    /// The same rule read off a tab.
    static func showsHeaders(in tab: Tab, isEnabled: Bool) -> Bool {
        showsHeaders(
            leafCount: tab.splitTree.allLeafIDs().count,
            isZoomed: isZoomed(tab),
            isEnabled: isEnabled
        )
    }

    /// Whether `paneID` is the pane its tab shows zoomed. Zoom counts only
    /// while the zoomed leaf is still in the tree, because that is when
    /// `PaneAreaView` renders the zoomed pane alone; a stale id falls back
    /// to the split.
    static func isZoomed(_ paneID: UUID, in tab: Tab?) -> Bool {
        guard let tab, tab.zoomedLeafID == paneID else { return false }
        return tab.splitTree.contains(leafID: paneID)
    }

    /// Whether the tab shows one of its panes zoomed; see `isZoomed(_:in:)`.
    static func isZoomed(_ tab: Tab) -> Bool {
        tab.zoomedLeafID.map { isZoomed($0, in: tab) } ?? false
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
    /// chooses a tab's title (`tab_titles` in `limpid-agent-core`), so a
    /// pane and the tab it names agree on what the conversation is called.
    ///
    /// A provider that supplies session titles must also have reported a
    /// conversation id before its titles count: without one the record may
    /// be left over from a session that has ended. A provider without
    /// session titles is named by its opening prompt alone. `resolve` is
    /// the same Rust resolver the tab rule runs, so the sanitizing and the
    /// length limits stay in one place.
    static func agentTitle(
        for badge: AgentBadge,
        hasSessionTitles: Bool,
        resolve: (String?, String?, String?) -> String? = LimpidRustTitleResolver.resolve
    ) -> String? {
        if hasSessionTitles {
            guard badge.conversationID != nil else { return nil }
            return normalizedName(resolve(
                badge.providerSessionTitle,
                badge.providerGeneratedTitle,
                badge.firstPrompt
            ))
        }
        return normalizedName(resolve(nil, nil, badge.firstPrompt))
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
    /// to the hover text and VoiceOver as `agentName`.
    static func label(
        customName: String?,
        agent: PaneHeaderAgent?,
        workingDirectory: String?,
        fallbackName: String
    ) -> PaneHeaderLabel {
        let directory = normalizedName(workingDirectory)
        let name = normalizedName(customName)
            ?? normalizedName(agent?.title)
            ?? directory.flatMap(directoryName(of:))
            ?? fallbackName
        let detail = directory.map(PathFormatting.abbreviateHome)
        return PaneHeaderLabel(
            name: name,
            detail: detail == name ? nil : detail,
            isAgent: agent != nil,
            agentName: agent.flatMap { normalizedName($0.providerName) }
        )
    }
}
