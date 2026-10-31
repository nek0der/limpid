// ClipboardConfirmationCoordinator.swift
// Weir — bridges libghostty's `confirm_read_clipboard_cb` to a
// SwiftUI sheet so OSC 52 reads / writes / unsafe pastes always get
// explicit user consent. Without this the embedding app is required
// (per libghostty's contract for the "ask" policy) to surface a
// confirmation UI — auto-confirming would let any escape sequence
// the shell receives read or overwrite the user's clipboard.

import AppKit
import Foundation
import GhosttyKit
import OSLog
import Synchronization

private let log = Logger.weir("clipboard.confirm")

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

/// libghostty's state for one clipboard request it handed us. It stays
/// allocated until we complete or deny it on the surface it came from,
/// and the C side frees it then, so exactly one answer may reach the C
/// API with this pointer. `@unchecked Sendable` because the pointer is
/// opaque to us: we only compare it and hand it back to libghostty on the
/// main actor, and `ClipboardRequestTracker` is what keeps that answer to
/// one.
struct ClipboardRequestState: Hashable, @unchecked Sendable {
    let pointer: UnsafeMutableRawPointer
}

/// Where a request came from, and so what refusing it takes.
///
/// A write under `clipboard-write = ask` reaches us through the write
/// callback, which allocates nothing: we refuse it by not writing the
/// text. Everything else comes through the read or confirm callbacks
/// with a state libghostty keeps until we answer it. They are separate
/// cases so a stateless write can never reach the C deny, which
/// dereferences the state it is given.
enum ClipboardRequestSource {
    case osc52Write
    case libghostty(ClipboardConfirmationKind, ClipboardRequestState)

    var kind: ClipboardConfirmationKind {
        switch self {
        case .osc52Write: .osc52Write
        case let .libghostty(kind, _): kind
        }
    }
}

/// The unanswered libghostty requests of one surface.
///
/// A request is tracked from the callback frame that receives it, before
/// any hop to the main actor, until something claims it to answer it.
/// Teardown denies whatever is still tracked before the surface is freed.
/// Without that, a pane that closes between a callback and the main-actor
/// work it scheduled leaves libghostty's state allocated for good, since
/// `ghostty_surface_free` does not walk outstanding requests. We keep
/// states here, never surface pointers, so nothing can answer on a freed
/// surface: the surface is read from a live pane, or by the teardown that
/// is about to free it.
///
/// A lock rather than the main actor, because the tracking has to happen
/// in the callback's own frame and we do not rely on which thread
/// libghostty calls it from.
final class ClipboardRequestTracker: Sendable {
    private struct Book {
        /// Set by teardown, so a request that arrives after it is refused
        /// in its own frame instead of being kept for a surface that is
        /// about to go.
        var isClosed = false
        var unanswered: Set<ClipboardRequestState> = []
    }

    private let book = Mutex(Book())

    init() {}

    /// Keep `state` until it is claimed. False once teardown has run; the
    /// caller then must not keep the request.
    func track(_ state: ClipboardRequestState) -> Bool {
        book.withLock { book in
            guard !book.isClosed else { return false }
            book.unanswered.insert(state)
            return true
        }
    }

    /// Take `state` to answer it. One claim succeeds, so a request is
    /// answered by whoever claims it and by nobody else, teardown included.
    func claim(_ state: ClipboardRequestState) -> Bool {
        book.withLock { $0.unanswered.remove(state) != nil }
    }

    /// Whether `state` is still waiting for its answer.
    func isTracking(_ state: ClipboardRequestState) -> Bool {
        book.withLock { $0.unanswered.contains(state) }
    }

    /// Close the book and deny every request still in it. Called once, by
    /// the surface's teardown, before the surface is freed.
    func denyUnanswered(_ deny: (ClipboardRequestState) -> Void) {
        let unanswered = book.withLock { book in
            book.isClosed = true
            defer { book.unanswered.removeAll() }
            return book.unanswered
        }
        for state in unanswered {
            deny(state)
        }
    }
}

/// The pane a clipboard request is answered on: `SurfaceView` in the
/// app, a stand-in in tests.
@MainActor
protocol ClipboardRequestTarget: AnyObject {
    /// The live libghostty surface; nil when the pane has none.
    var surface: ghostty_surface_t? { get }
    var clipboardRequests: ClipboardRequestTracker { get }
    /// The pane as a view, for the UI that decides where the sheet goes.
    var surfaceView: SurfaceView? { get }
}

/// The calls that answer a request. Injected so a test can see what would
/// reach libghostty and the pasteboard without touching either.
@MainActor
struct ClipboardRequestAnswerer {
    var deny: @MainActor (ghostty_surface_t, ClipboardRequestState) -> Void
    var complete: @MainActor (ghostty_surface_t, String, ClipboardRequestState) -> Void
    var writePasteboard: @MainActor (String) -> Void

