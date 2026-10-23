// AgentBadgeMenuImageTests.swift
// Limpid — every agent's badge, and the shell's mark, as an image a menu's item can carry the moment it asks.

import AppKit
import SwiftUI
import Testing
@testable import Limpid

@MainActor
struct AgentBadgeMenuImageTests {
    @Test(arguments: [ColorScheme.light, .dark])
    func everyAgent_hasItsBadge_atTheFirstAsking(_ colorScheme: ColorScheme) {
        let appearance = AgentBadgeMenuImage.Appearance(colorScheme: colorScheme, scale: 2)
        for entry in AgentCatalog.entries {
            let image = AgentBadgeMenuImage.image(for: entry.kind, size: .regular, in: appearance)
            // Drawn there and then, not on a later pass, at the field's
            // size, so the menu's badge and the chosen one match.
            #expect(image.size.width == LimpidLayout.Supervision.agentBadgeWidth, "\(entry.kind)")
            #expect(image.size.height == LimpidLayout.Supervision.agentBadgeLargeHeight, "\(entry.kind)")
            // The next item, or the next opening, reads the same image.
            #expect(AgentBadgeMenuImage.image(for: entry.kind, size: .regular, in: appearance) === image, "\(entry.kind)")
        }
    }

    /// The menus of conversations draw the row's badge, kept per appearance
    /// as the agent menu's is, so a dark menu has a dark badge.
    @Test func aConversationsBadge_isTheRowsSize_drawnForEachAppearance() {
        let light = AgentBadgeMenuImage.image(for: .claude, size: .row, in: .init(colorScheme: .light, scale: 2))
        let dark = AgentBadgeMenuImage.image(for: .claude, size: .row, in: .init(colorScheme: .dark, scale: 2))
        #expect(light.size.height == LimpidLayout.Supervision.agentBadgeHeight)
        #expect(AgentBadgeMenuImage.image(for: .claude, size: .row, in: .init(colorScheme: .light, scale: 2)) === light)
        #expect(light !== dark)
    }

    /// Terminal's mark is a drawn image, not a template the menu would paint
    /// in the window's tint, at the field's size.
    @Test(arguments: [ColorScheme.light, .dark])
    func terminal_hasTheShellsMark(_ colorScheme: ColorScheme) {
        let appearance = AgentBadgeMenuImage.Appearance(colorScheme: colorScheme, scale: 2)
        let image = AgentBadgeMenuImage.shellImage(in: appearance)
        #expect(!image.isTemplate)
        #expect(image.size.width == LimpidLayout.Supervision.agentBadgeWidth)
        #expect(image.size.height == LimpidLayout.Supervision.agentBadgeLargeHeight)
        #expect(AgentBadgeMenuImage.shellImage(in: appearance) === image)
    }

    /// The mark's quiet color follows the appearance it is drawn for, as
    /// the field's does.
    @Test func terminalsMark_isDrawnInEachAppearancesColor() {
        let light = AgentBadgeMenuImage.shellImage(in: .init(colorScheme: .light, scale: 2))
        let dark = AgentBadgeMenuImage.shellImage(in: .init(colorScheme: .dark, scale: 2))
        #expect(light.tiffRepresentation != dark.tiffRepresentation)
    }
}
