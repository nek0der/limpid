// NeedsAttentionListModel.swift
// Weir — the rows of the title bar's Needs Attention list.

import Foundation
import WeirDomain

/// The Needs Attention list: every item of the app's attention list,
/// one row each, in the order they arrived, across all projects. It is not
/// cut off at a count: a request past the sixth row must still be
/// answerable from here.
struct NeedsAttentionListModel: Equatable {
    enum RowState: Equatable {
        /// An approval request, or a wait at the agent's prompt its record
        /// says is one (or, for an older record, in a tool's words).
        case approval
        case question
        /// A wait at the agent's prompt we cannot name as an approval or a
        /// question; it ranks with approvals.
        case response
        /// The agent waits for the person to sign in again; it ranks with
        /// approvals.
        case signIn
        case stopped
        case unread
    }

    /// This is the button a row offers besides opening the item. A request Weir
    /// does not hold (a wait at the agent's prompt, one handed to the TUI or
    /// timed out, Codex's questions) is answered in the TUI, and the row
    /// itself already goes to that pane, so such a row offers no button: one
    /// beside it would only repeat the row.
    enum RowAction: Equatable {
        /// Opens the approval card for this request without leaving this
        /// window or pane: a request or Claude's question Weir can still
        /// answer.
        case answer(ApprovalKey)
    }

    struct Row: Identifiable, Equatable {
        let id: AttentionItemID
        let state: RowState
        /// The session's name, with its pane's where the session has several
        /// agent panes, or the agent's for a request no pane is known for.
        let title: String
        /// The agent the item is about, whose badge the row shows, so two
        /// items of one session can be told apart; `nil` for a session's own.
        var agent: AgentKind?
        /// The project (and worktree) the item is in; `nil` when it is in
        /// none, or not placed yet.
        let place: String?
        /// The one fact the row states: what the agent asks, why it
        /// stopped, or that a turn is unread. Resolved in the list's
        /// language, since a stop's reason sits inside another sentence.
        let fact: String
        /// What the row's second line says before its fact: where the item
        /// is, said to be in another window when its project is not the one
        /// this window shows, and the separator ("weir (another window) · ").
        /// Empty for an item in no place. Kept apart from the fact so a
        /// view can set the fact in its state's color.
        let placeLead: String
        /// `nil` for a row that offers only itself.
        let action: RowAction?
        let arrivedAt: Date
        /// The item is of a project no window shows: in a window, neither
        /// the list's nor another's; from the menu bar, none of the windows
        /// the caller names (`projectsInWindows`). ⌘-click then opens it
        /// in a new window, which the row's tooltip and VoiceOver
        /// action say (`NewWindowText`). Choosing any other row goes
        /// where it would without ⌘.
        var opensInNewWindow = false

        /// Where the second line is cut (`factTruncation(of:request:)`).
        var factTruncation = SupervisionTruncation.sentence

        /// The second line as VoiceOver reads it: the place and the fact
        /// as a list, a turn as "Turn 7". Empty reads
        /// the line as drawn.
        var spokenDetail = ""
    }

    /// Names an item's place, looked up by whoever holds the session.
    struct Names: Equatable {
        let title: String
        let place: String?
    }

    let rows: [Row]

    var count: Int {
        rows.count
    }

    /// The count, where the list reaches, and its order; an empty list has
    /// none of them to tell, and its empty state says the rest, so it is
    /// only the list's name.
    var heading: LocalizedStringResource {
        guard count > 0 else {
            return LocalizedStringResource("Needs Attention", comment: "Needs Attention list heading while the list is empty")
        }
        return LocalizedStringResource(
            "Needs Attention \(count) · All Projects · In Order of Arrival",
            comment: "Needs Attention list heading; the attention count"
        )
    }

