// PaneStripView.swift
// Limpid — the pane strip: the session's tabs, the review's tab while one is open, and "+".

import SwiftUI

/// The 30pt strip under the session header. Each tab is as wide as
/// what it holds, its title cut past a maximum. Short of room, the tabs
/// give way from the widest down, each title cut with an ellipsis inside
/// its own tab, and they scroll only once every title is at its minimum
/// (`PaneStripTabWidths`), keeping the selected tab in view and fading
/// each end past which tabs continue (`PaneStripOverflow`). The review's
/// tab is one of them, after the terminal tabs, so it never comes between
/// them, and is cut and scrolled as they are; only Open Tabs at the
/// leading end and "+" at the trailing end stay put. The selected tab
/// is a folder tab open onto the terminal: the rule under the strip stops
/// for it (`PaneStripRule`). A click picks a tab through
/// `setActiveTab`, as ⌘1…9 and ⇧⌘[ ⇧⌘] do, so a held request is handed
/// to the terminal however its tab is shown; a terminal tab picked while
/// the review tab is in front puts the review behind it, still open.
/// Rename, close, the right-click menu, dragging to reorder, and dropping
/// a ⌥⌘-dragged pane to merge it all work as in the tab list.
struct PaneStripView: View {
    let container: ContainerID
    @Environment(WorkspaceSession.self) private var session
    @Environment(AttentionQueueStore.self) private var attentionQueue
    @Environment(AttentionState.self) private var attention
    @Environment(TmuxPanePresence.self) private var tmuxPresence
    @Environment(ProjectWindowState.self) private var window
    /// The identity colors the tabs carry, which the changes panel's cards
    /// read from the same store.
    @Environment(\.conversationIdentities) private var conversationIdentities

    /// The strip's own space, which its selected tab reports its frame in.
    nonisolated static let coordinateSpace = "paneStrip"

    /// Only the model is made here. The runs it reads change with every
    /// word an agent reports (its detail), which the tabs never show; the
    /// strip below is drawn again only when the model it is handed differs.
    /// The identity colors are read here too, not in the session area
    /// around it: they follow the turns and the viewed lines, and read
    /// there they would draw the terminal again on every turn recorded.
    /// The store hands back its last read while none of that changed, so
    /// the read costs little on every word an agent reports.
    var body: some View {
        let model = PaneStripModel(
            container: container,
            session: session,
            window: window.id,
            queue: attentionQueue.queue,
            runtimes: attention.allRuntimes,
            identities: conversationIdentities?.identities(in: container) ?? [:],
            mountedTmuxPaneIDs: tmuxPresence.paneIDs,
            reviewTab: window.reviewStripTab(in: container, session: session)
        )
        PaneStripContent(container: container, model: model)
            .equatable()
    }
}

/// The strip itself, drawn from its model (`PaneStripView`).
private struct PaneStripContent: View, Equatable {
    let container: ContainerID
    let model: PaneStripModel
    @Environment(WorkspaceSession.self) private var session
    @Environment(ProjectWindowState.self) private var window
    @Environment(LimpidDragState.self) private var dragState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var paneMergeHighlight
    /// The tab being renamed.
    @State private var editingTabID: UUID?
    /// Where the tabs can be seen, in the strip's own space: the rule
    /// under the strip stops only there for a selected tab, and its width
    /// is what the tabs share.
    @State private var tabsVisibleRange: ClosedRange<CGFloat>?

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.container == rhs.container && lhs.model == rhs.model
    }

    var body: some View {
        HStack(spacing: LimpidLayout.Supervision.paneStripSpacing) {
            OpenTabsButton(container: container)
            PaneStripScrollingTabs(selected: selectedTab(model), visibleRange: $tabsVisibleRange) {
                tabs(model)
            }
            .animation(reduceMotion ? nil : LimpidMotion.renamePill, value: editingTabID)
            // The merge mark glides between tabs; under Reduce Motion it
            // moves at once.
            .animation(reduceMotion ? nil : LimpidMotion.paneMergeHighlight, value: dragState.hoverTargetID)
            AddTabButton(container: container)
        }
        .padding(.horizontal, LimpidLayout.Supervision.paneStripInset)
        .frame(height: LimpidLayout.Supervision.paneStripHeight)
        .coordinateSpace(.named(PaneStripView.coordinateSpace))
        .overlayPreferenceValue(SelectedStripTabKey.self) { selected in
            PaneStripRule(gap: selected?.frame, visible: selected?.scrolls == true ? tabsVisibleRange : nil)
        }
        // No detach target on the strip's empty space: a pane dropped in
        // the gap between two tabs would leave its tab by accident. The
        // pane's "Move Pane to New Tab" does it.
    }

    private func selectedTab(_ model: PaneStripModel) -> PaneStripSelectedTab? {
        if model.reviewTab == .inFront {
            return .review
        }
        return window.selection.activeTabID.map(PaneStripSelectedTab.terminal)
    }

    @ViewBuilder private func tabs(_ model: PaneStripModel) -> some View {
        let sourceTabID = session.tabOfDraggedPane(dragState)
        ForEach(model.items) { item in
            PaneStripTabCell(
                item: item,
                container: container,
                sourceTabID: sourceTabID,
                highlightNamespace: paneMergeHighlight,
                editingTabID: $editingTabID
            )
        }
        if model.showsReviewTab {
            ReviewStripTab()
        }
    }
}

