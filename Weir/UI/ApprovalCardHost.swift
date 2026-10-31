// ApprovalCardHost.swift
// Weir — scene-root, fixed detail card for a native agent approval.

import AppKit
import SwiftUI

private struct ApprovalCardMeasurement: Equatable {
    let approvalID: String
    let height: CGFloat
}

/// The card deliberately lives above the window's layout: it stands beside
/// the row that opened it and points back at it, while the pane, the Needs
/// Attention list, and the notifications are only entry points. The
/// otherwise empty host has no hit-test shape, so clicks outside the card
/// continue to reach the terminal and sidebar.
struct ApprovalCardHost: View {
    @Environment(ApprovalPresentationStore.self) private var approvals
    @Environment(WorkspaceSession.self) private var session
    @Environment(WindowRegistry.self) private var windowRegistry
    @Environment(AttentionQueueStore.self) private var attentionQueue
    /// The window this card is in: each window has its own card,
    /// and its ⌘J place follows the pane the card opens. The one host,
    /// `WindowChromeHost`, lays this over a main window's content, and
    /// `MainWindowContent` puts that window in the environment.
    @Environment(ProjectWindowState.self) private var window
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.locale) private var locale
    @State private var measuredCardHeights: [String: CGFloat] = [:]
    /// The tallest height measured for each card. Placing the card by this
    /// height keeps its top edge still when it shrinks: paging to a shorter
    /// question would otherwise re-center it on its row, or let the bottom
    /// clamp pull it down, in one unanimated jump. It moves only when the card
    /// grows past anything it has shown.
    @State private var placementHeights: [String: CGFloat] = [:]
    private let cardWidth: CGFloat = 400
    private let fallbackCardHeight: CGFloat = 180
    /// Between the card and the window's edges.
    private let cardMargin: CGFloat = 8

    /// The selection of the window this card is in.
    private var selection: WindowSelection {
        window.selection
    }

    var body: some View {
        GeometryReader { geometry in
            if let approval = window.approvalCard.presentedApproval(in: approvals),
               let model = ApprovalCardModel(approval: approval, in: approvals)
            {
                let width = min(cardWidth, max(296, geometry.size.width - 24))
                let origin = geometry.frame(in: .global).origin
                let openedFrom = window.approvalCard.state.openedFrom?.offsetBy(dx: -origin.x, dy: -origin.y)
                let rowAnchor = window.approvalCard.rowAnchor(for: approval)?.offsetBy(dx: -origin.x, dy: -origin.y)
                let cardHeight = measuredCardHeights[approval.id] ?? fallbackCardHeight
                let placed = placement(
                    openedFrom: openedFrom,
                    rowAnchor: rowAnchor,
                    panelSize: CGSize(width: width, height: cardHeight),
                    placementHeight: placementHeights[approval.id] ?? cardHeight,
                    container: geometry.size
                )
                ApprovalCard(
                    approval: approval,
                    card: window.approvalCard,
                    model: model,
                    place: place(of: approval),
                    // Without its row there is nothing to point at: once the
                    // request leaves the pending list, its row is gone and
                    // the last anchor marks another one.
                    arrow: openedFrom != nil || (rowAnchor != nil && approvals.hasRow(for: approval)) ? placed.arrow : nil,
                    onClose: { [window] in window.approvalCard.dismiss() },
                    onAnswerInTerminal: { answerInTerminal(approval) },
                    movesToPane: openPaneAction(for: approval) != nil,
                    onOpenPane: openPaneAction(for: approval),
                    maxHeight: FloatingPanelPlacement.maximumHeight(container: geometry.size.height, margin: cardMargin)
                )
                .id(approval.id)
                .frame(width: width)
                .onGeometryChange(for: ApprovalCardMeasurement.self) { cardGeometry in
                    ApprovalCardMeasurement(
                        approvalID: approval.id,
                        height: cardGeometry.size.height
                    )
                } action: { measurement in
                    guard measurement.height > 0,
                          measuredCardHeights[measurement.approvalID] != measurement.height
                    else { return }
                    measuredCardHeights[measurement.approvalID] = measurement.height
                    if measurement.height > placementHeights[measurement.approvalID] ?? 0 {
                        placementHeights[measurement.approvalID] = measurement.height
                    }
                }
                .position(x: placed.origin.x + width / 2, y: placed.origin.y + cardHeight / 2)
                // A floating panel like the dropdowns: it fades and does not
                // scale, so it never looks to come from anywhere but its row.
                .modalTransition(.floatingPanel, reduceMotion: reduceMotion)
                .zIndex(200)
            }
        }
        .animation(
            ModalMotion.floatingPanel.animation(reduceMotion: reduceMotion),
            value: window.approvalCard.presentedApproval(in: approvals)?.id
        )
        .ignoresSafeArea()
        .onChange(of: window.approvalCard.state.presentedID) { _, _ in
            measuredCardHeights = measuredCardHeights.filter { approvals.isKnown($0.key) }
            placementHeights = placementHeights.filter { approvals.isKnown($0.key) }
        }
    }

    /// Where the card goes. Opened from the title bar's Needs Attention
    /// pill, it hangs below the pill as the list does, pointing up at it;
    /// otherwise it stands beside its row in this window's sidebar. A
    /// request may arrive one layout pass before its row reports a frame:
    /// it then starts beside the window's sidebar edge (the window's left
    /// edge with the sidebar hidden) rather than flashing over the sidebar.
    private func placement(
        openedFrom: CGRect?,
        rowAnchor: CGRect?,
        panelSize: CGSize,
        placementHeight: CGFloat,
        container: CGSize
    ) -> (origin: CGPoint, arrow: FloatingPanelPlacement.Arrow?) {
        if let openedFrom {
            return FloatingPanelPlacement.layout(
                anchor: openedFrom,
                panelSize: panelSize,
                container: container,
                margin: cardMargin,
                style: .init(
                    alignment: .centered,
                    gap: WeirLayout.floatingPanelArrowAnchorGap,
                    arrowInset: WeirLayout.floatingPanelArrowInset
                )
            )
        }
        let sidebarWidth = !window.isSidebarPresented
            ? 0
            : window.sidebarDrawnWidth
        let anchor = rowAnchor ?? CGRect(
            x: 0,
            y: container.height / 2,
            width: min(sidebarWidth, container.width),
            height: 0
        )
        return FloatingPanelPlacement.beside(
            anchor: anchor,
            panelSize: panelSize,
            placementHeight: placementHeight,
            container: container,
            style: .init(
                margin: cardMargin,
                gap: WeirLayout.floatingPanelArrowAnchorGap,
                arrowInset: WeirLayout.floatingPanelArrowInset
            )
        )
    }

    /// Where the request is, after the agent's name: its session and its
    /// place, as the Needs Attention list names them.
    private func place(of approval: ApprovalPresentation) -> String? {
        attentionQueue.item(for: approval.key).flatMap { item in
            ApprovalCardModel.place(
                of: item,
                in: session,
                projectsInOtherWindows: windowRegistry.projectsShown(besides: window.id, in: session),
                locale: locale
            )
        }
    }

    /// We settle the native request when the provider takes over the question,
    /// even if its session has not yet been associated with a pane. The card
    /// stays, saying the request is with the TUI: handing over is not
    /// answering.
    private func answerInTerminal(_ approval: ApprovalPresentation) {
        approvals.resolve(approval, .delegate)
        openPaneAction(for: approval)?()
    }

    /// Goes to the request's pane through the attention list, as ⌘J would.
    /// Nil when the list does not place the request in a pane, so the card
    /// offers no pane to open.
    private func openPaneAction(for approval: ApprovalPresentation) -> (() -> Void)? {
        guard let item = attentionQueue.item(for: approval.key), item.subject.paneID != nil else { return nil }
        return {
            attentionQueue.focus(item, from: window)
        }
    }
}