    /// The rows for `items`, in the list's order. `names` gives each item's
    /// session and place; `request` gives a request's text, `nil` when the
    /// ledger no longer holds it. `projectsInOtherWindows` are the projects
    /// the windows other than the list's show, hidden ones included: an
    /// item of one is said to be in another window, since going to it
    /// brings that window forward. An item of a project no window
    /// shows is not: going to it switches this window. Empty outside a
    /// window, where no item is said to be in another. `windowProjectID`
    /// is the project the list's window shows (`.some(nil)` for a window
    /// that shows none), whose items are here already; `nil` outside a
    /// window (the menu bar). There `projectsInWindows` are the projects
    /// every window shows, hidden ones included, and ⌘-click opens an item
    /// of any other project in a new window, as the list does; left
    /// `nil`, no row opens a window of its own.
    init(
        items: [AttentionItem],
        names: (AttentionItem) -> Names,
        request: (ApprovalKey) -> RequestText?,
        projectsInOtherWindows: Set<UUID> = [],
        windowProjectID: UUID??,
        projectsInWindows: Set<UUID>? = nil,
        locale: Locale
    ) {
        rows = items.map { item in
            let names = names(item)
            let worded = Self.fact(of: item, request: request)
            let fact = worded.resolved(in: locale)
            let isInAnotherWindow = Self.isInAnotherWindow(item, projectsInOtherWindows: projectsInOtherWindows)
            let place = names.place.map { Self.place($0, isInAnotherWindow: isInAnotherWindow, locale: locale) }
            return Row(
                id: item.id,
                state: Self.state(of: item.kind),
                title: names.title,
                agent: item.subject.agentKind,
                place: names.place,
                fact: fact,
                placeLead: place.map { AgentStatusText.lead($0, before: fact, locale: locale) } ?? "",
                action: Self.action(for: item, hasRequest: { request($0) != nil }),
                arrivedAt: item.arrivedAt,
                opensInNewWindow: Self.opensInNewWindow(
                    item,
                    windowProjectID: windowProjectID,
                    projectsInWindows: projectsInWindows,
                    isInAnotherWindow: isInAnotherWindow
                ),
                factTruncation: Self.factTruncation(of: item, request: request),
                spokenDetail: AgentStatusText.spokenList(
                    [place.map { AgentStatusText.spokenPlace($0, locale: locale) } ?? "", worded.spoken(in: locale)],
                    locale: locale
                )
            )
        }
    }

    /// Whether ⌘-click opens `item` in a new window: it is of a project
    /// neither the list's window nor another shows. Outside a window, of a
    /// project no window shows, when the caller says which they show.
    private static func opensInNewWindow(
        _ item: AttentionItem,
        windowProjectID: UUID??,
        projectsInWindows: Set<UUID>?,
        isInAnotherWindow: Bool
    ) -> Bool {
        guard let projectID = item.subject.projectID else { return false }
        switch windowProjectID {
        case let .some(shown):
            return projectID != shown && !isInAnotherWindow
        case nil:
            return projectsInWindows.map { !$0.contains(projectID) } ?? false
        }
    }

    /// An item's place, said to be in another window when another window
    /// shows its project.
    static func place(_ place: String, isInAnotherWindow: Bool, locale: Locale) -> String {
        isInAnotherWindow
            ? LocalizedStringResource(
                "\(place) (another window)",
                comment: "Needs Attention row: the project of an item in another project's window"
            ).resolved(in: locale)
            : place
    }

    /// Whether `item` is in another window: one of the windows other than
    /// the one asking shows its project (`projectsInOtherWindows`), as the
    /// all projects cards and project ▾ say "Other Window". An item
    /// of no project, or of a project no window shows, is not.
    static func isInAnotherWindow(_ item: AttentionItem, projectsInOtherWindows: Set<UUID>) -> Bool {
        item.subject.projectID.map(projectsInOtherWindows.contains) ?? false
    }

    /// What the list shows of a request.
    typealias RequestText = ApprovalRequestText

    private static func state(of kind: AttentionItemKind) -> RowState {
        switch kind {
        case .approval, .prompt(.approval): .approval
        case .prompt(.unclassified): .response
        case .prompt(.signIn): .signIn
        case .question, .prompt(.question): .question
        case .stop: .stopped
        case .unread: .unread
        }
    }

    /// "Answer…" needs the request the card would show, and a broker that
    /// still takes a decision for it. Every other item offers only the row,
    /// which goes to its pane, where one answered at the agent's own prompt
    /// (`AttentionItem.requiresTerminalAnswer`) is answered.
    private static func action(for item: AttentionItem, hasRequest: (ApprovalKey) -> Bool) -> RowAction? {
        switch item.kind {
        case let .approval(fact), let .question(fact):
            item.canAnswerInWeir && hasRequest(fact.key) ? .answer(fact.key) : nil
        case .prompt, .stop, .unread:
            nil
        }
    }