/// This is the tab the strip keeps in view, and the id of each tab's scroll
/// target (`paneStripScrollTarget`). A terminal tab's UUID alone would
/// not do: it is also the tab's identity in its `ForEach`, which the
/// scroll view finds first, so the scroll would go to the tab rather than
/// to its target.
enum PaneStripSelectedTab: Hashable {
    case terminal(UUID)
    /// The review's tab, in front.
    case review
}

/// The strip's tabs in their scroll view: laid out by
/// `PaneStripTabsLayout` in the scroll view's width, which is measured
/// here, and scrolled to keep the selected tab in view, whether the
/// selection or the width changed. An end past which tabs continue fades
/// into the strip's edge (`PaneStripEdgeFade`). Each tab carries a scroll
/// target (`paneStripScrollTarget`) under its `PaneStripSelectedTab`.
///
/// The strip scrolls only as far as it must to bring the selected tab
/// clear of the fades, and not at all while it already is. Centering the
/// tab, as we first did, moved a strip at its start even for a tab in view,
/// and left the first tab cut under the leading fade.
struct PaneStripScrollingTabs<Content: View>: View {
    let selected: PaneStripSelectedTab?
    /// Where the tabs can be seen, in `PaneStripView.coordinateSpace`:
    /// measured here, and read by the strip's rule as well.
    @Binding var visibleRange: ClosedRange<CGFloat>?
    @ViewBuilder let content: () -> Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Which ends have tabs scrolled out of view, from the scroll view's
    /// own geometry.
    @State private var overflow: PaneStripOverflow = .none

    var body: some View {
        let layout = LimpidLayout.Supervision.self
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                PaneStripTabsLayout(
                    available: visibleRange.map { $0.upperBound - $0.lowerBound },
                    spacing: layout.paneStripSpacing,
                    titleMinimum: layout.paneStripTitleMinWidth
                ) {
                    content()
                }
                .frame(maxHeight: .infinity)
            }
            .onScrollGeometryChange(for: PaneStripOverflow.self) { geometry in
                PaneStripOverflow.of(
                    offset: geometry.contentOffset.x,
                    contentWidth: geometry.contentSize.width,
                    visibleWidth: geometry.containerSize.width
                )
            } action: { _, overflow in
                self.overflow = overflow
            }
            .mask {
                PaneStripEdgeFade(overflow: overflow, width: layout.paneStripEdgeFadeWidth)
            }
            .onGeometryChange(for: ClosedRange<CGFloat>.self) { proxy in
                let frame = proxy.frame(in: .named(PaneStripView.coordinateSpace))
                return frame.minX...max(frame.minX, frame.maxX)
            } action: { range in
                visibleRange = range
            }
            .onChange(of: selected) { _, selected in
                withAnimation(reduceMotion ? nil : LimpidMotion.stripScroll) {
                    scroll(proxy, to: selected)
                }
            }
            // The strip's first layout comes before its width is measured,
            // with every tab at its whole width, and the scroll on appear is
            // made against that. Once the tabs take the width they share,
            // the offset it left can put the selected tab out of view; so
            // can a window narrowed, or a sidebar or panel opened, after.
            // Whenever the width is known anew, we scroll to the selected
            // tab again, at once, so it is never the tab out of view.
            .onChange(of: visibleRange) { _, range in
                if range != nil {
                    scroll(proxy, to: selected)
                }
            }
            .onAppear {
                scroll(proxy, to: selected)
            }
        }
    }

    /// Scrolls with no anchor: the scroll view moves the least that shows the target
    /// whole, which is the tab and a fade's width on each side, and leaves
    /// a target already in view where it is.
    private func scroll(_ proxy: ScrollViewProxy, to selected: PaneStripSelectedTab?) {
        if let selected {
            proxy.scrollTo(selected)
        }
    }
}

