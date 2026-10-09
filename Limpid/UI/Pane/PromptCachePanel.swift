// PromptCachePanel.swift
// Limpid — the panel a prompt cache clock opens: what the cache costs now,
// and, once it has expired, the three ways to go on.
//
// One of Limpid's arrowed floating panels (`FloatingPanel.swift`), drawn
// at scene root rather than through `.popover`. The clocks are the wrong
// place to draw it: the panel is wider than the tab row or the pane header
// it hangs from, and each of those clips. `FloatingPanelLayer` hosts it
// with the other floating panels.
//
// What the panel says and when it opens by itself are Core's rules
// (`PromptCacheRules`, `AttentionState+PromptCache`); this file lays them
// out and carries out the answers against the pane's terminal.

import AppKit
import SwiftUI

/// Hosts the open panel at scene root, below its clock, and opens it by
/// itself when focus arrives at a pane whose cache has expired.
struct PromptCachePanelHost: View {
    @Environment(PromptCachePanelPresentation.self) private var presentation
    @Environment(AttentionState.self) private var attention
    @Environment(WindowSession.self) private var session
    @Environment(SettingsStore.self) private var settingsStore
    @Environment(ReviewPresentation.self) private var reviewPresentation
    @Environment(\.surfaceRegistry) private var registry
    @Environment(\.appearsActive) private var appearsActive
    @Environment(\.locale) private var locale

    /// The pending look at whether the panel should open by itself; see
    /// `scheduleAutoOpen()`.
    @State private var autoOpenTask: Task<Void, Never>?
    /// This overlay's frame in global coordinates, which is the window's
    /// content: a clock outside it cannot anchor a panel that opens by
    /// itself.
    @State private var windowBounds: CGRect = .zero

    /// The open panel's content, or nil when nothing is open or the clock it
    /// hung from has nothing left to say. Read against the pane's terminal,
    /// so the commands are disabled while they could not be typed.
    private var openContent: PromptCachePanelContent? {
        presentation.request.flatMap { request in
            attention.promptCachePanelContent(
                for: request.target,
                typist: registry.view(for: request.target.paneID)
            )
        }
    }

    /// The pane the keyboard is in, by the split tree's reading, and its tab.
    /// Focus arriving there is what the panel opens by itself on.
    private var focusedPane: PromptCacheFocusedPane? {
        guard let tab = session.activeTab, let paneID = tab.splitTree.effectiveFocusedLeafID else { return nil }
        return PromptCacheFocusedPane(tabID: tab.id, paneID: paneID)
    }

    var body: some View {
        FloatingPanelHost(
            request: openContent == nil ? nil : presentation.request,
            width: LimpidLayout.promptCachePanelWidth,
            style: .arrowed,
            onPointerPressedOutside: { presentation.pointerPressed() },
            onKey: { key in
                // Other keys close the panel only while they go to a
                // terminal, which is typing at a prompt. Keys moving
                // through the panel's own buttons, as Full Keyboard Access
                // does, leave it open.
                guard key.isEscape || key.isTypingInTerminal else { return false }
                return presentation.keyPressed(isEscape: key.isEscape)
            },
            onHover: { presentation.panelHoverChanged($0) },
            content: { request in
                if let content = openContent {
                    PromptCachePanelView(
                        content: content,
                        paneLine: attention.promptCachePaneLine(for: request.target, in: session, locale: locale)
                    ) { action in
                        perform(action, request: request, content: content)
                    }
                }
            }
        )
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { windowBounds = $0 }
        // Shown counts once the panel is up for an expired cache: when it
        // opens, and when a panel opened while yellow turns red under the
        // pointer, so neither opens by itself again for that expiry.
        .onChange(of: PromptCacheShownState(requestID: presentation.request?.id, isExpired: openContent?.isExpired)) {
            if let request = presentation.request {
                attention.notePromptCachePanelShown(request.target)
            }
        }
        // The run's turn started, the expiry was answered elsewhere, or a
        // new window replaced it: the clock is gone, and so is its panel.
        .onChange(of: presentation.request != nil && openContent == nil) { _, isStale in
            if isStale {
                presentation.close()
            }
        }
        .onChange(of: focusedPane, initial: true) { _, _ in scheduleAutoOpen() }
        .onChange(of: appearsActive) { _, isActive in
            // Coming back to the window is arriving at its focused pane.
            if isActive {
                scheduleAutoOpen()
            } else {
                autoOpenTask?.cancel()
            }
        }
    }