    private static func fact(of item: AttentionItem, request: (ApprovalKey) -> RequestText?) -> Fact {
        switch item.kind {
        case let .approval(fact):
            let text = request(fact.key).map(\.approvalText)
            return text.map { .text(LocalizedStringResource(
                "Waiting for approval: \($0)",
                comment: "Needs Attention row; the command an approval request waits on"
            )) } ?? .text("Needs approval")
        case let .question(fact):
            let text = request(fact.key).flatMap(\.questionText)
            return text.map { .text(LocalizedStringResource(
                "Question: \($0)",
                comment: "Needs Attention row; the start of the agent's question"
            )) } ?? .text("Needs answer")
        case let .prompt(wait):
            // Worded as the session row's second line words it.
            return .text(PromptWaitText.line(wait))
        case let .stop(reason):
            return .stopped(reason)
        case let .unread(turn):
            return .unread(turn)
        }
    }

    /// Where a row's fact is cut: an approval that names its command or
    /// file, and a wait at the prompt as `SupervisionTruncation.wait` says,
    /// keep both ends, so the place before it and the file at its end both
    /// stay ("alpha · Waiting for approval: notes.txt"); a question, a stop,
    /// and a turn read from their start.
    static func factTruncation(of item: AttentionItem, request: (ApprovalKey) -> RequestText?) -> SupervisionTruncation {
        switch item.kind {
        case let .approval(fact): request(fact.key) == nil ? .sentence : .subject
        case let .prompt(wait): SupervisionTruncation.wait(wait)
        case .question, .stop, .unread: .sentence
        }
    }

    /// A row's fact before it is put into words.
    private enum Fact {
        case text(LocalizedStringResource)
        case stopped(StopReason)
        case unread(UnreadTurn)

        func resolved(in locale: Locale) -> String {
            switch self {
            case let .text(resource): resource.resolved(in: locale)
            case let .stopped(reason): StopReasonText.make(reason, locale: locale)
            case let .unread(turn): Self.unreadText(turn, locale: locale)
            }
        }

        /// `resolved` as VoiceOver reads it: "Turn 7, Unread, 2 files
        /// +94 −2", the facts as a list.
        func spoken(in locale: Locale) -> String {
            guard case let .unread(turn) = self, let numbers = turn.numbers else {
                return AgentStatusText.spoken(resolved(in: locale), locale: locale)
            }
            return AgentStatusText.spokenList(
                [
                    ReceiptText.spokenTurns(numbers, locale: locale),
                    LocalizedStringResource("Unread").resolved(in: locale),
                    ReceiptText.changes(turn.changes, locale: locale)
                ],
                locale: locale
            )
        }

        /// "T7 Unread · 2 files +94 −2", "T3 Unread · No file changes". An
        /// episode no turn record stands for is only "Unread".
        private static func unreadText(_ turn: UnreadTurn, locale: Locale) -> String {
            guard let numbers = turn.numbers else {
                return LocalizedStringResource("Unread").resolved(in: locale)
            }
            let turns = ReceiptText.turns(numbers, locale: locale)
            let changes = ReceiptText.changes(turn.changes, locale: locale)
            return LocalizedStringResource(
                "\(turns) Unread · \(changes)",
                comment: "Needs Attention row: the unread turns and what they changed, as in T7 Unread · 2 files +94 −2"
            ).resolved(in: locale)
        }
    }
}

extension NeedsAttentionListModel {
    /// The list as the app's session and approval ledger describe it.
    @MainActor
    init(
        queue: AttentionQueue,
        session: WorkspaceSession,
        approvals: ApprovalPresentationStore,
        projectsInOtherWindows: Set<UUID> = [],
        windowProjectID: UUID??,
        projectsInWindows: Set<UUID>? = nil,
        locale: Locale
    ) {
        self.init(
            items: queue.items,
            names: { Self.names(of: $0, in: session, locale: locale) },
            request: { approvals.ledger.entries[$0].map { ApprovalRequestText($0.presentation) } },
            projectsInOtherWindows: projectsInOtherWindows,
            windowProjectID: windowProjectID,
            projectsInWindows: projectsInWindows,
            locale: locale
        )
    }