extension View {
    /// Marks the place `PaneStripScrollingTabs` scrolls to for this tab: the
    /// tab's frame and a fade's width past it on each side. A tab brought
    /// into view at an edge past which tabs continue then stands clear of
    /// that edge's fade, rather than half under it. At the strip's ends the
    /// scroll view cannot pass its content, so the first and last tabs rest
    /// at the edge, where no fade is drawn. In a strip narrower than the
    /// target, the scroll view decides where the tab rests. The target is
    /// laid behind the tab and takes no layout.
    func paneStripScrollTarget(_ id: PaneStripSelectedTab) -> some View {
        background {
            Color.clear
                .id(id)
                .padding(.horizontal, -LimpidLayout.Supervision.paneStripEdgeFadeWidth)
        }
    }
}

/// The mask that fades the strip's tabs into an edge past which they
/// continue: clear at the edge, whole a fade's width in, on each end
/// `overflow` names; the rest of the strip is drawn whole. The fade is the
/// strip's one word for "more tabs", so it is the same at either end, and
/// it changes nothing about a strip whose tabs all fit.
struct PaneStripEdgeFade: View {
    let overflow: PaneStripOverflow
    let width: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            if overflow.hasLeading {
                LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                    .frame(width: width)
            }
            Color.black
            if overflow.hasTrailing {
                LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: width)
            }
        }
    }
}

/// The strip's tabs side by side at the widths `PaneStripTabWidths` gives
/// them. The scroll view they sit in offers them no width of their own, so
/// the width they share is passed in: the scroll view's, measured. Each tab
/// is asked for its width with its whole title and with none, and is then
/// offered its share, which it fills by cutting its own title; so no tab
/// runs under the scroll view's edge until every title is at its minimum,
/// and then the strip scrolls.
struct PaneStripTabsLayout: Layout {
    /// The width the tabs share; `nil` before it is measured, when every
    /// tab takes its ideal width.
    let available: CGFloat?
    let spacing: CGFloat
    /// The least of a title a tab keeps (`paneStripTitleMinWidth`).
    let titleMinimum: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        let widths = widths(of: subviews, height: proposal.height)
        let height = zip(subviews, widths)
            .map { $0.sizeThatFits(ProposedViewSize(width: $1, height: proposal.height)).height }
            .max() ?? 0
        let width = widths.reduce(0, +) + spacing * CGFloat(max(widths.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        HorizontalLayoutPlacement.place(
            subviews,
            widths: widths(of: subviews, height: bounds.height),
            in: bounds,
            spacing: spacing
        )
    }

    private func widths(of subviews: Subviews, height: CGFloat?) -> [CGFloat] {
        let ideals = subviews.map { $0.sizeThatFits(ProposedViewSize(width: nil, height: height)).width }
        guard let available else { return ideals }
        let tabs = zip(subviews, ideals).map { subview, ideal in
            PaneStripTabWidths.Tab(
                ideal: ideal,
                bare: subview.sizeThatFits(ProposedViewSize(width: 0, height: height)).width
            )
        }
        return PaneStripTabWidths.widths(of: tabs, available: available, spacing: spacing, titleMinimum: titleMinimum)
    }
}

/// The rule under the strip, stopping for the selected tab so the tab
/// opens onto the terminal below it, as a folder tab does.
///
/// Laid out rather than stroked from a measured width: a path drawn in a
/// `GeometryReader` takes the strip's final width at once, so while a
/// surface slid in and the strip narrowed, the rule stopped short of the
/// strip's edge (or, widening, ran past it) until the slide ended. Here the
/// stretch after the opening fills the strip, and so follows its edge as it
/// is drawn.
struct PaneStripRule: View {
    /// The selected tab's frame in the strip's space; `nil` draws the rule
    /// whole.
    let gap: CGRect?
    /// Where the selected tab can be seen (`PaneStripRuleLayout`).
    let visible: ClosedRange<CGFloat>?

