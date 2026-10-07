// PaneMinimumSize+Literals.swift
// Limpid — lets tests write a uniform split floor as a bare number.

import CoreGraphics
@testable import Limpid

/// Literals read as a uniform floor, the shape every caller had before the
/// axes split, so a fixed number in a test keeps meaning the same thing.
/// Test-only: production code states both axes, or `.zero`, explicitly.
extension PaneMinimumSize: @retroactive ExpressibleByIntegerLiteral, @retroactive ExpressibleByFloatLiteral {
    public init(integerLiteral value: Int) {
        self.init(uniform: CGFloat(value))
    }

    public init(floatLiteral value: Double) {
        self.init(uniform: CGFloat(value))
    }
}
