// WidthCapTests.swift
// Limpid — a capped view takes its own width, not the width it is offered, and is cut only past its cap.

import AppKit
import SwiftUI
import Testing
@testable import Limpid

@MainActor
struct WidthCapTests {
    /// The width `view` takes when offered `width`, as a line in the
    /// sheet offers it.
    private static func width(of view: some View, offered width: CGFloat) -> CGFloat {
        let renderer = ImageRenderer(content: view)
        renderer.proposedSize = ProposedViewSize(width: width, height: nil)
        renderer.scale = 1
        return renderer.nsImage?.size.width ?? -1
    }

    @Test func aFlexibleView_takesItsOwnWidth_notTheWidthOffered() {
        // What a plain menu is: as wide as it is offered, 30pt ideally.
        let flexible = Color.clear.frame(idealWidth: 30, maxWidth: .infinity, minHeight: 10)
        #expect(Self.width(of: WidthCap(max: 200) { flexible }, offered: 440) == 30)
        // Beyond the cap, the cap.
        let wide = Color.clear.frame(idealWidth: 300, maxWidth: .infinity, minHeight: 10)
        #expect(Self.width(of: WidthCap(max: 200) { wide }, offered: 440) == 200)
        // Less offered than either: what is offered.
        #expect(Self.width(of: WidthCap(max: 200) { wide }, offered: 120) == 120)
    }
}
