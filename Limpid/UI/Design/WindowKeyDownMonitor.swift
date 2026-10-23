// WindowKeyDownMonitor.swift
// Limpid — the key-down monitor a surface sets on its own window, which the window's overlays, sheets, and cards route through.

import AppKit
import SwiftUI

/// Sees each key pressed in the window this view is in before the window
/// sends it on, and drops the ones `handle` takes. A surface that has to
/// answer a key before whatever holds the keyboard (a terminal under an
/// overlay, a field editor that would take Return) routes through it: the
/// window is followed as the view moves, the monitor is set while the view
/// is in the tree and removed with it, and another window's keys are never
/// seen. Each user decides only which keys are its own, as a pure route
/// (`WindowOverlayKeyRoute`, `NewSessionKey`, the approval card's).
struct WindowKeyDownMonitor: NSViewRepresentable {
    /// Whether the surface took `event`, pressed in `window`: `true`
    /// drops it.
    let handle: @MainActor (_ event: NSEvent, _ window: NSWindow) -> Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(handle: handle)
    }

    func makeNSView(context: Context) -> HostView {
        let view = HostView(frame: .zero)
        view.onWindowChange = { [weak coordinator = context.coordinator] window in
            coordinator?.hostWindow = window
        }
        context.coordinator.install()
        return view
    }

    func updateNSView(_ view: HostView, context: Context) {
        context.coordinator.handle = handle
        context.coordinator.hostWindow = view.window
    }

    static func dismantleNSView(_: HostView, coordinator: Coordinator) {
        coordinator.remove()
        coordinator.hostWindow = nil
    }

    @MainActor
    final class HostView: NSView {
        /// Set by the representable as it makes the view; `nil` before.
        var onWindowChange: ((NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindowChange?(window)
        }
    }

    @MainActor
    final class Coordinator {
        var handle: @MainActor (NSEvent, NSWindow) -> Bool
        /// The window the view is in; `nil` until it is in one.
        weak var hostWindow: NSWindow?
        /// The installed event monitor; `nil` before `install` and after
        /// `remove`.
        private var token: Any?

        init(handle: @escaping @MainActor (NSEvent, NSWindow) -> Bool) {
            self.handle = handle
        }

        func install() {
            guard token == nil else { return }
            token = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let hostWindow, event.window === hostWindow else { return event }
                return handle(event, hostWindow) ? nil : event
            }
        }

        func remove() {
            guard let token else { return }
            NSEvent.removeMonitor(token)
            self.token = nil
        }
    }
}

extension NSWindow {
    /// Whether the view holding the keyboard is composing text with an
    /// input method: a key then belongs to the input method, to commit or
    /// cancel its marked text, never to the surface's shortcuts.
    var isComposingText: Bool {
        (firstResponder as? any NSTextInputClient)?.hasMarkedText() == true
    }
}
