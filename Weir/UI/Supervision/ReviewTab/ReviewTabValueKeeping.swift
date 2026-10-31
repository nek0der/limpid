// ReviewTabValueKeeping.swift
// Weir — what the review tab's views hold for themselves, kept beside the window so the tab comes back as it was.

import SwiftUI

/// Keeps one value a review tab's view holds for itself in the window's
/// `ReviewTabDisplay`, and starts the view from it: the view goes as its
/// tab goes with its project, and the tab comes back drawn anew
/// (`ParkedReview`). For a part a view still holds as its own state; a view
/// that can bind to the display directly does (`ReviewFileRail`).
private struct ReviewTabValueKeeping<Value: Equatable>: ViewModifier {
    @Binding var value: Value
    let keyPath: ReferenceWritableKeyPath<ReviewTabDisplay, Value>
    /// Told the value kept as the view starts from it.
    let taken: ((Value) -> Void)?
    @Environment(ProjectWindowState.self) private var window

    func body(content: Content) -> some View {
        content
            .onAppear {
                let kept = window.reviewTabDisplay[keyPath: keyPath]
                taken?(kept)
                if value != kept {
                    value = kept
                }
            }
            .onChange(of: value) { _, value in
                window.reviewTabDisplay.assign(keyPath, value)
            }
    }
}

extension View {
    /// Keeps `value` in the window's `ReviewTabDisplay` at `keyPath`
    /// while the view draws the review tab, and starts from what is kept
    /// there; `taken` hears the value as the view starts from it.
    func keptInReviewTab<Value: Equatable>(
        _ value: Binding<Value>,
        as keyPath: ReferenceWritableKeyPath<ReviewTabDisplay, Value>,
        taken: ((Value) -> Void)? = nil
    ) -> some View {
        modifier(ReviewTabValueKeeping(value: value, keyPath: keyPath, taken: taken))
    }
}
