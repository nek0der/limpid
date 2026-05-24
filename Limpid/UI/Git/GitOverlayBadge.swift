// GitOverlayBadge.swift
// Limpid — compact `↑N ↓N ●dirty` cluster surfaced wherever git
// state needs a one-glance summary. Currently used by the L2 chrome
// title for a selected worktree; future Log / Diff mode headers
// will reuse it too. Keep this lightweight (no Environment, no
// Session) so it can render anywhere a `GitRef` is in hand.

import SwiftUI

struct GitOverlayBadge: View {
    let ref: GitRef

    var body: some View {
        HStack(spacing: 6) {
            if ref.ahead > 0 {
                indicator(symbol: "arrow.up", count: ref.ahead)
            }
            if ref.behind > 0 {
                indicator(symbol: "arrow.down", count: ref.behind)
            }
            if ref.isDirty {
                Circle()
                    .fill(LimpidColor.gitDirtyDot)
                    .frame(width: 6, height: 6)
            }
        }
    }

    private func indicator(symbol: String, count: Int) -> some View {
        HStack(spacing: 1) {
            Image(systemName: symbol)
                .font(.system(size: 8, weight: .bold))
            Text("\(count)")
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .monospacedDigit()
        }
        .foregroundStyle(LimpidColor.gitAheadBehindText)
    }
}
