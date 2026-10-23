// PaneExitText.swift
// Limpid — the line under a pane whose process exited: which keys close or restart it.

import Foundation

enum PaneExitText {
    /// The hint names the key Close Pane is bound to now, since a person
    /// can rebind it, and leaves the closing half out when nothing is
    /// bound: naming a key that does nothing would send them looking for
    /// it. Return always restarts, so that half stays.
    static func hint(closeKey: String?) -> LocalizedStringResource {
        guard let closeKey else { return "Press ⏎ to restart." }
        return "Press \(closeKey) to close, or ⏎ to restart."
    }
}
