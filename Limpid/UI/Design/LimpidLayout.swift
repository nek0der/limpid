// LimpidLayout.swift
// Limpid — layout constants gathered in one place so the various
// hard-coded sizes scattered across views become discoverable and
// movable in lockstep. Sits alongside `LimpidColor / LimpidFont /
// LimpidMotion` to round out the design-token set.

import CoreGraphics
import Foundation

enum LimpidLayout {

    // MARK: - Window toolbar

    /// Leading x of the close button. AppKit's own default is 9, which
    /// reads tight against a flush sidebar: every row underneath starts
    /// at `containerColumnIndentTop`, so a button at 9 sits closer to
    /// the window edge than anything below it. Lining the two up gives
    /// the row the same left margin as the labels it sits above.
    static var trafficLightOriginX: CGFloat {
        containerColumnIndentTop
    }

    /// Gap between the origins of two neighboring traffic lights, and
    /// the size AppKit draws each one at — both measured on macOS 26
    /// (buttons at x = 9 / 32 / 55, 14pt square). We move the row but
    /// keep its rhythm; the previous 20pt spacing packed the buttons
    /// tighter than the system does.
    static let trafficLightSpacing: CGFloat = 23
    static let trafficLightButtonSize: CGFloat = 14

    /// Width the traffic-light row occupies from the window's leading
    /// edge. We use it to leave room in the main area's top strip when
    /// the sidebar is hidden. Derived rather than typed in so it cannot
    /// drift away from the placement above.
    static var trafficLightWidth: CGFloat {
        trafficLightOriginX + 2 * trafficLightSpacing + trafficLightButtonSize
    }

    /// Height of the top toolbar strip inside each column. Everything
    /// the strip carries — the toolbar content row and the AppKit
    /// traffic lights — centers on its midline, so this is the one
    /// number the strip's geometry is built from.
    static let topStripHeight: CGFloat = 52

    /// Distance from the window top to the strip's midline. Both the
    /// toolbar content row and `repositionTrafficLights` center on it,
    /// which is what keeps the two rows on the same line.
    static var topStripMidline: CGFloat {
        topStripHeight / 2
    }

    // MARK: - 3-pane layout

    /// Smallest main-window content size we support. The responsive layout
    /// temporarily overlays the container sidebar below its full three-column
    /// requirement, leaving the tab list and primary content usable at this
    /// floor instead of allowing fixed-width children to clip both edges.
    static let mainWindowMinWidth: CGFloat = 560
    static let mainWindowMinHeight: CGFloat = 400

    /// Width ordinary terminal content should retain before the container
    /// sidebar switches from a reserved column to a transient overlay. Review
    /// uses `ReviewRail.inlineMinimumWidth` so its file list and diff remain
    /// usable together.
    static let terminalColumnMinWidth: CGFloat = 320

    /// Below this the terminal toolbar keeps its primary controls visible and
    /// folds navigation and split actions into one menu.
    static let terminalToolbarFullWidth: CGFloat = 520

    /// Minimum width of the active-container title inside a terminal toolbar.
    static let toolbarContainerTitleMinWidth: CGFloat = 200
    /// Standard gap between top-level toolbar controls.
    static let toolbarControlSpacing: CGFloat = 8
    /// Additional width needed when the terminal toolbar also owns the active
    /// container identity, including the gap after the title.
    static var terminalToolbarContainerContextWidth: CGFloat {
        toolbarContainerTitleMinWidth + toolbarControlSpacing
    }

    /// Container column width — clamped via min/max below.
    static let containerColumnWidth: CGFloat = 240

    /// Tab column (tab list / mode body) default width. The current value
    /// lives on `WindowSession.tabColumnWidth` so the user can drag-resize
    /// it; double-clicking the divider resets to this default.
    ///
    /// Derived from the container column rather than set apart from it.
    /// It used to be 260 against the container's 240, which gave the
    /// wider column to the shorter names — a tab list holds `main` and
    /// `shell`, the container list holds branch names long enough to
    /// truncate. Two widths that near each other also read as a mistake
    /// rather than as hierarchy.
    static var tabColumnWidth: CGFloat {
        containerColumnWidth
    }

