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
    let isInteractive: Bool
    let inactiveOpacity: Double
    let onClose: () -> Void

    @State private var fieldFocused = false
    @State private var focusTask: Task<Void, Never>?
    @State private var debounceTask: Task<Void, Never>?
    @State private var lastDispatchedNeedle: String?

    var body: some View {
        ViewThatFits {
            searchBar(fieldWidth: 180, showsCounter: true, showsNavigation: true)
                .padding(10)
                .fixedSize(horizontal: true, vertical: false)
            searchBar(fieldWidth: 120, showsCounter: true, showsNavigation: false)
                .padding(10)
                .fixedSize(horizontal: true, vertical: false)
            searchBar(fieldWidth: nil, showsCounter: false, showsNavigation: false)
                .padding(10)
                .frame(maxWidth: .infinity)
            ultraCompactSearchField
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .allowsHitTesting(isInteractive)
        .accessibilityHidden(!isInteractive)
        .onAppear {
            guard isInteractive else { return }
            // `ViewThatFits` chooses and mounts its winning TextField after
            // this outer view appears. Defer one actor turn so the focus
            // binding is attached to the visible candidate.
            focusTask?.cancel()
            focusTask = Task { @MainActor in
                await Task.yield()
                guard !Task.isCancelled, isInteractive else { return }
                fieldFocused = true
            }
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
            focusTask?.cancel()
            debounceTask?.cancel()
        }
        .onChange(of: isInteractive) { _, newValue in
            if newValue {
                if state.needle != lastDispatchedNeedle,
                   !state.needle.isEmpty || lastDispatchedNeedle != nil
                {
                    scheduleSearch(needle: state.needle)
                }
                return
            }
            focusTask?.cancel()
            fieldFocused = false
            debounceTask?.cancel()
        }
        .onReceive(NotificationCenter.default.publisher(for: .limpidSearchFocus)) { note in
            guard isInteractive, (note.object as? UUID) == paneID else { return }
            fieldFocused = true
        }
    }

    private func searchBar(
        fieldWidth: CGFloat?,
        showsCounter: Bool,
        showsNavigation: Bool
    ) -> some View {
        searchSurface(
            HStack(spacing: 6) {
                searchField(width: fieldWidth, showsCounter: showsCounter)
                    .layoutPriority(1)
                if showsNavigation {
                    navigationButton(forward: false)
                    navigationButton(forward: true)
                }
                closeButton
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        )
    }

    private var ultraCompactSearchField: some View {
        searchSurface(
            searchField(width: nil, showsCounter: false)
                .padding(4)
                .frame(maxWidth: .infinity)
        )
    }

    private func searchSurface(_ content: some View) -> some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)

        return content
            .limpidGlassBackground(.palette)
            .overlay(
                shape.strokeBorder(Color.primary.opacity(0.20), lineWidth: 0.5)
            )
            // Fade the complete control so an inactive search does not compete
            // with the focused pane. A full-strength material backing remains
            // underneath to blur terminal text instead of exposing it through
            // the faded glass surface.
            .opacity(displayOpacity)
            .background {
                if !isInteractive {
                    shape.fill(.regularMaterial)
                } else {
                    shape.fill(.clear)
                }
            }
    }

    private var displayOpacity: Double {
        isInteractive ? 1.0 : inactiveOpacity
    }

    private func searchField(width: CGFloat?, showsCounter: Bool) -> some View {
        PaneSearchTextField(
            text: $state.needle,
            isFocused: $fieldFocused,
            onChange: { scheduleSearch(needle: $0) },
            onSubmit: { isBackward in
                guard isInteractive else { return }
                navigate(forward: !isBackward)
            },
            onExit: {
                guard isInteractive else { return }
                onClose()
            }
        )
        .frame(width: width)
        .padding(.leading, 8)
        // Reserve trailing room only while the counter is visible. The
        // narrowest variant gives that space back to text entry.
        .padding(.trailing, showsCounter ? 52 : 8)
        .padding(.vertical, 5)
        .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
        .overlay(alignment: .trailing) {
            if showsCounter {
                matchCounter
                    .padding(.trailing, 8)
            }
        }
        .pointerStyle(.horizontalText)
    }

    private func navigationButton(forward: Bool) -> some View {
        Button { navigate(forward: forward) } label: {
            Image(systemName: forward ? "chevron.down" : "chevron.up")
                .font(.system(size: 11, weight: .semibold))
        }
        .buttonStyle(.borderless)
        .help(
            forward
                ? String(localized: "Next match (⏎)")
                : String(localized: "Previous match (⇧⏎)")
        )
        .accessibilityLabel(
            forward
                ? Text("Next match (⏎)")
                : Text("Previous match (⇧⏎)")
        )
        .pointerStyle(.default)
    }

    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .semibold))
        }
        .buttonStyle(.borderless)
        .help("Close (Esc)")
        .accessibilityLabel(Text("Close (Esc)"))
        .pointerStyle(.default)
    }

    // MARK: - Counter

    @ViewBuilder
    private var matchCounter: some View {
        if let selected = state.selected,
           let total = state.total,
           let position = PaneSearchDirection.displayPosition(selected: selected, total: total)
        {
            Text("\(position)/\(total)")
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
        guard isInteractive else { return }
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
            if Task.isCancelled || !isInteractive {
                return
            }
            fireSearch(needle: captured)
        }
    }

    private func fireSearch(needle: String) {
        guard isInteractive, let surface = surfaceView.surface else { return }
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
        lastDispatchedNeedle = needle
    }

    private func navigate(forward: Bool) {
        guard isInteractive, let surface = surfaceView.surface else { return }
        let direction: PaneSearchDirection = forward ? .forward : .backward
        let action = direction.bindingAction
        _ = ghostty_surface_binding_action(surface, action, UInt(action.utf8.count))
    }
}

