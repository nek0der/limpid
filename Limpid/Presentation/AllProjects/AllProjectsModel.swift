// AllProjectsModel.swift
// Limpid — the all projects sheet: every project's sessions as cards, in three sections, filtered and walked by keys.

import Foundation

/// Every session of every project as a card, under "Needs Attention",
/// "Running", and "Idle", the three layers of a session's state.
/// Commits and pull requests are not a section: they are chips on the
/// card. A value, so what the sheet shows is tested without a window.
struct AllProjectsModel: Equatable {
    enum Section: CaseIterable {
        case needsAttention
        case running
        case idle

        /// Where a session with `glyph` goes: anything blocked or unread
        /// needs the person, a turn in progress runs, and the rest is at
        /// rest. Work an agent left running after its turn is at rest: its
        /// run is finished, as the attention list and the notifications
        /// hold it, and the card's glyph and line say what still runs.
        static func of(_ glyph: SessionRowFact.Glyph) -> Self {
            switch glyph {
            case .needsAnswer, .needsApproval, .needsResponse, .stopped, .unread, .unreadWorkingAfterTurn: .needsAttention
            case .running: .running
            case .idle, .workingAfterTurn, .unknown, .shell: .idle
            }
        }

        /// The glyph beside the section's heading, from the one set every
        /// place draws: a question for what needs the person.
        var glyph: SessionRowFact.Glyph {
            switch self {
            case .needsAttention: .needsAnswer
            case .running: .running
            case .idle: .idle
            }
        }
    }

    /// Where the card's project is shown, when the sheet says so: in
    /// this window, or in another, which opening the card brings forward
    /// rather than switching this one.
    enum WindowNote: Equatable {
        case current
        case otherWindow
    }

    /// The one button a card carries, besides opening it.
    enum Action: Equatable {
        /// Opens the approval card for the request.
        case answer(ApprovalKey)
        /// A request Limpid does not hold, answered in the TUI: goes to
        /// the pane.
        case openPane

        var title: LocalizedStringResource {
            switch self {
            case .answer: "Answer…"
            case .openPane: "Open Pane"
            }
        }
    }

    struct Card: Identifiable, Equatable {
        let id: ContainerID
        let projectID: UUID
        let projectName: String
        let paletteIndex: Int?
        /// The branch of the card's folder; `nil` when not known.
        let branch: String?
        let name: String
        /// Where `name` is cut, as its row's name is
        /// (`SessionSidebarModel.Row.nameTruncation`).
        let nameTruncation: SupervisionTruncation
        let glyph: SessionRowFact.Glyph
        /// What the session does now: the row's fact, in words.
        let factText: String
        let chips: [SessionHeaderModel.GitChip]
        /// The agent the card speaks for, as its row's badge shows it, and
        /// the badge's words ("Cl"). A session with more than one agent
        /// shows the one the card speaks for here too: the badge is
        /// the card's one mark of its agent, as it is the row's.
        let badge: SessionRowFact.Badge
        let badgeText: String
        /// What the badge says to VoiceOver (`badgeSpokenName(...)`).
        let badgeSpokenName: String
        let windowNote: WindowNote?
        let action: Action?
        /// What opening the card goes to: the item it shows, else its
        /// session.
        let leadItemID: AttentionItemID?
        /// The pane the card's last lines are read from.
        let leadPaneID: UUID?
        /// Where `factText` is cut, as its row's fact is
        /// (`SupervisionTruncation.fact`).
        let factTruncation: SupervisionTruncation
        /// The pull request its row shows as a mark beside the badge,
        /// whatever the session's state (`SessionRowFact.pullRequest`);
        /// the card shows it in the same place.
        var pullRequest: SessionRowFact.PullRequest?
        /// This is the folder the card is placed by in place of its branch, for a
        /// card the person named (`SessionSidebarModel.Row.folder`).
        var folder: String?

        var section: Section {
            Section.of(glyph)
        }

        /// The card's project is shown by no window, this one included:
        /// ⌘-click or ⌘Return opens it in a new window, which the
        /// card's tooltip and VoiceOver action say. Any other card goes
        /// where it would without ⌘.
        var opensInNewWindow: Bool {
            windowNote == nil
        }

        /// Whether the card holds every word of `query`, ignoring case:
        /// in its project's name, its branch, the folder it is placed by,
        /// or its own name.
        func matches(_ query: String) -> Bool {
            let words = query.split(whereSeparator: \.isWhitespace)
            guard !words.isEmpty else { return true }
            let text = [projectName, branch ?? "", folder ?? "", name].joined(separator: " ")
            return words.allSatisfy { text.localizedStandardContains($0) }
        }
    }

    struct Group: Equatable {
        let section: Section
        let cards: [Card]
    }

    /// The sections that hold a card, in order.
    let groups: [Group]
    /// Every item that needs the person, the title bar's number.
    let attentionCount: Int
    /// The sessions running a turn, among the cards shown.
    let runningCount: Int
    /// What the sheet says in place of its cards, `nil` while it has
    /// some: no project at all, projects but no card (no worktree has a
    /// tab open or an item waiting), or cards the filter matches none of.
    let emptyState: EmptyState?

    /// `cards` in the order the projects and their sessions come, each
    /// staying in its project's order within its section.
    /// `hasProjects` is whether the session has any project, which tells
    /// a sheet with nothing added from one whose worktrees are all closed.
    init(cards: [Card], query: String, attentionCount: Int, hasProjects: Bool = true) {
        let shown = cards.filter { $0.matches(query) }
        groups = Section.allCases.compactMap { section in
            let inSection = shown.filter { $0.section == section }
            return inSection.isEmpty ? nil : Group(section: section, cards: inSection)
        }
        self.attentionCount = attentionCount
        runningCount = shown.count { $0.section == .running }
        emptyState = if !shown.isEmpty {
            nil
        } else if !hasProjects {
            .noProjects
        } else if cards.isEmpty {
            .noOpenWorktrees
        } else {
            .noMatchingWorktrees
        }
    }