    /// A pane's item is named as its workspace's sidebar row is (a label,
    /// else the branch, the conversation, or the folder; not the terminal's own
    /// title, which an agent sets to something generic), and placed by the
    /// tab's project; a request no pane is known for, by its agent; a
    /// session row by its worktree folder. A row the person labeled is
    /// placed by its project and its branch ("weir / feat/login",
    /// `WorkspaceSession.rowCheckout(of:)`), as its sidebar row shows it.
    @MainActor
    static func names(of item: AttentionItem, in session: WorkspaceSession, locale: Locale) -> Names {
        switch item.subject {
        case let .runtime(_, provider, paneID, tabID, _):
            guard let tab = tabID.flatMap({ session.tab($0) }) ?? session.tab(containing: paneID) else {
                return Names(title: provider.rawValue.capitalized, place: nil)
            }
            let rowName = SessionSidebarModel.rowName(of: tab.container, in: session, locale: locale)
            // Which pane, once the row's name alone leaves two items alike.
            let title = AgentStatusText.joined(
                [rowName] + (session.agentPaneNameAmongNeighbors(paneID).map { [$0] } ?? []),
                locale: locale
            )
            // Placed by its project: the title is the row's name already.
            // The scratch row's name is its place. A row the person labeled
            // is placed by its branch too, as its sidebar row shows it.
            let place = tab.container.projectID.flatMap { session.project($0)?.name }.map {
                AgentStatusText.place(project: $0, checkout: session.rowCheckout(of: tab.container)?.shown)
            }
            return Names(title: title, place: place)
        case let .sessionRow(projectID, worktreeRoot):
            // The row's name, as the sidebar shows it: the branch, not the
            // folder, which the placement prefixes with the repository's.
            // A labeled row's place adds its branch, as its sidebar row does.
            let project = projectID.flatMap { session.project($0) }
            let worktree = project?.worktrees.first { item.subject.isSessionRow(at: $0.workingDirectory) }
            let row = project.flatMap { project in worktree.map { ContainerID.worktree(projectID: project.id, worktreeID: $0.id) } }
            return Names(
                title: row.flatMap { session.rowName(of: $0)?.text } ?? worktreeRoot.lastPathComponent,
                place: project.map { AgentStatusText.place(project: $0.name, checkout: row.flatMap { session.rowCheckout(of: $0)?.shown }) }
            )
        case let .unplaced(provider):
            return Names(title: provider.rawValue.capitalized, place: nil)
        }
    }
}

/// Which row of the Needs Attention list the keyboard is on, and whether it
/// is on the row itself or on one of the row's buttons. The row moves as
/// every keyboard-driven list's does (`ListKeyboardSelection`). The list
/// gives a row one button at most (Answer…); the menu bar adds
/// the ones under the row that act in place, and a control in its
/// heading (⋯) that ⇧Tab reaches from the top.
struct NeedsAttentionListSelection: Equatable {
    /// Where the keyboard is when the list opens.
    enum Opening: Equatable, Sendable {
        /// On the first row, as a list opened from the keyboard (⌘J) is.
        case firstRow
        /// On no row, as a system menu opens: the menu bar's list is
        /// opened with the pointer, and a row lights only once ↓, ↑, or the
        /// pointer reaches it.
        case nothing
    }

    private var row: ListKeyboardSelection<AttentionItemID>
    /// Which of the selected row's buttons Tab moved the keyboard onto, in
    /// the order the row lays them out, so Return presses it rather than
    /// opening the row; `nil` on the row itself.
    private(set) var actionIndex: Int?
    /// The keyboard is on the heading's control rather than on a row.
    private(set) var isOnHeading = false
    /// Whether a list with no row selected keeps it so as the rows change
    /// (`reconcile`): a list that opened on nothing stays on nothing until
    /// the person moves.
    private let opensOnNothing: Bool

    var rowID: AttentionItemID? {
        row.id
    }

    var isOnAction: Bool {
        actionIndex != nil
    }

    /// What VoiceOver hears as the list's value: the title of the row the
    /// keys are on, empty while they are on none or on the heading. The
    /// list, not a row, holds the keyboard, so without it VoiceOver would
    /// say nothing as ↑↓ move.
    func spokenRow(in rows: [NeedsAttentionListModel.Row]) -> String {
        guard !isOnHeading else { return "" }
        return rows.first { $0.id == rowID }?.title ?? ""
    }

    /// The buttons a list row has: its one button, when it offers one.
    static func listActionCount(_ row: NeedsAttentionListModel.Row) -> Int {
        row.action == nil ? 0 : 1
    }

    init(rows: [NeedsAttentionListModel.Row], opening: Opening = .firstRow) {
        row = ListKeyboardSelection(ids: rows.map(\.id))
        opensOnNothing = opening == .nothing
        if opensOnNothing {
            row.clear()
        }
    }

    /// ↑ (`forward` false) or ↓, stopping at either end. From the heading,
    /// either goes back to the row the keyboard left.
    mutating func move(forward: Bool, in rows: [NeedsAttentionListModel.Row]) {
        actionIndex = nil
        guard !isOnHeading else {
            isOnHeading = false
            return
        }
        row.move(forward: forward, in: rows.map(\.id))
    }

