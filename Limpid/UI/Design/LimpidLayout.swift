// LimpidLayout.swift
// Limpid — layout constants gathered in one place so the various
// hard-coded sizes scattered across views become discoverable and
// movable in lockstep. Sits alongside `LimpidColor / LimpidFont /
// LimpidMotion` to round out the design-token set.

import CoreGraphics
import Foundation

enum LimpidLayout {

    // MARK: - Window toolbar

    /// Width reserved for the traffic-light buttons (close / minimize /
    /// zoom) at the top-left of the window. We use this to leave room
    /// in the main area's top strip when the sidebar is hidden.
    static let trafficLightWidth: CGFloat = 80

    /// Height of the top toolbar strip inside each column. Picked so
    /// the vertical-center of the toolbar buttons (≈ 26pt from the
    /// strip top) lines up with the repositioned AppKit traffic-light
    /// row — see `repositionTrafficLights` (originY=22 from titlebar
    /// bottom puts the close-button center near y=28 from the window
    /// top).
    static let topStripHeight: CGFloat = 52

    // MARK: - 3-pane layout (Notes 2026-style)

    /// Container column width — clamped via min/max below.
    static let containerColumnWidth: CGFloat = 240
    /// Horizontal inset from the window edge for the floating slab.
    static let containerColumnInsetH: CGFloat = 10
    /// Bottom inset for the slab so it stays clear of the window edge.
    static let containerColumnInsetV: CGFloat = 10

    /// Tab column (tab list / mode body) default width. The current value
    /// lives on `WindowSession.tabColumnWidth` so the user can drag-resize
    /// it; double-clicking the divider resets to this default.
    static let tabColumnWidth: CGFloat = 260
    static let tabColumnMinWidth: CGFloat = 200
    static let tabColumnMaxWidth: CGFloat = 500

    /// Container column Waiting region height as a fraction of the slab height.
    /// Drag-resizable via the divider above it (persisted on
    /// `WindowSession.attentionHeightFraction`); double-click resets to
    /// `attentionHeightFraction`. A fraction (not points) so the region
    /// keeps its proportion when the window resizes.
    static let attentionHeightFraction: CGFloat = 0.25
    static let attentionMinFraction: CGFloat = 0.08
    static let attentionMaxFraction: CGFloat = 0.6
    /// Floor for the Waiting region in points — regardless of the
    /// fraction, the region never shrinks below this so the header + the
    /// 0-item message ("All clear" / "N hidden by filter") stay visible
    /// in small sidebars. Eyeballed from the header padding (top 18 +
    /// bottom 10), the divider hit area, and one 11pt hint row.
    static let attentionMinHeight: CGFloat = 100
    /// Vertical drag handle hit-area height (the Waiting divider).
    static let attentionResizeHandleHeight: CGFloat = 8

    /// Distance from a column's top edge to where toolbar content (the
    /// action capsule / container title) starts. Aligns container / tab / terminal column
    /// toolbar content with the AppKit traffic-light row (center
    /// around window y ≈ 28). container column lives inside a slab whose own top is
    /// pushed down by `containerColumnInsetV`, so subtract that there.
    static let toolbarContentTopInsetContainer: CGFloat = 4
    static let toolbarContentTopInset: CGFloat = 14
    /// Height of the toolbar content row itself (button frame height).
    static let toolbarContentHeight: CGFloat = 32

    /// Point size for SF Symbols rendered in the toolbar strip (+, …,
    /// bell, sidebar toggle, back/forward, split, update). Centralized
    /// so the container / tab / terminal column toolbar icons keep the same weight and scale
    /// as the system's Notes-style toolbar — bump here, not per call site.
    static let toolbarIconSize: CGFloat = 18

