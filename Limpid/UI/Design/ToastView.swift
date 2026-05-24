// ToastView.swift
// Limpid — bottom-anchored glass capsule that surfaces the current
// `ToastCenter` slot. Shape borrows from macOS Mail's "Undo" banner
// and the macOS 26 Liquid Glass capsule pattern: a single pill with
// a tinted Undo button, fades in / out on identity change.

import SwiftUI

struct ToastHost: View {
    @Environment(ToastCenter.self) private var toastCenter

    var body: some View {
        VStack {
            Spacer(minLength: 0)
            if let item = toastCenter.current {
                ToastCapsule(item: item)
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .id(item.id)
            }
        }
        .allowsHitTesting(toastCenter.current != nil)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: toastCenter.current?.id)
    }
}

private struct ToastCapsule: View {
    @Environment(ToastCenter.self) private var toastCenter
    let item: ToastItem

    var body: some View {
        HStack(spacing: 12) {
            Text(item.message)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(.primary)
                .lineLimit(2)
            Button {
                toastCenter.undo()
            } label: {
                Text("Undo")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
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
            .help("Dismiss")
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
