// PaneSwapDropOverlay.swift
// Limpid — drop receiver for `pane:<uuid>` payloads inside the same
// window. ⌥⌘+drag from a `SurfaceView` posts the pasteboard payload via
// `SurfaceView+Drag.beginPaneDrag`; on the drop side, the cursor's
// position inside the target leaf decides what happens:
//
//   ┌────┬──────────────┬────┐
//   │    │   top 25%    │    │
//   │ L  ├──────────────┤  R │
//   │ 25%│  center 50%  │ 25%│
//   │    │   = swap     │    │
//   │    ├──────────────┤    │
//   │    │  bottom 25%  │    │
//   └────┴──────────────┴────┘
//
// Center drops trade the source and target slots (`swappingLeaves`).
// Edge drops detach the source from its current slot and re-insert it
// as a new split next to the target (`inserting(_:beside:on:)`).
//
// Each zone is its own `.dropDestination` so SwiftUI's `isTargeted`
// callback fires per zone — that's what lets the highlight track the
// cursor mid-drag (continuous-hover doesn't fire during a drag
// session).

import SwiftUI
import UniformTypeIdentifiers

/// Drop zone the cursor is hovering over (or `nil` while no pane drag
/// is in flight). `center` swaps; the four edges insert a new split.
enum PaneDropZone: Equatable {
    case center
    case left, right, top, bottom
}

struct PaneSwapDropOverlay: View {
    let targetPaneID: UUID
    let onDrop: (_ source: UUID, _ target: UUID, _ zone: PaneDropZone) -> Void
    /// Returns `true` when dropping the in-flight source pane on `zone`
    /// would change the split tree. Used to gray out (and refuse) edges
    /// whose insert would land the source in a slot it's already in.
    let isZoneEffective: (_ source: UUID, _ zone: PaneDropZone) -> Bool

    @State private var hoverZone: PaneDropZone?
    @Environment(LimpidDragState.self) private var dragState
    /// Settings-driven accent picked up via the env-injected color so
    /// the highlight follows the user's chosen accent instead of the
    /// macOS system one.
    @Environment(\.limpidAccent) private var accent

    /// Edge zones take 25% of the matching axis. Matches the standard
    /// pane-rearrangement UX seen across tiling terminals / editors.
    private static let edgeFraction: CGFloat = 0.25

    private var acceptsActiveDrag: Bool {
        guard dragState.current == .pane else { return false }
        return dragState.currentSourceID != targetPaneID.uuidString
    }

    /// In-flight source pane id (if any). Used to short-circuit
    /// no-op zones via `isZoneEffective`.
    private var activeSourceID: UUID? {
        guard let s = dragState.currentSourceID else { return nil }
        return UUID(uuidString: s)
    }

    /// `true` when the zone would actually move the source pane on drop.
    /// `nil` source (no drag in flight, malformed payload) treats every
    /// zone as effective so the visualization stays consistent for the
    /// "drag from another tab" case the caller may add later.
    private func isEffective(_ zone: PaneDropZone) -> Bool {
        guard let source = activeSourceID else { return true }
        return isZoneEffective(source, zone)
    }

    var body: some View {
        Group {
            if acceptsActiveDrag {
                GeometryReader { geo in
                    ZStack {
                        zoneGrid(in: geo.size)
                        if let zone = hoverZone {
                            // Inset the visual highlight to the same rect
                            // as `PaneContainerView`'s clipped surface +
                            // bell flash, so the drop-target outline lines
                            // up with the "this pane" rectangle the user
                            // already reads elsewhere. The hit grid above
                            // keeps the full slot extent so drops between
                            // panes still register.
                            highlight(for: zone, in: geo.size)
                                .padding(LimpidLayout.sidebarCardVerticalInset)
                                .allowsHitTesting(false)
                                .transition(.opacity)
                        }
                    }
                    .animation(LimpidMotion.reorderLive, value: hoverZone)
                }
            } else {
                // No pane drag in flight — let underlying gestures
                // through unchanged.
                Color.clear.allowsHitTesting(false)
            }
        }
        // SwiftUI tears the per-zone drop destinations down when
        // `acceptsActiveDrag` flips to false, and AppKit does NOT
        // fire a closing `isTargeted: false` after the drag session
        // has already ended — so without this reset `hoverZone`
        // would survive into the next pane drag and paint the
        // previous zone's highlight for a frame before the new
        // `isTargeted: true` callback arrives.
        .onChange(of: dragState.current) { _, new in
            if new != .pane { hoverZone = nil }
        }
    }

    // MARK: - Zone grid (5 independent drop destinations)

