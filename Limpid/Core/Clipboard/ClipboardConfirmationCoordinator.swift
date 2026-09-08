// ClipboardConfirmationCoordinator.swift
// Limpid — bridges libghostty's `confirm_read_clipboard_cb` to a
// SwiftUI sheet so OSC 52 reads / writes / unsafe pastes always get
// explicit user consent. Without this the embedding app is required
// (per libghostty's contract for the "ask" policy) to surface a
// confirmation UI — auto-confirming would let any escape sequence
// the shell receives read or overwrite the user's clipboard.

import AppKit
import Foundation
import GhosttyKit
import OSLog

private let log = Logger.limpid("clipboard.confirm")

/// Distinguishes the three flavors of clipboard request libghostty
/// can ask us about. The button labels and prompt copy differ
/// between read and write, so the sheet branches on this.
enum ClipboardConfirmationKind {
    case osc52Read
    case osc52Write
    case unsafePaste

    init?(_ raw: ghostty_clipboard_request_e) {
        switch raw {
        case GHOSTTY_CLIPBOARD_REQUEST_OSC_52_READ: self = .osc52Read
        case GHOSTTY_CLIPBOARD_REQUEST_OSC_52_WRITE: self = .osc52Write
        case GHOSTTY_CLIPBOARD_REQUEST_PASTE: self = .unsafePaste
        default: return nil
        }
    }
}

/// One pending clipboard request waiting on the user's verdict. Holds a
/// *weak* reference to the originating view rather than the raw surface
/// pointer: if the pane closes while the sheet is up, `view` (or
/// `view.surface`) goes nil and `allow()` / `deny()` skip the completion
/// instead of calling `ghostty_surface_complete_clipboard_request` on a
/// freed surface. `id` is a fresh UUID per request so SwiftUI's
/// `.sheet(item:)` rebuilds when a back-to-back request replaces the
/// previous one.
@MainActor
struct PendingClipboardRequest: Identifiable {
    let id = UUID()
    let kind: ClipboardConfirmationKind
    let contents: String
    /// Originating surface view; weak so a closed pane can't be revived
    /// through this request. The live `ghostty_surface_t` is read from
    /// `view.surface` at completion time, never cached.
    weak var view: SurfaceView?
    /// Opaque libghostty request state. `nonisolated(unsafe)` because it
    /// crosses the C ABI — passed straight back to the completion call.
    nonisolated(unsafe) let state: UnsafeMutableRawPointer?

}

/// Holds at most one pending request. If a second request arrives
/// while a sheet is still up we deny it immediately — libghostty
/// can't queue confirmation prompts and stacking sheets would let a
/// hostile shell flood the user into clicking Allow.
@MainActor
@Observable
final class ClipboardConfirmationCoordinator {
    /// Process-wide singleton. Set by `AppState.init` before any
    /// libghostty callback can fire. We use a `nonisolated(unsafe)`
    /// reference because the `confirm_read_clipboard_cb` lands on a
    /// background thread and only re-enters the main actor after
    /// reading this pointer.
    nonisolated(unsafe) static var shared: ClipboardConfirmationCoordinator?

    var pending: PendingClipboardRequest?

    /// Reentrancy guard. `allow` / `deny` set this before they nil out
    /// `pending`, so the `.sheet(item:)` binding's "dismiss = deny"
    /// fallback can tell the difference between "user clicked the
    /// button" (already completing, skip) and "user hit Esc / clicked
    /// outside" (no completion yet, run deny). Without this, in some
    /// SwiftUI ordering the binding setter fires after `allow()` has
    /// already cleared `pending` but before `pending = nil` is
    /// observed by the read inside the setter, producing a spurious
    /// second `complete_clipboard_request(... false)`.
    private var isCompleting = false
    private let reviewPasteLedger = ReviewPasteLedger()

    /// The review paste whose clipboard read is in flight.
    ///
    /// A request cannot take it off the surface itself. The callback that
    /// raises the sheet runs inside the read that started the paste but hops
    /// to the main queue before it gets here, and by then the read has
    /// finished and cleared the surface. It is parked here for the length of
    /// that one call instead, and taken in the callback's own frame.
    @MainActor static var inFlightReviewDelivery: ReviewPasteDelivery?