private struct PaneSearchTextField: NSViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    let onChange: (String) -> Void
    let onSubmit: (Bool) -> Void
    let onExit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> PaneSearchNSTextField {
        let field = PaneSearchNSTextField()
        field.delegate = context.coordinator
        field.stringValue = text
        field.placeholderString = String(localized: "Search")
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 12)
        field.lineBreakMode = .byClipping
        field.cell?.usesSingleLineMode = true
        field.setAccessibilityLabel(String(localized: "Search"))
        return field
    }

    func updateNSView(_ field: PaneSearchNSTextField, context: Context) {
        context.coordinator.parent = self
        let editor = field.currentEditor() as? NSTextView
        if editor?.hasMarkedText() != true, field.stringValue != text {
            field.stringValue = text
        }

        if isFocused {
            let coordinator = context.coordinator
            DispatchQueue.main.async { [weak field] in
                guard let field,
                      coordinator.parent.isFocused,
                      field.window?.firstResponder !== field.currentEditor()
                else { return }
                field.window?.makeFirstResponder(field)
            }
        } else if field.window?.firstResponder === field.currentEditor() {
            field.window?.makeFirstResponder(nil)
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: PaneSearchTextField

        init(parent: PaneSearchTextField) {
            self.parent = parent
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            parent.isFocused = true
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            parent.isFocused = false
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
            parent.onChange(field.stringValue)
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            guard !textView.hasMarkedText() else { return false }
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                let isBackward = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
                parent.onSubmit(isBackward)
                return true
            }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                parent.onExit()
                return true
            }
            return false
        }
    }
}

private final class PaneSearchNSTextField: NSTextField {
    /// Recreated by AppKit whenever the field's visible bounds change.
    private var cursorTrackingArea: NSTrackingArea?

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .iBeam)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let cursorTrackingArea {
            removeTrackingArea(cursorTrackingArea)
        }
        let cursorTrackingArea = NSTrackingArea(
            rect: .zero,
            options: [.cursorUpdate, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(cursorTrackingArea)
        self.cursorTrackingArea = cursorTrackingArea
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.iBeam.set()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        invalidateCursorRects()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        invalidateCursorRects()
    }

    private func invalidateCursorRects() {
        if let window {
            window.invalidateCursorRects(for: self)
        }
    }
}