    /// Whether the header shows its counts: not with no card at all, where
    /// "0 · 0" says nothing the empty state does not; still while a filter
    /// hides every card, since the cards are there.
    var showsCounts: Bool {
        emptyState != .noOpenWorktrees && emptyState != .noProjects
    }

    /// The cards in the order they are drawn.
    var cards: [Card] {
        groups.flatMap(\.cards)
    }
}

/// The selected card, held by the session it stands for rather than its
/// place, so a card that moves to another section as its state changes
/// stays selected.
struct AllProjectsSelection: Equatable {
    /// One step of the keys: a card at a time sideways, a row of the
    /// grid's columns up and down.
    enum Step: Equatable {
        case previous
        case next
        case up
        case down
    }

    /// The most cards a row of the grid holds, in a sheet wide enough.
    static let maxColumns = 3

    /// The cards a row of the grid holds in `width`: as many as fit at
    /// `cardMinWidth` each with `spacing` between them, from one up to
    /// `maxColumns`. A fixed three left a card about 180pt wide at the
    /// window's least width, too narrow for its title and its chips.
    static func columns(width: CGFloat, cardMinWidth: CGFloat, spacing: CGFloat) -> Int {
        guard width > 0, cardMinWidth > 0 else { return maxColumns }
        let fitting = Int(((width + spacing) / (cardMinWidth + spacing)).rounded(.down))
        return min(max(fitting, 1), maxColumns)
    }

    /// Which of the sheet's controls Tab put the keyboard on, which
    /// Return presses: the filter (Return opens the selected card), the
    /// selected card's button (Answer… or Open Pane), or the ×. The filter
    /// field keeps AppKit's keyboard throughout, so typing still filters;
    /// this is the control drawn as focused.
    enum Control: Equatable {
        case filter
        case cardAction
        case close
    }

    private(set) var selectedID: ContainerID?
    private(set) var control = Control.filter

    /// Tab (`backward` false) or ⇧Tab: the filter, the selected card's
    /// button when it has one, then the ×, and round to the filter again,
    /// as the Needs Attention list goes from a row to its button
    /// (`NeedsAttentionListSelection`).
    mutating func nextControl(backward: Bool, in cards: [AllProjectsModel.Card]) {
        let hasAction = cards.first { $0.id == selectedID }?.action != nil
        let order: [Control] = hasAction ? [.filter, .cardAction, .close] : [.filter, .close]
        let index = order.firstIndex(of: control) ?? 0
        control = order[(index + (backward ? order.count - 1 : 1)) % order.count]
    }

    /// The keyboard back on the filter: something was typed into it.
    mutating func returnToFilter() {
        control = .filter
    }

    init(selectedID: ContainerID? = nil) {
        self.selectedID = selectedID
    }

    /// Keeps the selection on its session while that is shown, else the
    /// first card.
    mutating func reconcile(with cards: [AllProjectsModel.Card]) {
        // A button that went (its request answered elsewhere) gives the
        // keyboard back to the filter.
        if control == .cardAction, cards.first(where: { $0.id == selectedID })?.action == nil {
            control = .filter
        }
        if let selectedID, cards.contains(where: { $0.id == selectedID }) {
            return
        }
        selectedID = cards.first?.id
        control = control == .close ? .close : .filter
    }

    /// Moves along `cards` as drawn: within a section a row is `columns`
    /// cards, as the grid lays them out at its width, and a step that
    /// leaves one section enters the next or the previous. Stays put at
    /// either end.
    mutating func move(_ step: Step, in groups: [AllProjectsModel.Group], columns: Int) {
        // The arrows choose a card, from the filter.
        control = .filter
        let cards = groups.flatMap(\.cards)
        guard let current = selectedID.flatMap({ id in cards.firstIndex { $0.id == id } }) else {
            selectedID = cards.first?.id
            return
        }
        let target = switch step {
        case .previous: current - 1
        case .next: current + 1
        case .up: Self.vertical(from: current, by: -1, in: groups, columns: max(columns, 1))
        case .down: Self.vertical(from: current, by: 1, in: groups, columns: max(columns, 1))
        }
        selectedID = cards[min(max(target, 0), cards.count - 1)].id
    }

    /// The card a row up or down from `index`: the same column in the
    /// next row of its section, else that column (or the last card) in the
    /// neighboring section's nearest row.
    private static func vertical(from index: Int, by direction: Int, in groups: [AllProjectsModel.Group], columns: Int) -> Int {
        var start = 0
        for (offset, group) in groups.enumerated() {
            let range = start..<(start + group.cards.count)
            defer { start += group.cards.count }
            guard range.contains(index) else { continue }
            let local = index - range.lowerBound
            let row = local / columns
            let lastRow = (group.cards.count - 1) / columns
            let column = local % columns
            // Another row of this section: the same column, or its last
            // card when that row is shorter.
            if direction > 0, row < lastRow {
                return range.lowerBound + min(local + columns, group.cards.count - 1)
            }
            if direction < 0, row > 0 {
                return index - columns
            }
            if direction > 0, offset + 1 < groups.count {
                let next = groups[offset + 1].cards
                return range.upperBound + min(column, next.count - 1)
            }
            if direction < 0, offset > 0 {
                let previous = groups[offset - 1].cards
                let lastRowStart = (previous.count - 1) / columns * columns
                return range.lowerBound - previous.count + min(lastRowStart + column, previous.count - 1)
            }
            return index
        }
        return index
    }
}
