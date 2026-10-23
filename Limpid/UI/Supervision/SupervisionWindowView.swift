// SupervisionWindowView.swift
// Limpid — the root of the supervision window, drawn in an app-owned window.

import SwiftUI

/// The supervision window's root: the title bar over the rail, the
/// sessions sidebar, and the window's body.
///
/// The body is the selected session: its header, its pane strip, and its
/// terminal (`SessionAreaView`). The sidebar, the session, and the changes
/// panel each stand on a surface of their own, 6pt apart on the window's
/// darker ground.
struct SupervisionWindowView: View {
    let state: AppState
    let app: GhosttyApp
    @Environment(ProjectWindowState.self) private var window
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.appearsActive) private var appearsActive
    /// The body under the title bar, in global coordinates.
    @State private var bodyFrame: CGRect = .zero

    /// Each surface's own space, which what is drawn on it measures itself
    /// in to find the surface's edges and corners.
    nonisolated static let surfaceSpace = "supervisionSurface"

    private var session: WorkspaceSession {
        state.session
    }

    /// This window's own selection: its sidebar, its frame, its session.
    private var selection: WindowSelection {
        window.selection
    }

    var body: some View {
        VStack(spacing: 0) {
            SupervisionTitleBar()
            HStack(spacing: LimpidLayout.Supervision.surfaceGap) {
                // Hidden from the View menu; its keys keep working.
                if !window.areRailsHidden {
                    LeftRailView()
                }
                HStack(spacing: LimpidLayout.Supervision.surfaceGap) {
                    if isSidebarShown {
                        sidebar
                            // One piece as it slides: what is placed in it
                            // after the slide began takes its place from
                            // where the sidebar is drawn, not where it will
                            // end (`ViewThatFits`, below for the panel).
                            .geometryGroup()
                            .transition(reduceMotion ? .identity : .move(edge: .leading).combined(with: .opacity))
                    }
                    // A window that shows nothing offers the projects to
                    // open where the session would be.
                    Group {
                        if selection.isChoosingProject {
                            EmptyWindowView()
                        } else {
                            SessionAreaView(state: state, app: app)
                        }
                    }
                    .supervisionSurface()
                    // One piece while a sidebar or panel beside it slides
                    // and it narrows or widens: the pane strip's scroll
                    // view, which AppKit moves frame by frame, is measured
                    // where it is drawn, as the tabs in it are, so the rule
                    // under the strip opens under the selected tab
                    // throughout (`PaneStripRule`). The terminal's own view
                    // is moved by AppKit frame by frame with or without it;
                    // its terminal keeps one size through the slide
                    // (`TerminalSlideHold`).
                    .geometryGroup()
                    // The panel's place beside the terminal. The panel is
                    // drawn once, in the overlay below, so moving between
                    // beside and over keeps its scroll, its focus, and a
                    // drag of its divider.
                    if selection.isChangesPanelPresented, panelLayout != .overlay {
                        Color.clear
                            .frame(width: panelWidth)
                            .accessibilityHidden(true)
                    }
                }
                // The same whatever the layout: what moves inside it is only
                // who takes which part.
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                    if window.changesPanelSharedWidth != width {
                        window.changesPanelSharedWidth = width
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if selection.isChangesPanelPresented {
                        placedPanel
                            // One piece as it slides in: a `ViewThatFits`
                            // (the head, a card's moves) picks its child after the panel was
                            // put in, and that child, outside a group, stood
                            // at the panel's final place while the panel
                            // slid toward it.
                            .geometryGroup()
                            // Docked, it slides in from the trailing edge;
                            // laid over the terminal, it fades as the other
                            // floating panels do (`ChangesPanelMotion`).
                            .modalTransition(ChangesPanelMotion.transition(
                                isFloating: window.changesPanelLayout == .overlay,
                                reduceMotion: reduceMotion
                            ))
                    }
                }
                // Clipped here, between the rails: the sidebar and the panel
                // slide in from the surfaces' edges, never under the rails,
                // the window's margin, or the title bar.
                .clipped()
                if !window.areRailsHidden {
                    RightRailView(state: state)
                }
            }
            // The window's own margin, which the gaps between the surfaces
            // repeat: the rails stand in from its edges as far as the
            // surfaces stand apart.
            .padding(.horizontal, LimpidLayout.Supervision.surfaceGap)
            // However the changes panel is opened or closed (its rail
            // button, its ×, the menu, ⌥⌘I), it slides the same way.
            .animation(
                ChangesPanelMotion.animation(isFloating: window.changesPanelLayout == .overlay, reduceMotion: reduceMotion),
                value: selection.isChangesPanelPresented
            )
            .animation(reduceMotion ? nil : LimpidMotion.sidebarToggle, value: panelLayout)
            // The history hangs from the rail's button; with the rails
            // hidden, ⇧⌘N still opens it, beside the body's leading edge
            // where the rail would be.
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                bodyFrame = frame
                anchorHistoryWithoutRails()
            }
            .onChange(of: window.areRailsHidden) { _, _ in anchorHistoryWithoutRails() }
            // Across the whole window, under the rails as well.
            StatusBandView()
        }
        // The title bar, the rails, and the band stand on the ground below,
        // which follows the background opacity as the surfaces do, so a box
        // drawn on them (the Needs Attention button, the palette's field, an
        // open rail button) takes the same opacity. Inside the ground's
        // modifier rather than over it, so the title bar menus and other
        // layers over the window keep their own grounds.
        .modifier(SupervisionGroundOpacity())
        // One ground under the title bar, the rails, the gaps, and the band
        // alike, so the glass has no seam between them; the surfaces stand
        // on it.
        .background(SupervisionWindowGround(isFullScreen: selection.isFullScreen).ignoresSafeArea())
        .overlay { TitleBarMenuHost() }
        .onChange(of: isSidebarShown, initial: true) { _, isShown in
            window.isSidebarPresented = isShown
            if !isShown {
                // Hover cards hang from rows that are gone.
                window.prHover.reset()
                // The card's rows are gone with the sidebar.
                window.approvalCard.clearRowAnchors()
            }
        }
        .background { KeyboardPaneFollower(session: session, window: window) }
        .background {
            if !isSidebarShown {
                HiddenSidebarSectionsFollower(state: state, window: window)
            }
        }
        .background { ChangesPanelLayoutFollower(state: state, window: window) }
        .background(UpdateControlVisibilityMarker(isHidden: window.areRailsHidden))
        // Back in front (shown again, or the app switched back): ⌘⏎ waits
        // before it acts, as after a change of item.
        .onChange(of: appearsActive) { _, isActive in
            if isActive {
                SupervisionWindowActions.windowCameToFront(window)
            }
        }
        .environment(\.primaryActionHandler, SupervisionWindowActions.primaryActionHandler(window: window, state: state))
        .restoreWindow(window, state: state)
        .environment(\.reviewTabHandler, ReviewTabActions.handler(
            window: window,
            stores: state.reviewTabStores,
            paneVisibility: PaneVisibilityReporter(windowID: window.id, registry: state.windowRegistry)
        ))
        // The window's own actions, asked of it by the menus, the
        // palette, and its rails.
        .onWindowCommand(of: window, takeCommand)
        // Here, not on the session's body, so it opens whatever the window
        // shows, a window that shows no project included.
        .hostsNewWorktreeSheet(state: state)
    }

    /// Carries out the commands that are the whole window's, and says
    /// whether `command` was one.
    private func takeCommand(_ command: WindowCommand) -> Bool {
        switch command {
        case .toggleSidebar:
            withAnimation(reduceMotion ? nil : LimpidMotion.sidebarToggle) {
                SupervisionWindowActions.toggleSidebar(in: session, window: window)
            }
        case .toggleChangesPanel:
            ChangesPanelActions.toggle(window, session: session)
        case .showNeedsAttention:
            SupervisionWindowActions.showNeedsAttention(in: window)
        case .newWindow:
            SupervisionWindowActions.newWindow(from: window, session: session, registry: state.windowRegistry)
        case .closeWindow:
            SupervisionWindowActions.closeWindow(window, registry: state.windowRegistry, session: state.session)
        // The window's own, so the sheet opens whatever its body shows.
        case .newWorktree:
            SupervisionWindowActions.newSession(in: window, session: session)
        case .openFolder:
            SupervisionWindowActions.openFolder(
                from: window,
                session: session,
                registry: state.windowRegistry,
                frecency: state.frecencyStore
            )
        case .focusSidebar:
            SupervisionWindowActions.focusSidebar(in: session, window: window)
        default:
            return false
        }
        return true
    }

    /// With the rails hidden the history hangs from the first surface's
    /// leading edge: the body's, inside the window's margin.
    private func anchorHistoryWithoutRails() {
        guard window.areRailsHidden, bodyFrame.width > 0 else { return }
        window.historyAnchor = NotificationHistoryAnchor(
            frame: CGRect(
                x: bodyFrame.minX + LimpidLayout.Supervision.surfaceGap,
                y: bodyFrame.minY,
                width: 1,
                height: LimpidLayout.Supervision.railButtonSize
            ),
            columnTop: bodyFrame.minY
        )
    }

    /// How the panel shares the window now: beside while it is open and
    /// the terminal keeps its columns (`ChangesPanelLayoutRule`).
    private var panelLayout: ChangesPanelLayout {
        selection.isChangesPanelPresented ? window.changesPanelLayout : .beside
    }

    /// Whether the sidebar is on screen (`ProjectWindowState.isSidebarShown`).
    private var isSidebarShown: Bool {
        window.isSidebarShown
    }

    private var panelWidth: CGFloat {
        window.changesPanelDrawnWidth
    }

    /// The panel where its layout puts it: at the body's trailing edge
    /// beside the terminal, or over the session from the columns' top down
    /// to the session's foot bar, or to its bottom when it shows none, with
    /// a shadow to stand apart from it (`ChangesPanelPlacement`). Its top
    /// is the sidebar's and the session's either way: laid over the
    /// terminal from the terminal's own top, it hung a header and a strip
    /// lower than the columns.
    private var placedPanel: some View {
        let isOver = panelLayout == .overlay
        return changesPanel(isOver: isOver)
            .modifier(ChangesPanelBottomInset(state: state, isOver: isOver))
    }

    /// The changes panel at its width (300 to 520, 360 by default), on
    /// its surface, with the divider that resizes it on its leading edge.
    /// Beside the terminal the divider straddles the gap between the two
    /// surfaces; laid over the terminal it stays on the panel, so it takes
    /// no clicks from the terminal under it. The panel takes the pointer
    /// over its whole face, so the terminal under it neither shows its text
    /// cursor nor hears the mouse; the divider, laid over it, keeps its
    /// own, including the half over the gap.
    private func changesPanel(isOver: Bool) -> some View {
        let range = LimpidLayout.Supervision.changesPanelWidthRange
        let width = panelWidth
        return ChangesPanelView(state: state)
            .frame(width: width)
            .contentShape(Rectangle())
            .pointerStyle(.default)
            // Opaque over the terminal, whose text would show through it.
            .supervisionSurface(isOpaque: isOver)
            // The shadow is cast by a shape behind the panel, never by the
            // panel: cast from its rows, it was worked out again on every
            // frame of a scroll, docked or not.
            .background {
                if isOver {
                    RoundedRectangle(cornerRadius: LimpidLayout.Supervision.surfaceCornerRadius, style: .continuous)
                        .fill(SupervisionTokens.window.color)
                        .modifier(FloatingSurfaceShadow())
                }
            }
            .overlay(alignment: .leading) {
                DividerResizeHandle(
                    currentWidth: { width },
                    setWidth: { session.selections[window.id]?.changesPanelWidth = $0 },
                    minWidth: range.lowerBound,
                    maxWidth: range.upperBound,
                    defaultWidth: LimpidLayout.Supervision.changesPanelDefaultWidth,
                    hitWidth: LimpidLayout.columnResizeHandleWidth,
                    accessibilityLabel: Text("Changes Width"),
                    isOnLeadingEdge: true
                )
                .offset(x: isOver ? 0 : -LimpidLayout.Supervision.surfaceGap)
            }
    }

    /// The sidebar at its width (220 to 400; a double click on the divider
    /// returns it to 304, which the step to schema v6 (`SessionSnapshotV5`)
    /// saved as the width), on its surface, with the divider that resizes it
    /// straddling the gap on its trailing edge. A narrow window draws it
    /// narrower so the session keeps the review's minimum, and the divider
    /// goes no further than that; the saved width stays for when the
    /// window widens (`SupervisionWindowWidths.sidebarDrawnWidth`).
    private var sidebar: some View {
        let range = LimpidLayout.Supervision.sidebarWidthRange
        let width = window.sidebarDrawnWidth
        return SessionSidebarView()
            .frame(width: width)
            .supervisionSurface()
            .overlay(alignment: .trailing) {
                DividerResizeHandle(
                    currentWidth: { width },
                    // Written only while the window has its selection.
                    setWidth: { session.selections[window.id]?.sidebarWidth = $0 },
                    minWidth: range.lowerBound,
                    maxWidth: window.sidebarDrawnMaxWidth,
                    defaultWidth: LimpidLayout.Supervision.sidebarDefaultWidth,
                    hitWidth: LimpidLayout.columnResizeHandleWidth,
                    accessibilityLabel: Text("Sidebar Width")
                )
                .offset(x: LimpidLayout.Supervision.surfaceGap)
            }
    }
}

