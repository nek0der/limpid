// PaletteDropdownPlacementTests.swift
// Limpid — where the palette's dropdown stands across the window.

import CoreGraphics
import Testing
@testable import Limpid

struct PaletteDropdownPlacementTests {
    @Test func theDropdown_centersOnTheField_withinTheWindow() {
        // Centered under the field.
        #expect(PaletteDropdownPlacement.originX(fieldMidX: 600, width: 560, containerWidth: 1200, margin: 8) == 320)
        // Held off either side.
        #expect(PaletteDropdownPlacement.originX(fieldMidX: 200, width: 560, containerWidth: 1200, margin: 8) == 8)
        #expect(PaletteDropdownPlacement.originX(fieldMidX: 1100, width: 560, containerWidth: 1200, margin: 8) == 632)
        // Narrower than the dropdown: it starts at the left margin.
        #expect(PaletteDropdownPlacement.originX(fieldMidX: 250, width: 560, containerWidth: 500, margin: 8) == 8)
    }
}
