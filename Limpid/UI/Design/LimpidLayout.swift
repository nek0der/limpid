// LimpidLayout.swift
// Limpid — layout constants gathered in one place so the various
// hard-coded sizes scattered across views become discoverable and
// movable in lockstep. Sits alongside `LimpidColor / LimpidFont /
// LimpidMotion` to round out the design-token set.

import CoreGraphics
import Foundation

enum LimpidLayout {

    // MARK: - Window chrome

    /// Width reserved for the traffic-light buttons (close / minimize /
    /// zoom) at the top-left of the window. We use this to leave room
    /// in the main area's top strip when the sidebar is hidden.
    static let trafficLightWidth: CGFloat = 80

    /// Height of the top chrome strip inside each column. Picked so
    /// the vertical-center of the chrome buttons (≈ 26pt from the
    /// strip top) lines up with the repositioned AppKit traffic-light
    /// row — see `repositionTrafficLights` (originY=22 from titlebar
    /// bottom puts the close-button center near y=28 from the window
    /// top).
    static let topStripHeight: CGFloat = 52

    // MARK: - 3-pane layout (Notes 2026-style)

    /// L1 (container slab) width — clamped via min/max below.
    static let l1Width: CGFloat = 240
    /// Horizontal inset from the window edge / L2 for the L1 floating slab.
    static let l1InsetH: CGFloat = 10
    /// Bottom inset for the L1 slab so it stays clear of the window edge.
    static let l1InsetV: CGFloat = 10

    /// L2 (tab list / mode body) default width. The current value
    /// lives on `WindowSession.l2Width` so the user can drag-resize
    /// it; double-clicking the divider resets to this default.
    static let l2Width: CGFloat = 260
    static let l2MinWidth: CGFloat = 200
    static let l2MaxWidth: CGFloat = 500

    /// Distance from a column's top edge to where chrome content (the
    /// action capsule / container title) starts. Aligns L1 / L2 / L3
    /// chrome content with the AppKit traffic-light row (center
    /// around window y ≈ 28). L1 lives inside a slab whose own top is
    /// pushed down by `l1InsetV`, so subtract that there.
    static let chromeContentTopInsetL1: CGFloat = 4
    static let chromeContentTopInset: CGFloat = 14
    /// Height of the chrome content row itself (button frame height).
    static let chromeContentHeight: CGFloat = 28

    /// Width × height of every clickable button inside a chrome
    /// capsule (action capsule, ellipsis menu). Keeping this in one
    /// place ensures L1 / L2 / L3 chromes all line up.
    static let chromeCapsuleButtonWidth: CGFloat = 32
    static let chromeCapsuleButtonHeight: CGFloat = 28
    /// Inner corner radius of the hover highlight inside a capsule
    /// button. Sits inside the capsule's clip path so the rounded
    /// fill ends up clipped to the parent shape anyway.
    static let chromeCapsuleHoverCorner: CGFloat = 6
    /// Width × height of the vertical hairline between buttons in a
    /// chrome capsule.
    static let chromeCapsuleDividerWidth: CGFloat = 0.5
    static let chromeCapsuleDividerHeight: CGFloat = 16

    // MARK: - Reorderable list spacing

    //
    // Inter-row spacing for every sidebar list backed by
    // `reorderableDropTarget(...)`. The live-reorder path animates
    // rows into their new slot rather than drawing an insertion line,
    // so we only need the spacing token now — the legacy
    // insertion-line geometry constants are gone.

    static let reorderRowSpacing: CGFloat = 6

    // MARK: - L1 row geometry (ContainerRow)

    /// Fixed-width slot for the leading marker (icon/dot). Every row
    /// reserves the same width so labels align across kinds.
    static let l1MarkerSlot: CGFloat = 14
    /// Row heights — slightly shorter for nested rows.
    static let l1RowHeightTop: CGFloat = 30
    static let l1RowHeightNested: CGFloat = 26
    /// Leading inset inside the row (after the slab interior).
    static let l1IndentTop: CGFloat = 18
    static let l1IndentNested: CGFloat = 32
    /// Inside-row trailing padding (keeps the count comfortably away
    /// from the active stroke).
    static let l1RowTrailingPadding: CGFloat = 18

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