/// How far above the body's bottom the changes panel ends. Beside the
/// terminal it runs to the bottom, so its foot bar shares the line of the
/// sidebar's and the decision bar's. Laid over the terminal it stops one
/// foot bar short while the session shows a foot bar along its bottom, so
/// its foot (its foot bar, or Commit & PR's ground when there is no move
/// for one) stands right above that bar and leaves the bar, and its
/// buttons, to be reached: the sidebar's and the session's rules still
/// share one line, and the panel's sits one bar above them. With no bar
/// there (no tab, a shell pane) the gap would be dead space, and the
/// panel's bottom would stand off the session's surface behind it, so it
/// runs to the bottom as it does beside the terminal.
enum ChangesPanelPlacement {
    static func bottomInset(isOver: Bool, sessionShowsFootBar: Bool) -> CGFloat {
        isOver && sessionShowsFootBar ? LimpidLayout.Supervision.decisionBarHeight : 0
    }

    /// What the session area draws, as far as its bottom edge goes.
    struct SessionBottom {
        /// The window shows the projects to open instead of a session.
        var isChoosingProject = false
        /// The review tab is in front, with its band at its foot.
        var isReviewShown = false
        /// A new session's setup line runs across the session's foot
        /// (`SessionLaunchBar`).
        var hasLaunchBar = false
        /// The tab the pane area draws, `nil` with no tab or while another
        /// window draws the scratch tabs.
        var tree: SplitTree?
        /// The leaf drawn alone over the whole area, if any.
        var zoomedLeafID: UUID?
    }