private struct ApprovalCard: View {
    let approval: ApprovalPresentation
    /// The card of the window it is drawn in.
    let card: WindowApprovalCard
    let model: ApprovalCardModel
    /// "{session} · {project}", or `nil` while the request is in no pane.
    let place: String?
    let arrow: FloatingPanelPlacement.Arrow?
    let onClose: () -> Void
    let onAnswerInTerminal: () -> Void
    /// Whether Answer in terminal takes the keyboard to the request's pane.
    /// Without a pane it stays here, and the card places it again once the
    /// pressed button gives way.
    let movesToPane: Bool
    /// Nil when no pane runs the request's session.
    let onOpenPane: (() -> Void)?
    /// The tallest the card may be, the window less its margins. A long
    /// reason or question scrolls in the card's body, between the heading
    /// and the actions, which stay on screen.
    let maxHeight: CGFloat
    @Environment(ApprovalPresentationStore.self) private var approvals
    @Environment(\.locale) private var locale
    @State private var showsDetails = false
    @State private var allowIsEnabled = false
    @State private var allowDelayTask: Task<Void, Never>?
    @FocusState private var focusedAction: ApprovalCardFocus?
    /// Set by a decision pressed in the card. The control that had focus
    /// gives way to "Sending…", and to whatever the outcome shows after it,
    /// so focus is placed again on each change until it leaves the card.
    @State private var focusFollowsState = false
    /// The card's measured height, and its scrolling body's: what the rest
    /// of the card takes is their difference, and the body gets what the
    /// cap leaves after it. Both are 0 until the first layout, which gives
    /// the body the whole cap; the next pass measures the rest and settles,
    /// as the rest does not depend on the body's height.
    @State private var cardHeight: CGFloat = 0
    @State private var scrollingBodyHeight: CGFloat = 0

