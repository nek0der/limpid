// SupervisionTruncation+Text.swift
// Limpid — applies the supervision window's one truncation rule to a view.

import SwiftUI

extension Text.TruncationMode {
    /// The mode the rule gives what a line holds (`SupervisionTruncation`).
    init(_ content: SupervisionTruncation) {
        switch content.edge {
        case .head: self = .head
        case .middle: self = .middle
        case .tail: self = .tail
        }
    }
}

extension View {
    /// Cuts the view's text where the rule says a line holding `content`
    /// gives way, so every surface of the window cuts the same thing alike.
    func supervisionTruncation(_ content: SupervisionTruncation) -> some View {
        truncationMode(Text.TruncationMode(content))
    }
}
