// SparkleUpdater.swift
// Limpid — Sparkle integration. Holds the `SPUUpdater`, the full
// `SPUUserDriver` (see `LimpidUpdateDriver`), and the shared
// `UpdateStateModel` that the chrome / popover subscribe to.
//
// We bypass `SPUStandardUpdaterController` entirely and construct
// `SPUUpdater(hostBundle:applicationBundle:userDriver:delegate:)`
// ourselves so we can supply a custom `SPUUserDriver`. The standard
// controller wires up its own driver internally and there's no way
// to swap it after construction.

import Sparkle
import SwiftUI

// MARK: - Convenience helpers

extension SUAppcastItem {
    /// Display version with a leading `v` so the UI consistently reads
    /// `v0.1.99` rather than the bare `0.1.99`. Sparkle's
    /// `displayVersionString` returns the raw `sparkle:shortVersionString`
    /// from the appcast (no prefix), which is too easily confused with
    /// other numeric strings in the popover (file size, %, dates).
    var displayVersion: String {
        "v\(displayVersionString)"
    }
}

// MARK: - Main window marker

/// Tags a Limpid main `NSWindow` so the updater can distinguish it
/// from the Settings window (both are titled and visible but only
/// the main window hosts `ChromeL3Segment` where the update affordance
/// lives). The SwiftUI `Window(id:)` scene id does NOT propagate to
/// `NSWindow.identifier`, so identifier-string filtering doesn't work.
///
/// Apply with `.background(LimpidMainWindowMarker())` inside the
/// `WindowGroup` content. The driver consults `NSWindow.isLimpidMainWindow`
/// in `hasInlineTarget`.
struct LimpidMainWindowMarker: NSViewRepresentable {
    func makeNSView(context _: Context) -> NSView {
        let view = NSView()
        // The view isn't attached to a window yet at make-time, so
        // defer the marker write until SwiftUI hooks it up.
        DispatchQueue.main.async {
            if let window = view.window {
                objc_setAssociatedObject(
                    window,
                    LimpidMainWindowMarker.associatedKey,
                    NSNumber(value: true),
                    .OBJC_ASSOCIATION_RETAIN_NONATOMIC
                )
            }
        }
        return view
    }

    func updateNSView(_: NSView, context _: Context) {}

    /// `objc_setAssociatedObject` needs a stable raw key. Using a
    /// static let on the struct keeps the address fixed for the
    /// process lifetime.
    nonisolated(unsafe) static let associatedKey: UnsafeRawPointer = {
        let p = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
        p.initialize(to: 0)
        return UnsafeRawPointer(p)
    }()
}

extension NSWindow {
    /// `true` when the window has been tagged by `LimpidMainWindowMarker`
    /// (i.e. it hosts a Limpid main `ContentView`, not the Settings
    /// scene or a Sparkle alert window).
    var isLimpidMainWindow: Bool {
        (objc_getAssociatedObject(self, LimpidMainWindowMarker.associatedKey) as? NSNumber)?.boolValue == true
    }
}

// MARK: - One-shot callback wrapper

/// Wraps a Sparkle reply / acknowledgement / cancellation closure so
/// it can be invoked from multiple call sites (chrome popover, inline
/// Settings popover, auto-dismiss timer, fallback to standard driver)
/// without violating Sparkle's "call exactly once" contract. First call
/// wins; subsequent calls are silently dropped.
///
/// Forgetting to call a Sparkle callback at all is a different bug
/// (stalls the state machine for the rest of the session). The OneShot
/// only fixes the *double-call* hazard ── code that takes ownership of
/// a OneShot still has to call it before transitioning state, or the
/// driver loses the chance to advance Sparkle's pipeline.
@MainActor
final class OneShot<Argument> {
    private var callback: ((Argument) -> Void)?

    init(_ callback: @escaping (Argument) -> Void) {
        self.callback = callback
    }

    /// Fire the callback if it hasn't fired yet. Subsequent calls
    /// no-op (no warning ── the design is to make double-call safe).
    func call(_ value: Argument) {
        guard let cb = callback else { return }
        callback = nil
        cb(value)
    }

    /// True after `call(_:)` has been invoked. Useful for assertions
    /// at transition boundaries (driver wants to ensure ack fired
    /// before overwriting state).
    var hasFired: Bool {
        callback == nil
    }
}

extension OneShot where Argument == Void {
    /// Parameterless convenience for callbacks like `acknowledgement`
    /// and `cancellation` that don't carry a value.
    func call() {
        call(())
    }
}

// MARK: - Update state

/// All states the updater lifecycle can be in. Closures embedded in
/// each case carry Sparkle's reply / cancellation / acknowledgement
/// callbacks wrapped in `OneShot` ── the popover and chrome read them
/// through this enum and may legitimately call from multiple surfaces.
///
/// Not Equatable / Sendable on purpose: the OneShots aren't, and we
/// only mutate this on `@MainActor` anyway.
@MainActor
enum UpdateState {
    case idle
    case checking(cancel: OneShot<Void>)
    case available(item: SUAppcastItem, reply: OneShot<SPUUserUpdateChoice>)
    case downloading(item: SUAppcastItem, expectedBytes: UInt64?, receivedBytes: UInt64, cancel: OneShot<Void>)
    case extracting(progress: Double)
    case readyToInstall(item: SUAppcastItem, reply: OneShot<SPUUserUpdateChoice>)
    case installing
    case installed(acknowledgement: OneShot<Void>)
    case notFound(acknowledgement: OneShot<Void>)
    case error(error: any Error, acknowledgement: OneShot<Void>)
}