    static let tabColumnMinWidth: CGFloat = 200
    static let tabColumnMaxWidth: CGFloat = 500

    /// Container column Waiting region height as a fraction of the slab height.
    /// Default for `WindowSession.attentionHeightFraction`: the share a
    /// session opens at until the user moves the divider, and the share
    /// a double-click resets to. A fraction (not points) so the region
    /// keeps its proportion when the window resizes.
    static let attentionHeightFraction: CGFloat = 0.25
    static let attentionMinFraction: CGFloat = 0.08
    static let attentionMaxFraction: CGFloat = 0.6
    /// Floor for the Waiting region in points — regardless of the
    /// fraction, the region never shrinks below this so the header + the
    /// 0-item message ("All clear" / "N hidden by filter") stay visible
    /// in small sidebars. Eyeballed from the header padding (top 18 +
    /// bottom 10) and one 11pt hint row. `VerticalSplitView` holds it on
    /// every path — drag, restore, and window resize — the last of which
    /// needs `splitView(_:resizeSubviewsWithOldSize:)` because
    /// `NSSplitView`'s own proportional resize ignores delegate limits.
    static let attentionMinHeight: CGFloat = 100
    /// Floor for the container list pane above the Waiting divider, so
    /// it can't collapse to nothing. Declared through the split view's
    /// divider limits, unlike `attentionMinHeight`, which
    /// `VerticalSplitView` also resolves itself.
    static let containerListMinHeight: CGFloat = 100

    /// Distance from a column's top edge to where toolbar content (the
    /// action capsule / container title) starts. Derived rather than
    /// typed in, so the space above the content always equals the space
    /// below it: a literal 14 left 14 above and 6 below and read
    /// top-heavy. One value covers all three columns because every one
    /// of them starts at the window top; the container column needed a
    /// smaller inset only while it sat inside an inset slab.
    static var toolbarContentTopInset: CGFloat {
        (topStripHeight - toolbarContentHeight) / 2
    }

    /// Height of the toolbar content row itself (button frame height).
    static let toolbarContentHeight: CGFloat = 28

    /// Point size for SF Symbols rendered in the toolbar strip (+, …,
    /// bell, sidebar toggle, back/forward, split, update). Centralized
    /// so the container / tab / terminal column toolbar icons keep the same weight and scale
    /// as the system's Notes-style toolbar — bump here, not per call site.
    static let toolbarIconSize: CGFloat = 14

    /// Width × height of every clickable icon in the main-window toolbar.
    static let toolbarButtonWidth: CGFloat = 28
    static let toolbarButtonHeight: CGFloat = 28
    /// Corner radius of the transient hover highlight.
    static let toolbarButtonHoverCorner: CGFloat = 7
    /// Width × height of the separator between control scopes.
    static let toolbarSeparatorWidth: CGFloat = 0.5
    static let toolbarSeparatorHeight: CGFloat = 18

    // MARK: - Reorderable list spacing

    // Inter-row spacing for every sidebar list backed by
    // `reorderableDropTarget(...)`. The live-reorder path animates
    // rows into their new slot rather than drawing an insertion line,
    // so we only need the spacing token now — the legacy
    // insertion-line geometry constants are gone.

    static let reorderRowSpacing: CGFloat = 6

    /// Inset from a row's frame to its selection pill, so consecutive
    /// pills never touch. `selectablePillBackground` defaults to it;
    /// rows that compute their own content insets subtract it to get
    /// the distance from the pill's edge rather than the row's.
    static let rowPillInset: CGFloat = 10

    // MARK: - Container column row geometry

