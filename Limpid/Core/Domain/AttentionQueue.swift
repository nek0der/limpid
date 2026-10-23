// AttentionQueue.swift
// Limpid — the attention list in arrival order, and which item leads a pane.

import Foundation

/// The attention list: every item in the order it arrived.
///
/// The list is never re-sorted. An item keeps its place while its content
/// changes (a request going from held to sending, say), so the row the
/// person is looking at does not jump; only insertion and removal change
/// the order. The queue numbers the items itself, so two sources inserting
/// in the same pass cannot hand out the same position.
struct AttentionQueue: Equatable, Sendable {
    private(set) var items: [AttentionItem] = []
    private var nextSequence: UInt64 = 1

    /// Appends a new item. Returns `false`, leaving the queue unchanged,
    /// when an item with this ID is already in it: a source that reports the
    /// same request on every pass must not move it to the end.
    @discardableResult
    mutating func insert(
        id: AttentionItemID,
        kind: AttentionItemKind,
        subject: AttentionSubject,
        arrivedAt: Date
    ) -> Bool {
        guard !items.contains(where: { $0.id == id }) else { return false }
        items.append(AttentionItem(
            id: id,
            kind: kind,
            subject: subject,
            arrivalSequence: nextSequence,
            arrivedAt: arrivedAt
        ))
        nextSequence += 1
        return true
    }

    /// Replaces an item's content in place, and its subject when one is
    /// given (the pane moved to another tab, or a tmux session is now seen
    /// through another pane). Does nothing for an ID that is not in the queue.
    mutating func update(id: AttentionItemID, kind: AttentionItemKind, subject: AttentionSubject? = nil) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let item = items[index]
        items[index] = AttentionItem(
            id: item.id,
            kind: kind,
            subject: subject ?? item.subject,
            arrivalSequence: item.arrivalSequence,
            arrivedAt: item.arrivedAt
        )
    }

    mutating func remove(_ id: AttentionItemID) {
        items.removeAll { $0.id == id }
    }

    /// The item `id` while the queue holds it.
    func item(_ id: AttentionItemID) -> AttentionItem? {
        items.first { $0.id == id }
    }

    func items(inPane paneID: UUID) -> [AttentionItem] {
        items.filter { $0.subject.paneID == paneID }
    }

    func counts() -> AttentionCounts {
        Self.counts(of: items)
    }

    /// The counts of one project's items, for the project menu and the
    /// mark beside the project's name.
    func counts(inProject projectID: UUID) -> AttentionCounts {
        Self.counts(of: items.filter { $0.subject.projectID == projectID })
    }

    /// The counts of the items in projects other than `projectID`, for the
    /// mark beside the project's name. Items in no project (scratch tabs, a
    /// request no pane is known for) are not another project's, so they are
    /// left out.
    func counts(inProjectsOtherThan projectID: UUID?) -> AttentionCounts {
        Self.counts(of: items.filter { item in
            item.subject.projectID.map { $0 != projectID } ?? false
        })
    }

    /// The counts of `items`, some of the list's: what a caller that has
    /// grouped the list once counts each group by.
    static func counts(of items: [AttentionItem]) -> AttentionCounts {
        var counts = AttentionCounts()
        for item in items {
            switch item.kind {
            case .approval, .prompt(.approval): counts.approvals += 1
            case .question, .prompt(.question): counts.questions += 1
            case .prompt(.unclassified): counts.prompts += 1
            case .stop: counts.stops += 1
            case .unread: counts.unread += 1
            }
        }
        return counts
    }
}

/// The attention count by kind. Every place that shows "Needs attention n"
/// (title bar, list, all projects, menu bar, Dock) reads `total` from here,
/// so they cannot disagree.
struct AttentionCounts: Equatable, Sendable {
    var approvals = 0
    var questions = 0
    /// Waits at the agent's own prompt we cannot name as an approval or a
    /// question ("Needs response"); the ones we can are counted with
    /// `approvals` and `questions`. All show in one amber glyph.
    var prompts = 0
    var stops = 0
    var unread = 0

    var total: Int {
        approvals + questions + prompts + stops + unread
    }

    /// Whether anything is blocked on the person. The title bar pill is
    /// filled amber for these and only outlined blue for unread turns.
    var hasBlockingItems: Bool {
        approvals + questions + prompts + stops > 0
    }
}

/// Which item a pane shows when it is opened without choosing one.
enum PanePriority {
    /// The highest-ranked item, and among equals the one that arrived
    /// first. Questions come before approvals, and both before stops:
    /// Limpid can answer a request only until its deadline, while a stop
    /// has none. The Rust `RunState::priority` holds the same order (a
    /// wait before a stop before an unread turn) for the runs that compete
    /// for one pane.
    static func dominant(_ items: [AttentionItem]) -> AttentionItem? {
        items.min(by: precedes)
    }

    /// Whether an item of kind `lhs` comes before one of kind `rhs`
    /// whenever they arrived: a question before an approval, both before
    /// a stop, and a stop before an unread turn.
    static func outranks(_ lhs: AttentionItemKind, _ rhs: AttentionItemKind) -> Bool {
        rank(lhs) < rank(rhs)
    }

    private static func precedes(_ lhs: AttentionItem, _ rhs: AttentionItem) -> Bool {
        let left = rank(lhs.kind)
        let right = rank(rhs.kind)
        return left != right ? left < right : lhs.arrivalSequence < rhs.arrivalSequence
    }

    /// Lower ranks first.
    private static func rank(_ kind: AttentionItemKind) -> Int {
        switch kind {
        case .question, .prompt(.question): 0
        // A wait at the prompt ranks as the question its record says, else
        // with approvals, whether its record says approval or nothing.
        case .approval, .prompt: 1
        case .stop: 2
        case .unread: 3
        }
    }
}