    /// The parked delivery's receipt, if this request is the one it belongs
    /// to. Taken rather than read: one paste has one answer, and taking it
    /// moves the duty to report a refusal along with it.
    @MainActor static func takeInFlightReviewReceipt() -> ReviewPasteReceipt? {
        defer { inFlightReviewDelivery = nil }
        return inFlightReviewDelivery?.handedOn()
    }

    /// Enqueue a request from libghostty. Called on the main actor
    /// after the C callback hops over. Returns silently if another
    /// request is already in flight — see the class doc-comment for
    /// the rationale.
    func enqueue(
        kind: ClipboardConfirmationKind,
        contents: String,
        view: SurfaceView,
        state: UnsafeMutableRawPointer?,
        receipt: ReviewPasteReceipt? = nil
    ) {
        guard reviewPasteLedger.enqueue(receipt: receipt) else {
            log.notice("clipboard request denied: another prompt is already up")
            if let surface = view.surface {
                ghostty_surface_deny_clipboard_request(surface, state)
            }
            return
        }
        pending = PendingClipboardRequest(
            kind: kind,
            contents: contents,
            view: view,
            state: state
        )
    }

    /// Tell review that a paste it started never reached the terminal.
    ///
    /// The paste action answers as soon as the request begins, so review has
    /// already recorded the comments as inserted, and usually closed, by the
    /// time a refusal arrives. This is what takes the mark back off them.
    ///
    /// Reachable from the clipboard callbacks as well as from here. A receipt
    /// is taken out of the surface synchronously, one main-queue hop before it
    /// reaches this class, and a pane that dies inside that hop leaves a
    /// delivery that never happened recorded as one that did.
    @MainActor static func reportReviewPasteDenied(_ receipt: ReviewPasteReceipt?) {
        guard let receipt else { return }
        NotificationCenter.default.post(
            name: .limpidReviewPasteDenied,
            object: receipt
        )
    }

    /// User clicked Allow. The read and unsafe-paste paths complete
    /// libghostty's request (which lets it actually deliver the
    /// pasteboard contents to the shell). The OSC 52 write path skips
    /// the C call — libghostty never allocated a request state for
    /// writes (`state == nil`); instead we set the pasteboard
    /// ourselves now that the user has approved.
    func allow() {
        guard let req = pending, !isCompleting else { return }
        isCompleting = true
        pending = nil
        let surface = req.view?.surface
        reviewPasteLedger.allow(paneIsAlive: surface != nil || (req.kind == .osc52Write && req.state == nil))
        if req.kind == .osc52Write, req.state == nil {
            NSPasteboard.general.declareTypes([.string], owner: nil)
            NSPasteboard.general.setString(req.contents, forType: .string)
        } else if let surface {
            GhosttyFFI.completeClipboardRequest(
                surface: surface,
                text: req.contents,
                state: req.state,
                confirmed: true
            )
        } else {
            log.notice("clipboard allow skipped: the pane closed before the user answered")

        }

        isCompleting = false
    }

    /// User clicked Deny (or the sheet was dismissed). For read /
    /// unsafe-paste, `ghostty_surface_deny_clipboard_request` drops the
    /// request and frees the state libghostty allocated for it. For the
    /// OSC 52 write path (`state == nil`), there is nothing to answer —
    /// just clear `pending` and leave the pasteboard untouched.
    func deny() {
        guard let req = pending, !isCompleting else { return }
        isCompleting = true
        pending = nil
        reviewPasteLedger.deny()
        if req.state != nil, let surface = req.view?.surface {
            ghostty_surface_deny_clipboard_request(surface, req.state)
        }
        isCompleting = false
    }

    /// Pane is closing while a prompt is up for it. Drain libghostty's
    /// per-request allocation through the deny path before dropping
    /// `pending`; otherwise the `ClipboardRequest` state libghostty
    /// allocated for the confirmation route would leak (only
    /// `complete_clipboard_request` / `deny_clipboard_request` free it
    /// — `Surface.deinit` does not walk pending request states). The
    /// `=== view` gate ensures
    /// we only complete prompts that belong to the closing pane.
    func cancelPending(for view: SurfaceView) {
        guard pending?.view === view else { return }
        deny()
    }
}