    @ViewBuilder
    private func zoneGrid(in size: CGSize) -> some View {
        let edge = Self.edgeFraction
        let leftW = size.width * edge
        let rightW = size.width * edge
        let middleW = size.width - leftW - rightW
        let topH = size.height * edge
        let bottomH = size.height * edge
        let centerH = size.height - topH - bottomH

        HStack(spacing: 0) {
            zoneTarget(.left)
                .frame(width: leftW)
            VStack(spacing: 0) {
                zoneTarget(.top)
                    .frame(height: topH)
                zoneTarget(.center)
                    .frame(height: centerH)
                zoneTarget(.bottom)
                    .frame(height: bottomH)
            }
            .frame(width: middleW)
            zoneTarget(.right)
                .frame(width: rightW)
        }
    }

    /// One transparent zone — accepts the same `pane:<uuid>` payload
    /// and dispatches with its own `PaneDropZone` tag. SwiftUI fires
    /// `isTargeted` per zone while the cursor crosses between them, so
    /// the parent's `hoverZone` state always reflects the live cursor
    /// position even during an AppKit drag session. Zones whose drop
    /// would be a no-op (`isZoneEffective` returns `false`) still
    /// track hover for visual feedback; the `dropDestination` action
    /// returns `false` so the drop bounces back on release rather
    /// than mutating the tree. The modern `dropDestination(for:)`
    /// API has no hover-time `DropProposal(operation: .forbidden)`
    /// hook, so the cursor's no-drop badge does NOT appear while
    /// hovering (the source-row tab uses the legacy
    /// `onDrop(of:delegate:)` path to opt back into that).
    private func zoneTarget(_ zone: PaneDropZone) -> some View {
        let target = targetPaneID
        return Color.clear
            .contentShape(Rectangle())
            .dropDestination(for: String.self) { strings, _ in
                guard isEffective(zone) else { return false }
                for wire in strings {
                    if let source = Self.parsePanePayload(wire), source != target {
                        onDrop(source, target, zone)
                        return true
                    }
                }
                return false
            } isTargeted: { active in
                if active {
                    hoverZone = zone
                } else if hoverZone == zone {
                    hoverZone = nil
                }
            }
    }

    // MARK: - Visual highlight

    /// The visual is always anchored to the *whole pane* — a single
    /// accent frame + a translucent overlay covering the entire leaf —
    /// so the user reads "this pane is the drop target" regardless of
    /// where the cursor sits. A small SF Symbol at the center hints
    /// at *what* the drop will do (swap / insert above / below / left /
    /// right). Splitting the highlight into per-zone tints used to
    /// suggest distinct actions for what is really one and the same
    /// target.
    @ViewBuilder
    private func highlight(for zone: PaneDropZone, in size: CGSize) -> some View {
        let active = isEffective(zone)
        let strokeColor = active
            ? accent.opacity(0.7)
            : Color.secondary.opacity(0.5)
        let fillColor = active
            ? accent.opacity(0.10)
            : Color.secondary.opacity(0.06)
        let symbolColor = active
            ? accent
            : Color.secondary
        ZStack {
            RoundedRectangle(cornerRadius: LimpidLayout.sidebarCardCornerRadius, style: .continuous)
                .fill(fillColor)
            Group {
                if active {
                    RoundedRectangle(cornerRadius: LimpidLayout.sidebarCardCornerRadius, style: .continuous)
                        .strokeBorder(strokeColor, lineWidth: 2)
                } else {
                    RoundedRectangle(cornerRadius: LimpidLayout.sidebarCardCornerRadius, style: .continuous)
                        .strokeBorder(
                            strokeColor,
                            style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])
                        )
                }
            }
            Image(systemName: Self.symbolName(for: zone))
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(symbolColor)
                .padding(14)
                .background(
                    Circle().fill(Material.regular)
                )
                .overlay(
                    Circle().strokeBorder(strokeColor.opacity(0.5), lineWidth: 1)
                )
        }
    }

    /// SF Symbol hinting at the action the drop will perform.
    static func symbolName(for zone: PaneDropZone) -> String {
        switch zone {
        case .center: "rectangle.2.swap"
        case .left: "arrow.left.to.line"
        case .right: "arrow.right.to.line"
        case .top: "arrow.up.to.line"
        case .bottom: "arrow.down.to.line"
        }
    }

    // MARK: - Payload parsing

    /// Extracts the UUID portion of a `pane:<uuid>` pasteboard payload.
    /// Mirrors the wire format used by `SurfaceView.beginPaneDrag`.
    static func parsePanePayload(_ payload: String) -> UUID? {
        let prefix = "pane:"
        guard payload.hasPrefix(prefix) else { return nil }
        return UUID(uuidString: String(payload.dropFirst(prefix.count)))
    }
}
