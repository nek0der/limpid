// DisplayText+Text.swift
// Limpid — draws a `DisplayText` so its localized case follows `\.locale`.

import SwiftUI

extension Text {
    /// The localized case goes to SwiftUI as a resource, which it resolves
    /// in the environment's locale and redraws when that changes; the
    /// verbatim case is drawn as is. Labeled, so it can never be the
    /// overload a `Text("…")` literal picks.
    init(display text: DisplayText) {
        switch text {
        case let .localized(resource): self.init(resource)
        case let .verbatim(string): self.init(verbatim: string)
        }
    }
}