    /// A background release or hand-off can be in flight while the ledger
    /// still reads held; a decision then would only be dropped.
    private var isResolving: Bool {
        approvals.resolvingIDs.contains(approval.id)
    }

    private var acceptsDecision: Bool {
        model.actions == .decide && !isResolving
    }

    private var visibleRequestDescription: String? {
        ApprovalCardModel.visibleDescription(approval.requestDescription, summary: approval.summary)
    }

    private var detailsHeight: CGFloat {
        let font = NSFont.monospacedSystemFont(ofSize: WeirFont.Supervision.Size.caption.rawValue, weight: .regular)
        return ApprovalCardModel.detailsHeight(
            of: approval.inputDescription,
            lineHeight: ceil(font.ascender - font.descender + font.leading),
            verticalInsets: WeirLayout.Supervision.approvalDetailsVerticalInsets,
            maxHeight: WeirLayout.Supervision.approvalDetailsMaxHeight
        )
    }

    private var draft: ApprovalAnswerDraft {
        approvals.answerDraft(for: approval)
    }

    private var draftBinding: Binding<ApprovalAnswerDraft> {
        Binding(
            get: { approvals.answerDraft(for: approval) },
            set: { approvals.updateAnswerDraft($0, for: approval) }
        )
    }

    private var activeQuestionIndex: Int {
        draft.activeQuestionIndex
    }

    private var isLastQuestion: Bool {
        ApprovalCardModel.isLastQuestion(activeQuestionIndex, of: approval.questions.count)
    }

    /// The answer Send would deliver, once every question has one.
    private var composedAnswer: ApprovalResolution? {
        draft.answers(for: approval.questions).map(ApprovalResolution.answer)
    }

    private var answerExceedsLimit: Bool {
        ApprovalCardModel.answerExceedsLimit(composedAnswer)
    }

    private var canSendAnswer: Bool {
        ApprovalCardModel.canSend(composedAnswer)
    }