    /// Looks, once focus has settled, at whether the focused pane's panel
    /// should open by itself. The wait lets a tab switch lay out the clock
    /// the panel hangs from, and lets a walk across panes pass through
    /// without a panel opening at each one; a newer arrival replaces it.
    private func scheduleAutoOpen() {
        autoOpenTask?.cancel()
        guard appearsActive else { return }
        autoOpenTask = Task { @MainActor in
            try? await Task.sleep(for: PromptCacheRules.autoOpenSettle)
            guard !Task.isCancelled, let pane = focusedPane, let tab = session.tab(containing: pane.paneID) else {
                return
            }
            attention.autoOpenPromptCachePanel(
                paneID: pane.paneID,
                in: PromptCacheAutoOpenWindow(
                    tabID: pane.tabID,
                    showsPaneHeader: PaneHeaderRules.showsHeader(
                        in: tab,
                        isEnabled: settingsStore.settings.terminal.showsSplitPaneHeaders,
                        isReviewPresented: reviewPresentation.isPresented
                    ),
                    // Read now, when the panel would open: a surface that
                    // came up during the wait counts.
                    isAnotherPanelOpen: presentation.isAnotherSurfaceOpen,
                    bounds: windowBounds
                ),
                presentation: presentation
            )
        }
    }

    /// Carries out one answer against the pane's terminal. A command that
    /// went through brings its pane forward, so the user sees it run, even
    /// when the panel was opened from another tab's row; otherwise the
    /// keyboard goes back to the pane if it is in view, since the button
    /// took the click. Why a refusal happened is logged in Core.
    private func perform(
        _ action: PromptCacheAction,
        request: PromptCachePanelPresentation.Request,
        content: PromptCachePanelContent
    ) {
        presentation.close()
        let paneID = request.target.paneID
        let expired = ExpiredPromptCache(runtimeID: request.target.runtimeID, paneID: paneID, window: content.window)
        let isDone = attention.performPromptCacheAction(action, for: expired, typist: registry.view(for: paneID))
        if !isDone {
            // The click did nothing visible, so say so rather than leave the
            // user wondering whether it registered.
            NSSound.beep()
        }
        if isDone, action.command != nil, let tabID = session.tab(containing: paneID)?.id {
            PaneActions.activateAndFocus(session, registry: registry, tabID: tabID, paneID: paneID)
        } else if session.activeTab?.splitTree.allLeafIDs().contains(paneID) == true {
            PaneActions.pullKeyboardFocus(to: paneID, registry: registry)
        }
    }
}

/// The focused pane as `PromptCachePanelHost` watches it.
private struct PromptCacheFocusedPane: Equatable {
    let tabID: UUID
    let paneID: UUID
}

/// What decides whether the open panel counts as shown for an expiry: which
/// panel is open, and whether its cache has expired.
private struct PromptCacheShownState: Equatable {
    let requestID: UUID?
    let isExpired: Bool?
}

/// The panel's body: the clock and title, the sentences, and, when the
/// cache has expired, the three answers.
struct PromptCachePanelView: View {
    let content: PromptCachePanelContent
    /// The pane the panel is about, by its header's name and directory; see
    /// `AttentionState.promptCachePaneLine(for:in:locale:)`.
    let paneLine: String
    let onAction: (PromptCacheAction) -> Void

    @Environment(\.locale) private var locale

    var body: some View {
        // Once a minute, so "expired 12m ago" keeps up while it is open.
        TimelineView(.everyMinute) { context in
            panel(now: context.date)
        }
    }

