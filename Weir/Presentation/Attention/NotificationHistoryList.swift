// NotificationHistoryList.swift
// Weir — the notification history by day, then by source, with each source's read rows past the first few folded.

import Foundation
import WeirDomain

/// Where a notification came from, for the history to gather its rows
/// under one heading: the pane, and whether the agent in it or its shell
/// spoke. Worked out as the panel draws, never stored.
///
/// The pane is the unit because whether a source is closed is the pane's:
/// "Closed Pane" is then said once, on the heading. A command that finished
/// in the pane an agent ran in is its shell's, not the agent's, so the
/// heading's badge never disagrees with the row under it.
struct NotificationSourceKey: Hashable, Sendable {
    enum Place: Hashable, Sendable {
        case pane(UUID)
        case container(ContainerID)
        case label(String)
        case none
    }

    enum Speaker: Hashable, Sendable {
        case agent
        case shell
    }

    let place: Place
    let speaker: Speaker

    /// The first the entry has of its pane, its container, and the label it
    /// recorded.
    init(_ entry: NotificationEntry) {
        place = if let paneID = entry.paneID {
            .pane(paneID)
        } else if let container = entry.containerID {
            .container(container)
        } else if let label = entry.containerLabel, !label.isEmpty {
            .label(label)
        } else {
            .none
        }
        speaker = entry.kind.isFromACommand ? .shell : .agent
    }
}

/// The history's day headings: relative names, as the entries a person
/// opens the panel for are almost always the running session's; anything
/// older is one "Earlier" rather than a heading per date.
enum NotificationHistoryDay: Hashable, Sendable {
    case today
    case yesterday
    case earlier

    static func of(_ date: Date, now: Date, calendar: Calendar) -> Self {
        if calendar.isDate(date, inSameDayAs: now) {
            return .today
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return .yesterday
        }
        return .earlier
    }

    var title: LocalizedStringResource {
        switch self {
        case .today: "Today"
        case .yesterday: "Yesterday"
        case .earlier: "Earlier"
        }
    }
}

/// The history as the panel lists it: under each day, a heading for
/// each source and its rows, newest first. Sources come in the order of
/// their newest row, and nothing else reorders them, so where a new
/// notification lands can be foreseen.
///
/// A source shows every unread row and every row whose agent still waits,
/// then read rows up to `shownPerSource`; the rest of its read rows fold
/// into "n more", which opens that source alone. A row the person has not
/// seen, or still has to answer, is never folded away.
///
/// What the panel needs of the app comes in as functions, each asked once
/// per row or once per source: whether the agent still waits, whether the
/// source's pane can still be opened, and where it is.
struct NotificationHistoryList: Equatable {
    /// A source on one day: a source that spans two days has a heading on
    /// each.
    struct SourceID: Hashable, Sendable {
        let day: NotificationHistoryDay
        let key: NotificationSourceKey
    }

    /// A source's heading (`NotificationHistoryHeading`).
    typealias Heading = NotificationHistoryHeading

    struct Row: Equatable {
        let entry: NotificationEntry
        let source: SourceID
        /// Whether the agent is still in the state the row reported; `nil`
        /// for a row with nothing live to ask.
        let liveStatus: NotificationLiveStatus?
        /// The source's: its rows rest, muted, once its pane is gone.
        let isClosed: Bool
        /// Whether choosing the row opens what it names: the click, the
        /// menu's Open Pane, and VoiceOver's action all ask this. A closed
        /// source's row only marks itself read.
        let opensPane: Bool
        /// The tab a shell's heading names, so a command's row names its
        /// own only when it was another; `nil` for an agent's.
        let headingTab: String?
        /// Where the row stands among its source's lines, which are drawn
        /// together in one edged group under the heading.
        var isFirstOfSource = false
        /// No row and no fold under it in its source.
        var isLastOfSource = false
    }

    struct Source: Equatable {
        let id: SourceID
        /// Every row, newest first.
        let entries: [NotificationEntry]
        /// The rows shown, newest first.
        let shown: [Row]
        /// The read rows folded away, or that would be while the source is
        /// open.
        let foldableCount: Int
        let isExpanded: Bool
        let heading: Heading

        /// The newest row, which names the heading's agent and tab.
        var newest: NotificationEntry? {
            entries.first
        }
    }

    enum ItemID: Hashable, Sendable {
        case day(NotificationHistoryDay)
        case heading(SourceID)
        case row(UUID)
        case fold(SourceID)
    }