    /// Width × height of every clickable button inside a toolbar
    /// capsule (action capsule, ellipsis menu). Keeping this in one
    /// place ensures container / tab / terminal column toolbars all line up.
    static let toolbarCapsuleButtonWidth: CGFloat = 38
    static let toolbarCapsuleButtonHeight: CGFloat = 32
    /// Inner corner radius of the hover highlight inside a capsule
    /// button. Sits inside the capsule's clip path so the rounded
    /// fill ends up clipped to the parent shape anyway.
    static let toolbarCapsuleHoverCorner: CGFloat = 7
    /// Width × height of the vertical hairline between buttons in a
    /// toolbar capsule.
    static let toolbarCapsuleDividerWidth: CGFloat = 0.5
    static let toolbarCapsuleDividerHeight: CGFloat = 20

    // MARK: - Reorderable list spacing

    // Inter-row spacing for every sidebar list backed by
    // `reorderableDropTarget(...)`. The live-reorder path animates
    // rows into their new slot rather than drawing an insertion line,
    // so we only need the spacing token now — the legacy
    // insertion-line geometry constants are gone.

    static let reorderRowSpacing: CGFloat = 6

    // MARK: - Container column row geometry

    /// Fixed-width slot for the leading marker (icon/dot). Every row
    /// reserves the same width so labels align across kinds.
    static let containerColumnMarkerSlot: CGFloat = 18
    /// Row heights — slightly shorter for nested rows.
    static let containerColumnRowHeightTop: CGFloat = 30
    static let containerColumnRowHeightNested: CGFloat = 26
    /// Leading inset inside the row (after the slab interior).
    static let containerColumnIndentTop: CGFloat = 18
    static let containerColumnIndentNested: CGFloat = 32
    /// Inside-row trailing padding (keeps the count comfortably away
    /// from the active stroke).
    static let containerColumnRowTrailingPadding: CGFloat = 18

    /// Vertical offset applied to the top strip + tab bar so they land
    /// at the same baseline as the sidebar card's first content row.
    static let topStripPadding: CGFloat = 8

    // MARK: - Sidebar card

    /// Corner radius for the sidebar card and the row pills inside.
    static let sidebarCardCornerRadius: CGFloat = 10
    /// Inset from the window edge for the sidebar card.
    static let sidebarCardLeadingInset: CGFloat = 8
    /// Top / bottom inset for the sidebar card.
    static let sidebarCardVerticalInset: CGFloat = 8

    /// Sidebar card width clamp (the user can drag the right edge).
    static let sidebarMinWidth: CGFloat = 180
    static let sidebarMaxWidth: CGFloat = 400

    /// Width of the transparent resize handle hugging the card's right edge.
    static let sidebarResizeHandleWidth: CGFloat = 6

    // MARK: - Tab pill

    /// Tab pill width clamp. The pill grows to maxWidth while renaming
    /// so the editor field has room.
    static let tabPillMinWidth: CGFloat = 100
    static let tabPillMaxWidth: CGFloat = 200

    /// Tab pill height — matches the sidebar group row height so the
    /// two strips align at the top of the window.
    static let tabPillHeight: CGFloat = 32

    // MARK: - Horizontal tab bar (tab column horizontal mode)

    /// Height of the horizontal tab strip shown above terminal column in horizontal
    /// mode. Sized to fit a pill (icon + title with vertical padding)
    /// plus the strip's own vertical padding.
    static let horizontalTabBarHeight: CGFloat = 52

    /// Minimum width a tab keeps in horizontal mode. When the tabs no
    /// longer fit the strip at this width, the strip becomes
    /// horizontally scrollable instead of squeezing them narrower.
    static let horizontalTabMinWidth: CGFloat = 180

    /// Inter-pill spacing for the horizontal tab strip. The horizontal
    /// pill drops `SelectablePillBackground.horizontalPadding` to 0, so
    /// this `HStack` gap is the *only* space between adjacent pills.
    static let horizontalTabSpacing: CGFloat = 6

    /// Leading / trailing inset for the horizontal tab strip so the
    /// first and last pills don't kiss the terminal column edges. Matches the
    /// padding the vertical list inherits from `selectablePillBackground`.
    static let horizontalTabStripInset: CGFloat = 10

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
