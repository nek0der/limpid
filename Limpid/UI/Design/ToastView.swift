// ToastView.swift
// Limpid — bottom-anchored glass capsule that surfaces the current
// `ToastCenter` slot. Shape borrows from macOS Mail's "Undo" banner
// and the macOS 26 Liquid Glass capsule pattern: a single pill with
// a tinted Undo button, fades in / out on identity change.

import SwiftUI

struct ToastHost: View {
    @Environment(ToastCenter.self) private var toastCenter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack {
            Spacer(minLength: 0)
            if let item = toastCenter.current {
                ToastCapsule(item: item)
                    .padding(.bottom, 24)
                    // Vertical slide + spring overshoot is the kind of
                    // motion Reduce Motion users opt out of. Drop the
                    // move half (pure cross-fade) and flatten the
                    // spring when the setting is on.
                    .transition(reduceMotion
                        ? .opacity
                        : .move(edge: .bottom).combined(with: .opacity))
                    .id(item.id)
            }
        }
        .allowsHitTesting(toastCenter.current != nil)
        .animation(
            reduceMotion ? .linear(duration: 0.15) : LimpidMotion.transientBanner,
            value: toastCenter.current?.id
        )
    }
}

private struct ToastCapsule: View {
    @Environment(ToastCenter.self) private var toastCenter
    @Environment(\.limpidAccent) private var accent
    let item: ToastItem

    var body: some View {
        HStack(spacing: 12) {
            Text(item.message)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(.primary)
                .lineLimit(2)
            if item.undo != nil {
                Button {
                    toastCenter.undo()
                } label: {
                    Text("Undo")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(accent)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointerStyle(.link)
            }
            // No ⌘Z shortcut — Limpid runs terminal sessions where
            // ⌘Z routes into the focused pane (editor undo), so the
            // toast can't claim that key without breaking the host
            // app's primary use case. Users click Undo explicitly.
            Button {
                toastCenter.dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)
            .help("Dismiss")
            .accessibilityLabel(Text("Dismiss"))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            Capsule()
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.18), radius: 14, y: 4)
        )
        .overlay(
            Capsule().stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
    }
}