    var body: some View {
        let lineWidth = LimpidLayout.Supervision.paneStripRuleWidth
        let opening = PaneStripRuleLayout.opening(gap: gap, visible: visible, lineWidth: lineWidth)
        // The same three stretches whether the rule opens or not, so a tab
        // selected or let go changes widths, never which views are drawn.
        HStack(spacing: 0) {
            SupervisionTokens.line.color
                .frame(width: opening?.lowerBound ?? 0)
            Color.clear
                .frame(width: opening.map { $0.upperBound - $0.lowerBound } ?? 0)
            SupervisionTokens.line.color
        }
        .frame(height: lineWidth)
        // From the leading edge: an opening past the strip's end runs off
        // its trailing side rather than centering the stretches.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// One tab of the strip: the tab with its actions, its place to drop a
/// dragged tab before or after it, and its place to drop a ⌥⌘-dragged
/// pane into it.
private struct PaneStripTabCell: View {
    let item: PaneStripModel.Item
    let container: ContainerID
    /// The tab of the pane being dragged, which refuses the drop.
    let sourceTabID: UUID?
    let highlightNamespace: Namespace.ID
    @Binding var editingTabID: UUID?
    @Environment(WorkspaceSession.self) private var session
    @Environment(AttentionState.self) private var attention
    @Environment(LimpidDragState.self) private var dragState
    @Environment(\.surfaceRegistry) private var registry
    @Environment(\.agentProjection) private var agentProjection
    @Environment(ProjectWindowState.self) private var window
    @Environment(\.paneVisibilityReporter) private var paneVisibility

    var body: some View {
        PaneStripTab(
            item: item,
            // A terminal tab picked while the review tab is in front puts
            // the review behind it.
            onActivate: {
                ReviewTabActions.hide(
                    window: window,
                    showing: item.id,
                    session: session,
                    registry: registry,
                    paneVisibility: paneVisibility
                )
            },
            onClose: {
                TabActions.closeTab(
                    session,
                    registry: registry,
                    tabID: item.id,
                    source: .mouse,
                    attention: attention,
                    agentProjection: agentProjection,
                    in: window.id
                )
            },
            onRename: { name in
                session.renameTab(item.id, to: name, runtimes: attention.allRuntimes)
            },
            onEditingChanged: { isEditing in
                editingTabID = isEditing ? item.id : (editingTabID == item.id ? nil : editingTabID)
            }
        )
        .tabReorderTarget(beforeTabID: item.id, container: container, session: session)
        .paneMergeDropTarget(
            targetTabID: item.id,
            session: session,
            dragState: dragState,
            highlightNamespace: highlightNamespace,
            sourceTabID: sourceTabID
        )
        .paneStripScrollTarget(.terminal(item.id))
    }
}

/// The review's tab: an eye and the scope it reads, with its close
/// button; "Review · {scope}" whole is its tooltip and VoiceOver label. A
/// click brings it in front of the terminal tabs; it cannot be renamed,
/// dragged, or reopened. It takes the terminal tabs' look, a folder tab,
/// and their menu less what it cannot do: Close alone.
struct ReviewStripTab: View {
    @Environment(ProjectWindowState.self) private var window
    @Environment(\.reviewTabHandler) private var reviewTabHandler
    @Environment(SettingsStore.self) private var settingsStore
    @Environment(\.locale) private var locale
    @State private var isHovering = false

    var body: some View {
        if let tab = window.review {
            let layout = LimpidLayout.Supervision.self
            HStack(spacing: layout.paneStripTabSpacing) {
                Button {
                    ReviewTabActions.show(window: window)
                } label: {
                    HStack(spacing: layout.paneStripTabSpacing) {
                        // The review's own symbol, in the place a terminal
                        // tab's badge takes, as the menu and the palette
                        // draw it: the same command reads as one.
                        Image(systemName: ReviewPresentation.symbol)
                            .font(.supervision(.row, weight: .medium))
                            .foregroundStyle(SupervisionTokens.muted.color)
                            .accessibilityHidden(true)
                        // The scope alone, cut at its end as a terminal
                        // tab's title is: its start is what tells two
                        // scopes apart.
                        Text(verbatim: ReviewTabText.tabName(tab.selection, locale: locale))
                            .font(.supervision(.label, weight: .medium))
                            .foregroundStyle(tab.isShown || isHovering ? SupervisionTokens.text.color : SupervisionTokens.muted.color)
                            .lineLimit(1)
                            .supervisionTruncation(.name)
                    }
                    .frame(maxWidth: LimpidLayout.Supervision.reviewTabTitleMaxWidth)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(Text(verbatim: ReviewTabText.title(tab.selection, locale: locale)))
                .accessibilityLabel(Text(verbatim: AgentStatusText.spoken(
                    ReviewTabText.title(tab.selection, locale: locale),
                    locale: locale
                )))
                // On the button itself: macOS may not read a trait set on a
                // containing group.
                .accessibilityAddTraits(tab.isShown ? .isSelected : [])
                DismissGlyphButton(label: "Close Review") {
                    reviewTabHandler?.close()
                }
            }
            .padding(.horizontal, layout.paneStripTabHorizontalPadding)
            // Centered over the strip's rule, as a terminal tab is.
            .padding(.bottom, layout.paneStripRuleWidth)
            .frame(height: layout.paneStripHeight)
            // The tab takes the width the strip gives it
            // (`PaneStripTabsLayout`), cutting its title at the end.
            .folderTabFace(isSelected: tab.isShown, isHovering: isHovering, scrolls: true)
            .onHover { isHovering = $0 }
            .contextMenu {
                Button(role: .destructive) {
                    reviewTabHandler?.close()
                } label: {
                    Label("Close", systemImage: "xmark")
                }
                // ⌘W closes the review only while it is in front, so the
                // menu shows the key only then.
                .contextMenuShortcut(tab.isShown ? MenuCommand.closePane.shortcut(in: settingsStore.settings.keyboard) : nil)
                .tint(Color.primary)
            }
            // The close button stays its own element, so pressing the tab in
            // VoiceOver never closes the review.
            .accessibilityElement(children: .contain)
            .paneStripScrollTarget(.review)
        }
    }
}

extension ProjectWindowState {
    /// The review tab, as `container`'s strip draws it: only in the session
    /// it was opened in, where its agent is.
    func reviewStripTab(in container: ContainerID, session: WorkspaceSession) -> PaneStripModel.ReviewTab {
        guard let review, ReviewTabActions.belongs(review, to: container, session: session) else { return .none }
        return review.isShown ? .inFront : .behind
    }
}

/// The strip's leading button: Open Tabs, every tab of the session in a
/// list to search and switch from, which a crowded strip cuts short or
/// scrolls out of view. It stays put at the strip's start and looks as
/// Chrome's tab search button does: a filled rounded square apart from the
/// tabs, rather than a tab itself, since it is a control, not a place.
private struct OpenTabsButton: View {
    let container: ContainerID
    @Environment(SettingsStore.self) private var settings

    private typealias Layout = LimpidLayout.Supervision

    var body: some View {
        let shortcut = settings.settings.keyboard.shortcut(for: .showOpenTabs)?.displayString
        TitleBarMenuButton(menu: .openTabs(container)) { isLit in
            Image(systemName: "chevron.down")
                .font(.supervision(.glyph, weight: .semibold))
                .foregroundStyle(isLit ? SupervisionTokens.text.color : SupervisionTokens.muted.color)
                .frame(width: Layout.openTabsButtonSize, height: Layout.openTabsButtonSize)
                .background(
                    RoundedRectangle(cornerRadius: Layout.paneStripTabCornerRadius, style: .continuous)
                        .fill(isLit ? SupervisionTokens.selection.color : SupervisionTokens.hover.color)
                )
                // Centered over the strip's rule, as the tabs' content is.
                .padding(.bottom, Layout.paneStripRuleWidth)
                .frame(width: Layout.paneStripAddButtonWidth, height: Layout.paneStripHeight)
                .contentShape(Rectangle())
        }
        .iconButtonHelp("Open Tabs", shortcut: shortcut)
    }
}

/// The strip's "+": adds a tab to this session. Its menu hangs below
/// it on the surface every dropdown shares, opened as the title bar's
/// dropdowns are. It is drawn as an unselected tab is, muted until the
/// pointer is on it: the tab's hover fill while lit.
private struct AddTabButton: View {
    let container: ContainerID
    @Environment(WorkspaceSession.self) private var session
    @Environment(\.locale) private var locale

    var body: some View {
        let help = Text("Add Tab to \(AddTabMenu.placeName(of: container, in: session, locale: locale))")
        TitleBarMenuButton(menu: .addTab(container)) { isLit in
            Image(systemName: "plus")
                .font(.supervision(.label, weight: .medium))
                .foregroundStyle(isLit ? SupervisionTokens.text.color : SupervisionTokens.muted.color)
                .padding(.bottom, LimpidLayout.Supervision.paneStripRuleWidth)
                .frame(
                    width: LimpidLayout.Supervision.paneStripAddButtonWidth,
                    height: LimpidLayout.Supervision.paneStripHeight
                )
                .folderTabFace(isSelected: false, isHovering: isLit, scrolls: false)
                .contentShape(Rectangle())
        }
        .help(help)
        .accessibilityLabel(help)
    }
}
