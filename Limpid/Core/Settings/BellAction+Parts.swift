// BellAction+Parts.swift
// Limpid — the bell's stored choice read as the two things it switches: a flash and a sound.

import Foundation

/// Settings shows the bell as two checkboxes, since its four values are
/// every combination of two on/off parts. The file keeps the one value
/// (`terminal.bellAction`), so earlier builds read it as they always did.
extension BellAction {
    init(flashes: Bool, sounds: Bool) {
        self = switch (flashes, sounds) {
        case (false, false): .none
        case (true, false): .visual
        case (false, true): .audio
        case (true, true): .both
        }
    }

    var flashes: Bool {
        self == .visual || self == .both
    }

    var sounds: Bool {
        self == .audio || self == .both
    }
}
