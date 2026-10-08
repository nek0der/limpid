// PromptCachePanel.swift
// Limpid — the panel a prompt cache clock opens: what the cache costs now,
// and, once it has expired, the three ways to go on.
//
// Drawn as a scene-root overlay on the command palette's surface rather
// than through `.popover`. A popover brings its own arrow, frame, and
// corner radius, none of which can be changed, so it could never match the
// app's other floating panel; and with one open, a click elsewhere only
// dismissed it, as `PRHoverCard` records. The clocks are also the wrong
// place to draw it: the panel is wider than the tab row or the pane header it
// hangs from, and each of those clips. `ContentView`
// hosts it with its neighbors, as it does the PR card.
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
    @Environment(PaneRenamePresentation.self) private var renamePresentation
    @Environment(ApprovalPresentationStore.self) private var approvalPresentation
    @Environment(NotificationHistoryPresentation.self) private var historyPresentation
    @Environment(PRHoverPresentation.self) private var prHoverPresentation
    @Environment(\.surfaceRegistry) private var registry
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.appearsActive) private var appearsActive

    /// The panel's measured height, for keeping it inside the window. Zero
    /// until the first layout, which places it below the clock.
    @State private var panelHeight: CGFloat = 0
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

    /// Another floating panel, or review, is up. The cache panel does not
    /// open by itself over one: it would cover what the user is working in.
    private var isAnotherPanelOpen: Bool {
        session.commandPaletteState != nil
            || renamePresentation.request != nil
            || approvalPresentation.presentedID != nil
            || historyPresentation.isPresented
            || prHoverPresentation.visible != nil
            || reviewPresentation.isPresented
    }

    var body: some View {
        GeometryReader { overlayGeo in
            if let request = presentation.request, let content = openContent {
                let overlayOrigin = overlayGeo.frame(in: .global).origin
                let anchor = request.anchor.offsetBy(dx: -overlayOrigin.x, dy: -overlayOrigin.y)
                let width = LimpidLayout.promptCachePanelWidth
                // Centered under the clock, so it reads as hanging from it,
                // then kept inside the window; near the window's bottom it
                // opens above the clock instead.
                let panelSize = CGSize(width: width, height: panelHeight)
                let origin = PaneRenamePresentation.panelOrigin(
                    anchor: CGRect(x: anchor.midX - width / 2, y: anchor.minY, width: width, height: anchor.height),
                    panelSize: panelSize,
                    container: overlayGeo.size,
                    margin: LimpidLayout.floatingPanelWindowMargin,
                    gap: LimpidLayout.promptCachePanelAnchorGap
                )
                // Points at the clock from wherever the clamping above put
                // the panel, so the panel says where it came from even when
                // it has slid over a neighboring pane.
                let arrow = PromptCachePanelPresentation.arrowPlacement(
                    anchor: anchor,
                    panelOrigin: origin,
                    panelSize: panelSize,
                    minimumInset: LimpidLayout.promptCachePanelArrowInset
                )
                PromptCachePanelView(
                    content: content,
                    paneLine: attention.promptCachePaneLine(for: request.target, in: session)
                ) { action in
                    perform(action, request: request, content: content)
                }
                .floatingPanelSurface(in: PromptCachePanelShape(
                    cornerRadius: LimpidLayout.floatingPanelCornerRadius,
                    arrow: arrow,
                    arrowHeight: LimpidLayout.promptCachePanelArrowHeight
                ))
                .pointerStyle(.default)
                .fixedSize()
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { panelHeight = $0 }
                // Held back until measured: placed with no height, a panel
                // near the window's bottom would show below its clock for a
                // frame and then jump above it.
                .opacity(panelHeight > 0 ? 1 : 0)
                .onHover { presentation.panelHoverChanged($0) }
                .background(PromptCachePanelEventMonitor(presentation: presentation))
                .offset(x: origin.x, y: origin.y)
                .transition(.opacity)
                .id(request.id)
            }
        }
        .ignoresSafeArea()
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { windowBounds = $0 }
        .animation(reduceMotion ? nil : LimpidMotion.paletteToggle, value: presentation.request?.id)
        // Each panel is measured afresh: the last one's height belongs to
        // content that may have had another line or no buttons.
        .onChange(of: presentation.request?.id) { _, _ in panelHeight = 0 }
        .onChange(of: isAnotherPanelOpen, initial: true) { _, isOpen in
            presentation.isPointerOpenSuppressed = isOpen
        }
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
                    isAnotherPanelOpen: isAnotherPanelOpen,
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
    /// `AttentionState.promptCachePaneLine(for:in:)`.
    let paneLine: String
    let onAction: (PromptCacheAction) -> Void

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
                        Text(verbatim: content.title)
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
                    ForEach(content.lines(now: now), id: \.self) { line in
                        Text(verbatim: line)
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
                        Text(verbatim: block.reason)
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
        .frame(width: LimpidLayout.promptCachePanelWidth, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: "\(content.title), \(paneLine)"))
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
        let reason = content.commandBlock.map { Text(verbatim: $0.reason) } ?? help
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

/// The panel's outline: its rounded rectangle with an arrow on the edge that
/// faces its clock, drawn as one closed path so the surface fills and
/// strokes it as one piece, with no seam where the arrow meets the edge. The
/// arrow stands outside the panel's frame, in the gap left for it.
struct PromptCachePanelShape: Shape {
    let cornerRadius: CGFloat
    /// Nil draws the plain rounded rectangle.
    let arrow: PromptCachePanelPresentation.ArrowPlacement?
    /// How far the tip stands out, which is also the half-width of its base,
    /// as for a square turned 45 degrees.
    let arrowHeight: CGFloat

    func path(in rect: CGRect) -> Path {
        let radius = min(cornerRadius, rect.width / 2, rect.height / 2)
        let topArrowX = arrow?.edge == .top ? arrow.map { rect.minX + $0.x } : nil
        let bottomArrowX = arrow?.edge == .bottom ? arrow.map { rect.minX + $0.x } : nil
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + radius, y: rect.minY))
        if let x = topArrowX {
            path.addLine(to: CGPoint(x: x - arrowHeight, y: rect.minY))
            path.addLine(to: CGPoint(x: x, y: rect.minY - arrowHeight))
            path.addLine(to: CGPoint(x: x + arrowHeight, y: rect.minY))
        }
        path.addArc(
            tangent1End: CGPoint(x: rect.maxX, y: rect.minY),
            tangent2End: CGPoint(x: rect.maxX, y: rect.maxY),
            radius: radius
        )
        path.addArc(
            tangent1End: CGPoint(x: rect.maxX, y: rect.maxY),
            tangent2End: CGPoint(x: rect.minX, y: rect.maxY),
            radius: radius
        )
        if let x = bottomArrowX {
            path.addLine(to: CGPoint(x: x + arrowHeight, y: rect.maxY))
            path.addLine(to: CGPoint(x: x, y: rect.maxY + arrowHeight))
            path.addLine(to: CGPoint(x: x - arrowHeight, y: rect.maxY))
        }
        path.addArc(
            tangent1End: CGPoint(x: rect.minX, y: rect.maxY),
            tangent2End: CGPoint(x: rect.minX, y: rect.minY),
            radius: radius
        )
        path.addArc(
            tangent1End: CGPoint(x: rect.minX, y: rect.minY),
            tangent2End: CGPoint(x: rect.maxX, y: rect.minY),
            radius: radius
        )
        path.closeSubpath()
        return path
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

/// Watches the window's keys and clicks while the panel is open, so Escape,
/// typing at the prompt, and a click outside close it. An AppKit monitor
/// because the keyboard stays with the terminal while the panel is up: the
/// panel never takes focus, so SwiftUI's own key handling would not see the
/// keys.
private struct PromptCachePanelEventMonitor: NSViewRepresentable {
    let presentation: PromptCachePanelPresentation

    func makeNSView(context _: Context) -> MonitorView {
        let view = MonitorView()
        view.presentation = presentation
        return view
    }

    func updateNSView(_ view: MonitorView, context _: Context) {
        view.presentation = presentation
    }

    static func dismantleNSView(_ view: MonitorView, coordinator _: ()) {
        view.removeMonitor()
    }

    @MainActor final class MonitorView: NSView {
        weak var presentation: PromptCachePanelPresentation?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                removeMonitor()
            } else {
                installMonitor()
            }
        }

        private func installMonitor() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(
                matching: [.keyDown, .leftMouseDown, .rightMouseDown]
            ) { [weak self] event in
                guard let self, let presentation, let window, event.window === window else { return event }
                guard event.type == .keyDown else {
                    // A click on the panel itself is for its buttons. Asked
                    // of the panel's frame rather than of its hover state: a
                    // panel that opened by itself under a pointer that never
                    // moved has had no hover, and closing it here would eat
                    // the click before the button sees it. This view is the
                    // panel's background, so its bounds are the panel's.
                    if !bounds.contains(convert(event.locationInWindow, from: nil)) {
                        presentation.pointerPressed()
                    }
                    return event
                }
                // An input method composing text owns its keys, Escape
                // included.
                if let input = window.firstResponder as? any NSTextInputClient, input.hasMarkedText() {
                    return event
                }
                let isEscape = event.namedKey == .escape
                    && event.modifierFlags.isDisjoint(with: [.command, .control, .option, .shift])
                // Other keys close the panel only while they go to a
                // terminal, which is typing at a prompt. Keys moving through
                // the panel's own buttons, as Full Keyboard Access does,
                // leave it open.
                guard isEscape || window.firstResponder is SurfaceView else { return event }
                return presentation.keyPressed(isEscape: isEscape) ? nil : event
            }
        }

        func removeMonitor() {
            guard let monitor else { return }
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }
}
