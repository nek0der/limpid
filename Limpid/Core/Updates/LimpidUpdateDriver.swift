// LimpidUpdateDriver.swift
// Limpid — full `SPUUserDriver` implementation that drives the
// chrome shippingbox + popover state machine. Mirrors the hybrid
// pattern Ghostty uses: every event updates our `UpdateStateModel`
// for the inline UI, AND optionally forwards to a wrapped
// `SPUStandardUserDriver` so users never miss an update found while
// the app has no visible main Limpid window.
//
// Sparkle's lifecycle invokes ~20 protocol methods in a fixed order
// (permission → check → found → release-notes → download → extract
// → ready → install → installed). Each delegate reply / acknowledgement
// / cancellation closure MUST be called exactly once — forgetting one
// stalls Sparkle's internal state machine for the rest of the session,
// calling it twice asserts. We protect both directions with `OneShot`
// at the driver boundary and consume the OneShot whenever we discard
// a state (auto-dismiss timer, state overwrites).

import AppKit
import Sparkle

/// Declared `@MainActor` because Sparkle calls every `SPUUserDriver`
/// method on the main thread. Letting Swift see the isolation makes
/// the embedded reply / cancellation closures usable without
/// `Sendable` gymnastics — they're captured into `UpdateState` which
/// lives on the same actor.
@MainActor
final class LimpidUpdateDriver: NSObject, SPUUserDriver {
    private let stateModel: UpdateStateModel
    private let standard: SPUStandardUserDriver

    init(stateModel: UpdateStateModel, hostBundle: Bundle) {
        self.stateModel = stateModel
        self.standard = SPUStandardUserDriver(hostBundle: hostBundle, delegate: nil)
        super.init()
    }

    /// True when at least one main Limpid window is visible — i.e.
    /// somewhere `ChromeUpdateButton` can actually render. The Settings
    /// window is also titled & visible but doesn't host the L3 chrome,
    /// so it's filtered out via the `isLimpidMainWindow` marker the
    /// main `ContentView` sets on its host `NSWindow` (the SwiftUI
    /// `Window(id:)` scene id does NOT propagate to
    /// `NSWindow.identifier`, so identifier-based filtering doesn't
    /// work).
    private var hasInlineTarget: Bool {
        NSApp.windows.contains { $0.isVisible && $0.isLimpidMainWindow }
    }

    /// Pre-flight any pending OneShot embedded in the current state so
    /// it doesn't get dropped on the floor when we overwrite. Sparkle
    /// treats unfired acknowledgements as a stall; this ensures every
    /// state transition consumes its predecessor's contract.
    private func consumePendingCallback() {
        switch stateModel.state {
        case let .checking(cancel):
            cancel.call()
        case let .available(_, reply),
             let .readyToInstall(_, reply):
            // No user choice was made; behave like Later.
            reply.call(.dismiss)
        case let .downloading(_, _, _, cancel):
            cancel.call()
        case let .notFound(ack),
             let .error(_, ack),
             let .installed(ack):
            ack.call()
        case .idle, .extracting, .installing:
            break
        }
    }

    // MARK: - Permission

    func show(
        _: SPUUpdatePermissionRequest,
        reply: @escaping (SUUpdatePermissionResponse) -> Void
    ) {
        // We don't surface the permission prompt in our own UI — the
        // "Automatically check for updates" toggle in Settings is the
        // authoritative control. Reply with the user's current
        // preference; Sparkle will respect it.
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
    }

