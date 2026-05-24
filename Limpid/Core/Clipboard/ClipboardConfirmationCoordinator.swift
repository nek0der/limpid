// ClipboardConfirmationCoordinator.swift
// Limpid — bridges libghostty's `confirm_read_clipboard_cb` to a
// SwiftUI sheet so OSC 52 reads / writes / unsafe pastes always get
// explicit user consent. Without this the embedding app is required
// (per libghostty's contract for the "ask" policy) to surface a
// confirmation UI — auto-confirming would let any escape sequence
// the shell receives read or overwrite the user's clipboard.

import Foundation
import GhosttyKit
import OSLog

private let log = Logger(subsystem: "dev.limpid", category: "clipboard.confirm")

/// Distinguishes the three flavours of clipboard request libghostty
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

/// One pending clipboard request waiting on the user's verdict.
/// Carries the libghostty surface + state opaque pointers so we can
/// call `ghostty_surface_complete_clipboard_request` once the user
/// answers. `id` is a fresh UUID per request so SwiftUI's
/// `.sheet(item:)` rebuilds the view when a back-to-back request
/// replaces the previous one.
@MainActor
struct PendingClipboardRequest: Identifiable {
    let id = UUID()
    let kind: ClipboardConfirmationKind
    let contents: String
    /// Opaque libghostty surface handle. `nonisolated(unsafe)` because
    /// it crosses the C ABI — only used to pass back through
    /// `ghostty_surface_complete_clipboard_request`.
    nonisolated(unsafe) let surface: ghostty_surface_t
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

    /// Enqueue a request from libghostty. Called on the main actor
    /// after the C callback hops over. Returns silently if another
    /// request is already in flight — see the class doc-comment for
    /// the rationale.
    func enqueue(
        kind: ClipboardConfirmationKind,
        contents: String,
        surface: ghostty_surface_t,
        state: UnsafeMutableRawPointer?
    ) {
        guard pending == nil else {
            log.notice("clipboard request denied: another prompt is already up")
            ghostty_surface_complete_clipboard_request(surface, "", state, false)
            return
        }
        pending = PendingClipboardRequest(
            kind: kind,
            contents: contents,
            surface: surface,
            state: state
        )
    }

    /// User clicked Allow. Pass the original contents through and
    /// flag `confirmed=true` so libghostty actually performs the
    /// read / write / paste.
    func allow() {
        guard let req = pending, !isCompleting else { return }
        isCompleting = true
        pending = nil
        req.contents.withCString { ptr in
            ghostty_surface_complete_clipboard_request(req.surface, ptr, req.state, true)
        }
        isCompleting = false
    }

    /// User clicked Deny (or the sheet was dismissed). Pass an empty
    /// string and `confirmed=false`; libghostty treats this as "the
    /// request was rejected" and won't retry.
    func deny() {
        guard let req = pending, !isCompleting else { return }
        isCompleting = true
        pending = nil
        ghostty_surface_complete_clipboard_request(req.surface, "", req.state, false)
        isCompleting = false
    }
}
