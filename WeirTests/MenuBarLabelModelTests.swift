// MenuBarLabelModelTests.swift
// Weir — the menu bar extra's icon: which lamp the pill's tone lights, how it is drawn, its count, and what VoiceOver says.

import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Weir
@testable import WeirDomain

struct MenuBarLabelModelTests {
    private static let english = Locale(identifier: "en")
    private static let japanese = Locale(identifier: "ja")

    /// One rule with the title bar pill: anything that blocks lights
    /// the amber disc, a stop alone or a stop with unread turns included;
    /// unread turns alone are the ring with its dot; nothing is the empty
    /// ring.
    @Test(arguments: [
        (AttentionCounts(approvals: 1), MenuBarLabelModel.Lamp.blocking),
        (AttentionCounts(questions: 1), .blocking),
        (AttentionCounts(prompts: 1), .blocking),
        (AttentionCounts(stops: 1), .blocking),
        (AttentionCounts(approvals: 1, stops: 1), .blocking),
        (AttentionCounts(stops: 1, unread: 3), .blocking),
        (AttentionCounts(approvals: 2, unread: 1), .blocking),
        (AttentionCounts(unread: 2), .unread),
        (AttentionCounts(unread: 1), .unread),
        (AttentionCounts(), .off)
    ])
    func theLamp_followsThePillsTone(_ counts: AttentionCounts, _ lamp: MenuBarLabelModel.Lamp) {
        let model = MenuBarLabelModel(counts)
        #expect(model.lamp == lamp)
        #expect(model.style == NeedsAttentionPillModel(counts).style)
    }

    /// The icon no longer shows the number, so the count stays in the model
    /// for VoiceOver and the menu's heading.
    @Test func theCount_isTheTotal() {
        #expect(MenuBarLabelModel(AttentionCounts()).count == 0)
        #expect(MenuBarLabelModel(AttentionCounts(unread: 1)).count == 1)
        #expect(MenuBarLabelModel(AttentionCounts(approvals: 2, unread: 1)).count == 3)
    }

    @Test func voiceOver_saysTheApp_thePillsLabel_andTheKinds() {
        let model = MenuBarLabelModel(AttentionCounts(approvals: 2, questions: 1, unread: 1))
        #expect(model.accessibilityLabel(locale: Self.english) == "Weir, Needs Attention 4, 2 Approvals, 1 Question, 1 Unread")
        #expect(model.accessibilityLabel(locale: Self.japanese) == "Weir、要対応 4、承認 2、質問 1、未読 1")
    }

    @Test func voiceOver_atZero_saysTheCountStill() {
        let model = MenuBarLabelModel(AttentionCounts())
        #expect(model.accessibilityLabel(locale: Self.english) == "Weir, Needs Attention 0")
        #expect(model.accessibilityLabel(locale: Self.japanese) == "Weir、要対応 0")
    }
}

@MainActor
struct MenuBarLampImageTests {
    /// Every lamp is drawn in the menu bar's own ink, as the icons beside
    /// it are; none keeps a color of its own.
    @Test func everyLamp_isATemplate() {
        for lamp in MenuBarLabelModel.Lamp.allCases {
            #expect(MenuBarLampImage.image(lamp).isTemplate)
        }
    }

    /// One size for every lamp, so the item does not move its neighbors
    /// as the state changes.
    @Test func everyLamp_takesTheSameSize() {
        for lamp in [MenuBarLabelModel.Lamp.off, .unread, .blocking] {
            #expect(MenuBarLampImage.image(lamp).size == WeirLayout.Supervision.menuBarLampImageSize)
        }
    }

    /// The lamp drawn into a bitmap at `scale`.
    private static func bitmap(_ lamp: MenuBarLabelModel.Lamp, scale: CGFloat) throws -> NSBitmapImageRep {
        let image = MenuBarLampImage.image(lamp)
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(image.size.width * scale), pixelsHigh: Int(image.size.height * scale), bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ))
        let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: scale, y: scale)
        image.draw(in: NSRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()
        return bitmap
    }

    /// The shape alone carries the meaning: every lamp keeps the mark, the
    /// corner is clear with nothing to say, a dot fills it for unread turns,
    /// and the badge is cut through by its "!" and solid beside it. Checked
    /// at 1x and 2x, since the image is drawn per screen.
    @Test(arguments: [CGFloat(1), 2])
    func theBadges_differAtTheCorner_andShareTheMark(_ scale: CGFloat) throws {
        func alpha(_ lamp: MenuBarLabelModel.Lamp, at point: CGPoint) throws -> CGFloat {
            let bitmap = try Self.bitmap(lamp, scale: scale)
            let pixel = try #require(bitmap.colorAt(x: Int(point.x * scale), y: Int(point.y * scale)))
            return pixel.alphaComponent
        }
        // In the bitmap's rows, which count from the top.
        let onTheTile = CGPoint(x: 14.5, y: 3)
        let onAFlow = CGPoint(x: 6, y: 5.35)
        for lamp in MenuBarLabelModel.Lamp.allCases {
            #expect(try alpha(lamp, at: onTheTile) == 1)
            #expect(try alpha(lamp, at: onAFlow) == 0)
        }
        let onTheDot = CGPoint(x: 17, y: 13.5)
        let onTheStem = CGPoint(x: 16.5, y: 11)
        let besideTheStem = CGPoint(x: 14.5, y: 12.5)
        #expect(try alpha(.off, at: onTheDot) == 0)
        #expect(try alpha(.unread, at: onTheDot) == 1)
        #expect(try alpha(.blocking, at: onTheStem) == 0)
        #expect(try alpha(.unread, at: onTheStem) == 1)
        #expect(try alpha(.blocking, at: besideTheStem) == 1)
    }
}