    /// Whether the session shows a foot bar along its bottom: the review's
    /// band, a new session's setup line, or a bar under a pane on the
    /// bottom edge (`paneShowsFootBar`: its decision bar or its restore
    /// strip).
    ///
    /// Any pane on the bottom edge counts, not only those under the
    /// panel's span. The panel covers the session's trailing part, and how
    /// far into a split it reaches changes with the panel's width, the
    /// window's, and each divider, so a rule that followed the geometry
    /// would flip the panel's foot as any of them is dragged. Stopping
    /// short for every bar on that edge keeps each bar's buttons in reach
    /// whatever the widths; what it costs is a bar's height of gap under a
    /// panel that does not reach the bar, beside a bar whose rule the
    /// panel's foot then lines up with. A pane above another has its bar
    /// mid-session, where the panel covers it with or without the gap.
    static func sessionShowsFootBar(_ bottom: SessionBottom, paneShowsFootBar: (UUID) -> Bool) -> Bool {
        guard !bottom.isChoosingProject else { return false }
        if bottom.isReviewShown || bottom.hasLaunchBar {
            return true
        }
        guard let tree = bottom.tree else { return false }
        if let zoomed = bottom.zoomedLeafID, tree.contains(leafID: zoomed) {
            return paneShowsFootBar(zoomed)
        }
        return tree.bottomEdgeLeafIDs().contains(where: paneShowsFootBar)
    }
}

