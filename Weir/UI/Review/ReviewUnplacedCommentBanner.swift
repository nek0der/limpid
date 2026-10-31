// ReviewUnplacedCommentBanner.swift
// Weir — the banner that offers a comment the review could not keep where it was written, to copy or throw away.

import AppKit
import SwiftUI

/// A comment being written that could not stay where it was written
/// (`ReviewSession.unplacedComment`): its code went as the diff changed
/// under it, or the review cannot open at all. The text is offered to
/// copy, so it is never dropped unseen; Copy and Discard both let it go.
/// Drawn over the review and over the screen that says the review cannot
/// open, from the review's own state, so it is there whichever is drawn and
/// however often the surface is drawn anew.
struct ReviewUnplacedCommentBanner: View {
    let reviewSession: ReviewSession

    var body: some View {
        if let text = reviewSession.unplacedComment {
            ReviewBanner(
                systemImage: "exclamationmark.triangle.fill",
                message: Text("The comment you were writing couldn’t be put back where it was. Copy it to write it again."),
                tone: .error,
                actionTitle: "Copy",
                action: {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    reviewSession.unplacedComment = nil
                },
                secondaryActionTitle: "Discard",
                secondaryAction: { reviewSession.unplacedComment = nil }
            )
        }
    }
}
