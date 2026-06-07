// SidebarResizeHandle.swift
// Limpid — generic invisible drag divider used for both the container slab
// and the tab column's right edge. Clamps width to a min/max range,
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
                                let delta = value.translation.width
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

/// Drop-in for the container slab right edge.
struct SidebarResizeHandle: View {
    @Bindable var session: WindowSession

    var body: some View {
        DividerResizeHandle(
            currentWidth: { session.sidebarWidth },
            setWidth: { session.sidebarWidth = $0 },
            minWidth: LimpidLayout.sidebarMinWidth,
            maxWidth: LimpidLayout.sidebarMaxWidth,
            defaultWidth: LimpidLayout.containerColumnWidth
        )
    }
}

/// Drop-in for the tab column right edge.
struct TabColumnResizeHandle: View {
    @Bindable var session: WindowSession

    var body: some View {
        DividerResizeHandle(
            currentWidth: { session.tabColumnWidth },
            setWidth: { session.tabColumnWidth = $0 },
            minWidth: LimpidLayout.tabColumnMinWidth,
            maxWidth: LimpidLayout.tabColumnMaxWidth,
            defaultWidth: LimpidLayout.tabColumnWidth
        )
    }
}

private extension CGFloat {
    func clampedToResizeRange(min lo: CGFloat, max hi: CGFloat) -> CGFloat {
        Swift.min(Swift.max(self, lo), hi)
    }
}