/// Puts the changes panel's foot where `ChangesPanelPlacement` says. A view
/// of its own so that only it, not the window's root, is drawn again as
/// agents come and go in the panes and their bars with them; and it reads
/// none of that while the panel is beside the terminal, where the session's
/// bottom changes nothing.
private struct ChangesPanelBottomInset: ViewModifier {
    let state: AppState
    let isOver: Bool
    @Environment(ProjectWindowState.self) private var window

    func body(content: Content) -> some View {
        // Beside the terminal the session's bottom is not read at all.
        let showsFootBar = isOver && sessionShowsFootBar
        return content.padding(.bottom, ChangesPanelPlacement.bottomInset(isOver: isOver, sessionShowsFootBar: showsFootBar))
    }

    /// Read from what the session area draws: the tab its pane area draws
    /// (`WorkspaceSession.drawnTab(in:)`), the review and the setup line
    /// as `SessionAreaView` places them, and each pane's bar as
    /// `DecisionBarView` decides it. A restore strip counts whether or not
    /// it yields to the agent's question: when it does, the agent's bar
    /// stands in its place.
    private var sessionShowsFootBar: Bool {
        let session = state.session
        let selection = window.selection
        let drawnTab = session.drawnTab(in: window.id)
        let bottom = ChangesPanelPlacement.SessionBottom(
            isChoosingProject: selection.isChoosingProject,
            isReviewShown: window.review?.isShown == true,
            hasLaunchBar: state.sessionLaunches.launch(in: selection.activeContainerID) != nil,
            tree: drawnTab?.splitTree,
            zoomedLeafID: drawnTab?.zoomedLeafID
        )
        return ChangesPanelPlacement.sessionShowsFootBar(bottom) { paneID in
            window.restoreStrips[paneID] != nil || DecisionBarModel.hasBar(
                in: paneID,
                runtimes: state.attention.allRuntimes,
                session: session,
                queue: state.attentionQueue.queue
            )
        }
    }
}