    /// Tab (or ⇧Tab, `backward`) through the selected row: the row, then
    /// each of its `count` buttons in order, then the row again. A row
    /// with no button keeps the keyboard on itself.
    mutating func nextAction(count: Int, backward: Bool = false) {
        guard count > 0 else {
            actionIndex = nil
            return
        }
        // The row is the place before the first button and after the last.
        let place = actionIndex.map { $0 + 1 } ?? 0
        let next = (place + (backward ? count : 1)) % (count + 1)
        actionIndex = next == 0 ? nil : next - 1
    }

    /// Tab where the heading has a control: as `nextAction`, except that ⇧Tab
    /// on the first row itself, or in an empty list, goes up to the heading,
    /// and Tab from there comes back down to the row. With no row selected
    /// (a list opened on nothing), Tab goes to the first row and ⇧Tab to
    /// the heading, so the keys enter the list where the pointer did not.
    mutating func nextControl(count: Int, backward: Bool, in rows: [NeedsAttentionListModel.Row]) {
        if isOnHeading {
            if !backward, let first = rows.first {
                isOnHeading = false
                actionIndex = nil
                // Down from the heading lands on the row it came from, or
                // on the first when none was lit.
                if rowID == nil {
                    row.select(first.id)
                }
            }
            return
        }
        if backward, actionIndex == nil, rows.first?.id == rowID || rowID == nil {
            isOnHeading = true
            return
        }
        if rowID == nil, let first = rows.first {
            select(first.id)
            return
        }
        nextAction(count: count, backward: backward)
    }

    mutating func select(_ id: AttentionItemID) {
        row.select(id)
        actionIndex = nil
        isOnHeading = false
    }

    /// The pointer left `id`'s row: the row goes dark as a system menu's
    /// does, unless the keys are on one of its buttons, which the pointer
    /// does not take from them. Another row keeps the selection it has.
    mutating func deselect(_ id: AttentionItemID) {
        guard rowID == id, actionIndex == nil else { return }
        row.clear()
    }

    /// Keeps the selection when the list changes under it. An item that
    /// left (answered, read) hands the selection to the row that took its
    /// place, or to the last row; the keyboard is then on that row, not
    /// its button. A row that kept its place keeps the keyboard on the same
    /// button (`controls`, in Tab's order), wherever that button now is,
    /// and puts it back on the row when that button went. The heading keeps
    /// the keyboard whatever the rows do, and a list opened on nothing with
    /// nothing selected yet stays so: rows arriving do not light one.
    mutating func reconcile<Control: Equatable>(
        previous: [NeedsAttentionListModel.Row],
        current: [NeedsAttentionListModel.Row],
        previousControls: (AttentionItemID) -> [Control],
        currentControls: (AttentionItemID) -> [Control]
    ) {
        if opensOnNothing, rowID == nil {
            return
        }
        guard row.reconcile(previous: previous.map(\.id), current: current.map(\.id)) else {
            actionIndex = nil
            return
        }
        guard let index = actionIndex, let id = rowID else { return }
        let before = previousControls(id)
        actionIndex = before.indices.contains(index) ? currentControls(id).firstIndex(of: before[index]) : nil
    }

    /// The list's form: a row's one button is its `RowAction`.
    mutating func reconcile(previous: [NeedsAttentionListModel.Row], current: [NeedsAttentionListModel.Row]) {
        func controls(in rows: [NeedsAttentionListModel.Row]) -> (AttentionItemID) -> [NeedsAttentionListModel.RowAction] {
            { id in rows.first { $0.id == id }?.action.map { [$0] } ?? [] }
        }
        reconcile(previous: previous, current: current, previousControls: controls(in: previous), currentControls: controls(in: current))
    }
}

/// How a row of the Needs Attention list was chosen, which decides
/// whether an item of another project opens in a new window. The list's
/// view says only which of these happened; this says what it does.
enum NeedsAttentionListOpening: Equatable {
    /// Return, with ⌘ or without: ⌘⏎ is the decision bar's key, and the
    /// list does not take it for a new window.
    case returnKey
    case click(holdsCommand: Bool)
    /// VoiceOver's "Open in New Window", ⌘-click's stand-in.
    case newWindowAction

    var opensInNewWindow: Bool {
        switch self {
        case .returnKey: false
        case let .click(holdsCommand): holdsCommand
        case .newWindowAction: true
        }
    }
}
