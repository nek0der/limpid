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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var measuredCardHeights: [String: CGFloat] = [:]
    private let cardWidth: CGFloat = 320
    private let fallbackCardHeight: CGFloat = 180

    private func clampedCenterY(_ proposed: CGFloat, cardHeight: CGFloat, in size: CGSize) -> CGFloat {
        let margin = cardHeight / 2 + 8
        guard size.height > margin * 2 else { return size.height / 2 }
        return min(max(proposed, margin), size.height - margin)
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
                ApprovalCard(approval: approval, onClose: approvals.dismissCard)
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
                    }
                    .onHover { approvals.cardHoverChanged($0) }
                    .position(x: x, y: clampedCenterY(proposedY, cardHeight: cardHeight, in: geometry.size))
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.97)))
                    .zIndex(200)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: approvals.presentedApproval?.id)
        .ignoresSafeArea()
    }
}

private struct ApprovalCard: View {
    private enum FocusedAction: Hashable {
        case details
        case deny
        case allow
    }

    let approval: ApprovalPresentation
    let onClose: () -> Void
    @Environment(ApprovalPresentationStore.self) private var approvals
    @Environment(WindowSession.self) private var session
    @State private var showsDetails = false
    @State private var allowIsEnabled = false
    @State private var allowDelayTask: Task<Void, Never>?
    @State private var resolvingDecision: String?
    @FocusState private var focusedAction: FocusedAction?

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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: "\(approval.provider.rawValue.capitalized)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(LimpidColor.rowActiveFill, in: Capsule())
                Text(verbatim: approval.toolName)
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
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
            if let paneContext {
                Text(verbatim: paneContext)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
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
            HStack {
                Button(isResolving && resolvingDecision == "deny" ? "Sending…" : "Deny") {
                    resolvingDecision = "deny"
                    approvals.resolve(approval, decision: "deny")
                }
                .buttonStyle(.bordered)
                .approvalActionCursor()
                .focused($focusedAction, equals: .deny)
                .accessibilityLabel(Text(isResolving && resolvingDecision == "deny" ? "Sending denial" : "Deny"))
                Spacer()
                Button(isResolving && resolvingDecision == "allow_once" ? "Sending…" : "Allow once") {
                    resolvingDecision = "allow_once"
                    approvals.resolve(approval, decision: "allow_once")
                }
                .buttonStyle(.borderedProminent)
                .approvalActionCursor()
                .focused($focusedAction, equals: .allow)
                .accessibilityLabel(Text(isResolving && resolvingDecision == "allow_once" ? "Sending approval" : "Allow once"))
                .disabled(!allowIsEnabled || isResolving)
            }
            .disabled(isResolving)
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.12), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.18), radius: 18, y: 6)
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
            // focus bridge. Defer one turn so Deny, not the terminal, receives
            // the initial keyboard focus.
            await Task.yield()
            guard !Task.isCancelled else { return }
            focusedAction = .deny
            approvals.cardFocusChanged(focusedAction != nil, for: approval)
            approvals.cardFocusRequestCompleted(for: approval)
        }
        .background(ApprovalCardKeyMonitor(onEscape: onClose))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Approval request"))
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
    let onEscape: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onEscape: onEscape)
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
        weak var hostWindow: NSWindow?
        private var monitor: Any?

        init(onEscape: @escaping () -> Void) {
            self.onEscape = onEscape
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