/// How the changes panel comes and goes. Docked beside the terminal
/// it pushes the session aside, so it slides from the trailing edge with
/// the sidebar's curve, and appears at once under Reduce Motion. Laid over
/// the terminal it is a floating panel, so it fades as the notification
/// history does (`ModalMotion.floatingPanel`), Reduce Motion or not.
enum ChangesPanelMotion {
    static func transition(isFloating: Bool, reduceMotion: Bool) -> ModalMotion.Transition {
        if isFloating {
            return ModalMotion.floatingPanel.transition(reduceMotion: reduceMotion)
        }
        return reduceMotion ? .identity : ModalMotion.Transition(fades: true, edge: .trailing, scale: nil)
    }

    static func animation(isFloating: Bool, reduceMotion: Bool) -> Animation? {
        if isFloating {
            return ModalMotion.floatingPanel.animation(reduceMotion: reduceMotion)
        }
        return reduceMotion ? nil : LimpidMotion.sidebarToggle
    }
}

/// The window's ground: the well the surfaces stand on, showing in
/// the gaps between them and under the title bar, the rails, and the band.
/// With transparency it tints the behind-window glass at the background
/// opacity, as the surfaces lay `window` over the same glass at the same
/// opacity: mixed alike, the two keep their tokens' step between them, so
/// the gaps read darker in both appearances. With transparency off or
/// reduced it is opaque, as the surfaces are. Its opacity comes from the
/// rule the surfaces and the boxes on this ground take theirs from
/// (`SupervisionSurfaceOpacity`), so the three cannot drift apart.
private struct SupervisionWindowGround: View {
    let isFullScreen: Bool
    @Environment(SettingsStore.self) private var settings
    @Environment(ReduceTransparencyResolver.self) private var reduceTransparencyResolver