    /// One line of the list, flat, so a long history stays lazily drawn.
    enum Item: Identifiable, Equatable {
        case day(NotificationHistoryDay, isFirst: Bool)
        /// `isFirstOfDay`: right under the day's heading, with no room above.
        case heading(Source, isFirstOfDay: Bool)
        case row(Row)
        /// "n more" while folded; "Show Less" while open.
        case fold(Source, count: Int, isExpanded: Bool)

        var id: ItemID {
            switch self {
            case let .day(day, _): .day(day)
            case let .heading(source, _): .heading(source.id)
            case let .row(historyRow): .row(historyRow.entry.id)
            case let .fold(source, _, _): .fold(source.id)
            }
        }

        /// Whether the keyboard stops on it: the rows and the fold, not the
        /// headings.
        var isSelectable: Bool {
            switch self {
            case .row, .fold: true
            case .day, .heading: false
            }
        }
    }

    static let shownPerSource = 3

    let sources: [Source]
    let items: [Item]

    /// What ↑ and ↓ move through, in order.
    var selectableIDs: [ItemID] {
        items.filter(\.isSelectable).map(\.id)
    }

    /// `entries` may come in any order. A row stamped after `now` (a clock
    /// set back) is placed as if it came now, so it neither leads the list
    /// forever nor falls outside every day.
    init(
        entries: [NotificationEntry],
        now: Date,
        calendar: Calendar,
        expanded: Set<SourceID>,
        liveStatus: (NotificationEntry) -> NotificationLiveStatus?,
        canOpen: (NotificationEntry) -> Bool,
        place: (NotificationEntry) -> NotificationHistoryRowText.Place?,
        projectsInOtherWindows: Set<UUID>
    ) {
        // Stable, so rows of the same instant keep the store's order.
        let ordered = entries.enumerated()
            .map { (offset: $0.offset, entry: $0.element, time: min($0.element.timestamp, now)) }
            .sorted { lhs, rhs in lhs.time != rhs.time ? lhs.time > rhs.time : lhs.offset < rhs.offset }
        var order: [SourceID] = []
        var rows: [SourceID: [NotificationEntry]] = [:]
        for stamped in ordered {
            let id = SourceID(
                day: NotificationHistoryDay.of(stamped.time, now: now, calendar: calendar),
                key: NotificationSourceKey(stamped.entry)
            )
            if rows[id] == nil {
                order.append(id)
            }
            rows[id, default: []].append(stamped.entry)
        }

        // Where each source is, asked once, of its newest row; then how many
        // agent sources of one day share an agent and a place's name, which
        // decides whether their headings name the tab.
        let places = order.map { id in rows[id]?.first.flatMap(place) }
        let agents = order.map { id in Self.agent(of: rows[id] ?? []) }
        var namesakes: [Namesake: Int] = [:]
        for (index, id) in order.enumerated() where id.key.speaker == .agent {
            namesakes[Namesake(day: id.day, agent: agents[index], place: places[index]?.name ?? ""), default: 0] += 1
        }

        // Newest first, the days come in their own order, and each source
        // where its newest row is.
        sources = order.enumerated().map { index, id in
            let entries = rows[id] ?? []
            let placeName = places[index]?.name ?? ""
            let note: Heading.Note? = if case .pane = id.key.place, let newest = entries.first, !canOpen(newest) {
                .paneClosed
            } else if let place = places[index],
                      NotificationHistoryRowText.isInAnotherWindow(place, projectsInOtherWindows: projectsInOtherWindows)
            {
                .otherWindow
            } else {
                nil
            }
            let badge: Heading.Badge = switch id.key.speaker {
            case .shell: .shell
            case .agent: agents[index].map(Heading.Badge.agent) ?? .none
            }
            let heading = Heading(
                badge: badge,
                place: placeName,
                tabTitle: entries.first?.tabTitleSnapshot,
                namesTab: id.key.speaker == .shell
                    || (namesakes[Namesake(day: id.day, agent: agents[index], place: placeName)] ?? 0) > 1,
                note: note
            )
            return Self.source(id, entries: entries, heading: heading, isExpanded: expanded.contains(id), liveStatus: liveStatus)
        }

        var items: [Item] = []
        var day: NotificationHistoryDay?
        for source in sources {
            let isFirstOfDay = source.id.day != day
            if isFirstOfDay {
                items.append(.day(source.id.day, isFirst: day == nil))
                day = source.id.day
            }
            items.append(.heading(source, isFirstOfDay: isFirstOfDay))
            items += source.shown.map(Item.row)
            if source.foldableCount > 0 {
                items.append(.fold(source, count: source.foldableCount, isExpanded: source.isExpanded))
            }
        }
        self.items = items
    }

