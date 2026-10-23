// ReceiptRunRendererTests.swift
// Limpid — the receipt's and the notification facts' run styles, drawn by one renderer.

import SwiftUI
import Testing
@testable import Limpid

@MainActor
struct ReceiptRunRendererTests {
    @Test func receipt_emphasisFollowsShowsEmphasis() {
        let base = SupervisionTokens.text.color
        let shown = ReceiptRunRenderer.appearance(of: .emphasized, style: .receipt(base: base, showsEmphasis: true))
        let even = ReceiptRunRenderer.appearance(of: .added(isEmphasized: true), style: .receipt(base: base, showsEmphasis: false))
        #expect(shown.color == base)
        #expect(shown.isSemibold)
        #expect(even.color == SupervisionTokens.added.color)
        #expect(!even.isSemibold)
    }

    @Test func receipt_unviewedIsUnreadBlueInSemibold() {
        let unviewed = ReceiptRunRenderer.appearance(
            of: .unviewed,
            style: .receipt(base: SupervisionTokens.muted.color, showsEmphasis: false)
        )
        #expect(unviewed.color == SupervisionTokens.unreadText.color)
        #expect(unviewed.isSemibold)
    }

    @Test func mutedFacts_wordsAreMutedAndRegular_countsKeepDiffColors() {
        let words: [ReceiptRun.Role] = [.emphasized, .plain, .quiet, .unviewed]
        for role in words {
            let appearance = ReceiptRunRenderer.appearance(of: role, style: .mutedFacts)
            #expect(appearance.color == SupervisionTokens.muted.color)
            #expect(!appearance.isSemibold)
        }
        let added = ReceiptRunRenderer.appearance(of: .added(isEmphasized: true), style: .mutedFacts)
        let failed = ReceiptRunRenderer.appearance(of: .failed, style: .mutedFacts)
        #expect(added.color == SupervisionTokens.added.color)
        #expect(!added.isSemibold)
        #expect(failed.color == SupervisionTokens.stoppedText.color)
    }

    @Test func attributed_joinsRunsInOrder() {
        let runs = [
            ReceiptRun(text: "T7", role: .plain),
            ReceiptRun(text: " · ", role: .quiet),
            ReceiptRun(text: "+3", role: .added(isEmphasized: false))
        ]
        let line = ReceiptRunRenderer.attributed(runs, size: .body, style: .mutedFacts)
        #expect(String(line.characters) == "T7 · +3")
    }
}