    var body: some View {
        let opacity = SupervisionSurfaceOpacity.resolve(
            backgroundOpacity: settings.settings.appearance.backgroundOpacity,
            reducesTransparency: reduceTransparencyResolver.shouldReduceTransparency
        )
        // While transparency is reduced the base is itself opaque and the
        // well covers it whole.
        WindowBaseFill(isFullScreen: isFullScreen)
            .overlay(SupervisionTokens.well.color.opacity(opacity))
    }
}

/// One of the window's independent surfaces: the sidebar, the
/// session, the changes panel. Each is filled here, once, so the three read
/// alike, cut to 10pt corners, and edged in `line`. The fill follows the
/// appearance settings: the background opacity while transparency is
/// on, opaque while it is off or reduced.
///
/// What is drawn on a surface finds its edges through `surfaceSpace`, so a
/// frame along them can stay inside the border and follow the corners
/// (`SurfaceFrameFit`).
private struct SupervisionSurface: ViewModifier {
    let isOpaque: Bool
    @Environment(SettingsStore.self) private var settings
    @Environment(ReduceTransparencyResolver.self) private var reduceTransparencyResolver

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: LimpidLayout.Supervision.surfaceCornerRadius, style: .continuous)
        let opacity = SupervisionSurfaceOpacity.resolve(
            backgroundOpacity: settings.settings.appearance.backgroundOpacity,
            reducesTransparency: reduceTransparencyResolver.shouldReduceTransparency,
            isOpaque: isOpaque
        )
        content
            .environment(\.supervisionSurfaceOpacity, opacity)
            .coordinateSpace(.named(SupervisionWindowView.surfaceSpace))
            .background(SupervisionTokens.window.color.opacity(opacity))
            .clipShape(shape)
            .overlay {
                shape
                    .strokeBorder(SupervisionTokens.line.color, lineWidth: LimpidLayout.Supervision.surfaceBorderWidth)
                    .allowsHitTesting(false)
            }
    }
}

/// The window's ground under the title bar, the rails, and the band, as
/// opaque as `SupervisionWindowGround` tints it: the background opacity
/// while transparency is on, 1 while it is off or reduced.
private struct SupervisionGroundOpacity: ViewModifier {
    @Environment(SettingsStore.self) private var settings
    @Environment(ReduceTransparencyResolver.self) private var reduceTransparencyResolver

    func body(content: Content) -> some View {
        content.environment(\.supervisionSurfaceOpacity, SupervisionSurfaceOpacity.resolve(
            backgroundOpacity: settings.settings.appearance.backgroundOpacity,
            reducesTransparency: reduceTransparencyResolver.shouldReduceTransparency
        ))
    }
}

extension EnvironmentValues {
    /// How opaque the ground a view stands on is filled: a surface's
    /// (`SupervisionSurface`), the title bar's, the rails', and the band's
    /// (`SupervisionGroundOpacity`), or 1 under a view that fills its own
    /// ground opaquely (the decision bar, a floating panel) and says so. A
    /// box or a bordered button filled on it takes the same opacity
    /// (`SurfaceGround`), so with transparency on it does not stand out as
    /// an opaque patch.
    @Entry var supervisionSurfaceOpacity: Double = 1
}

/// A ground drawn under a box on a surface or on the window's ground (a
/// chip, a tag, a field, a button's fill), laid on at the ground's opacity
/// (`supervisionSurfaceOpacity`), so with the background opacity under
/// 100% the box mixes with the glass as the surface under it does instead
/// of standing out as an opaque patch.
///
/// The `compositingGroup()` is there for a ground of more than one layer:
/// the layers are flattened first and faded as one, so a lower layer does
/// not show through an upper one. A ground of one fill gets it too, so
/// every ground is drawn the same way.
struct SurfaceGround<Content: View>: View {
    @ViewBuilder let content: Content
    @Environment(\.supervisionSurfaceOpacity) private var surfaceOpacity

