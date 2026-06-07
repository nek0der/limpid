// PaneSearchOverlay.swift
// Limpid — floating ⌘F search bar for one pane. Mirrors libghostty's
// reference macOS overlay: TextField + chevron buttons + close button +
// n/total counter. Esc closes, ⏎ / ⇧⏎ navigate.
//
// The overlay observes `PaneSearchState` (one per pane in
// `WindowSession.paneSearchStates`). Needle edits flow through a
// 300ms debounce (immediate for 3+ chars or empty) into the
// libghostty binding action `search:<needle>`. Esc / the close
// button route through `SearchActions.endSearch`, which both drops
// the state entry and emits `end_search` to libghostty.

import AppKit
import GhosttyKit
import SwiftUI

struct PaneSearchOverlay: View {
    let paneID: UUID
    @Bindable var state: PaneSearchState
    let surfaceView: SurfaceView
    let onClose: () -> Void

    @FocusState private var fieldFocused: Bool
    @State private var debounceTask: Task<Void, Never>?

    var body: some View {
        HStack(spacing: 6) {
            TextField("Search", text: $state.needle)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($fieldFocused)
                .frame(width: 180)
                .padding(.leading, 8)
                // Reserve trailing room so the n/total counter never
                // overlaps the typed needle. Matches mainline Ghostty.
                .padding(.trailing, 52)
                .padding(.vertical, 5)
                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                .overlay(alignment: .trailing) {
                    matchCounter
                        .padding(.trailing, 8)
                }
                .onChange(of: state.needle) { _, new in scheduleSearch(needle: new) }
                .onSubmit {
                    if NSEvent.modifierFlags.contains(.shift) {
                        navigate(forward: false)
                    } else {
                        navigate(forward: true)
                    }
                }
                .onExitCommand { onClose() }

            Button { navigate(forward: false) } label: {
                Image(systemName: "chevron.up")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .help("Previous match (⇧⏎)")
            .accessibilityLabel(Text("Previous match (⇧⏎)"))

            Button { navigate(forward: true) } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .help("Next match (⏎)")
            .accessibilityLabel(Text("Next match (⏎)"))

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .help("Close (Esc)")
            .accessibilityLabel(Text("Close (Esc)"))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            // Adaptive hairline — pure white at 10% disappears against
            // the near-white light-mode material; route through the
            // same adaptive token the sidebar pill stroke uses so the
            // popover keeps a visible rim in both appearances.
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(LimpidColor.rowActiveBorder, lineWidth: 0.5)
        )
        .shadow(color: Color.black.opacity(0.25), radius: 10, x: 0, y: 4)
        .padding(10)
        .onAppear {
            fieldFocused = true
            // Cover the case where libghostty's START_SEARCH hands a
            // pre-populated needle (e.g. selection hand-off). The
            // `.onChange` below only fires on subsequent edits, so the
            // initial state.needle wouldn't otherwise hit
            // `ghostty_surface_binding_action`.
            if !state.needle.isEmpty {
                fireSearch(needle: state.needle)
            }
        }
        .onDisappear {
            debounceTask?.cancel()
        }
        .onReceive(NotificationCenter.default.publisher(for: .limpidSearchFocus)) { note in
            guard (note.object as? UUID) == paneID else { return }
            fieldFocused = true
        }
    }

    // MARK: - Counter

    @ViewBuilder
    private var matchCounter: some View {
        if let selected = state.selected, let total = state.total {
            Text("\(selected + 1)/\(total)")
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        } else if let total = state.total, total > 0 {
            Text("-/\(total)")
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        } else if !state.needle.isEmpty, state.total == 0 {
            Text("0")
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Debounced binding action

    /// Mirror mainline Ghostty's debounce: short queries wait ~300ms,
    /// 3+ char queries fire immediately. Keeps the core thread from
    /// re-running an expensive scan on every keystroke when the
    /// needle is just one letter long.
    private func scheduleSearch(needle: String) {
        debounceTask?.cancel()
        let delayMs = needle.count >= 3 || needle.isEmpty ? 0 : 300
        let captured = needle
        debounceTask = Task { @MainActor in
            if delayMs > 0 {
                try? await Task.sleep(for: .milliseconds(delayMs))
            }
            // Check cancellation on BOTH branches. The immediate-fire
            // path (3+ chars or empty needle) used to skip the guard
            // because there was no suspension point — but Esc /
            // ⏎ both call `debounceTask?.cancel()` and a queued
            // main-actor task enqueued on the same tick would run
            // anyway, re-arming `search:<stale needle>` against a
            // libghostty surface we just told to `end_search`. The
            // overlay disappears while the pane stays full of stale
            // highlights.
            if Task.isCancelled { return }
            fireSearch(needle: captured)
        }
    }

    private func fireSearch(needle: String) {
        guard let surface = surfaceView.surface else { return }
        // Clear the displayed counter before libghostty publishes the
        // first total for the new needle. Without this, the user types
        // "ab" while the previous "a" totals are still on screen ("3/5"
        // briefly stuck during the debounce), and then libghostty
        // emits an interim `total_matches = 0 / selected = null` before
        // the new totals land — which renders as a one-frame "0" that
        // reads as "no matches" even when matches will appear a tick
        // later. Hide the counter (nil) so the field stays clean until
        // libghostty replies with real numbers.
        state.total = nil
        state.selected = nil
        let action = "search:\(needle)"
        _ = ghostty_surface_binding_action(surface, action, UInt(action.utf8.count))
    }

    private func navigate(forward: Bool) {
        guard let surface = surfaceView.surface else { return }
        let action = forward ? "navigate_search:next" : "navigate_search:previous"
        _ = ghostty_surface_binding_action(surface, action, UInt(action.utf8.count))
    }
}