/// Shared observable wrapping `UpdateState`. The driver writes; the
/// chrome / popover read. Splitting the enum out so SwiftUI can read
/// the *current* state without invoking any of the embedded closures
/// during diff.
@MainActor
@Observable
final class UpdateStateModel {
    var state: UpdateState = .idle

    /// Convenience: appcast item attached to the current state, if any.
    /// Used by the chrome help-text tooltip without case-matching.
    var pendingItem: SUAppcastItem? {
        switch state {
        case let .available(item, _),
             let .downloading(item, _, _, _),
             let .readyToInstall(item, _):
            item
        case .idle, .checking, .extracting, .installing, .installed, .notFound, .error:
            nil
        }
    }

    /// True when the chrome should render the shippingbox / progress
    /// affordance. `.idle` and `.notFound` (after auto-dismiss) hide it.
    var showsBadge: Bool {
        switch state {
        case .idle: false
        default: true
        }
    }

    /// True while an update operation is actively in flight (network
    /// fetch, download, extract, install). The Settings "Check Now…"
    /// and App-menu "Check for Updates…" buttons disable on this so
    /// the user can't kick off a second concurrent pipeline. Terminal
    /// states (.available / .readyToInstall awaiting user choice,
    /// .notFound / .installed / .error) leave the buttons clickable
    /// so the user can re-check at will.
    var isBusy: Bool {
        switch state {
        case .checking, .downloading, .extracting, .installing:
            true
        case .idle, .available, .readyToInstall, .installed, .notFound, .error:
            false
        }
    }
}

// MARK: - View model that surfaces canCheckForUpdates for the menu

/// View model that surfaces Sparkle's `canCheckForUpdates` flag as a
/// `@Published` property so SwiftUI views can disable the menu item
/// while the updater is busy.
@MainActor
final class CheckForUpdatesViewModel: ObservableObject {
    @Published var canCheckForUpdates = false

    init(updater: SPUUpdater) {
        updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }
}

/// SwiftUI menu item suitable for placement in
/// `CommandGroup(after: .appInfo)`. Both Debug (mock pipeline) and
/// Release (real `checkForUpdates()`) flow through here; the button
/// disables itself whenever `UpdateStateModel.isBusy` is true so
/// concurrent pipelines can't be launched from the menu.
///
/// We don't gate on Sparkle's `canCheckForUpdates` because that flag
/// has been observed to stick at `false` after a failed appcast fetch
/// (404, no network at launch, etc.), leaving the menu item
/// permanently un-clickable.
struct CheckForUpdatesMenuItem: View {
    let updaterStack: UpdaterStack

    var body: some View {
        Button("Check for Updates…") {
            #if DEBUG
                MockUpdateAvailability.simulate(into: updaterStack.stateModel)
            #else
                updaterStack.updater.checkForUpdates()
            #endif
        }
        // The state model isn't injected into the CommandGroup
        // environment, so we observe it directly via Bindable rather
        // than `@Environment`. The closure-style read keeps SwiftUI's
        // dependency tracking honest.
        .disabled(updaterStack.stateModel.isBusy)
    }
}

// MARK: - Updater stack (owns SPUUpdater + driver + state)

/// Bundles the `SPUUpdater`, its `LimpidUpdateDriver`, and the shared
/// `UpdateStateModel` into one object with matched lifetime. `LimpidApp`
/// holds one of these as a stored `let`.
@MainActor
final class UpdaterStack {
    let updater: SPUUpdater
    let driver: LimpidUpdateDriver
    let stateModel: UpdateStateModel

    init(allowsAutomaticChecks: Bool) {
        let stateModel = UpdateStateModel()
        let driver = LimpidUpdateDriver(stateModel: stateModel, hostBundle: .main)
        self.stateModel = stateModel
        self.driver = driver
        self.updater = SPUUpdater(
            hostBundle: .main,
            applicationBundle: .main,
            userDriver: driver,
            delegate: nil
        )
        // Always `start()` — without it, `checkForUpdates()` (both the
        // menu item and Settings → Check Now) silently no-ops. We
        // still want manual checks to work in Debug, so the gating
        // happens on the auto-check schedule via
        // `automaticallyChecksForUpdates` rather than on `start()`
        // itself.
        do {
            try updater.start()
        } catch {
            NSLog("[Limpid] SPUUpdater.start failed: \(error)")
        }
        // In Debug, keep scheduled auto-checks off so a `make dev`
        // session running alongside the installed Release dmg can't
        // replace its own DerivedData binary mid-debug.
        if !allowsAutomaticChecks {
            updater.automaticallyChecksForUpdates = false
        }
    }
}

