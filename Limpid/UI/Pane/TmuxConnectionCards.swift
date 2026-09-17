// TmuxConnectionCards.swift
// Limpid — the banner a mirror tab shows while it is not live, and the card of a pane whose source cannot be read.

import SwiftUI

/// The connection banner of mirror tab `tabID`, floated over the top of its
/// pane area. It floats rather than taking a row of its own: the space it
/// took would shrink the pane area, which a mirror tab reports to the store
/// as the size its tmux window is given, so a reconnect would size the
/// window down and back up for everyone attached to it. The panes stay as
/// they are underneath, so what they show can still be scrolled and
/// selected (stage 11 decision 4); the few lines the banner covers are
/// reached by scrolling.
///
/// The host has no hit-test shape of its own, so only the banner takes
/// clicks.
struct TmuxConnectionBanner: View {
    let tabID: UUID
    @Environment(WindowSession.self) private var session
    @Environment(AttentionState.self) private var attention
    @Environment(\.surfaceRegistry) private var registry
    @Environment(\.tmuxConnectionStore) private var tmuxStore
    @Environment(\.agentProjection) private var agentProjection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Read in the body, so a change to the tab's record or to its mirror
    /// redraws the banner.
    private var content: TmuxConnectionCardContent? {
        guard let tmuxStore,
              let tab = session.tab(tabID),
              let ref = TmuxMirrorActions.mirrorRef(of: tab)
        else { return nil }
        return TmuxConnectionCardContent.make(
            connection: tmuxStore.tabConnections[tabID],
            hasMirror: tmuxStore.mirror(for: tabID) != nil,
            canReconnect: tmuxStore.tmuxExecutable != nil && tmuxStore.canReconnect(tabID: tabID),
            sessionName: ref.binding.sessionName
        )
    }

    var body: some View {
        let content = content
        VStack(spacing: 0) {
            if let content {
                TmuxConnectionCard(content: content, perform: perform)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .transition(reduceMotion ? .identity : .move(edge: .top).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: content?.kind)
        // The banner stays up across the change, so VoiceOver would not
        // otherwise hear that a reconnect began or how it ended.
        .onChange(of: content?.kind) { _, kind in
            guard kind != nil, let content = self.content else { return }
            AccessibilityNotification.Announcement(String(localized: content.title)).post()
        }
    }

    private func perform(_ action: TmuxConnectionCardContent.Action) {
        switch action {
        case .reconnect:
            guard let tmuxStore else { return }
            TmuxMirrorActions.reconnectAsked(tabID: tabID, session: session, store: tmuxStore)
        case .closeTab:
            TabActions.closeTab(
                session,
                registry: registry,
                tabID: tabID,
                source: .mouse,
                attention: attention,
                agentProjection: agentProjection
            )
        }
    }
}

private struct TmuxConnectionCard: View {
    let content: TmuxConnectionCardContent
    let perform: (TmuxConnectionCardContent.Action) -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            leadingMark
                .frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(content.title)
                    .font(LimpidFont.headline)
                    .foregroundStyle(LimpidColor.primaryText)
                    .accessibilityAddTraits(.isHeader)
                if let message = content.message {
                    Text(message)
                        .font(LimpidFont.bodySecondary)
                        .foregroundStyle(LimpidColor.secondaryText)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            ForEach(content.actions, id: \.self) { action in
                button(for: action, isDefault: action == content.actions.last)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: 640)
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

    @ViewBuilder private var leadingMark: some View {
        switch content.kind {
        case .connecting:
            ProgressView()
                .controlSize(.small)
        case .disconnected:
            Image(systemName: "bolt.horizontal.circle")
                .foregroundStyle(LimpidColor.secondaryText)
        case .unreachable:
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(LimpidColor.warning)
        case .serverReplaced:
            Image(systemName: "clock.arrow.circlepath")
                .foregroundStyle(LimpidColor.secondaryText)
        }
    }

    @ViewBuilder
    private func button(for action: TmuxConnectionCardContent.Action, isDefault: Bool) -> some View {
        let label: LocalizedStringKey = switch action {
        case .reconnect: "Reconnect"
        case .closeTab: "Close Tab"
        }
        if isDefault {
            Button(label) { perform(action) }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        } else {
            Button(label) { perform(action) }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
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
