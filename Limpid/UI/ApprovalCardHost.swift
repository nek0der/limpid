// ApprovalCardHost.swift
// Limpid — scene-root, fixed detail card for a native agent approval.

import AppKit
import SwiftUI

private struct ApprovalCardMeasurement: Equatable {
    let approvalID: String
    let height: CGFloat
}

/// The card deliberately lives above the three-pane layout: its anchor is the
/// Waiting column's trailing edge, while the pane and Waiting affordances are
/// only entry points. The otherwise empty host has no hit-test shape, so clicks
/// outside the card continue to reach the terminal and sidebar.
struct ApprovalCardHost: View {
    @Environment(ApprovalPresentationStore.self) private var approvals
    @Environment(WindowSession.self) private var session
    @Environment(AttentionState.self) private var attention
    @Environment(\.surfaceRegistry) private var registry
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var measuredCardHeights: [String: CGFloat] = [:]
    /// The tallest height measured for each card. Placing the card by this
    /// height keeps its top edge still when it shrinks: paging to a shorter
    /// question would otherwise re-center it on its row, or let the bottom
    /// clamp pull it down, in one unanimated jump. It moves only when the card
    /// grows past anything it has shown.
    @State private var placementHeights: [String: CGFloat] = [:]
    private let cardWidth: CGFloat = 400
    private let fallbackCardHeight: CGFloat = 180

    private func clampedCenterY(
        _ proposed: CGFloat,
        placementHeight: CGFloat,
        cardHeight: CGFloat,
        in size: CGSize
    ) -> CGFloat {
        guard size.height > placementHeight + 16 else { return size.height / 2 }
        let top = min(max(proposed - placementHeight / 2, 8), size.height - placementHeight - 8)
        return top + cardHeight / 2
    }

    var body: some View {
        GeometryReader { geometry in
            if let approval = approvals.presentedApproval {
                let width = min(cardWidth, max(296, geometry.size.width - 24))
                let origin = geometry.frame(in: .global).origin
                let anchor = approvals.rowAnchor(for: approval)
                // A request may arrive one layout pass before its Waiting row
                // reports an anchor. Start beside the persisted sidebar width
                // instead of flashing over the sidebar at the window origin.
                let fallbackAnchorX = origin.x + min(session.sidebarWidth, geometry.size.width)
                let x = min(
                    max((anchor?.maxX ?? fallbackAnchorX) - origin.x + 12 + width / 2, width / 2 + 8),
                    geometry.size.width - width / 2 - 8
                )
                let proposedY = (anchor?.midY ?? origin.y + geometry.size.height / 2) - origin.y
                let cardHeight = measuredCardHeights[approval.id] ?? fallbackCardHeight
                let placementHeight = placementHeights[approval.id] ?? cardHeight
                ApprovalCard(
                    approval: approval,
                    onClose: approvals.dismissCard,
                    onAnswerInTerminal: { answerInTerminal(approval) }
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
                .onHover { approvals.cardHoverChanged($0) }
                .position(x: x, y: clampedCenterY(
                    proposedY,
                    placementHeight: placementHeight,
                    cardHeight: cardHeight,
                    in: geometry.size
                ))
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.97)))
                .zIndex(200)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: approvals.presentedApproval?.id)
        .ignoresSafeArea()
        .onChange(of: approvals.pending.map(\.id)) { _, ids in
            let live = Set(ids)
            measuredCardHeights = measuredCardHeights.filter { live.contains($0.key) }
            placementHeights = placementHeights.filter { live.contains($0.key) }
        }
    }

    /// The request stays pending for the terminal dialog, so closing the card
    /// alone would leave the user hunting for the pane that is asking. The
    /// Waiting row takes the user to the same pane.
    private func answerInTerminal(_ approval: ApprovalPresentation) {
        let location = approvals.paneLocation(for: approval, in: session)
        approvals.dismissCard()
        guard let location else { return }
        attention.focusAttention(in: session, registry: registry, tabID: location.0, paneID: location.1)
    }
}

/// Every keyboard target inside the approval card. The card reports "lost
/// focus" to the store whenever this is nil, and the store then dismisses the
/// card once the pointer leaves it, so each focusable control, including the
/// question form's fields, needs its own case.
enum ApprovalCardFocus: Hashable {
    case details
    /// The action that commits nothing: Deny, or Answer in terminal.
    case secondaryAction
    /// Allow once, Next, or Send answer.
    case primaryAction
    case questionTab(Int)
    case option(Int)
    case otherOption
    case answerField
}

private struct ApprovalCard: View {
    let approval: ApprovalPresentation
    let onClose: () -> Void
    let onAnswerInTerminal: () -> Void
    @Environment(ApprovalPresentationStore.self) private var approvals
    @Environment(WindowSession.self) private var session
    @State private var showsDetails = false
    @State private var allowIsEnabled = false
    @State private var allowDelayTask: Task<Void, Never>?
    @State private var resolvingDecision: String?
    @FocusState private var focusedAction: ApprovalCardFocus?

    private var isResolving: Bool {
        approvals.resolvingIDs.contains(approval.id)
    }