    /// Agent sources of one day that read alike on their headings.
    private struct Namesake: Hashable {
        let day: NotificationHistoryDay
        let agent: AgentKind?
        let place: String
    }

    /// Every row that never folds (unread, or still waited on), then read
    /// rows, newest first, until the source shows `shownPerSource`; the
    /// read rows left over fold.
    private static func source(
        _ id: SourceID,
        entries: [NotificationEntry],
        heading: Heading,
        isExpanded: Bool,
        liveStatus: (NotificationEntry) -> NotificationLiveStatus?
    ) -> Source {
        let rows = entries.map { entry in
            Row(
                entry: entry,
                source: id,
                liveStatus: liveStatus(entry),
                isClosed: heading.isClosed,
                opensPane: !heading.isClosed,
                headingTab: id.key.speaker == .shell ? heading.tabTitle : nil
            )
        }
        let pinned = rows.map(isPinned)
        var room = max(0, shownPerSource - pinned.count(where: \.self))
        var shown: [Row] = []
        var folded = 0
        for (candidate, isPinned) in zip(rows, pinned) {
            if isPinned {
                shown.append(candidate)
            } else if room > 0 {
                shown.append(candidate)
                room -= 1
            } else {
                folded += 1
                if isExpanded {
                    shown.append(candidate)
                }
            }
        }
        // The fold, when there is one, closes the group.
        for index in shown.indices {
            shown[index].isFirstOfSource = index == shown.startIndex
            shown[index].isLastOfSource = folded == 0 && index == shown.index(before: shown.endIndex)
        }
        return Source(id: id, entries: entries, shown: shown, foldableCount: folded, isExpanded: isExpanded, heading: heading)
    }

    /// The opened sources after the fold of `source` is chosen: opened if it
    /// was folded, folded again if it was open.
    static func toggled(_ source: SourceID, in expanded: Set<SourceID>) -> Set<SourceID> {
        expanded.contains(source) ? expanded.subtracting([source]) : expanded.union([source])
    }

    /// The agent a source's rows name, newest first: the first row whose
    /// event says, else the first whose run's ID begins with it. The newest
    /// row alone left a heading without its badge whenever that row was
    /// written before events were recorded, though an older one said which
    /// agent it was. `nil` when none says.
    static func agent(of entries: [NotificationEntry]) -> AgentKind? {
        if let agent = entries.lazy.compactMap(\.event?.agent).first {
            return agent
        }
        return entries.lazy.compactMap { entry in entry.runtimeID.flatMap(Self.agent(inRuntimeID:)) }.first
    }

    /// The agent a run's ID begins with (`AgentRuntimePresentation.id`:
    /// the provider, a colon, then the run or, for a record from before
    /// run IDs, the pane). Read only for the badge, never to find the run.
    static func agent(inRuntimeID runtimeID: String) -> AgentKind? {
        guard let provider = runtimeID.split(separator: ":", maxSplits: 1).first else { return nil }
        return AgentKind(rawValue: String(provider))
    }

    /// Never folded away: what the person has not seen, and what the agent
    /// still waits on.
    static func isPinned(_ historyRow: Row) -> Bool {
        !historyRow.entry.isRead || historyRow.liveStatus == .stillWaiting
    }
}

/// A source's heading: its badge, where it ran, the tab when the heading
/// names it, and the note that gives way first.
struct NotificationHistoryHeading: Equatable {
    enum Badge: Equatable {
        case agent(AgentKind)
        case shell
        /// An agent's entry that never said which (history from before
        /// events and run IDs), or one that recorded no place either: the
        /// heading wears the generic place mark, so it has the same shape
        /// as the others.
        case none
    }

    enum Note: Equatable {
        /// The source's pane is gone. Only a source that names a pane
        /// says so: one placed by its container or label never had one
        /// to lose.
        case paneClosed
        /// Another window shows the source's project.
        case otherWindow
    }

    /// The heading's words.
    struct Words: Equatable {
        let title: String
        let tab: String?
        let note: String?
        /// Where the title is cut: a place ("alpha / feat-login") keeps its
        /// project and its branch's end; a tab standing in for one is cut
        /// as `tabTruncation` says; an agent's name at its end.
        var titleTruncation = SupervisionTruncation.name
        /// Where the tab is cut, as the strip cuts it. Read from the whole
        /// title: `shortTab` may already have cut a path's start, and what
        /// is left need not read as a path.
        var tabTruncation = SupervisionTruncation.name

