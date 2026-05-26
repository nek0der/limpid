// SidebarResizeHandle.swift
// Limpid — generic invisible drag divider used for both the L1 slab
// and the L2 column's right edge. Clamps width to a min/max range,
// updates a session field in real time, and resets to a default on
// double-click — matches how AppKit window splitters behave.

import AppKit
import SwiftUI

struct DividerResizeHandle: View {
    /// Closure that reads the current width — the caller owns the
    /// state on `WindowSession`; we just stay reactive.
    let currentWidth: () -> CGFloat
    /// Sink for width changes during drag.
    let setWidth: (CGFloat) -> Void
    let minWidth: CGFloat
    let maxWidth: CGFloat
    let defaultWidth: CGFloat
    /// `true` when the panel grows by dragging *left* (e.g. a right
    /// sidebar whose handle hugs its leading edge). Default `false`
    /// matches the L1/L2 columns which grow by dragging right.
    var invertDrag: Bool = false

    @State private var dragStart: CGFloat?

    var body: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: LimpidLayout.sidebarResizeHandleWidth)
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.pop()
                }
            }
            // `.gesture(...)` + `.onTapGesture(...)` don't compose: a
            // DragGesture with `minimumDistance: 0` claims every mouse
            // down, so the tap can never complete. Combine them with
            // `ExclusiveGesture` so the double-click is tried first;
            // if the user moves the cursor, the tap fails and the
            // drag takes over.
            .gesture(
                TapGesture(count: 2)
                    .onEnded {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            setWidth(defaultWidth)
                        }
                    }
                    .exclusively(before:
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                if dragStart == nil { dragStart = currentWidth() }
                                let delta = invertDrag ? -value.translation.width : value.translation.width
                                let next = (dragStart ?? currentWidth()) + delta
                                setWidth(next.clampedToResizeRange(min: minWidth, max: maxWidth))
                            }
                            .onEnded { _ in
                                dragStart = nil
                            }
                    )
            )
    }
}

/// Drop-in for the L1 slab right edge.
struct SidebarResizeHandle: View {
    @Bindable var session: WindowSession

    var body: some View {
        DividerResizeHandle(
            currentWidth: { session.sidebarWidth },
            setWidth: { session.sidebarWidth = $0 },
            minWidth: LimpidLayout.sidebarMinWidth,
            maxWidth: LimpidLayout.sidebarMaxWidth,
            defaultWidth: LimpidLayout.l1Width
        )
    }
}

/// Drop-in for the L2 column right edge.
struct L2ResizeHandle: View {
    @Bindable var session: WindowSession

    var body: some View {
        DividerResizeHandle(
            currentWidth: { session.l2Width },
            setWidth: { session.l2Width = $0 },
            minWidth: LimpidLayout.l2MinWidth,
            maxWidth: LimpidLayout.l2MaxWidth,
            defaultWidth: LimpidLayout.l2Width
        )
    }
}

/// Drop-in for the prompt-history sidebar's *leading* edge — the
/// sidebar sits to the right of the terminal, so the drag handle is
/// on its left. Width grows when the user drags leftward; the closure
/// inverts the delta to match that orientation.
struct PromptSidebarResizeHandle: View {
    @Bindable var session: WindowSession

    var body: some View {
        DividerResizeHandle(
            currentWidth: { session.promptSidebarWidth },
            setWidth: { session.promptSidebarWidth = $0 },
            minWidth: LimpidLayout.promptSidebarMinWidth,
            maxWidth: LimpidLayout.promptSidebarMaxWidth,
            defaultWidth: LimpidLayout.promptSidebarWidth,
            invertDrag: true
        )
    }
}

private extension CGFloat {
    func clampedToResizeRange(min lo: CGFloat, max hi: CGFloat) -> CGFloat {
        Swift.min(Swift.max(self, lo), hi)
    }
}
