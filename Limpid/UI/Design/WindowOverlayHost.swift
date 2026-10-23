// WindowOverlayHost.swift
// Limpid — a panel over the whole window on a dimming scrim that closes it when clicked: All Projects and the keyboard shortcuts panel.

import SwiftUI

/// Lays a panel over its window while `isPresented`, dimming what is behind
/// it. A click on the scrim calls `onDismiss`, with no monitor of the
/// window's clicks. The scrim and the panel share one curve
/// (`ModalMotion.overlayPanel` over `.overlayScrim`), so they come and go
/// together; Reduce Motion drops the panel's scale, not the fade.
///
/// Only the scrim and the motion are shared. The panel's size, its keys, and
/// its environment are the caller's, and so is everything else that closes
/// it: `onDismiss` is for the scrim's click alone and is not tied to
/// `isPresented` turning off. A panel that goes because another layer came
/// up must not run a close that hands the keyboard back to the terminal,
/// since that layer has the keyboard now (`WindowLayer`).
struct WindowOverlayHost<Content: View>: View {
    let isPresented: Bool
    let onDismiss: () -> Void
    /// This builds the panel, laid out in the window's whole size.
    @ViewBuilder let content: (GeometryProxy) -> Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if isPresented {
                SupervisionTokens.scrim
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onDismiss)
                    .accessibilityHidden(true)
                    .modalTransition(.overlayScrim, reduceMotion: reduceMotion)
                GeometryReader { proxy in
                    content(proxy)
                }
                .modalTransition(.overlayPanel, reduceMotion: reduceMotion)
            }
        }
        .animation(ModalMotion.overlayPanel.animation(reduceMotion: reduceMotion), value: isPresented)
    }
}