    var body: some View {
        content
            .compositingGroup()
            .opacity(surfaceOpacity)
    }
}

private extension View {
    func supervisionSurface(isOpaque: Bool = false) -> some View {
        modifier(SupervisionSurface(isOpaque: isOpaque))
    }
}

/// Tells the window when the pane with its keyboard changes, so the pane
/// left behind lets its decision bar's choice go. A view of its own,
/// so the tabs it reads redraw this and not the window.
private struct KeyboardPaneFollower: View {
    let session: WorkspaceSession
    let window: ProjectWindowState

    private var keyboardPane: UUID? {
        session.activeTab(in: window.id)?.splitTree.effectiveFocusedLeafID
    }

    var body: some View {
        Color.clear
            .onChange(of: keyboardPane) { previous, _ in
                window.keyboardMoved(
                    from: previous,
                    livePanes: session.allPaneIDs
                )
            }
    }
}

/// While the sidebar is not drawn (hidden, or folded for the changes
/// panel), keeps the sections ⌃⌘1…9 and ⌘[ ⌘] count as the rows stand,
/// which the sidebar does while it is drawn: without it, the menus would
/// count the rows it last drew, and a menu item those stale rows turned off
/// would not take its key. Nothing holds the sections while the sidebar is away, so they are
/// the rows as they stand (`AppState.sidebarSections(in:)`). A view of its
/// own, so the rows, the queue, and the Git and forge readings it reads
/// redraw this and not the window.
private struct HiddenSidebarSectionsFollower: View {
    let state: AppState
    let window: ProjectWindowState

    var body: some View {
        Color.clear
            .onChange(of: state.sidebarSections(in: window), initial: true) { _, sections in
                window.present(sections)
            }
    }
}

/// Keeps the window's changes panel layout (`ChangesPanelLayoutRule`), as
/// drawn while the panel is open and as it would open while it is closed,
/// so it opens straight into the right place rather than first squeezing
/// the terminal. A view of its own, so the panes and cells it reads redraw
/// this and not the window. It follows the window, its panes, and the font
/// as they change; while the panel is open a move to another tab keeps the
/// layout (`ChangesPanelLayoutRule.redecides`). A switch to another project
/// is settled before the window draws (`WindowRegistry.onDidSwitchProject`),
/// so what the scroll restore counts as on screen is what is drawn.
private struct ChangesPanelLayoutFollower: View {
    let state: AppState
    let window: ProjectWindowState
    @Environment(\.surfaceRegistry) private var registry
    @Environment(\.accessibilityVoiceOverEnabled) private var isVoiceOverOn
    @Environment(\.locale) private var locale

    private var reading: ChangesPanelLayoutReading {
        _ = state.session.cellSizeGeneration
        return window.changesPanelLayoutReading(
            in: state.session,
            isAgentPane: { state.attention.headerRuntime(inPane: $0) != nil },
            cellWidth: { registry.view(for: $0)?.cellWidth }
        )
    }

    /// Whether the open panel has folded the sidebar.
    private var isSidebarFolded: Bool {
        window.isSidebarFoldedForChanges(isPresented: window.selection.isChangesPanelPresented)
    }

    var body: some View {
        Color.clear
            .onChange(of: reading, initial: true) { _, reading in
                let session = state.session
                window.settleChangesPanelLayout(reading, isTabOpen: { session.tab($0) != nil })
            }
            // The sidebar going away on its own is news to VoiceOver, on
            // opening as much as on a resize.
            .onChange(of: isSidebarFolded) { _, isFolded in
                if isFolded, isVoiceOverOn {
                    AccessibilityNotification.Announcement(ChangesPanelText.sidebarFolded(locale: locale)).post()
                }
            }
    }
}