    private var visibleRequestDescription: String? {
        guard let description = approval.requestDescription?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !description.isEmpty,
            description != approval.summary?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        else { return nil }
        return description
    }

    private var paneContext: String? {
        guard let location = approvals.paneLocation(for: approval, in: session),
              let tab = session.tab(location.0)
        else { return nil }
        return tab.displayTitle
    }

    private var detailsHeight: CGFloat {
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        let lineCount = approval.inputDescription
            .split(separator: "\n", omittingEmptySubsequences: false)
            .count
        return min(CGFloat(max(1, lineCount)) * lineHeight + 12, 180)
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
        activeQuestionIndex >= approval.questions.count - 1
    }

    /// The answer Send would deliver, once every question has one.
    private var composedAnswer: ApprovalResolution? {
        draft.answers(for: approval.questions).map(ApprovalResolution.answer)
    }

    private var answerExceedsLimit: Bool {
        composedAnswer.map { !$0.fitsDecisionLimit } ?? false
    }

    private var canSendAnswer: Bool {
        composedAnswer?.fitsDecisionLimit ?? false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: "\(approval.provider.rawValue.capitalized)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(LimpidColor.rowActiveFill, in: Capsule())
                if approval.isQuestion {
                    Text("Question")
                        .font(.headline)
                        .lineLimit(1)
                } else {
                    Text(verbatim: approval.toolName)
                        .font(.headline)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            if approval.isQuestion {
                ApprovalQuestionForm(
                    questions: approval.questions,
                    draft: draftBinding,
                    focus: $focusedAction
                )
            } else {
                requestSummary
            }
            if let paneContext {
                Text(verbatim: paneContext)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if !approval.isQuestion {
                details
            }
            HStack {
                if approval.isQuestion {
                    questionActions
                } else {
                    approvalActions
                }
            }
            .disabled(isResolving)
            if approval.isQuestion, answerExceedsLimit {
                Text("The answer is too long to send. Shorten it or answer in the terminal.")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else if approvals.lastFailureID == approval.id {
                Text("Could not send the decision. Try again.")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .floatingPanelSurface(cornerRadius: 12)
        .pointerStyle(.default)
        .onAppear {
            beginAllowDelay()
        }
        .onChange(of: approval.id) { _, _ in
            resolvingDecision = nil
            beginAllowDelay()
        }
        .onChange(of: isResolving) { wasResolving, isResolving in
            if wasResolving, !isResolving {
                resolvingDecision = nil
            }
        }
        .onChange(of: focusedAction) { _, action in
            approvals.cardFocusChanged(action != nil, for: approval)
        }
        .onDisappear { allowDelayTask?.cancel() }
        .task(id: approvals.cardFocusRequestID) {
            guard approvals.cardFocusRequestID == approval.id else { return }
            // The overlay can appear before AppKit has installed the button's
            // focus bridge. Defer one turn so the card's non-committing action,
            // not the terminal, receives the initial keyboard focus: Deny on an
            // approval, Answer in terminal on a question. A case with no control
            // on screen would leave focus nowhere and the card would treat the
            // hand-off as lost.
            await Task.yield()
            guard !Task.isCancelled else { return }
            focusedAction = .secondaryAction
            approvals.cardFocusChanged(focusedAction != nil, for: approval)
            approvals.cardFocusRequestCompleted(for: approval)
        }
        .background(ApprovalCardKeyMonitor(
            isAnswerFieldFocused: focusedAction == .answerField,
            onEscape: onClose,
            onAnswerFieldReturn: submitFromField
        ))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(approval.isQuestion ? "Question from agent" : "Approval request"))
    }

    @ViewBuilder private var requestSummary: some View {
        if let visibleRequestDescription {
            Text(verbatim: visibleRequestDescription)
                .font(.subheadline)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let summary = approval.summary, !summary.isEmpty {
            Text(verbatim: summary)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var details: some View {
        Button {
            showsDetails.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: showsDetails ? "chevron.down" : "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .accessibilityHidden(true)
                Text(showsDetails ? "Hide details" : "Show details")
            }
        }
        .buttonStyle(.link)
        .focused($focusedAction, equals: .details)
        .accessibilityLabel(Text(showsDetails ? "Hide details" : "Show details"))
        if showsDetails {
            ScrollView([.horizontal, .vertical]) {
                Text(verbatim: approval.inputDescription)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
            }
            .defaultScrollAnchor(.topLeading, for: .alignment)
            .frame(height: detailsHeight, alignment: .topLeading)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .accessibilityLabel(Text("Tool input"))
        }
    }

    @ViewBuilder private var approvalActions: some View {
        Button(isResolving && resolvingDecision == "deny" ? "Sending…" : "Deny") {
            resolvingDecision = "deny"
            approvals.resolve(approval, .deny)
        }
        .buttonStyle(.bordered)
        .approvalActionCursor()
        .focused($focusedAction, equals: .secondaryAction)
        .accessibilityLabel(Text(isResolving && resolvingDecision == "deny" ? "Sending denial" : "Deny"))
        Spacer()
        Button(isResolving && resolvingDecision == "allow_once" ? "Sending…" : "Allow once") {
            resolvingDecision = "allow_once"
            approvals.resolve(approval, .allowOnce)
        }
        .buttonStyle(.borderedProminent)
        .approvalActionCursor()
        .focused($focusedAction, equals: .primaryAction)
        .accessibilityLabel(Text(isResolving && resolvingDecision == "allow_once" ? "Sending approval" : "Allow once"))
        .disabled(!allowIsEnabled || isResolving)
    }

    @ViewBuilder private var questionActions: some View {
        Button("Answer in terminal") { onAnswerInTerminal() }
            .buttonStyle(.bordered)
            .approvalActionCursor()
            .focused($focusedAction, equals: .secondaryAction)
            .accessibilityLabel(Text("Answer in terminal"))
        Spacer()
        if isLastQuestion {
            Button(isResolving ? "Sending…" : "Send answer") { sendAnswer() }
                .buttonStyle(.borderedProminent)
                .approvalActionCursor()
                .focused($focusedAction, equals: .primaryAction)
                .accessibilityLabel(Text(isResolving ? "Sending answer" : "Send answer"))
                .disabled(!allowIsEnabled || isResolving || !canSendAnswer)
        } else {
            Button("Next") { advance() }
                .buttonStyle(.borderedProminent)
                .approvalActionCursor()
                .focused($focusedAction, equals: .primaryAction)
                .accessibilityLabel(Text("Next question"))
                .disabled(isResolving)
        }
    }

    private func sendAnswer() {
        guard allowIsEnabled, !isResolving, let composedAnswer, canSendAnswer else { return }
        resolvingDecision = "answer"
        approvals.resolve(approval, composedAnswer)
    }

    private func advance() {
        guard !isResolving, !isLastQuestion else { return }
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
    /// exists afterwards: Send answer when it can already be pressed, since a
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

/// A scene overlay does not become the AppKit key responder, so consume Escape
/// at the hosting window before a focused terminal can receive its byte.
private struct ApprovalCardKeyMonitor: NSViewRepresentable {
    /// Gates Return handling: the monitor sees every key in the window, and
    /// the terminal and other text fields must keep their own Return.
    let isAnswerFieldFocused: Bool
    let onEscape: () -> Void
    let onAnswerFieldReturn: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onEscape: onEscape, onAnswerFieldReturn: onAnswerFieldReturn)
    }

    func makeNSView(context: Context) -> HostView {
        let view = HostView(frame: .zero)
        view.onWindowChange = { [weak coordinator = context.coordinator] window in
            coordinator?.hostWindow = window
        }
        context.coordinator.install()
        return view
    }

    func updateNSView(_ view: HostView, context: Context) {
        context.coordinator.onEscape = onEscape
        context.coordinator.onAnswerFieldReturn = onAnswerFieldReturn
        context.coordinator.isAnswerFieldFocused = isAnswerFieldFocused
        context.coordinator.hostWindow = view.window
    }

    static func dismantleNSView(_ view: HostView, coordinator: Coordinator) {
        coordinator.remove()
        coordinator.hostWindow = nil
    }

    @MainActor final class HostView: NSView {
        var onWindowChange: ((NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindowChange?(window)
        }
    }

    @MainActor final class Coordinator {
        var onEscape: () -> Void
        var onAnswerFieldReturn: () -> Void
        var isAnswerFieldFocused = false
        weak var hostWindow: NSWindow?
        private var monitor: Any?

        init(onEscape: @escaping () -> Void, onAnswerFieldReturn: @escaping () -> Void) {
            self.onEscape = onEscape
            self.onAnswerFieldReturn = onAnswerFieldReturn
        }

        func install() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self,
                      let hostWindow,
                      event.window === hostWindow,
                      event.modifierFlags.isDisjoint(with: [.command, .control, .option])
                else { return event }
                switch event.keyCode {
                case 53:
                    // Let the active text input client finish or cancel its
                    // marked text before Escape changes approval UI state.
                    if let textInput = hostWindow.firstResponder as? any NSTextInputClient,
                       textInput.hasMarkedText()
                    {
                        return event
                    }
                    onEscape()
                    return nil
                case 36, 76:
                    // Measured on macOS 27 with a vertical SwiftUI text field:
                    // the field editor breaks a line on Option-Return, which
                    // the guard above leaves to it, and treats Shift-Return
                    // as a submit. Shift-Return is the line break chat inputs
                    // use, so we route it to the same command. A plain Return
                    // submits and then selects the whole text, so the next
                    // keystroke would replace the answer; we take Return
                    // before the field editor sees it. Marked text keeps
                    // Return for the input method to commit.
                    guard isAnswerFieldFocused,
                          let editor = hostWindow.firstResponder as? NSTextView,
                          editor.isFieldEditor,
                          !editor.hasMarkedText()
                    else { return event }
                    if event.modifierFlags.contains(.shift) {
                        editor.insertNewlineIgnoringFieldEditor(nil)
                    } else {
                        onAnswerFieldReturn()
                    }
                    return nil
                default:
                    return event
                }
            }
        }

        func remove() {
            guard let monitor else { return }
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
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
