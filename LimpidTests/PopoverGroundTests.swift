// PopoverGroundTests.swift
// Limpid — a popover's ground, opaque or the material as transparency is set, and the rows and words that must show on it.

import AppKit
import SwiftUI
import Testing
@testable import Limpid

struct PopoverGroundTests {
    private typealias Tokens = SupervisionTokens

    /// With transparency off the popovers are opaque `popover`: a hovered
    /// row, the row the keys are on, and a rule must still show on it, as
    /// they do on white in light, for the keyboard alone.
    @Test(arguments: [false, true])
    func rowsAndRules_standOffThePopover(isDark: Bool) {
        let popover = Tokens.popover.value(isDark: isDark)
        let selection = ContrastRatio.between(Tokens.selection.value(isDark: isDark), popover)
        let hover = ContrastRatio.between(Tokens.hover.value(isDark: isDark), popover)
        let line = ContrastRatio.between(Tokens.line.value(isDark: isDark), popover)
        #expect(selection >= 1.2, "selection: \(selection)")
        #expect(hover >= 1.1, "hover: \(hover)")
        #expect(line >= 1.2, "line: \(line)")
        #expect(selection > hover, "the chosen row reads stronger than a hovered one")
    }

    /// The surface is opaque while transparency is off or reduced, and the
    /// material otherwise.
    @Test func aPanelsGround_followsTheTransparencySetting() {
        #expect(PopoverGround(reducesTransparency: true) == .opaque)
        #expect(PopoverGround(reducesTransparency: false) == .material)
    }

    /// Turning off the app's own transparency switch makes a floating part
    /// opaque, not only the system's Reduce Transparency.
    @Test @MainActor func aFloatingPart_turnsOpaqueWithTheAppsTransparencySwitchOff() {
        let resolver = ReduceTransparencyResolver()
        resolver.apply(userEnabled: false)
        #expect(PopoverGround(resolver: resolver) == .opaque)
        // With no resolver in reach the part keeps the material.
        #expect(PopoverGround(resolver: nil) == .material)
    }

    /// While transparency is reduced the surfaces, the window's ground, and
    /// the boxes on them are whole at any background opacity; while it is
    /// on they follow that opacity.
    @Test(arguments: [0.3, 0.7, 1.0])
    func aSurfacesOpacity_isWholeOnlyWhileTransparencyIsReduced(backgroundOpacity: Double) {
        #expect(SupervisionSurfaceOpacity.resolve(backgroundOpacity: backgroundOpacity, reducesTransparency: true) == 1)
        #expect(SupervisionSurfaceOpacity.resolve(backgroundOpacity: backgroundOpacity, reducesTransparency: false) == backgroundOpacity)
        // A surface that is always opaque (the changes panel laid over the
        // session) is whole whatever the setting.
        #expect(SupervisionSurfaceOpacity.resolve(backgroundOpacity: backgroundOpacity, reducesTransparency: false, isOpaque: true) == 1)
    }

    /// A row outside any panel hears the opaque ground, and there it keeps
    /// the fills it had before the material had fills of its own.
    @Test func aRowsFill_staysOpaqueOutsideAPanel() {
        #expect(EnvironmentValues().popoverSurface.ground == .opaque)
        #expect(PopoverGround.opaque.selection == .solid(Tokens.selection))
        #expect(PopoverGround.opaque.hover == .solid(Tokens.hover))
    }

    /// On the material, the selected row stands off it further than the
    /// opaque `selection` did (about 1.1:1, all but gone), and further than
    /// a hovered one, so the row the keys are on shows.
    @Test(arguments: [false, true])
    func rows_standOffThePopoverMaterial(isDark: Bool) {
        let material = Tokens.popoverMaterial.value(isDark: isDark)
        let fills = PopoverGround.material
        let selection = ContrastRatio.between(fills.selection.value(over: material, isDark: isDark), material)
        let hover = ContrastRatio.between(fills.hover.value(over: material, isDark: isDark), material)
        let opaqueSelection = ContrastRatio.between(Tokens.selection.value(isDark: isDark), material)
        #expect(selection > 1.12, "selection: \(selection)")
        #expect(hover >= 1.06, "hover: \(hover)")
        #expect(selection > hover, "the chosen row reads stronger than a hovered one")
        #expect(selection > opaqueSelection, "selection \(selection) against the opaque token's \(opaqueSelection)")
    }

    /// The edge inside a selected row on the material, laid over the row's
    /// fill, stands clearly off the material and off the fill it borders,
    /// so the row the keys are on is plain where the fill alone is quiet.
    @Test(arguments: [false, true])
    func aSelectedRowsEdge_standsOffThePopoverMaterial(isDark: Bool) throws {
        let material = Tokens.popoverMaterial.value(isDark: isDark)
        let fill = PopoverGround.material.selection.value(over: material, isDark: isDark)
        let edge = try #require(PopoverGround.material.selectionEdge).value(over: fill, isDark: isDark)
        let onMaterial = ContrastRatio.between(edge, material)
        let onFill = ContrastRatio.between(edge, fill)
        #expect(onMaterial > 1.4, "edge on the material in \(isDark ? "dark" : "light"): \(onMaterial)")
        #expect(onFill > 1.2, "edge on the fill in \(isDark ? "dark" : "light"): \(onFill)")
    }

    /// Every text token a popover's rows draw keeps 4.5:1 on a selected or
    /// hovered row on the material, which is what bounds how far the
    /// fills stand off it.
    @Test(arguments: [false, true])
    func textOnThePopoverMaterialsRows_reachesFourAndAHalfToOne(isDark: Bool) {
        let material = Tokens.popoverMaterial.value(isDark: isDark)
        let fills = PopoverGround.material
        let grounds = [fills.selection, fills.hover].map { $0.value(over: material, isDark: isDark) }
        let texts: [(String, ThemedColor)] = [
            ("text", Tokens.text), ("muted", Tokens.muted), ("unreadText", Tokens.unreadText),
            ("waitingText", Tokens.waitingText), ("stoppedText", Tokens.stoppedText),
            // The history's receipts count lines added in `added`; `removed`
            // is `stoppedText`'s value, so it is covered above.
            ("added", Tokens.added)
        ]
        for ground in grounds {
            for (name, token) in texts {
                let ratio = ContrastRatio.between(token.value(isDark: isDark), ground)
                #expect(ratio >= ContrastRatio.text, "\(name) in \(isDark ? "dark" : "light"): \(ratio)")
            }
        }
    }
}