    /// Fixed-width slot for the leading marker. Every row reserves it,
    /// including nested ones that draw nothing in it: that is what
    /// puts a child's label on the same left edge as its parent's, and
    /// it leaves the column the project rule runs down. Making the
    /// slot conditional also desynchronizes the markers from their
    /// labels when a sibling row is removed — see `ContainerRow`.
    static let containerColumnMarkerSlot: CGFloat = 18
    /// Gap between the row's leading marker, its label, and the
    /// trailing accessories.
    static let containerColumnRowContentSpacing: CGFloat = 8
    /// Height of every row in the container list, nested or not.
    ///
    /// Nested rows used to be 4pt shorter. The selection pill is the
    /// row, so that made the highlight hug a worktree label more
    /// tightly than a project label — one control changing shape with
    /// its contents. Depth is already carried by the palette dot, the
    /// label's weight, and the project rule, so the height was buying
    /// nothing. macOS source lists keep one height throughout.
    static let containerColumnRowHeight: CGFloat = 30
    /// Leading inset inside the row (after the slab interior).
    static let containerColumnIndentTop: CGFloat = 18
    /// Inside-row trailing padding (keeps the accessories comfortably
    /// away from the pill's trailing edge).
    static let containerColumnRowTrailingPadding: CGFloat = 18

    /// One slot of the row's trailing group. Only the bell reserves
    /// one unconditionally; the request mark and agent state take a
    /// slot when they have something to say and none when they do
    /// not. That fixes the group's right edge across every row, which
    /// a permanently reserved slot on only some kinds did not.
    static let containerColumnTrailingSlot: CGFloat = 16
    /// Gap between those slots. Tighter than
    /// `containerColumnRowContentSpacing` because the trailing icons
    /// are one group, where the marker and label are separate things.
    static let containerColumnTrailingSpacing: CGFloat = 6

    /// Drawn size of the pull-request glyph inside its trailing slot.
    /// Smaller than `containerColumnTrailingSlot`, which the Octicons
    /// drawings would otherwise fill edge to edge and out-weigh the
    /// agent state beside them. Scaling a filled path costs no
    /// density, so the mark sits quieter without going faint.
    static let containerColumnPRGlyphSize: CGFloat = 12

    /// Width of the tinted rule `ProjectSectionView` runs down a
    /// project's worktree rows.
    static let containerColumnProjectRuleWidth: CGFloat = 2
    /// Where that rule is centerd, measured from the row's leading
    /// edge. The middle of the marker slot, so the rule descends from
    /// the parent's palette dot rather than sitting at an unrelated x.
    static var containerColumnProjectRuleCenter: CGFloat {
        containerColumnIndentTop + containerColumnMarkerSlot / 2
    }

    /// Leading inset for a nested row's selection pill.
    ///
    /// Wider than the usual symmetric inset so the pill begins clear
    /// of the project rule. At the shared inset the rule ran straight
    /// through the pill's rounded corner, which read as a mistake
    /// rather than as structure. Starting the pill after the rule also
    /// makes the child rows hang off it, which is what the rule is
    /// there to say.
    static var containerColumnNestedPillLeading: CGFloat {
        // The clearance is the trailing group's own gap, reused so the
        // pill sits off the rule by the same distance the accessories
        // sit off each other.
        containerColumnProjectRuleCenter
            + containerColumnProjectRuleWidth / 2
            + containerColumnTrailingSpacing
    }

    // MARK: - Pull-request hover card

    /// Drawn size of the check-status glyph inside the hover card,
    /// picked to sit with the `.callout` text beside it rather than
    /// inside a row's trailing slot. Separate from
    /// `containerColumnPRGlyphSize` so adjusting one does not silently
    /// move the other. Fixed, like every size here, so it does not
    /// track the `.callout` under Dynamic Type.
    static let prCardGlyphSize: CGFloat = 14

    /// How long the pointer has to rest on a row before its card
    /// appears. Long enough that dragging the pointer down the sidebar
    /// does not flash a card per row, short enough to read as a
    /// deliberate peek rather than a wait.
    static let prHoverCardOpenDelay: Duration = .milliseconds(250)

    /// Grace period started when the pointer leaves either the row or
    /// the card, long enough to cross the gap between them before the
    /// card is taken away. Whether it is actually gone is decided when
    /// the period expires, not when it starts. Long enough for the
    /// trip, short enough that a dismissal the user did intend does
    /// not feel sticky — nothing ties it to the open delay.
    static let prHoverCardDismissGrace: Duration = .milliseconds(150)