    private var initialFocus: ApprovalCardFocus {
        ApprovalCardModel.initialFocus(for: model.actions, canOpenPane: onOpenPane != nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: WeirLayout.Supervision.approvalCardSpacing) {
            header
            // Once with the TUI or timed out, the card says so and offers the
            // pane, and nothing more: the request is answered there now.
            if model.actions != .openPane {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: WeirLayout.Supervision.approvalCardSpacing) {
                        Text(kindLabel)
                            .font(.supervision(.meta))
                            .foregroundStyle(SupervisionTokens.muted.color)
                        if approval.isQuestion {
                            ApprovalQuestionForm(
                                questions: approval.questions,
                                draft: draftBinding,
                                focus: $focusedAction
                            )
                            .disabled(!acceptsDecision)
                            timeLeft
                        } else {
                            requestSummary
                            details
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollBounceBehavior(.basedOnSize)
                // As tall as what it holds, up to what the cap leaves.
                .frame(maxHeight: FloatingPanelPlacement.scrollingBodyHeight(
                    cap: maxHeight,
                    chrome: cardHeight - scrollingBodyHeight
                ))
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { scrollingBodyHeight = $0 }
            }
            statusLine
            actions
            if approval.isQuestion, acceptsDecision, answerExceedsLimit {
                Text("The answer is too long to send. Shorten it or answer in the terminal.")
                    .font(.supervision(.row))
                    .foregroundStyle(SupervisionTokens.stoppedText.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.supervision(.body))
        .foregroundStyle(SupervisionTokens.text.color)
        .padding(WeirLayout.Supervision.approvalCardInsets)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { cardHeight = $0 }
        .floatingPanelSurface(in: FloatingPanelShape(
            cornerRadius: WeirLayout.floatingPanelCornerRadius,
            arrow: arrow,
            arrowHeight: WeirLayout.floatingPanelArrowHeight
        ))
        .pointerStyle(.default)
        .onAppear {
            beginAllowDelay()
        }
        .onChange(of: approval.id) { _, _ in
            beginAllowDelay()
        }
        .onChange(of: focusedAction) { _, action in
            card.focusChanged(action != nil, for: approval)
            // Losing focus while a send is in flight is the pressed button
            // going away; at any other time the person moved elsewhere.
            if action == nil, model.actions != .sending {
                focusFollowsState = false
            }
        }
        .onChange(of: model) { _, _ in
            if focusFollowsState {
                focusedAction = initialFocus
            }
        }
        .onDisappear { allowDelayTask?.cancel() }
        .task(id: card.state.cardFocusRequestID) {
            guard card.state.cardFocusRequestID == approval.id else { return }
            // The overlay can appear before AppKit has installed the button's
            // focus bridge. Wait until the terminal has let go, so the card,
            // not the terminal, receives the initial keyboard focus.
            await KeyboardHandoff.responderSettled()
            guard !Task.isCancelled else { return }
            focusedAction = initialFocus
            card.focusChanged(focusedAction != nil, for: approval)
            card.focusRequestCompleted(for: approval)
        }
        .background(ApprovalCardKeyMonitor(
            isCardFocused: focusedAction != nil,
            isAnswerFieldFocused: focusedAction == .answerField,
            onEscape: onClose,
            onAnswerFieldReturn: submitFromField
        ))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(approval.isQuestion ? "Question from agent" : "Approval request"))
    }

    /// The agent's name, then where the request is, then ×.
    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: WeirLayout.Supervision.spaceS) {
            Text(verbatim: SessionRowFactText.agentName(.agent(approval.provider), locale: locale))
                .font(.supervision(.body, weight: .bold))
                .fixedSize()
            if let place {
                Text(verbatim: place)
                    .font(.supervision(.row))
                    .foregroundStyle(SupervisionTokens.muted.color)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    // "session · project / worktree" as a list: the
                    // separators would be read as symbols.
                    .accessibilityLabel(Text(verbatim: AgentStatusText.spokenPlace(
                        AgentStatusText.spoken(place, locale: locale),
                        locale: locale
                    )))
            }
            Spacer(minLength: 0)
            Button(action: onClose) {
                // The system caption is the window's micro step on macOS.
                DismissGlyph(size: .micro, weight: .semibold)
                    .foregroundStyle(SupervisionTokens.muted.color)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .approvalActionCursor()
            .focused($focusedAction, equals: .close)
            .help(Text("Close"))
            .accessibilityLabel(Text("Close"))
            .accessibilitySortPriority(-2)
        }
    }

    private var kindLabel: LocalizedStringResource {
        ApprovalCardModel.kindLabel(isQuestion: approval.isQuestion, action: ApprovalRequestText(approval).action)
    }

    /// "8:42 left" while Weir holds the request. The service clock stops
    /// while the Mac sleeps, as ours does, so ticking once a second needs no
    /// correction on wake.
    @ViewBuilder private var timeLeft: some View {
        if model.showsTimeLeft, let deadline = approvals.serviceDeadlines[approval.id] {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                let remaining = deadline.remaining(at: .now)
                Text(verbatim: ApprovalCardModel.timeLeftText(for: remaining, locale: locale))
                    .font(.supervision(.body).monospacedDigit())
                    .foregroundStyle(SupervisionTokens.muted.color)
                    .accessibilityLabel(Text(verbatim: ApprovalCardModel.spokenTimeLeftText(for: remaining, locale: locale)))
            }
            // Read after the request itself (the command, the reason).
            .accessibilitySortPriority(-1)
        }
    }

