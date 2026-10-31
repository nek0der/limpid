// DecisionBarView.swift
// Weir — the 32pt line under an agent's pane: what waits on the person there, or what the agent is doing.

import SwiftUI

/// The decision bar of one pane. Always there while an agent runs in
/// the pane, so the terminal's rows change only when the agent starts and
/// when it leaves, never as the bar's content changes. It states where an
/// approval or a question is answered but never answers one itself, and
/// the keyboard stays with the terminal: its buttons take no focus, and
/// ⌘⏎ reaches the primary one from the terminal.
struct DecisionBarView: View {
    let paneID: UUID
    @Environment(WorkspaceSession.self) private var session
    @Environment(ProjectWindowState.self) private var window
    @Environment(WindowRegistry.self) private var windowRegistry
    @Environment(AttentionQueueStore.self) private var attentionQueue
    @Environment(AttentionState.self) private var attention
    @Environment(ApprovalPresentationStore.self) private var approvals
    @Environment(\.agentProjection) private var agentProjection
    @Environment(\.restoreHandler) private var restore
    @Environment(StopLedgerStore.self) private var stopLedger
    @Environment(UsageLimitResetSync.self) private var resetSync: UsageLimitResetSync?
    @Environment(\.locale) private var locale
    /// The item the bar showed last, and the epoch of its pane then, so the
    /// bar can tell when a request handed to the terminal was answered
    /// there rather than left with its turn or its agent.
    @State private var lastShown: ProjectWindowState.ShownItem?
    /// This bar, as the gate knows it: a pane's next bar may be drawn
    /// before this one goes.
    @State private var barID = UUID()

    var body: some View {
        // A restore strip opened for this pane takes the bar's place, also
        // in a pane whose agent has left, unless the agent asks
        // something now.
        if let restore, let strip = window.restoreStrips[paneID],
           !RestoreStrip.yields(to: attentionQueue.queue.items(inPane: paneID))
        {
            RestoreStripView(paneID: paneID, strip: strip, handler: restore)
        } else {
            // Drawn again as each usage limit resets, when the sync reads
            // the limits again: the stop's words and its primary change
            // then, with no event to say so.
            content(now: max(resetSync?.resetPassedAt ?? .distantPast, Date()))
        }
    }

    /// The bar, or at rest the record of a restore of the pane's worktree
    /// that may still be undone.
    @ViewBuilder
    private func barOrRecord(_ model: DecisionBarModel) -> some View {
        if model.isAtRest, let restore, let journal = restore.record(paneID) {
            RestoreRecordLine(journal: journal, handler: restore)
        } else {
            bar(model)
        }
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        let items = attentionQueue.queue.items(inPane: paneID)
        if let model = DecisionBarModel(
            paneID: paneID,
            sources: .init(
                session: session,
                window: window,
                queue: attentionQueue.queue,
                runtimes: attention.allRuntimes,
                approvals: approvals.ledger,
                // ⌘J's next stop is worked out only for a "Done" line,
                // so a move of the cursor does not redraw every bar.
                next: window.decisionBarDone[paneID] == nil ? nil : attentionQueue.peekNext(from: window),
                history: agentProjection?.turnHistory.conversations ?? [:],
                stopResume: { item in stopLedger.offers[item.id] ?? .unavailable },
                resetNotice: { item in resetSync?.notice(for: item, now: now) },
                now: now
            ),
            locale: locale
        ) {
            barOrRecord(model)
                .onChange(of: items, initial: true) { _, items in
                    window.itemsChanged(
                        .init(
                            paneID: paneID,
                            items: items,
                            lastShown: lastShown,
                            epoch: windowRegistry.epoch(inPane: paneID),
                            isDeclined: isDeclined(lastShown)
                        ),
                        isSelectedPane: isSelectedPane,
                        isCurrent: isCurrent
                    )
                    lastShown = shown(model.content.itemID, in: items)
                }
                .onChange(of: model.content.itemID) { _, id in
                    lastShown = shown(id, in: items)
                }
                // A restore's "Done" ends with its record: once undone, or
                // once a turn begins after it.
                .onChange(of: shownRestoreRecord) { _, _ in
                    if let done = window.decisionBarDone[paneID], !isCurrent(done) {
                        clearDone()
                    }
                }
                // ⌘⏎ acts on what is on screen, once it has been there a
                // moment.
                .onChange(of: GateEntry(itemID: model.content.itemID, primaryAction: model.primaryAction), initial: true) { _, entry in
                    window.primaryActionGate.noteShown(
                        entry.itemID,
                        primaryAction: entry.primaryAction,
                        inPane: paneID,
                        by: barID,
                        at: SuspendingClock().now
                    )
                }
                // Moving on to another pane ends this one's choice; the
                // window decides that (`ProjectWindowState.keyboardMoved`),
                // not the bar's coming and going.
                .onDisappear { window.primaryActionGate.forget(pane: paneID, by: barID) }
        }
    }

    /// What the gate keeps of the bar, compared as one value so a change
    /// to either is noted once.
    private struct GateEntry: Equatable {
        let itemID: AttentionItemID?
        let primaryAction: PrimaryAction?
    }

    /// The receipt's tooltip, for a turn's receipt: its prompt, how long it
    /// ran, and its check's command, as the changes panel's row has them.
    private func receiptHelp(_ model: DecisionBarModel) -> String? {
        let unread: UnreadTurn? = switch model.content.body {
        case let .unread(turn), let .lastTurn(turn): turn
        default: nil
        }
        return unread.flatMap {
            ChangesPanelText.receiptHelp($0, history: agentProjection?.turnHistory.conversations ?? [:], locale: locale)
        }
    }

