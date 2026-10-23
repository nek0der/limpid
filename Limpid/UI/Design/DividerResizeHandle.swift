// DividerResizeHandle.swift
// Limpid — the invisible drag divider beside a resizable column, which a double click resets.

import SwiftUI

/// Used for the sidebar, the changes panel, and the review's file list.
/// Clamps width to a min/max range, updates its owner in real time, and
/// resets to a default on double-click — matches how AppKit window
/// splitters behave.
struct DividerResizeHandle: View {
    /// Reads the current width. The caller owns it (the window's selection
    /// on `WorkspaceSession`, or the review's presentation); we only read it.
    let currentWidth: () -> CGFloat
    /// Sink for width changes during drag.
    let setWidth: (CGFloat) -> Void
    let minWidth: CGFloat
    let maxWidth: CGFloat
    let defaultWidth: CGFloat
    /// Width reserved for pointer hit testing. Column dividers use a wider
    /// band than compact secondary surfaces so users do not grab a row drag.
    var hitWidth: CGFloat = LimpidLayout.resizeHandleWidth
    /// Names the divider for VoiceOver, which also gets increment and
    /// decrement from it. Optional only so a caller cannot forget to say what
    /// its divider adjusts; every handle in the app passes one.
    var accessibilityLabel: Text?
    /// How far one increment moves the divider.
    var accessibilityStep: CGFloat = 24
    /// Whether the divider sits on the column's leading edge (a panel on
    /// the right), where dragging left is what makes it wider.
    var isOnLeadingEdge = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dragStart: CGFloat?

    var body: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: hitWidth)
            .contentShape(Rectangle())
            .pointerStyle(.columnResize)
            // `.gesture(...)` + `.onTapGesture(...)` don't compose: a
            // DragGesture with `minimumDistance: 0` claims every mouse
            // down, so the tap can never complete. Combine them with
            // `ExclusiveGesture` so the double-click is tried first;
            // if the user moves the cursor, the tap fails and the
            // drag takes over.
            .gesture(
                TapGesture(count: 2)
                    .onEnded {
                        withAnimation(reduceMotion ? nil : LimpidMotion.columnReset) {
                            setWidth(defaultWidth)
                        }
                    }
                    .exclusively(before:
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                if dragStart == nil {
                                    dragStart = currentWidth()
                                }
                                let delta = isOnLeadingEdge ? -value.translation.width : value.translation.width
                                let next = (dragStart ?? currentWidth()) + delta
                                write(next)
                            }
                            .onEnded { _ in
                                dragStart = nil
                            }
                    )
            )
            .accessibilityElement()
            .accessibilityHidden(accessibilityLabel == nil)
            .accessibilityLabel(accessibilityLabel ?? Text(verbatim: ""))
            .accessibilityValue(Text(verbatim: "\(Int(currentWidth().rounded()))"))
            .accessibilityAdjustableAction { direction in
                let delta = direction == .increment ? accessibilityStep : -accessibilityStep
                write(currentWidth() + delta)
            }
    }

    /// Writes `proposed` held to the range, unless that is the width
    /// already drawn (`DividerResizeRule`).
    private func write(_ proposed: CGFloat) {
        if let width = DividerResizeRule.width(
            proposed: proposed,
            current: currentWidth(),
            minWidth: minWidth,
            maxWidth: maxWidth
        ) {
            setWidth(width)
        }
    }
}
