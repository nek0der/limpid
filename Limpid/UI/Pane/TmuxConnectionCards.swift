// TmuxConnectionCards.swift
// Limpid — the notice a mirror pane shows when typing into it went nowhere, and the card of a pane whose source cannot be read.

import SwiftUI

/// The one-line notice a mirror pane shows when typing into it went
/// nowhere. It is the whole of what a tab that is not live says over its
/// panes: the chip in the toolbar carries the state at all times, and a
/// state that sat over the panes could only say it by covering them.
///
/// Raised by typing rather than by the state, because the state alone is
/// not news — a tab can sit disconnected for as long as the user likes,
/// and only a keystroke that went nowhere is something they need told.
/// Floated over the pane area's top-right corner: the area's height is the
/// size a mirror tab gives its tmux window, and a row of its own would
/// resize that window for everyone attached to it (decision D3).
struct TmuxDroppedInputNotice: View {
    let tabID: UUID
    @Environment(WindowSession.self) private var session
    @Environment(\.tmuxConnectionStore) private var tmuxStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// How long the notice stays. Long enough to read in passing, short
    /// enough that it is gone before the next thing the user does.
    static let duration: Duration = .seconds(3)

    @State private var isShowing = false

    /// The drop the store last recorded, when it was in a pane of this tab.
    /// A drop in another tab's pane is another tab's news.
    private var drop: TmuxConnectionStore.DroppedInput? {
        guard let drop = tmuxStore?.droppedInput,
              let tab = session.tab(tabID),
              tab.splitTree.contains(leafID: drop.paneID)
        else { return nil }
        return drop
    }

    var body: some View {
        VStack(spacing: 0) {
            if isShowing {
                notice
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .transition(reduceMotion ? .identity : .opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topTrailing)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: isShowing)
        // Keyed on the drop itself, so typing on while the notice is up
        // restarts the wait rather than letting it expire mid-sentence.
        .task(id: drop) {
            guard drop != nil else {
                isShowing = false
                return
            }
            isShowing = true
            AccessibilityNotification.Announcement(String(localized: "Input isn't reaching tmux")).post()
            try? await Task.sleep(for: Self.duration)
            guard !Task.isCancelled else { return }
            isShowing = false
        }
    }

    private var notice: some View {
        HStack(spacing: 10) {
            Image(systemName: TmuxStatePresentation.disconnected.symbol)
                .foregroundStyle(TmuxStatePresentation.Severity.warning.color)
                .accessibilityHidden(true)
            Text("Input isn't reaching tmux")
                .font(LimpidFont.bodySecondary)
                .foregroundStyle(LimpidColor.primaryText)
            Button("Reconnect") { reconnect() }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!canReconnect)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            .regularMaterial,
            in: RoundedRectangle(cornerRadius: LimpidLayout.paneBannerCornerRadius, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: LimpidLayout.paneBannerCornerRadius, style: .continuous)
                .stroke(Color.primary.opacity(0.12), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
        .pointerStyle(.default)
        .accessibilityElement(children: .contain)
    }

    private var canReconnect: Bool {
        guard let tmuxStore else { return false }
        return tmuxStore.tmuxExecutable != nil && tmuxStore.canReconnect(tabID: tabID)
    }

    private func reconnect() {
        guard let tmuxStore else { return }
        isShowing = false
        TmuxMirrorActions.reconnectAsked(tabID: tabID, session: session, store: tmuxStore)
    }
}

/// Laid over a pane whose source this build cannot read, the way
/// `PaneCreationFailureCard` is: the surface behind it is fed nothing, so
/// there is nothing underneath worth keeping in view.
struct UnavailablePaneCard: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "questionmark.square.dashed")
                .font(.system(size: 22))
                .foregroundStyle(LimpidColor.secondaryText)
                .accessibilityHidden(true)
            Text(UnavailablePaneCardContent.title)
                .font(LimpidFont.headline)
                .foregroundStyle(LimpidColor.primaryText)
                .accessibilityAddTraits(.isHeader)
            Text(UnavailablePaneCardContent.message)
                .font(LimpidFont.bodySecondary)
                .foregroundStyle(LimpidColor.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 24)
        .background(
            .regularMaterial,
            in: RoundedRectangle(cornerRadius: LimpidLayout.paneBannerCornerRadius, style: .continuous)
        )
        .pointerStyle(.default)
        .accessibilityElement(children: .combine)
    }
}
