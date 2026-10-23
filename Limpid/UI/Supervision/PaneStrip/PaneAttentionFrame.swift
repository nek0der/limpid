// PaneAttentionFrame.swift
// Limpid — the frame around a pane whose agent waits on the person or stopped.

import SwiftUI

/// A thin inner frame (`paneAttentionFrameWidth`): amber while the
/// pane's agent waits for an answer or an approval, red once it stopped.
/// It blinks once, for 600ms, when it appears, and not under Reduce
/// Motion. An unread turn has none: it is not urgent. The keyboard stays
/// with the terminal. Where the pane
/// meets the edges of the session's surface, the frame steps inside the
/// surface's border and follows its rounded corners, so none of it is
/// covered or cut (`SurfaceFrameFit`).
struct PaneAttentionFrame: View {
    let paneID: UUID
    @Environment(AttentionQueueStore.self) private var attentionQueue
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isDimmed = false
    @State private var blink: Task<Void, Never>?
    /// Which of the pane's edges and corners are the surface's, read from
    /// the pane's place on it.
    @State private var fit = SurfaceFrameFit.none

    var body: some View {
        let attention = PaneAttention.of(attentionQueue.queue.items(inPane: paneID))
        ZStack {
            if let attention {
                UnevenRoundedRectangle(cornerRadii: fit.radii, style: .continuous)
                    .strokeBorder(
                        attention.isWaiting ? SupervisionTokens.waiting.color : SupervisionTokens.stopped.color,
                        lineWidth: LimpidLayout.Supervision.paneAttentionFrameWidth
                    )
                    .padding(fit.insets)
                    .opacity(isDimmed ? 0.2 : 1)
            }
        }
        // The pane's whole face, frame or not, so its place is known before
        // the frame first shows.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The pane's place and the surface's size in one reading, so a
        // resize never pairs one moment's place with another's size.
        .onGeometryChange(for: SurfaceFrameFit.self) { proxy in
            SurfaceFrameFit.fit(size: proxy.size, surfaceBounds: proxy.bounds(of: .named(SupervisionWindowView.surfaceSpace)))
        } action: { newFit in
            fit = newFit
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear {
            if attention != nil {
                blinkOnce()
            }
        }
        // Once when it appears, and again only when its color changes: an
        // approval followed by a question is still the same amber frame.
        .onChange(of: attention) { previous, current in
            if let current, previous?.isWaiting != current.isWaiting {
                blinkOnce()
            }
        }
        .onDisappear { blink?.cancel() }
    }

    private func blinkOnce() {
        blink?.cancel()
        guard !reduceMotion else { return }
        blink = Task { @MainActor in
            withAnimation(LimpidMotion.attentionBlinkHalf) { isDimmed = true }
            try? await Task.sleep(for: .seconds(LimpidMotion.attentionBlinkHalfDuration))
            // Canceled or not, the frame ends drawn in full.
            withAnimation(LimpidMotion.attentionBlinkHalf) { isDimmed = false }
        }
    }
}