    /// The reason with the time left after it, "{reason} · 8:42 left", as
    /// one run of text, so the clock follows the sentence's last line or
    /// drops whole to the line below. Beside the reason as a view of its
    /// own, it sat on the reason's first line once the reason wrapped, and
    /// a wrapped reason read as two sentences with the clock between them.
    private func reasonWithTimeLeft(_ reason: String, deadline: ServiceDeadline) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let remaining = deadline.remaining(at: .now)
            Text(reasonLine(reason, remaining: remaining))
                .foregroundStyle(SupervisionTokens.muted.color)
                .fixedSize(horizontal: false, vertical: true)
                // The reason, then the time left, as the eye takes them.
                .accessibilityLabel(Text(verbatim: AgentStatusText.spokenList(
                    [reason, ApprovalCardModel.spokenTimeLeftText(for: remaining, locale: locale)],
                    locale: locale
                )))
        }
    }

    /// The reason and, after a space, the time left in digits of one
    /// width, so the clock ticks without the sentence shifting.
    private func reasonLine(_ reason: String, remaining: Duration) -> AttributedString {
        var line = AttributedString(reason + " ")
        var clock = AttributedString(ApprovalCardModel.timeLeftAfterReason(for: remaining, locale: locale))
        clock.font = .supervision(.body).monospacedDigit()
        line += clock
        return line
    }

    /// The command first, in its box, then the agent's reason for it with
    /// the time left after it, as the person weighs them and as VoiceOver
    /// reads them.
    @ViewBuilder private var requestSummary: some View {
        if let summary = approval.summary, !summary.isEmpty {
            // The whole command, as the person is asked to allow it. Long
            // ones scroll inside the card rather than being cut short.
            ScrollView(.vertical) {
                Text(verbatim: summary)
                    .font(.supervision(.row, design: .monospaced))
                    .foregroundStyle(SupervisionTokens.text.color)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(WeirLayout.Supervision.approvalCommandInsets)
            }
            .frame(maxHeight: WeirLayout.Supervision.approvalCommandMaxHeight)
            .fixedSize(horizontal: false, vertical: true)
            .background(ApprovalCommandWell())
        }
        if let visibleRequestDescription {
            if model.showsTimeLeft, let deadline = approvals.serviceDeadlines[approval.id] {
                reasonWithTimeLeft(visibleRequestDescription, deadline: deadline)
            } else {
                Text(verbatim: visibleRequestDescription)
                    .foregroundStyle(SupervisionTokens.muted.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            timeLeft
        }
    }

    @ViewBuilder private var details: some View {
        Button {
            showsDetails.toggle()
        } label: {
            HStack(spacing: WeirLayout.Supervision.spaceXS) {
                Image(systemName: showsDetails ? "chevron.down" : "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .accessibilityHidden(true)
                Text(showsDetails ? "Hide Details" : "Show Details")
            }
        }
        // A ghost button as the window's other quiet commands are, since
        // blue is kept for unread and unviewed.
        .buttonStyle(.supervisionSecondary(tone: .ghost))
        .focused($focusedAction, equals: .details)
        .accessibilityLabel(Text(showsDetails ? "Hide Details" : "Show Details"))
        if showsDetails {
            ScrollView([.horizontal, .vertical]) {
                Text(verbatim: approval.inputDescription)
                    .font(.supervision(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(.horizontal, WeirLayout.Supervision.spaceS)
                    .padding(.vertical, WeirLayout.Supervision.spaceSnug)
            }
            .defaultScrollAnchor(.topLeading, for: .alignment)
            .frame(height: detailsHeight, alignment: .topLeading)
            .background(ApprovalCommandWell(cornerRadius: WeirLayout.Supervision.smallControlCornerRadius))
            .accessibilityLabel(Text("Tool input"))
        }
    }

    @ViewBuilder private var statusLine: some View {
        switch model.status {
        case .none:
            EmptyView()
        case .sendFailed:
            statusText("Couldn’t send your answer. Try again.", isError: true)
        case .handedToTerminal:
            statusText("Handed to the terminal. Answer in that pane.")
        case .timedOut:
            statusText("Timed out. Answer in the terminal.")
        case .alreadyAnswered:
            statusText("Already answered.")
        }
    }

    private func statusText(_ text: LocalizedStringKey, isError: Bool = false) -> some View {
        Text(text)
            .foregroundStyle(isError ? SupervisionTokens.stoppedText.color : SupervisionTokens.muted.color)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var actions: some View {
        switch model.actions {
        case .decide:
            HStack {
                if approval.isQuestion {
                    questionActions
                } else {
                    approvalActions
                }
            }
            .disabled(isResolving)
        case .sending:
            // The buttons go and "Sending…" stands in their place, so
            // nothing is sent twice.
            HStack(spacing: WeirLayout.Supervision.spaceSnug) {
                Spacer()
                ProgressView()
                    .controlSize(.small)
                    .accessibilityHidden(true)
                Text("Sending…")
                    .foregroundStyle(SupervisionTokens.muted.color)
            }
        case .openPane:
            if let onOpenPane {
                HStack {
                    Spacer()
                    Button("Open Pane", action: onOpenPane)
                        .buttonStyle(SupervisionPrimaryButtonStyle())
                        .approvalActionCursor()
                        .cardFocus($focusedAction, equals: .primaryAction)
                        .accessibilityLabel(Text("Open Pane"))
                }
            }
        case .none:
            EmptyView()
        }
    }

    /// Hands the request to the TUI: on an approval its own focus place,
    /// on a question the one that commits nothing.
    private func answerInTerminalButton(focus: ApprovalCardFocus) -> some View {
        Button("Answer in terminal") { answerInTerminal() }
            .buttonStyle(.supervisionSecondary)
            .approvalActionCursor()
            .cardFocus($focusedAction, equals: focus)
            .accessibilityLabel(Text("Answer in terminal"))
    }

    @ViewBuilder private var approvalActions: some View {
        answerInTerminalButton(focus: .answerInTerminal)
        Spacer()
        Button("Deny") {
            decide(.deny)
        }
        // Its title in the stop color, as a refusal; edged and unfilled,
        // so it never reads as the primary one beside it.
        .buttonStyle(.supervisionSecondary(tone: .refusal))
        .approvalActionCursor()
        .cardFocus($focusedAction, equals: .secondaryAction)
        .accessibilityLabel(Text("Deny"))
        Button("Allow once") {
            decide(.allowOnce)
        }
        .buttonStyle(SupervisionPrimaryButtonStyle())
        .approvalActionCursor()
        .cardFocus($focusedAction, equals: .primaryAction)
        .accessibilityLabel(Text("Allow once"))
        .disabled(!allowIsEnabled)
    }

    @ViewBuilder private var questionActions: some View {
        answerInTerminalButton(focus: .secondaryAction)
        Spacer()
        if isLastQuestion {
            Button("Send Answer") { sendAnswer() }
                .buttonStyle(SupervisionPrimaryButtonStyle())
                .approvalActionCursor()
                .cardFocus($focusedAction, equals: .primaryAction)
                .accessibilityLabel(Text("Send Answer"))
                .disabled(!allowIsEnabled || !canSendAnswer)
        } else {
            Button("Next") { advance() }
                .buttonStyle(SupervisionPrimaryButtonStyle())
                .approvalActionCursor()
                .cardFocus($focusedAction, equals: .primaryAction)
                .accessibilityLabel(Text("Next question"))
        }
    }

    private func sendAnswer() {
        guard allowIsEnabled, acceptsDecision, let composedAnswer, canSendAnswer else { return }
        decide(composedAnswer)
    }

    private func answerInTerminal() {
        focusFollowsState = !movesToPane
        onAnswerInTerminal()
    }

    /// Sends the person's decision and keeps the keyboard in the card
    /// through what the send changes.
    private func decide(_ resolution: ApprovalResolution) {
        focusFollowsState = true
        approvals.resolve(approval, resolution)
    }

    private func advance() {
        guard acceptsDecision, !isLastQuestion else { return }
        ApprovalAnswerComposition.commit()
        draftBinding.wrappedValue.activeQuestionIndex += 1
        focusAfterNext()
    }

    private func submitFromField() {
        if isLastQuestion {
            sendAnswer()
        } else {
            advance()
        }
    }

    /// The Next button leaves the hierarchy as soon as the index advances, and
    /// a removed control drops keyboard focus. Hand focus to a control that
    /// exists afterwards: Send Answer when it can already be pressed, since a
    /// disabled button cannot take focus, and otherwise the next question's
    /// first option, or its text field when it has no options.
    private func focusAfterNext() {
        if isLastQuestion, allowIsEnabled, canSendAnswer {
            focusedAction = .primaryAction
        } else if approval.questions.indices.contains(activeQuestionIndex),
                  !approval.questions[activeQuestionIndex].options.isEmpty
        {
            focusedAction = .option(0)
        } else {
            focusedAction = .answerField
        }
    }

    private func beginAllowDelay() {
        allowDelayTask?.cancel()
        allowIsEnabled = false
        allowDelayTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            allowIsEnabled = true
        }
    }
}

private extension View {
    /// A card button's focus place, with the ring that shows it in place
    /// of the system's, which a custom button style does not get: a
    /// keyboard user must see where Return goes.
    func cardFocus(
        _ focus: FocusState<ApprovalCardFocus?>.Binding,
        equals value: ApprovalCardFocus
    ) -> some View {
        focused(focus, equals: value)
            .focusEffectDisabled()
            .supervisionFocusRing(
                isFocused: focus.wrappedValue == value,
                cornerRadius: WeirLayout.Supervision.buttonCornerRadius
            )
    }

    func approvalActionCursor() -> some View {
        pointerStyle(.default)
            .onContinuousHover { phase in
                // The terminal's AppKit cursor rect can remain active beneath
                // this scene overlay. Reassert the button cursor as the mouse
                // moves so the terminal's I-beam cannot leak through.
                if case .active = phase {
                    NSCursor.arrow.set()
                }
            }
    }
}

/// The well the command and the tool input sit in. A view of its own so it
/// reads the ground the card's surface hands down: the surface is a
/// modifier in the card's own body, so the card's environment never hears
/// of it.
private struct ApprovalCommandWell: View {
    var cornerRadius = WeirLayout.Supervision.approvalCommandCornerRadius
    @Environment(\.popoverSurface.ground) private var ground

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(ground.well.color)
    }
}

/// A scene overlay does not become the AppKit key responder, so consume Escape
/// at the hosting window before a focused terminal can receive its byte, but
/// only while focus is in the card. The card stays on screen after the
/// person moves to the terminal (to answer there, for one), and the TUI's
/// own prompt needs that Escape.
private struct ApprovalCardKeyMonitor: View {
    /// Whether keyboard focus is in the card, which is when Escape is ours.
    let isCardFocused: Bool
    /// Gates Return handling: the monitor sees every key in the window, and
    /// the terminal and other text fields must keep their own Return.
    let isAnswerFieldFocused: Bool
    let onEscape: () -> Void
    let onAnswerFieldReturn: () -> Void

    var body: some View {
        WindowKeyDownMonitor(handle: handle)
    }

    /// Whether the card took `event`.
    private func handle(_ event: NSEvent, in window: NSWindow) -> Bool {
        guard event.modifierFlags.isDisjoint(with: [.command, .control, .option]) else { return false }
        switch event.namedKey {
        case .escape:
            // The active text input client finishes or cancels its marked
            // text before Escape changes the approval's state.
            guard isCardFocused, !window.isComposingText else { return false }
            onEscape()
            return true
        case .return:
            // Measured on macOS 27 with a vertical SwiftUI text field:
            // the field editor breaks a line on Option-Return, which
            // the guard above leaves to it, and treats Shift-Return
            // as a submit. Shift-Return is the line break chat inputs
            // use, so we insert a line break for it as well. A plain Return
            // submits and then selects the whole text, so the next
            // keystroke would replace the answer; we take Return
            // before the field editor sees it. Marked text keeps
            // Return for the input method to commit.
            guard isAnswerFieldFocused,
                  let editor = window.firstResponder as? NSTextView,
                  editor.isFieldEditor,
                  !editor.hasMarkedText()
            else { return false }
            if event.modifierFlags.contains(.shift) {
                editor.insertNewlineIgnoringFieldEditor(nil)
            } else {
                onAnswerFieldReturn()
            }
            return true
        default:
            return false
        }
    }
}

/// Finishes an input method's composition before the card changes question.
/// Text still being converted belongs to the question it was typed into; left
/// marked, the input method commits it later into the next one. We commit it
/// the way a field editor does when it loses focus.
enum ApprovalAnswerComposition {
    @MainActor static func commit() {
        guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView,
              editor.isFieldEditor,
              editor.hasMarkedText()
        else { return }
        editor.unmarkText()
        editor.inputContext?.discardMarkedText()
    }
}
