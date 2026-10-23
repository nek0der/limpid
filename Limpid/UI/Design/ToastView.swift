// ToastView.swift
// Limpid — the bottom-anchored toast that surfaces the current
// `ToastCenter` slot, an inverted box that fades in and out on identity
// change.

import SwiftUI

struct ToastHost: View {
    /// The gap below the toast, measured from the window's bottom edge.
    let bottomInset: CGFloat
    @Environment(ToastCenter.self) private var toastCenter
    /// The window this host is in, which shows its own toasts only. The
    /// one host, `WindowChromeHost`, lays this over a main window's content,
    /// and `MainWindowContent` puts that window in the environment.
    @Environment(ProjectWindowState.self) private var window
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var windowID: WindowID {
        window.id
    }

    var body: some View {
        VStack {
            Spacer(minLength: 0)
            if let item = toastCenter.current(in: windowID) {
                ToastCapsule(item: item, windowID: windowID)
                    .padding(.bottom, bottomInset)
                    // Reduce Motion stops the toast's animation: it
                    // appears and goes at once, with no slide and no fade.
                    .modalTransition(.transientBanner, reduceMotion: reduceMotion)
                    .id(item.id)
            }
        }
        .allowsHitTesting(toastCenter.current(in: windowID) != nil)
        .animation(
            ModalMotion.transientBanner.animation(reduceMotion: reduceMotion),
            value: toastCenter.current(in: windowID)?.id
        )
    }
}

private struct ToastCapsule: View {
    @Environment(ToastCenter.self) private var toastCenter
    @Environment(\.colorScheme) private var colorScheme
    let item: ToastItem
    let windowID: WindowID

    /// A box in the text color with the window's color on it, its Undo in
    /// `toastLink`, the link color that reads on that inverted ground.
    var body: some View {
        content(
            font: .supervision(.body),
            linkFont: .supervision(.body, weight: .semibold),
            text: SupervisionTokens.window.color,
            link: SupervisionTokens.toastLink.color,
            spacing: LimpidLayout.Supervision.toastSpacing
        )
        .padding(LimpidLayout.Supervision.toastInsets)
        .background(
            RoundedRectangle(cornerRadius: LimpidLayout.Supervision.toastCornerRadius, style: .continuous)
                .fill(SupervisionTokens.text.color)
                .modifier(FloatingSurfaceShadow())
        )
        .pointerStyle(.default)
    }

    private func content(font: Font, linkFont: Font, text: Color, link: Color, spacing: CGFloat) -> some View {
        HStack(spacing: spacing) {
            Text(display: item.message)
                .font(font)
                .foregroundStyle(text)
                .lineLimit(2)
            if item.undo != nil {
                Button {
                    toastCenter.undo(in: windowID)
                } label: {
                    Text("Undo", comment: "Takes back the last move: a toast's, the decision bar's after Mark as Viewed, or a restore's")
                        .font(linkFont)
                        .foregroundStyle(link)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // A mark across conversations takes every line back, which
                // "Undo" alone does not say.
                .help(item.undoLabel.map { Text($0) } ?? Text(verbatim: ""))
                .accessibilityLabel(item.undoLabel.map { Text($0) } ?? Text("Undo"))
            }
            // No ⌘Z shortcut — Limpid runs terminal sessions where
            // ⌘Z routes into the focused pane (editor undo), so the
            // toast can't claim that key without breaking the host
            // app's primary use case. Users click Undo explicitly.
            DismissGlyphButton(label: "Dismiss") {
                toastCenter.dismiss(in: windowID)
            }
            // On the inverted box the × takes the other appearance's
            // gray, which reads on a ground of the opposite lightness.
            .environment(\.colorScheme, colorScheme == .dark ? .light : .dark)
        }
    }
}