    static let libghostty = ClipboardRequestAnswerer(
        deny: { surface, state in
            ghostty_surface_deny_clipboard_request(surface, state.pointer)
        },
        complete: { surface, text, state in
            GhosttyFFI.completeClipboardRequest(
                surface: surface,
                text: text,
                state: state.pointer,
                confirmed: true
            )
        },
        writePasteboard: { text in
            NSPasteboard.general.declareTypes([.string], owner: nil)
            NSPasteboard.general.setString(text, forType: .string)
        }
    )

    /// Refuse a request. Every refusal goes through here, so the rule that
    /// keeps the C deny safe lives in one place: a write is refused by
    /// dropping its text, and only a tracked state on a live surface reaches
    /// the C API. A pane without a surface keeps its request tracked, for
    /// its teardown to deny before the surface is freed.
    func refuse(_ source: ClipboardRequestSource, on target: (any ClipboardRequestTarget)?) {
        guard case let .libghostty(_, state) = source else { return }
        refuse(state, on: target)
    }

    /// Refuse a libghostty request by its state, including one we have no
    /// prompt for. The one place outside teardown that calls the C deny.
    func refuse(_ state: ClipboardRequestState, on target: (any ClipboardRequestTarget)?) {
        guard let target, let surface = target.surface else {
            log.notice("clipboard deny skipped: the pane is gone, and its teardown answers the request")
            return
        }
        guard target.clipboardRequests.claim(state) else { return }
        deny(surface, state)
    }

    /// Carry out an allowed request. Returns whether it reached the pane
    /// or the pasteboard.
    func approve(
        _ source: ClipboardRequestSource,
        contents: String,
        on target: (any ClipboardRequestTarget)?
    ) -> Bool {
        switch source {
        case .osc52Write:
            writePasteboard(contents)
            return true
        case let .libghostty(_, state):
            guard let target, let surface = target.surface else {
                log.notice("clipboard allow skipped: the pane closed before the user answered")
                return false
            }
            guard target.clipboardRequests.claim(state) else { return false }
            complete(surface, contents, state)
            return true
        }
    }
}

/// One pending clipboard request waiting on the user's verdict. Holds a
/// *weak* reference to the originating pane rather than the raw surface
/// pointer: if the pane closes while the sheet is up, the target goes nil
/// and `allow()` / `deny()` leave the request to the pane's teardown
/// instead of answering on a freed surface. `id` is a fresh UUID per
/// request so SwiftUI's `.sheet(item:)` rebuilds when a back-to-back
/// request replaces the previous one.
@MainActor
struct PendingClipboardRequest: Identifiable {
    let id = UUID()
    let source: ClipboardRequestSource
    let contents: String
    /// Originating pane; weak so a closed pane can't be revived through
    /// this request. The live `ghostty_surface_t` is read from it at
    /// completion time, never cached.
    weak var target: (any ClipboardRequestTarget)?

    var kind: ClipboardConfirmationKind {
        source.kind
    }

    /// The originating view, for the UI that decides where the sheet goes.
    var view: SurfaceView? {
        target?.surfaceView
    }
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
    private let answerer: ClipboardRequestAnswerer

    init(answerer: ClipboardRequestAnswerer = .libghostty) {
        self.answerer = answerer
    }

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
    /// after the C callback hops over. Refuses it if another request is
    /// already in flight — see the class doc-comment for the rationale.
    func enqueue(
        _ source: ClipboardRequestSource,
        contents: String,
        target: any ClipboardRequestTarget,
        receipt: ReviewPasteReceipt? = nil
    ) {
        guard reviewPasteLedger.enqueue(receipt: receipt) else {
            log.notice("clipboard request denied: another prompt is already up")
            answerer.refuse(source, on: target)
            return
        }
        pending = PendingClipboardRequest(source: source, contents: contents, target: target)
    }

    /// User clicked Allow. A libghostty request is completed, which lets
    /// it deliver the pasteboard contents to the shell. An OSC 52 write
    /// has no request to complete; we set the pasteboard ourselves now
    /// that the user has approved.
    func allow() {
        guard let req = pending, !isCompleting else { return }
        isCompleting = true
        pending = nil
        let didLand = answerer.approve(req.source, contents: req.contents, on: req.target)
        reviewPasteLedger.allow(paneIsAlive: didLand)
        isCompleting = false
    }

    /// User clicked Deny (or the sheet was dismissed). A libghostty
    /// request is denied, which drops it and frees its state. An OSC 52
    /// write is refused by leaving the pasteboard untouched.
    func deny() {
        guard let req = pending, !isCompleting else { return }
        isCompleting = true
        pending = nil
        reviewPasteLedger.deny()
        answerer.refuse(req.source, on: req.target)
        isCompleting = false
    }

    /// Pane is closing while a prompt is up for it. Deny it now, while the
    /// surface is still live, rather than leave a sheet up for a pane that
    /// is going away. The `=== target` gate ensures we only answer prompts
    /// that belong to the closing pane.
    func cancelPending(for target: any ClipboardRequestTarget) {
        guard pending?.target === target else { return }
        deny()
    }
}