    // MARK: - Checking

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        consumePendingCallback()
        let cancelOnce = OneShot(cancellation)
        stateModel.state = .checking(cancel: cancelOnce)
        if !hasInlineTarget {
            standard.showUserInitiatedUpdateCheck(cancellation: { cancelOnce.call() })
        }
    }

    func showUpdateNotFoundWithError(
        _ error: any Error,
        acknowledgement: @escaping () -> Void
    ) {
        consumePendingCallback()
        let ackOnce = OneShot(acknowledgement)
        if hasInlineTarget {
            stateModel.state = .notFound(acknowledgement: ackOnce)
            // Auto-dismiss after a moment so the chrome doesn't keep
            // a "no update" badge around forever. The OneShot ensures
            // the auto-dismiss and a manual OK click never both fire
            // ack, and that ack ALWAYS fires before we leave the
            // state — Sparkle stalls otherwise.
            let stateRef = stateModel
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                if case .notFound = stateRef.state {
                    ackOnce.call()
                    stateRef.state = .idle
                }
            }
        } else {
            standard.showUpdateNotFoundWithError(error, acknowledgement: { ackOnce.call() })
        }
    }

    func showUpdaterError(
        _ error: any Error,
        acknowledgement: @escaping () -> Void
    ) {
        consumePendingCallback()
        let ackOnce = OneShot(acknowledgement)
        if hasInlineTarget {
            stateModel.state = .error(error: error, acknowledgement: ackOnce)
        } else {
            standard.showUpdaterError(error, acknowledgement: { ackOnce.call() })
        }
    }

    // MARK: - Update found

    func showUpdateFound(
        with appcastItem: SUAppcastItem,
        state: SPUUserUpdateState,
        reply: @escaping (SPUUserUpdateChoice) -> Void
    ) {
        consumePendingCallback()
        let replyOnce = OneShot(reply)
        if hasInlineTarget {
            stateModel.state = .available(item: appcastItem, reply: replyOnce)
        } else {
            // Don't also write state when we're handing off entirely
            // to the standard alert ── otherwise a window that opens
            // mid-flow could let the user click Install in our popover
            // and in Sparkle's alert, racing the OneShot. With state
            // unset, the chrome stays empty and only the standard
            // alert can answer.
            standard.showUpdateFound(
                with: appcastItem,
                state: state,
                reply: { choice in replyOnce.call(choice) }
            )
        }
    }

    func showUpdateReleaseNotes(with _: SPUDownloadData) {
        // Release notes are surfaced via the appcast `releaseNotesURL`
        // link inside the popover, not via Sparkle's bundled
        // WebKit-based renderer. No-op.
    }

    func showUpdateReleaseNotesFailedToDownloadWithError(_: any Error) {
        // Same reason ── we don't render release notes inline.
    }

    // MARK: - Download progress

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        consumePendingCallback()
        let cancelOnce = OneShot(cancellation)
        // Carry forward the appcast item if we have one in state;
        // otherwise show a placeholder.
        let item = stateModel.pendingItem ?? Self.placeholderItem
        stateModel.state = .downloading(
            item: item,
            expectedBytes: nil,
            receivedBytes: 0,
            cancel: cancelOnce
        )
        if !hasInlineTarget {
            standard.showDownloadInitiated(cancellation: { cancelOnce.call() })
        }
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        guard case let .downloading(item, _, received, cancel) = stateModel.state else { return }
        stateModel.state = .downloading(
            item: item,
            expectedBytes: expectedContentLength,
            receivedBytes: received,
            cancel: cancel
        )
        if !hasInlineTarget {
            standard.showDownloadDidReceiveExpectedContentLength(expectedContentLength)
        }
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        guard case let .downloading(item, expected, received, cancel) = stateModel.state else { return }
        stateModel.state = .downloading(
            item: item,
            expectedBytes: expected,
            receivedBytes: received + length,
            cancel: cancel
        )
        if !hasInlineTarget {
            standard.showDownloadDidReceiveData(ofLength: length)
        }
    }

    // MARK: - Extraction

    func showDownloadDidStartExtractingUpdate() {
        // Extracting doesn't carry a cancellation, so we don't need
        // `consumePendingCallback` ── the previous `.downloading`
        // cancel is naturally fulfilled (download succeeded), not
        // dropped.
        stateModel.state = .extracting(progress: 0)
        if !hasInlineTarget {
            standard.showDownloadDidStartExtractingUpdate()
        }
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        stateModel.state = .extracting(progress: progress)
        if !hasInlineTarget {
            standard.showExtractionReceivedProgress(progress)
        }
    }

    // MARK: - Install + relaunch

    func showReady(
        toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void
    ) {
        consumePendingCallback()
        let replyOnce = OneShot(reply)
        if hasInlineTarget {
            let item = stateModel.pendingItem ?? Self.placeholderItem
            stateModel.state = .readyToInstall(item: item, reply: replyOnce)
        } else {
            standard.showReady(
                toInstallAndRelaunch: { choice in replyOnce.call(choice) }
            )
        }
    }

    func showInstallingUpdate(
        withApplicationTerminated _: Bool,
        retryTerminatingApplication _: @escaping () -> Void
    ) {
        stateModel.state = .installing
        // Standard driver path intentionally skipped here — once
        // installation actually begins, the standard driver would
        // show its own modal progress window over ours. Our inline
        // UI is enough.
    }

    func showUpdateInstalledAndRelaunched(
        _: Bool,
        acknowledgement: @escaping () -> Void
    ) {
        consumePendingCallback()
        let ackOnce = OneShot(acknowledgement)
        stateModel.state = .installed(acknowledgement: ackOnce)
        // Acknowledge immediately so Sparkle frees its resources; the
        // OneShot keeps any view-side `acknowledgement.call()` safe.
        ackOnce.call()
        // Auto-dismiss the inline state regardless of whether the
        // popover is ever opened. Without this the green ✓ badge
        // persists indefinitely after a real-Sparkle relaunch (the
        // popover view's own onAppear timer only fires while the
        // popover is open, which it isn't in a freshly-relaunched
        // process). 5 s is a touch longer than `.notFound`'s 3 s so
        // the success message has time to land.
        let stateRef = stateModel
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            if case .installed = stateRef.state {
                stateRef.state = .idle
            }
        }
    }

    // MARK: - Misc lifecycle

    func showUpdateInFocus() {
        // Triggered when the user clicks the Sparkle alert that's
        // already visible. We don't show a Sparkle alert in the
        // inline path, so no-op.
    }

    func dismissUpdateInstallation() {
        consumePendingCallback()
        stateModel.state = .idle
    }

    // MARK: - Helpers

    /// Sparkle can hand us callback events even when no appcast item
    /// is associated (rare ── e.g. resumed download with stale state).
    /// Using a placeholder avoids forcing `pendingItem` to be optional
    /// across the UI.
    private static let placeholderItem: SUAppcastItem = {
        let dict: [String: Any] = [
            "sparkle:version": "0.0.0",
            "enclosure": [
                "url": "https://invalid.placeholder/limpid.dmg",
                "length": "0"
            ]
        ]
        // Force-unwrap is acceptable: the dictionary is static and
        // exercised by the unit-test smoke run before shipping.
        return SUAppcastItem(dictionary: dict)!
    }()
}