    /// The record of the pane's worktree while its bar shows a restore's
    /// "Done", the only time the record is looked up on each draw.
    private var shownRestoreRecord: String? {
        guard case .restored = window.decisionBarDone[paneID] else { return nil }
        return restore?.record(paneID)?.opID
    }

    /// Returns whether the run of the item the bar showed was declined at
    /// its prompt rather than answered there, as the runtimes and the turns
    /// say now. It is read in the handlers only, like `shown(_:in:)`.
    private func isDeclined(_ shown: ProjectWindowState.ShownItem?) -> Bool {
        guard let runtimeID = shown?.item.subject.runtimeID else { return false }
        let runtime = attention.allRuntimes.first { $0.id == runtimeID }
        let turn = runtime?.currentTurnID.flatMap { agentProjection?.turnHistory.turn($0) }
        return DecisionBarModel.isDeclined(runtime: runtime, turn: turn)
    }

    /// Whether a "Done" line still says something true: a restore's, only
    /// while the pane's record is that restore.
    private func isCurrent(_ done: DecisionBarContent.DoneResult) -> Bool {
        guard case let .restored(restored) = done else { return true }
        return restore?.record(paneID)?.opID == restored.opID
    }

    /// The item `id` of `items`, with the epoch its pane is in now. Read
    /// in the handlers only, never in `body`: the epochs are not observed.
    private func shown(_ id: AttentionItemID?, in items: [AttentionItem]) -> ProjectWindowState.ShownItem? {
        items.first { $0.id == id }.map { .init(item: $0, epoch: windowRegistry.epoch(inPane: paneID)) }
    }

    /// Written only when there is something to clear: each write tells
    /// every bar of the window to draw again.
    private func clearDone() {
        if window.decisionBarDone[paneID] != nil {
            window.decisionBarDone[paneID] = nil
        }
    }

    /// The pane the window shows the keyboard in: its selected tab's focused
    /// pane. A lone pane or a zoomed one is always drawn as focused, so the
    /// pane's own look cannot say whether the person moved away.
    private var isSelectedPane: Bool {
        guard let tabID = window.selection.activeTabID else { return false }
        return session.tab(tabID)?.splitTree.effectiveFocusedLeafID == paneID
    }

    private func bar(_ model: DecisionBarModel) -> some View {
        DecisionBarFootBar(
            model: model,
            paneID: paneID,
            receiptHelp: receiptHelp(model),
            canStartNew: model.stopItem.map(stopLedger.startsNew.contains) ?? false,
            newConversationBlocker: model.stopItem.flatMap { stopLedger.newConversationBlockers[$0] }
        ) {
            window.decisionBarSelection[paneID] = DecisionBarContent.next(
                after: model.content.itemID,
                in: attentionQueue.queue.items(inPane: paneID)
            )
        }
    }
}

/// The bar's tag: one word in a soft chip of the tone's family, so the
/// color is never the only sign of what the bar is on; at rest and while
/// resuming, only edged. A new session's line (`SessionLaunchBar`), the
/// review tab's band, and a restore strip wear the same.
struct DecisionBarTag: View {
    let text: String
    let tone: DecisionBarModel.Tone

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: WeirLayout.Supervision.chipCornerRadius, style: .continuous)
        let style = DecisionBarTagStyle.of(tone)
        Text(verbatim: text)
            .font(.supervision(.caption, weight: .bold))
            .tracking(0.4)
            .foregroundStyle(style.label.color)
            .padding(.horizontal, WeirLayout.Supervision.decisionBarTagHorizontalPadding)
            .frame(height: WeirLayout.Supervision.decisionBarTagHeight)
            .background(shape.fill(style.fill?.color ?? .clear))
            .overlay(shape.strokeBorder(style.edge.color, lineWidth: 1))
            .fixedSize()
    }
}

/// The tag's colors by tone: the soft fill of the state's
/// family, with its words in the family's text tone at 4.5:1, and a 1pt
/// edge in the state's own color. The bar's ground is that same soft fill,
/// so the edge is what makes the tag a chip on it (the strong
/// amber fill with dark letters read as a dark block on the pale bar). At
/// rest and while resuming the tag has no fill and the `line` edge, as
/// quiet as the line it sits on.
struct DecisionBarTagStyle: Equatable {
    /// `nil` where the tag is only edged.
    let fill: ThemedColor?
    let label: ThemedColor
    let edge: ThemedColor

    static func of(_ tone: DecisionBarModel.Tone) -> Self {
        switch tone {
        case .waiting:
            Self(fill: SupervisionTokens.waitingFill, label: SupervisionTokens.waitingText, edge: SupervisionTokens.waiting)
        case .stopped:
            Self(fill: SupervisionTokens.stoppedFill, label: SupervisionTokens.stoppedText, edge: SupervisionTokens.stopped)
        // Blue for unread, whatever the person's accent.
        case .unread:
            Self(fill: SupervisionTokens.unreadFill, label: SupervisionTokens.unreadText, edge: SupervisionTokens.unread)
        case .done, .muted:
            Self(fill: nil, label: SupervisionTokens.muted, edge: SupervisionTokens.line)
        }
    }
}