#if DEBUG
    /// Inject a fake state so the chrome bubble can be visually
    /// iterated without a real appcast / server round-trip. Hooked
    /// into the App menu (Debug builds only).
    @MainActor
    enum MockUpdateAvailability {
        /// Drives the full mock lifecycle in one entry point. Sets
        /// `.available`; when the user presses Install in the popover
        /// the embedded reply closure advances us through download →
        /// extract → readyToInstall → installing → installed → idle,
        /// each step visually inspectable in chrome + popover. Skip /
        /// Later route to `.idle` immediately.
        static func simulate(into model: UpdateStateModel) {
            guard let item = makeFakeItem() else { return }
            let reply = OneShot<SPUUserUpdateChoice> { [weak model] choice in
                guard let model else { return }
                switch choice {
                case .install:
                    runFakeInstallPipeline(item: item, into: model)
                case .skip, .dismiss:
                    model.state = .idle
                @unknown default:
                    model.state = .idle
                }
            }
            model.state = .available(item: item, reply: reply)
        }

        /// Runs the download → extract → ready chain with realistic-
        /// feeling delays. Pressing Install in `.readyToInstall` then
        /// hands off to `runFakeInstallStage` to complete the loop.
        private static func runFakeInstallPipeline(
            item: SUAppcastItem,
            into model: UpdateStateModel
        ) {
            let cancel = OneShot<Void> { [weak model] in model?.state = .idle }
            let total: UInt64 = 60_817_408
            model.state = .downloading(item: item, expectedBytes: total, receivedBytes: 0, cancel: cancel)
            Task { @MainActor [weak model] in
                guard let model else { return }
                await runFakeDownload(item: item, total: total, cancel: cancel, in: model)
                guard case .downloading = model.state else { return }
                await runFakeExtract(in: model)
                guard case .extracting = model.state else { return }
                try? await Task.sleep(for: .milliseconds(180))
                model.state = .readyToInstall(
                    item: item,
                    reply: makeReadyReply(item: item, model: model)
                )
            }
        }

        private static func runFakeDownload(
            item: SUAppcastItem,
            total: UInt64,
            cancel: OneShot<Void>,
            in model: UpdateStateModel
        ) async {
            for step in 1 ... 10 {
                try? await Task.sleep(for: .milliseconds(220))
                guard case .downloading = model.state else { return }
                let received = UInt64(Double(total) * Double(step) / 10.0)
                model.state = .downloading(
                    item: item,
                    expectedBytes: total,
                    receivedBytes: received,
                    cancel: cancel
                )
            }
        }

        private static func runFakeExtract(in model: UpdateStateModel) async {
            try? await Task.sleep(for: .milliseconds(180))
            model.state = .extracting(progress: 0)
            for step in 1 ... 6 {
                try? await Task.sleep(for: .milliseconds(180))
                guard case .extracting = model.state else { return }
                model.state = .extracting(progress: Double(step) / 6.0)
            }
        }

        /// Reply handler for the mock `.readyToInstall` state. Install
        /// kicks off the installing → installed → idle tail; Skip /
        /// Later short-circuit back to idle.
        private static func makeReadyReply(
            item _: SUAppcastItem,
            model: UpdateStateModel
        ) -> OneShot<SPUUserUpdateChoice> {
            OneShot<SPUUserUpdateChoice> { [weak model] choice in
                guard let model else { return }
                if case .install = choice {
                    Task { @MainActor [weak model] in
                        guard let model else { return }
                        await runFakeInstallStage(in: model)
                    }
                } else {
                    model.state = .idle
                }
            }
        }

        private static func runFakeInstallStage(in model: UpdateStateModel) async {
            model.state = .installing
            try? await Task.sleep(for: .milliseconds(800))
            let ack = OneShot<Void> { [weak model] in model?.state = .idle }
            model.state = .installed(acknowledgement: ack)
            // Mirror the production driver's auto-dismiss so the
            // green ✓ doesn't persist forever in Debug iterations.
            try? await Task.sleep(for: .seconds(5))
            if case .installed = model.state {
                model.state = .idle
            }
        }

        private static func makeFakeItem() -> SUAppcastItem? {
            // Keys mirror Sparkle's appcast XML element / attribute
            // names exactly — `sparkle:version` not `version`, `url`
            // and `length` live inside `enclosure`. Element values
            // with attributes are dicts with a `"content"` key.
            let dict: [String: Any] = [
                "sparkle:version": "0.1.99",
                "sparkle:shortVersionString": "0.1.99",
                "enclosure": [
                    "url": "https://example.invalid/limpid-mock.dmg",
                    "length": "60817408",
                    "type": "application/octet-stream"
                ],
                "pubDate": "Wed, 27 May 2026 09:00:00 +0000",
                "sparkle:releaseNotesLink": [
                    "content": "https://nek0der.github.io/limpid/Limpid-0.1.5.md"
                ]
            ]
            return SUAppcastItem(dictionary: dict)
        }
    }
#endif
