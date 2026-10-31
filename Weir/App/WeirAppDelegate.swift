// WeirAppDelegate.swift
// Weir — NSApplicationDelegate adapter wired by `@NSApplicationDelegateAdaptor`
// on `WeirApp`. Intercepts ⌘Q so we can surface a confirmation dialog
// when the user is about to lose live Claude work, opens Weir's own
// main windows at launch and on a Dock click, and opens the folders handed
// to Weir from outside. Everything else still flows through SwiftUI /
// AppState.
//
// `AppState.init` registers `quitGate` with the closure that owns the
// policy + dirty check + alert. The delegate stays trivial — it just
// invokes the gate and translates its Bool into an `NSApplication.TerminateReply`.
// This mirrors how `WeirNotificationDelegate` uses a static
// `registry` slot to bridge AppKit callbacks back into the
// MainActor-isolated AppState graph.

import AppKit

@MainActor
final class WeirAppDelegate: NSObject, NSApplicationDelegate {
    /// Returns `true` when quit should proceed, `false` to cancel.
    /// `AppState.init` assigns this; nil means "no gate registered,
    /// allow quit" so a partially-initialized launch can still
    /// terminate (e.g. AppState boot failed before reaching its
    /// registration line).
    nonisolated(unsafe) static var quitGate: (@MainActor () -> Bool)?

    /// Run once launching finishes: the presenter shows the windows the
    /// session restored (`AppState.presentSupervisionWindows`). `nil` only
    /// before that is connected.
    static var launchHandler: (() -> Void)?

    /// Answers a Dock click: `true` lets AppKit and SwiftUI handle it as
    /// they always have. Set alongside `launchHandler`, it brings back the
    /// window the person was last in (`WindowRegistry.showLastWindow`) and
    /// returns `false`, because SwiftUI's own handling
    /// would open an empty scene window instead.
    static var reopenHandler: (() -> Bool)?

    /// The Dock icon's menu of Weir's own items, past the windows macOS
    /// lists there itself. `nil` adds nothing.
    static var dockMenu: (() -> NSMenu?)?

    /// Opens the folders handed to Weir from outside: Finder's Open With,
    /// `open -a`, a drop on the Dock icon. No scene takes them (Settings
    /// declines every external event), so this is where they arrive. `nil`
    /// only before the presenter is connected.
    static var openHandler: (([URL]) -> Void)?

    /// What arrived before launching finished, opened once the restored
    /// windows are out (`PendingOpens`).
    private var pendingOpens = PendingOpens()

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.launchHandler?()
        open(pendingOpens.finishLaunching())
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        open(pendingOpens.receive(urls))
    }

    private func open(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        Self.openHandler?(urls)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Self.reopenHandler?() ?? true
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        Self.dockMenu?()
    }

    /// Weir keeps running with no window open: the last project window
    /// hides rather than closes, its agents go on, and the Dock brings it
    /// back. Said here because the only scene left with a window is
    /// Settings, and SwiftUI may take an app whose one window scene is a
    /// `Window` as one that quits when that window closes.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(
        _ sender: NSApplication
    ) -> NSApplication.TerminateReply {
        guard let gate = Self.quitGate else { return .terminateNow }
        return gate() ? .terminateNow : .terminateCancel
    }
}