    private func panel(now: Date) -> some View {
        VStack(alignment: .leading, spacing: LimpidLayout.promptCachePanelSectionSpacing) {
            VStack(alignment: .leading, spacing: LimpidLayout.promptCachePanelTitleSpacing) {
                VStack(alignment: .leading, spacing: LimpidLayout.promptCachePanelPaneLineSpacing) {
                    HStack(spacing: LimpidLayout.promptCachePanelTitleGlyphSpacing) {
                        Image(systemName: "clock")
                            .font(.system(size: LimpidLayout.promptCacheClockFontSize, weight: .semibold))
                            .foregroundStyle(content.isExpired ? LimpidColor.promptCacheExpired : LimpidColor.warning)
                            .frame(width: LimpidLayout.promptCachePanelTitleGlyphWidth)
                            .accessibilityHidden(true)
                        Text(content.title)
                            .font(.system(size: LimpidLayout.promptCachePanelTitleFontSize, weight: .semibold))
                            .foregroundStyle(LimpidColor.primaryText)
                            .accessibilityAddTraits(.isHeader)
                    }
                    // Which pane this is about. In a split tab every header
                    // can carry a red clock, and a panel that slid over a
                    // neighbor would otherwise leave that to guesswork.
                    // Spoken as part of the panel's label instead.
                    Text(verbatim: paneLine)
                        .font(.system(size: LimpidLayout.promptCachePanelPaneLineFontSize))
                        .foregroundStyle(LimpidColor.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .padding(
                            .leading,
                            LimpidLayout.promptCachePanelTitleGlyphWidth + LimpidLayout.promptCachePanelTitleGlyphSpacing
                        )
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: LimpidLayout.promptCachePanelLineSpacing) {
                    ForEach(Array(content.lines(now: now, locale: locale).enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .font(.system(size: LimpidLayout.promptCachePanelTextFontSize))
                .foregroundStyle(LimpidColor.primaryText)
            }
            if !content.actions.isEmpty {
                VStack(alignment: .leading, spacing: LimpidLayout.promptCachePanelButtonSpacing) {
                    // Why the two commands are gray, said in the panel: a
                    // disabled button's tooltip does not reliably show on
                    // macOS, so the help alone would leave them unexplained.
                    if let block = content.commandBlock {
                        Text(block.reason)
                            .font(.system(size: LimpidLayout.promptCachePanelTextFontSize))
                            .foregroundStyle(LimpidColor.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                            // The buttons carry it as their hint already.
                            .accessibilityHidden(true)
                    }
                    ForEach(content.actions, id: \.self) { action in
                        button(for: action)
                    }
                }
            }
        }
        .padding(LimpidLayout.promptCachePanelPadding)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: "\(content.title.resolved(in: locale)), \(paneLine)"))
    }

    @ViewBuilder
    private func button(for action: PromptCacheAction) -> some View {
        switch action {
        case .summarize:
            command(
                Text("Summarize and continue"),
                help: Text("Reads the whole conversation once; later turns are light."),
                action: action
            )
        case .newConversation:
            command(
                Text("Continue in a new conversation"),
                help: Text("No re-write cost. Return with /resume."),
                action: action
            )
        case .continueAsIs:
            let button = Button {
                onAction(action)
            } label: {
                Text("Continue as is")
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(PromptCacheButtonStyle(isProminent: false))
            // The cost, when the provider reported it; the panel's own
            // sentence says it too, so nothing is lost without it.
            if let tokens = content.window.rewriteTokens {
                let size = PromptCacheFormatting.tokens(tokens)
                button
                    .help(Text("Re-writes about \(size) tokens."))
                    .accessibilityHint(Text("Re-writes about \(size) tokens."))
            } else {
                button
            }
        }
    }

    /// One of the two answers that type a command. Disabled, saying why,
    /// while the command could not land on an empty prompt of the agent's:
    /// it is busy or not in front, or the prompt may hold unsent text. The
    /// same checks run again when it is pressed.
    private func command(_ title: Text, help: Text, action: PromptCacheAction) -> some View {
        let reason = content.commandBlock.map { Text($0.reason) } ?? help
        return Button {
            onAction(action)
        } label: {
            title
                .lineLimit(1)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(PromptCacheButtonStyle(isProminent: true))
        .disabled(!content.canTypeCommands)
        .help(reason)
        .accessibilityLabel(title)
        .accessibilityHint(reason)
    }
}

/// The panel's buttons: a filled, outlined pair for the two commands, and a
/// borderless one for leaving things as they are, which does nothing and
/// should not look like it does as much as the other two.
private struct PromptCacheButtonStyle: ButtonStyle {
    let isProminent: Bool
    @Environment(\.isEnabled) private var isEnabled

    /// The press tint laid over a command button's fill.
    private static let pressedOverlayOpacity = 0.08
    /// A disabled button stays legible, so its label and the reason in its
    /// help still read, but plainly not pressable.
    private static let disabledOpacity = 0.45

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: LimpidLayout.promptCacheButtonCornerRadius, style: .continuous)
        configuration.label
            .font(.system(size: LimpidLayout.promptCachePanelTextFontSize))
            .foregroundStyle(isProminent ? LimpidColor.primaryText : LimpidColor.secondaryText)
            .padding(.horizontal, LimpidLayout.promptCacheButtonHorizontalPadding)
            .padding(
                .vertical,
                isProminent
                    ? LimpidLayout.promptCacheButtonVerticalPadding
                    : LimpidLayout.promptCachePlainButtonVerticalPadding
            )
            .background {
                if isProminent {
                    shape.fill(LimpidColor.promptCacheButtonFill)
                        .overlay(shape.fill(.primary.opacity(configuration.isPressed ? Self.pressedOverlayOpacity : 0)))
                }
            }
            .overlay {
                if isProminent {
                    shape.strokeBorder(LimpidColor.promptCacheButtonEdge, lineWidth: 1)
                }
            }
            .opacity(isEnabled ? 1 : Self.disabledOpacity)
            .contentShape(shape)
    }
}
