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
    @Environment(SettingsStore.self) private var settings
    @Environment(\.surfaceRegistry) private var registry
    @Environment(\.tmuxConnectionStore) private var tmuxStore
    @Environment(\.agentProjection) private var agentProjection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Whether `.connecting` has lasted long enough to be worth saying. See
    /// `connectingDelay`.
    @State private var showsConnecting = false

    /// How long a tab may be connecting before the banner says so. At launch
    /// every restored mirror tab connects at once, and a banner that appears
    /// and goes again in a few hundred milliseconds is noise on every tab
    /// rather than news about one. A connect that takes longer than this is
    /// the one worth showing.
    static let connectingDelay: Duration = .seconds(1)

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
            tmuxSupport: settings.agentTmuxSupport,
            // An agent's session is named after the launch, not after
            // anything the user typed, so the card names the agent instead.
            sessionName: TmuxConnectionStore.noticeName(of: tab, tmuxName: ref.binding.sessionName)
        )
    }

    /// What the banner shows of `content`: everything but a connect that has
    /// not yet lasted `connectingDelay`. Every other state appears at once —
    /// only connecting is both common and short-lived.
    static func visibleContent(
        _ content: TmuxConnectionCardContent?,
        showsConnecting: Bool
    ) -> TmuxConnectionCardContent? {
        guard let content, content.state == .connecting else { return content }
        return showsConnecting ? content : nil
    }

    /// What VoiceOver hears when the banner changes. Heading and body
    /// together: the heading alone says a reconnect ended without saying how.
    private func announcement(_ content: TmuxConnectionCardContent) -> String {
        let title = String(localized: content.title)
        guard let message = content.message else { return title }
        return "\(title) \(String(localized: message))"
    }

    var body: some View {
        let content = Self.visibleContent(content, showsConnecting: showsConnecting)
        VStack(spacing: 0) {
            if let content {
                TmuxConnectionCard(content: content, perform: perform)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .transition(reduceMotion ? .identity : .move(edge: .top).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: content?.state)
        // Restarted whenever the state changes, so a tab that stops
        // connecting — or starts again — is timed from that moment, and the
        // wait is dropped with the view.
        .task(id: self.content?.state) {
            showsConnecting = false
            guard self.content?.state == .connecting else { return }
            try? await Task.sleep(for: Self.connectingDelay)
            guard !Task.isCancelled else { return }
            showsConnecting = true
        }
        // The banner stays up across the change, so VoiceOver would not
        // otherwise hear that a reconnect began or how it ended. A reconnect
        // that worked takes the banner away entirely, which is the one
        // outcome nothing on screen is left to announce. Announced from what
        // is shown, so a connect too short to appear is not spoken either.
        .onChange(of: content?.state) { old, state in
            guard state != nil else {
                guard old != nil, session.tab(tabID) != nil else { return }
                AccessibilityNotification.Announcement(String(localized: "Connected to tmux")).post()
                return
            }
            guard let content = Self.visibleContent(self.content, showsConnecting: showsConnecting) else { return }
            AccessibilityNotification.Announcement(announcement(content)).post()
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
                button(for: action, isProminent: action == content.primaryAction)
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
        if content.showsProgress {
            ProgressView()
                .controlSize(.small)
        } else {
            // Symbol and color come from the shared vocabulary, so the mark
            // in this tab's row stands for the same state in the same way.
            Image(systemName: content.state.symbol)
                .foregroundStyle(content.state.severity.color)
        }
    }

    /// Reconnecting is the only action the card emphasizes, and it is
    /// emphasized by weight alone: the banner floats over panes whose
    /// surface holds first responder, so Return goes to the terminal and a
    /// button marked as the window's default action would promise a key that
    /// never reaches it.
    @ViewBuilder
    private func button(for action: TmuxConnectionCardContent.Action, isProminent: Bool) -> some View {
        let label: LocalizedStringKey = switch action {
        case .reconnect: "Reconnect"
        case .closeTab: "Close Tab"
        }
        if isProminent {
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
