// SurfaceView+Review.swift
// Limpid — explicit paste-only delivery to an existing terminal surface.

import AppKit
import GhosttyKit

extension SurfaceView: ReviewTextDelivering, ReviewPasteStaging {
    /// `userInfo` key of `limpidMirrorReviewPasteRequested`: the prompt text.
    static let reviewPromptTextKey = "text"
    /// `userInfo` key of `limpidMirrorReviewPasteRequested`: the
    /// `ReviewPasteReceipt` the delivery answers with, absent when review
    /// asked for none.
    static let reviewPasteReceiptKey = "receipt"

    /// Deliver assembled feedback to this surface as a paste.
    ///
    /// Through libghostty's paste action rather than as typed text.
    ///
    /// A program that asked for bracketed paste receives one framed block, and
    /// an agent composer folds that into a single message. An interactive shell
    /// asks for it too, and what arrives there sits in the line editor rather
    /// than running. A program that did not ask — a shell running a command in
    /// front of it, or one old enough not to know the mode — sends the paste
    /// through the confirmation sheet first, where the reader sees what is
    /// about to arrive and decides. That step is what this path is for: an
    /// unbracketed paste turns newlines into carriage returns, and a shell runs
    /// each line. The diff we quote is repository content, and running it is
    /// not ours to decide.
    ///
    /// There is deliberately no fallback to `ghostty_surface_text`: that path
    /// completes the paste with `allow_unsafe`, which is exactly the
    /// protection this method exists to keep.
    ///
    /// The text is staged on this surface rather than on `NSPasteboard`, so
    /// review never overwrites what the user has on their clipboard.
    ///
    /// A pane whose tab sends its input through tmux
    /// (`TabCapabilities.sendsInputThroughTmux`) takes neither route here:
    /// libghostty's paste would reach the mirror surface, which is a picture
    /// of the tmux pane and not a terminal anything is running on. It goes as
    /// a tmux paste buffer instead, under the same confirmation rule
    /// (`TmuxPasteBuffer`), through the window that holds the tmux store.
    func deliverReviewText(_ prompt: ReviewPrompt, receipt: ReviewPasteReceipt?) throws {
        if tabCapabilities?()?.sendsInputThroughTmux == true {
            var userInfo: [String: Any] = [Self.reviewPromptTextKey: prompt.text]
            userInfo[Self.reviewPasteReceiptKey] = receipt
            NotificationCenter.default.post(
                name: .limpidMirrorReviewPasteRequested,
                object: self,
                userInfo: userInfo
            )
            return
        }
        guard let surface else { throw ReviewError.targetUnavailable }
        try ReviewPasteAttempt.deliver(prompt, receipt: receipt, staging: self) {
            let action = "paste_from_clipboard"
            return ghostty_surface_binding_action(surface, action, UInt(action.utf8.count))
        }
    }
}
