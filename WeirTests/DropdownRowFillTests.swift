// DropdownRowFillTests.swift
// Weir — which fill a dropdown's or a short list's row takes: the ground's selection when chosen, its hover under the pointer.

import Testing
@testable import Weir

struct DropdownRowFillTests {
    /// The project menu, the worktree menu, the empty window's projects,
    /// and the empty session area's commands share the attention list's rule:
    /// the chosen row takes the selection fill, pointer or not, and another
    /// row under the pointer takes the hover fill, never the selection's.
    @Test(arguments: [PopoverGround.opaque, .material])
    func aChosenRow_takesTheSelection_aRowUnderThePointer_theHover(ground: PopoverGround) {
        #expect(DropdownRowFill.fill(isSelected: true, isHovering: false, on: ground) == ground.selection)
        #expect(DropdownRowFill.fill(isSelected: true, isHovering: true, on: ground) == ground.selection)
        #expect(DropdownRowFill.fill(isSelected: false, isHovering: true, on: ground) == ground.hover)
        #expect(DropdownRowFill.fill(isSelected: false, isHovering: false, on: ground) == nil)
    }
}