    // MARK: - Pane surface

    /// Radius of the banner a pane shows when its process exits. The
    /// pane itself is square and flush: it is the content, and a
    /// terminal's character grid — a full-width tmux status row most
    /// visibly — should not be clipped by a corner or held off the
    /// column edge. The banner is a card floating over that content,
    /// so it still rounds.
    static let paneBannerCornerRadius: CGFloat = 10

    // MARK: - Sidebar

    /// Sidebar width clamp (the user can drag the right edge).
    static let sidebarMinWidth: CGFloat = 180
    static let sidebarMaxWidth: CGFloat = 400

    /// Default width of an invisible resize handle.
    static let resizeHandleWidth: CGFloat = 6

    /// Width of the transparent resize handles between main-window columns.
    /// Rows remain selectable outside this band; their trailing controls start
    /// farther inward at `containerColumnRowTrailingPadding`.
    static let columnResizeHandleWidth: CGFloat = 12

    // MARK: - Tab pill

    /// Tab pill width clamp. The pill grows to maxWidth while renaming
    /// so the editor field has room.
    static let tabPillMinWidth: CGFloat = 100
    static let tabPillMaxWidth: CGFloat = 200

    /// Tab pill height. Derived from the container row rather than
    /// typed in: the container list is the canonical row geometry and
    /// the tab list follows it. It used to be a literal 32 that nothing
    /// read at all, while the tab row's real height fell out of its
    /// vertical padding — so the two lists ran at different pitches and
    /// drifted further apart the further down you looked.
    static var tabPillHeight: CGFloat {
        containerColumnRowHeight
    }

    // MARK: - Horizontal tab bar (tab column horizontal mode)

    /// Breathing room above a row list, between it and the toolbar row
    /// it sits under. Every list that carries rows takes it — the
    /// container list, the tab list, and the horizontal strip, which
    /// takes it below its pills as well. Sharing one value is what puts
    /// the first row of all three on the same line; a strip that
    /// centered its pills in a taller frame used to sit 11pt lower than
    /// the sidebar beside it.
    static let rowListInset: CGFloat = 8

    /// Height of the horizontal tab strip shown above the terminal
    /// column in horizontal mode. Derived from the pill and the shared
    /// inset so a change to the row geometry carries the strip with it.
    static var horizontalTabBarHeight: CGFloat {
        tabPillHeight + 2 * rowListInset
    }

    /// Minimum width a tab keeps in horizontal mode. When the tabs no
    /// longer fit the strip at this width, the strip becomes
    /// horizontally scrollable instead of squeezing them narrower.
    static let horizontalTabMinWidth: CGFloat = 180

    /// Inter-pill spacing for the horizontal tab strip. The horizontal
    /// pill drops `SelectablePillBackground.horizontalPadding` to 0, so
    /// this `HStack` gap is the *only* space between adjacent pills.
    static let horizontalTabSpacing: CGFloat = 6

    /// Leading / trailing inset for the horizontal tab strip so the
    /// first and last pills don't kiss the terminal column edges. It is
    /// the vertical list's pill inset, read from the token rather than
    /// repeated, because the comment claiming they match is only worth
    /// having if nothing can drift them apart.
    static var horizontalTabStripInset: CGFloat {
        rowPillInset
    }

    // MARK: - Pane

    /// Minimum size a pane can be resized to via the split divider.
    static let paneMinSize: CGFloat = 80

    // MARK: - Timings

    /// Debounce window before the on-disk state file is rewritten.
    static let persistenceDebounce: TimeInterval = 0.400

    /// Debounce window applied to libghostty SET_TITLE updates so a
    /// shell that prints "exit" right before terminating doesn't flash
    /// it onto the tab before close_surface_cb fires.
    static let setTitleDebounce: TimeInterval = 0.08

    /// Easing curve used when the tab pill grows / shrinks between its
    /// natural width and the rename-mode `maxWidth` lock.
    static let renamePillDuration: TimeInterval = 0.18
}
