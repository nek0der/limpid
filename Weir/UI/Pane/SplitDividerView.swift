// SplitDividerView.swift
// Weir — the seam between two split panes and the band that resizes them.

import SwiftUI

/// Where a split's two children, its seam, and its grab band go, in the
/// split's own points.
///
/// The panes meet at a seam one device pixel wide, the width of the rule
/// under a pane header, so side-by-side headers read as one row cut by a
/// hairline rather than two bands with a gutter between them. Every edge
/// is rounded to the device's pixel grid here, so the seam is exactly one
/// pixel at any ratio rather than whatever two independent roundings of
/// the panes' frames leave (nothing, or two pixels). The grid is the
/// split's own, so this holds while the split starts on a pixel, as the
/// pane area does and as every child placed here does.
struct SplitSeamGeometry: Equatable {
    let first: CGRect
    let second: CGRect
    /// The one-pixel line between `first` and `second`.
    let seam: CGRect
    /// What the pointer grabs: the seam and `hitOverhang` over each pane.
    let hitArea: CGRect

    /// How far the grab band reaches over each pane. A one-pixel seam is too
    /// thin to grab, so the band lies over both panes' edges instead of
    /// taking room between them. Whole points keep the band's edges, and the
    /// seam drawn inside it, on the pixel grid at every display scale.
    static let hitOverhang: CGFloat = 3

    /// `firstMinimum` and `secondMinimum` are the two sides' floors along
    /// the split's axis, the ones `PaneSplit.resolvedRatio` resolved `ratio`
    /// against.
    init(
        size: CGSize,
        ratio: Double,
        direction: SplitDirection,
        displayScale: CGFloat,
        firstMinimum: CGFloat = 0,
        secondMinimum: CGFloat = 0
    ) {
        let scale = max(displayScale, 1)
        let pixel = 1 / scale
        let extent = direction == .horizontal ? size.width : size.height
        let rawFirst = CGFloat(ratio) * extent - pixel / 2
        var firstExtent = (rawFirst * scale).rounded() / scale
        // `resolvedRatio` keeps half a point of room on each side of the
        // ratio, which covers the pixel and its rounding on a Retina display
        // but not on a 1x one, where both are a whole point. So the floors
        // are held here too, on the grid, whenever both fit.
        let lowest = (firstMinimum * scale).rounded(.up) / scale
        let highest = ((extent - pixel - secondMinimum) * scale).rounded(.down) / scale
        if lowest <= highest {
            firstExtent = min(max(firstExtent, lowest), highest)
        }
        firstExtent = min(max(firstExtent, 0), max(extent - pixel, 0))
        let secondOrigin = firstExtent + pixel
        let secondExtent = max(extent - secondOrigin, 0)
        let overhang = Self.hitOverhang
        switch direction {
        case .horizontal:
            first = CGRect(x: 0, y: 0, width: firstExtent, height: size.height)
            second = CGRect(x: secondOrigin, y: 0, width: secondExtent, height: size.height)
            seam = CGRect(x: firstExtent, y: 0, width: pixel, height: size.height)
            hitArea = CGRect(x: firstExtent - overhang, y: 0, width: pixel + 2 * overhang, height: size.height)
        case .vertical:
            first = CGRect(x: 0, y: 0, width: size.width, height: firstExtent)
            second = CGRect(x: 0, y: secondOrigin, width: size.width, height: secondExtent)
            seam = CGRect(x: 0, y: firstExtent, width: size.width, height: pixel)
            hitArea = CGRect(x: 0, y: firstExtent - overhang, width: size.width, height: pixel + 2 * overhang)
        }
    }
}

/// The seam between two panes and the band over it that resizes them: a
/// drag moves the seam, a double click equalizes the split.
///
/// At rest only the seam shows, in the color of the rule under a pane
/// header, so the two read as one kind of line. The seam lies between the
/// panes and a header's rule inside its pane, so where they meet they touch
/// end to end and never draw over each other. Under the pointer the whole
/// band takes the accent's tint.
///
/// The band lies over the edges of both panes' terminals, which are AppKit
/// views (`SurfaceView`). It still takes the pointer there because it comes
/// after both panes in the split's `ZStack`: SwiftUI hit-tests its content
/// front to back and answers the window's hit test with its own view inside
/// the band, so AppKit sends the press to the drag gesture, not to the
/// terminal; `SplitSeamGeometryTests` holds this against a hosted AppKit
/// view. The terminal's tracking area still hears the moves, but
/// `SurfaceView.mouseMoved` asks the window what is under the pointer and
/// steps aside when it is not the terminal, so it neither sets its I-beam
/// on a move nor reports the pointer to the program inside. Its I-beam
/// cursor rect gives way to the band's pointer style as it does to the
/// changes panel's `.pointerStyle(.default)` laid over a terminal.
///
/// Within 3pt of the seam the band is what a click, a double click or a
/// scroll reaches, not the terminal, as it is in any editor whose split
/// handle lies over its panes' edges.
struct SplitDividerView: View {
    let direction: SplitDirection
    let geometry: SplitSeamGeometry
    /// The pointer's place in the split's coordinates while it drags.
    let onDrag: (CGPoint) -> Void
    let onEqualize: () -> Void

    @State private var isHovering: Bool = false
    @Environment(\.weirAccent) private var accent

    var body: some View {
        let hitArea = geometry.hitArea
        let seam = geometry.seam
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(isHovering ? accent.opacity(0.35) : Color.clear)
            if !isHovering {
                WeirColor.paneHeaderDivider
                    .frame(width: seam.width, height: seam.height)
                    .offset(x: seam.minX - hitArea.minX, y: seam.minY - hitArea.minY)
            }
        }
        .frame(width: hitArea.width, height: hitArea.height, alignment: .topLeading)
        .contentShape(Rectangle())
        .pointerStyle(direction == .horizontal ? .columnResize : .rowResize)
        .onHover { isHovering = $0 }
        .help("Double-click to equalize")
        .position(x: hitArea.midX, y: hitArea.midY)
        // Attached after `position`, which fills the split, so the drag's
        // location is in the split's coordinates; the hit shape stays the
        // band's.
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { onDrag($0.location) }
        )
        // Tap classification runs before `DragGesture` accumulates the
        // 1px slop it needs to fire `onChanged`, so a clean double-
        // click reaches us even though the drag modifier is attached
        // above. `simultaneousGesture` avoids the priority struggle
        // that an `.onTapGesture(count: 2)` modifier would force.
        .simultaneousGesture(
            TapGesture(count: 2).onEnded { onEqualize() }
        )
        // Only a pointer can drag or double-click it; VoiceOver and
        // the keyboard size panes with the menu's Equalize Splits, so
        // an element with nothing to do would only be one more stop.
        .accessibilityHidden(true)
    }
}
