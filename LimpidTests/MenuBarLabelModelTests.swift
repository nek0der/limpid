// MenuBarLabelModelTests.swift
// Limpid — the menu bar extra's icon: which lamp the pill's tone lights, how it is drawn, its count, and what VoiceOver says.

import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Limpid

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
        #expect(model.accessibilityLabel(locale: Self.english) == "Limpid, Needs Attention 4, 2 Approvals, 1 Question, 1 Unread")
        #expect(model.accessibilityLabel(locale: Self.japanese) == "Limpid、要対応 4、承認 2、質問 1、未読 1")
    }

    @Test func voiceOver_atZero_saysTheCountStill() {
        let model = MenuBarLabelModel(AttentionCounts())
        #expect(model.accessibilityLabel(locale: Self.english) == "Limpid, Needs Attention 0")
        #expect(model.accessibilityLabel(locale: Self.japanese) == "Limpid、要対応 0")
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
    @Test func everyLamp_takesTheSameSquare() {
        let side = LimpidLayout.Supervision.menuBarLampImageSize
        for lamp in [MenuBarLabelModel.Lamp.off, .unread, .blocking] {
            #expect(MenuBarLampImage.image(lamp).size == NSSize(width: side, height: side))
        }
    }

    /// The lamp drawn into a bitmap at `scale`.
    private static func bitmap(_ lamp: MenuBarLabelModel.Lamp, scale: CGFloat) throws -> NSBitmapImageRep {
        let image = MenuBarLampImage.image(lamp)
        let side = Int(image.size.width * scale)
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
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

    /// The shape alone carries the meaning: the empty ring is clear at its
    /// center, the dot fills it, the disc is cut through by its "!" and
    /// solid beside it, and the ring's stroke is there on the two
    /// rings. Checked at 1x and 2x, since the image is drawn per screen.
    @Test(arguments: [CGFloat(1), 2])
    func theShapes_differAtTheCenter_andShareTheRing(_ scale: CGFloat) throws {
        func alpha(_ lamp: MenuBarLabelModel.Lamp, at point: CGPoint) throws -> CGFloat {
            let bitmap = try Self.bitmap(lamp, scale: scale)
            let pixel = try #require(bitmap.colorAt(x: Int(point.x * scale), y: Int(point.y * scale)))
            return pixel.alphaComponent
        }
        let side = LimpidLayout.Supervision.menuBarLampImageSize
        // In the bitmap's rows, which count from the top.
        let center = CGPoint(x: side / 2, y: side / 2)
        let onTheMarksStem = CGPoint(x: side / 2, y: side / 2 - 2)
        let besideTheMark = CGPoint(x: side / 2 - 3, y: side / 2)
        let onRing = CGPoint(x: side / 2, y: (side - LimpidLayout.Supervision.menuBarLampRingDiameter) / 2 + 0.75)
        #expect(try alpha(.off, at: center) == 0)
        #expect(try alpha(.unread, at: center) == 1)
        #expect(try alpha(.blocking, at: onTheMarksStem) == 0)
        #expect(try alpha(.blocking, at: besideTheMark) == 1)
        #expect(try alpha(.off, at: onRing) > 0.5)
        #expect(try alpha(.unread, at: onRing) > 0.5)
    }

    /// The three lamps read apart at a glance by how much ink each lays
    /// down, each well above the one before it: a disc no heavier than the
    /// ring with a dot was the blot the two read as.
    @Test(arguments: [CGFloat(1), 2])
    func theLamps_differInInk_byAClearMargin(_ scale: CGFloat) throws {
        func ink(_ lamp: MenuBarLabelModel.Lamp) throws -> CGFloat {
            let bitmap = try Self.bitmap(lamp, scale: scale)
            var sum: CGFloat = 0
            for x in 0..<bitmap.pixelsWide {
                for y in 0..<bitmap.pixelsHigh {
                    sum += bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0
                }
            }
            return sum / (scale * scale)
        }
        let off = try ink(.off)
        let unread = try ink(.unread)
        let blocking = try ink(.blocking)
        #expect(unread >= off * 1.25, "unread \(unread) against off \(off)")
        #expect(blocking >= unread * 1.25, "blocking \(blocking) against unread \(unread)")
    }
}