        /// Whether the tab leads the heading, the place after it. A short
        /// tab tells this source from the others in one place at a glance;
        /// one longer than the place is usually a prompt an agent set as
        /// the title, which would fill the line and repeat the row under it.
        var isTabLeading: Bool {
            guard let tab else { return false }
            return tab.count <= title.count
        }
    }

    let badge: Badge
    /// Where the source ran; empty when nothing names it (an entry
    /// from before places were recorded).
    let place: String
    /// The newest row's tab.
    let tabTitle: String?
    /// Whether the heading names the tab beside the place: always for a
    /// shell, and for an agent only beside another source of the same
    /// agent in a place of the same name.
    let namesTab: Bool
    /// Closed says more than which window: the pane is in none.
    let note: Note?

    var isClosed: Bool {
        note == .paneClosed
    }

    /// "Closed Pane": a closed source's note, and the first line of its
    /// rows' tooltips.
    static let paneClosed = LocalizedStringResource(
        "Closed Pane",
        comment: "Notification history: a source's heading, when its pane is gone"
    )

    /// The most of a tab's title the heading says. An agent sets the
    /// terminal's title to whatever it likes; Codex sets it to the prompt,
    /// thousands of characters for a harness's, which offered whole would
    /// take the line from the place.
    static let tabTitleLimit = 40

    /// A tab's title on one line, cut to `tabTitleLimit`; `nil` when it is
    /// blank. Cut where the strip cuts it (`SupervisionTruncation.title`):
    /// a path keeps its end, the folder that tells two shells apart, and
    /// anything else its start.
    static func shortTab(_ title: String) -> String? {
        let line = title.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !line.isEmpty else { return nil }
        guard line.count > tabTitleLimit else { return line }
        if SupervisionTruncation.isPathTitle(line) {
            return "…" + String(line.suffix(tabTitleLimit - 1)).trimmingCharacters(in: .whitespaces)
        }
        return String(line.prefix(tabTitleLimit - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// The title "alpha / feat-login", the tab "zsh", the note "Closed
    /// Pane"; the view sets the tab and the note off with the separator.
    /// With no place, the tab names the source, then the agent, then that
    /// the place is not known, so a heading never begins with a separator.
    func words(locale: Locale) -> Words {
        let tab = tabTitle.flatMap(Self.shortTab)
        let tabTruncation = tabTitle.map(SupervisionTruncation.title) ?? .name
        let noteText = note.map { note in
            switch note {
            case .paneClosed:
                Self.paneClosed.resolved(in: locale)
            case .otherWindow:
                LocalizedStringResource("Other Window").resolved(in: locale)
            }
        }
        guard place.isEmpty else {
            return Words(
                title: place,
                tab: namesTab ? tab : nil,
                note: noteText,
                titleTruncation: .branch,
                tabTruncation: tabTruncation
            )
        }
        if let tab {
            return Words(title: tab, tab: nil, note: noteText, titleTruncation: tabTruncation)
        }
        return Words(
            title: speakerName(locale: locale) ?? LocalizedStringResource(
                "Unknown place",
                comment: "Notification history: a source's heading, for an entry that recorded neither where it ran nor its tab"
            ).resolved(in: locale),
            tab: nil,
            note: noteText
        )
    }

    /// What VoiceOver reads for the heading: "alpha, feat-login,
    /// Claude, Closed Pane"; the agent's name once, when it is also the
    /// heading's title.
    func spokenLabel(locale: Locale) -> String {
        let words = words(locale: locale)
        let speaker = speakerName(locale: locale)
        return AgentStatusText.spokenList(
            [
                AgentStatusText.spokenPlace(words.title, locale: locale),
                speaker == words.title ? "" : speaker ?? "",
                words.tab ?? "",
                words.note ?? ""
            ],
            locale: locale
        )
    }

    /// What VoiceOver names the source by on its fold, read apart from the
    /// heading: the title, and a shell's tab with it, since a pane's shell
    /// is told apart by its tab ("alpha, zsh").
    func foldName(locale: Locale) -> String {
        let words = words(locale: locale)
        let title = AgentStatusText.spokenPlace(words.title, locale: locale)
        guard badge == .shell, let tab = words.tab else { return title }
        return AgentStatusText.spokenList([title, tab], locale: locale)
    }

    /// "Claude", "Shell"; `nil` when the entry never said which agent.
    private func speakerName(locale: Locale) -> String? {
        switch badge {
        case let .agent(kind): SessionRowFactText.agentName(.agent(kind), locale: locale)
        case .shell: SessionRowFactText.agentName(.shell, locale: locale)
        case .none: nil
        }
    }
}
