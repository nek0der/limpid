// AllProjectsModel+Session.swift
// Weir — builds the all projects sheet's cards from every project's sidebar rows.

import Foundation
import WeirDomain

extension AllProjectsModel {
    /// What the sheet is read from: the same sources each window's sidebar
    /// reads, for every project at once.
    struct Sources {
        let session: WorkspaceSession
        /// The window the sheet is open in, whose project says "Current
        /// Window".
        let window: WindowID
        let registry: WindowRegistry
        let queue: AttentionQueue
        let runtimes: [AgentRuntimePresentation]
        let approvals: ApprovalLedger
        let pullRequest: (ContainerID) -> PRInfo?
        let gitFacts: (ContainerID) -> GitFacts?
        let locale: Locale
    }

    /// Every worktree of every project, as the sidebar of the window lists
    /// it, but only the ones with a tab open or an item: a folder with
    /// nothing in it is not a session, but one whose new session stopped
    /// before a tab opened (or whose worktree is gone) is what the person
    /// has to see. The projects come in the window's sidebar order, and each
    /// one's cards as its sidebar lists the rows, so within a section
    /// a card is where the sidebar has its row; the sections are the one
    /// order the sidebar does not keep.
    @MainActor
    static func cards(_ sources: Sources) -> [Card] {
        let session = sources.session
        let currentProject = session.selection(sources.window)?.shownProjectID
        let byID = Dictionary(session.projects.map { ($0.id, $0) }) { first, _ in first }
        let projectIDs = session.projects.map(\.id)
        let order = session.selection(sources.window)?.sidebarArrangement.ordered(projectIDs) ?? projectIDs
        return order.compactMap { byID[$0] }.flatMap { project in
            let rows = SessionSidebarModel(
                project: project,
                session: session,
                window: sources.window,
                queue: sources.queue,
                runtimes: sources.runtimes,
                approvals: sources.approvals,
                pullRequest: sources.pullRequest,
                gitFacts: sources.gitFacts,
                locale: sources.locale
            ).rows
            let byRow = Dictionary(rows.map { ($0.id, $0) }) { first, _ in first }
            // A card's row has a tab or an item, which keeps it among the
            // working rows however the sidebar holds its sections, so the
            // working order (the folder, then the worktrees) is the
            // sidebar's for every card.
            let listed = SidebarPresentedSections().ordered(project).compactMap { byRow[$0.row] }
            let note = windowNote(of: project.id, currentProject: currentProject, sources: sources)
            return listed.filter { $0.hasTabs || $0.leadItemID != nil }.map { row in
                card(row, project: project, note: note, sources: sources)
            }
        }
    }

    @MainActor
    private static func card(_ row: SessionSidebarModel.Row, project: Project, note: WindowNote?, sources: Sources) -> Card {
        let pullRequest = sources.pullRequest(row.id)
        let header = SessionHeaderModel(
            row: row,
            pullRequestNumber: pullRequest?.number,
            pullRequestState: pullRequest?.state,
            gitFacts: sources.gitFacts(row.id),
            locale: sources.locale
        )
        return Card(
            id: row.id,
            projectID: project.id,
            projectName: project.name,
            paletteIndex: project.paletteIndex,
            branch: CheckoutName.of(row.id, in: sources.session),
            name: row.name,
            nameTruncation: row.nameTruncation,
            glyph: row.fact.glyph,
            factText: factLine(row.factText, chips: header.gitChips),
            chips: header.gitChips,
            agentKinds: row.agentKinds,
            badgesSpokenName: badgesSpokenName(row.agentKinds, locale: sources.locale),
            windowNote: note,
            // "Answer…" only while the ledger still holds the request, as
            // the Needs Attention list offers it.
            action: action(
                answerKey: row.answerKey.flatMap { sources.approvals.entries[$0]?.presentation == nil ? nil : $0 },
                requiresTerminalAnswer: row.requiresTerminalAnswer,
                hasPane: row.leadPaneID != nil
            ),
            leadItemID: row.leadItemID,
            leadPaneID: row.leadPaneID,
            leadPaneName: row.leadPaneID.flatMap { sources.session.agentPaneNameAmongNeighbors($0) },
            factTruncation: .fact(row.fact.fact),
            pullRequest: row.fact.pullRequest,
            checkout: row.checkout?.shown,
            folderName: sources.session.rowFolderName(of: row.id)
        )
    }

    /// The card's line under its place: the row's own, unless it only
    /// repeats a Git chip the place line already shows (a session at rest,
    /// whose row speaks of its commits), which would say it twice.
    static func factLine(_ factText: String, chips: [SessionHeaderModel.GitChip]) -> String {
        chips.contains { $0.text == factText } ? "" : factText
    }

    /// The agents' names for the card's badges to say: the card's label is
    /// made of what it shows, and a badge's "Cl" says nothing aloud.
    static func badgesSpokenName(_ kinds: [AgentKind], locale: Locale) -> String {
        AgentStatusText.spokenList(kinds.map { SessionRowFactText.agentName(.agent($0), locale: locale) }, locale: locale)
    }

    /// "Answer…" for a request Weir can still answer; "Open Pane" for one
    /// answered in the TUI (a wait Weir holds no request for, one handed
    /// to the TUI or timed out, Codex's questions) when the card has a pane
    /// to go to, as the Needs Attention list offers them; nothing
    /// otherwise.
    static func action(answerKey: ApprovalKey?, requiresTerminalAnswer: Bool, hasPane: Bool) -> Action? {
        if let answerKey {
            return .answer(answerKey)
        }
        return requiresTerminalAnswer && hasPane ? .openPane : nil
    }

    /// "Current Window" for the sheet's own project; "Other Window" for one
    /// another window shows, hidden or not, since opening it brings that
    /// window forward. A project no window shows says nothing:
    /// opening it switches this window.
    @MainActor
    private static func windowNote(of projectID: UUID, currentProject: UUID?, sources: Sources) -> WindowNote? {
        if projectID == currentProject {
            return .current
        }
        return sources.registry.window(showingProject: projectID, in: sources.session) == nil ? nil : .otherWindow
    }
}
