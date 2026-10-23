// ReviewCardLayoutTests.swift
// Limpid — comment cards and the composer stay inside the part of the diff the reader can see.

import AppKit
import SwiftUI
import Testing
@testable import Limpid

@Suite("Review card layout")
@MainActor
struct ReviewCardLayoutTests {
    private let en = Locale(identifier: "en")
    private let ja = Locale(identifier: "ja")

    // MARK: - Metrics

    /// No viewport, gutter or layout puts a card past the visible area, and
    /// a card keeps its place beside the strip whenever the column has the
    /// room for it.
    @Test func cardFrame_staysInsideTheViewport_forEveryGutterAndLayout() {
        var failures: [String] = []
        for viewport in stride(from: CGFloat(200), through: 1400, by: 5) {
            for digits in 2...6 {
                let numberWidth = numberWidth(digits: digits)
                for layout in ReviewDiffLayout.allCases {
                    let frame = ReviewRowMetrics.cardFrame(viewport: viewport, numberWidth: numberWidth, layout: layout)
                    let inset = ReviewRowMetrics.cardInset(numberWidth: numberWidth, layout: layout)
                    let roomBeside = viewport - inset - ReviewRowMetrics.cardTrailing
                    let isInside = frame.leading >= ReviewRowMetrics.cardEdgeInset
                        && frame.leading + frame.width + ReviewRowMetrics.cardTrailing <= viewport
                        && frame.width > 0
                    let keepsItsPlace = roomBeside < ReviewRowMetrics.cardComfortableWidth
                        || (frame.leading == inset && frame.width == roomBeside)
                    let isComfortable = frame.width >= min(
                        ReviewRowMetrics.cardComfortableWidth,
                        viewport - ReviewRowMetrics.cardEdgeInset - ReviewRowMetrics.cardTrailing
                    )
                    if !isInside || !keepsItsPlace || !isComfortable {
                        failures.append("\(viewport) \(digits) \(layout): \(frame)")
                    }
                }
            }
        }
        #expect(failures.isEmpty)
    }

    /// The composer is measured at the width it is drawn at, and the header's
    /// second line adds exactly its own height.
    @Test func composerHeight_countsTheHeadersSecondLine() {
        let header = ReviewComposerRowView.header(line: line(1200), start: line(1180), isEditing: false, locale: ja)
        let wide = ReviewCardMetrics(viewport: 1200, numberWidth: numberWidth(digits: 4), layout: .unified)
        let narrow = ReviewCardMetrics(viewport: 360, numberWidth: numberWidth(digits: 4), layout: .unified)
        #expect(!header.wraps(inCardWidth: wide.frame.width))
        #expect(header.wraps(inCardWidth: narrow.frame.width))
        #expect(
            ReviewRowMetrics.composerHeight(for: "", header: header, metrics: narrow)
                == ReviewRowMetrics.composerHeight(for: "", header: header, metrics: wide)
                + ReviewRowMetrics.cardHeaderWrapHeight
        )
    }

    // MARK: - Hosted rows

    /// At a 360pt viewport over a 900pt column and a four-digit gutter, the
    /// card ends inside the viewport, its buttons and its header inside the
    /// card, and the Japanese position on a line of its own under the title.
    @Test func composer_atANarrowViewport_fitsInsideIt() throws {
        let metrics = ReviewCardMetrics(viewport: 360, numberWidth: numberWidth(digits: 4), layout: .unified)
        let composer = ReviewComposerRowView(frame: NSRect(x: 0, y: 0, width: 900, height: 200))
        composer.configure(line(1200), start: line(1180), text: "", isEditing: false, metrics: metrics, locale: ja)
        composer.setFrameSize(NSSize(
            width: 900,
            height: ReviewRowMetrics.composerHeight(for: "", header: composer.header, metrics: metrics)
        ))
        composer.layoutSubtreeIfNeeded()

        let card = try #require(composer.subviews.first { $0 is ReviewCardView })
        #expect(card.frame.minX >= 0)
        #expect(card.frame.maxX <= metrics.viewport - ReviewRowMetrics.cardTrailing + 0.5)
        let buttons = card.subviews.compactMap { $0 as? NSButton }
        #expect(buttons.count == 2)
        for button in buttons {
            #expect(card.bounds.insetBy(dx: -0.5, dy: -0.5).contains(button.frame))
        }
        let add = try #require(buttons.first { $0.title == LocalizedStringResource("Add").resolved(in: ja) })
        #expect(add.frame.width >= add.intrinsicContentSize.width - 0.5)

        let labels = card.subviews.compactMap { $0 as? NSTextField }
        let title = try #require(labels.first { $0.stringValue == composer.header.title })
        let position = try #require(labels.first { $0.stringValue == composer.header.detail })
        #expect(position.stringValue.hasPrefix("変更前"))
        // Not flipped: under the title is lower on the y axis.
        #expect(position.frame.maxY <= title.frame.minY)
        #expect(card.bounds.contains(position.frame))
        #expect(position.frame.width >= position.intrinsicContentSize.width - 0.5)
        #expect(title.frame.width >= title.intrinsicContentSize.width - 0.5)

        // The field under the two-line header is as tall as under a header
        // of one line: the second line was paid for in the row's height.
        let wide = ReviewCardMetrics(viewport: 1200, numberWidth: metrics.numberWidth, layout: .unified)
        let reference = ReviewComposerRowView(frame: NSRect(x: 0, y: 0, width: 1200, height: 200))
        reference.configure(line(1200), start: line(1180), text: "", isEditing: false, metrics: wide, locale: ja)
        reference.setFrameSize(NSSize(
            width: 1200,
            height: ReviewRowMetrics.composerHeight(for: "", header: reference.header, metrics: wide)
        ))
        reference.layoutSubtreeIfNeeded()
        #expect(fieldHeight(in: composer) == fieldHeight(in: reference))
    }

    /// A saved comment takes the same treatment: inside the viewport, its
    /// buttons inside the card, its position under the title when narrow.
    @Test func savedComment_atANarrowViewport_fitsInsideIt() throws {
        let comment = comment(body: "Fix this before it ships.")
        let metrics = ReviewCardMetrics(viewport: 200, numberWidth: numberWidth(digits: 5), layout: .unified)
        let row = ReviewCommentRowView(frame: NSRect(x: 0, y: 0, width: 900, height: 120))
        row.configure(comment, metrics: metrics, locale: ja)
        let header = ReviewCommentRowView.header(for: comment, locale: ja)
        #expect(header.wraps(inCardWidth: metrics.frame.width))
        row.setFrameSize(NSSize(
            width: 900,
            height: ReviewRowMetrics.commentHeight(for: comment.body, header: header, metrics: metrics)
        ))
        row.layoutSubtreeIfNeeded()

        let card = try #require(row.subviews.first { $0 is ReviewCardView })
        #expect(card.frame.maxX <= metrics.viewport - ReviewRowMetrics.cardTrailing + 0.5)
        let buttons = card.subviews.compactMap { $0 as? NSButton }
        #expect(buttons.count == 3)
        for button in buttons {
            #expect(card.bounds.insetBy(dx: -0.5, dy: -0.5).contains(button.frame))
        }
        let labels = card.subviews.compactMap { $0 as? NSTextField }
        let title = try #require(labels.first { $0.stringValue == header.title })
        let position = try #require(labels.first { $0.stringValue == header.detail })
        // Not flipped: under the title is lower on the y axis.
        #expect(position.frame.maxY <= title.frame.minY)
        #expect(card.bounds.contains(position.frame))
    }

    /// A file whose long lines are scrolled past: the card is moved back to
    /// what the reader sees rather than going off to the left with the code.
    @Test func horizontalScroll_keepsTheCardInView() async throws {
        let (window, host) = hostedInWindow(makeTable(rows: Self.rows(lines: 1, commentsAfter: [0])), width: 600, height: 400)
        defer { window.close() }
        let settled = await settledValue(in: host) { (try? scrollView(in: host)).flatMap { try? cardFrame(in: $0) } }
        let before = try #require(settled)
        let scroll = try scrollView(in: host)
        #expect(scroll.documentVisibleRect.contains(before))
        let offsetBefore = before.minX - scroll.documentVisibleRect.minX

        let document = try #require(scroll.documentView)
        let reach = document.frame.width - scroll.contentSize.width
        #expect(reach > 400)
        scroll.contentView.scroll(to: NSPoint(x: 400, y: scroll.contentView.bounds.origin.y))
        scroll.reflectScrolledClipView(scroll.contentView)
        await settle(host) { (try? cardFrame(in: scroll)).map { scroll.documentVisibleRect.contains($0) } ?? false }
        #expect(scroll.documentVisibleRect.minX == 400)
        let after = try cardFrame(in: scroll)
        #expect(scroll.documentVisibleRect.contains(after))
        #expect(after.width == before.width)
        #expect(after.minX - scroll.documentVisibleRect.minX == offsetBefore)
    }

    /// The table keeps rows ready above and below what is on screen, and
    /// shows one as it is when it scrolls into view. A sideways scroll moves
    /// the cards on those rows as well, so none comes into view where the
    /// previous offset left it.
    @Test func horizontalScroll_movesTheCardsOnPreparedRowsToo() async throws {
        let parent = makeTable(rows: Self.rows(lines: 80, commentsAfter: [1, 20, 30]))
        let rows = parent.rows
        let (window, host) = hostedInWindow(parent, width: 600, height: 300)
        defer { window.close() }
        await settle(host) { (try? scrollView(in: host)).flatMap { try? cardFrame(in: $0) } != nil }
        let scroll = try scrollView(in: host)
        let table = try #require(scroll.documentView as? NSTableView)
        // A row ready below what is shown, as responsive scrolling keeps
        // them: built and configured now, at the offset of now.
        let commentRows = rows.indices.filter {
            if case .comment = rows[$0].kind {
                return true
            }
            return false
        }
        let offscreen = try #require(commentRows.first { !table.rect(ofRow: $0).intersects(table.visibleRect) })
        _ = table.rowView(atRow: offscreen, makeIfNecessary: true)
        #expect(!offscreenCards(in: table).isEmpty, "a card on a row the table holds off screen")

        // The scroll alone, with no pass of the table's layout after it to
        // build or configure rows again: what moves the card is the scroll.
        scroll.contentView.scroll(to: NSPoint(x: 400, y: scroll.contentView.bounds.origin.y))
        let visible = scroll.documentVisibleRect
        #expect(visible.minX == 400)
        let held = rowViews(in: table)
        for rowView in held {
            rowView.layoutSubtreeIfNeeded()
        }
        let cards = cardFrames(in: table)
        #expect(cards.count >= 2)
        #expect(!offscreenCards(in: table).isEmpty, "the row off screen is still the one the table holds")
        for card in cards {
            #expect(card.minX >= visible.minX && card.maxX <= visible.maxX, "\(card) outside \(visible)")
        }
    }

    // MARK: - Header wrap

    /// The header goes to two lines exactly where its one line stops
    /// fitting, as the constraints lay it out: one point narrower wraps, the
    /// width itself does not.
    @Test func headerWrap_switchesAtTheWidthTheConstraintsNeed() {
        let headers = [
            ReviewCommentRowView.header(for: comment(body: "x"), locale: ja),
            ReviewCommentRowView.header(for: comment(body: "x", isInserted: true), locale: en),
            ReviewComposerRowView.header(line: line(1200), start: line(1180), isEditing: false, locale: ja),
            ReviewComposerRowView.header(line: line(14), start: nil, isEditing: true, locale: en)
        ]
        for header in headers {
            let width = header.singleLineWidth
            #expect(!header.wraps(inCardWidth: width), "\(header)")
            #expect(!header.wraps(inCardWidth: width + 1), "\(header)")
            #expect(header.wraps(inCardWidth: width - 1), "\(header)")
        }
    }

    /// Laid out just above the threshold, the header's one line is drawn
    /// whole; just below, the position is drawn whole on the line under the
    /// title. Saved comments with and without a state, and the composer.
    @Test(arguments: [false, true])
    func header_justAboveAndBelowTheThreshold_isDrawnWhole(isInserted: Bool) throws {
        let comment = comment(body: "x", isInserted: isInserted)
        let header = ReviewCommentRowView.header(for: comment, locale: ja)
        for (offset, wraps) in [(CGFloat(0), false), (1, false), (-1, true), (-2, true)] {
            let metrics = metrics(forCardWidth: header.singleLineWidth + offset)
            let row = ReviewCommentRowView(frame: NSRect(x: 0, y: 0, width: 900, height: 120))
            row.configure(comment, metrics: metrics, locale: ja)
            row.setFrameSize(NSSize(
                width: 900,
                height: ReviewRowMetrics.commentHeight(for: comment.body, header: header, metrics: metrics)
            ))
            row.layoutSubtreeIfNeeded()
            try expectWhole(header, in: row, wraps: wraps)
        }

        let composerHeader = ReviewComposerRowView.header(line: line(1200), start: line(1180), isEditing: false, locale: ja)
        for (offset, wraps) in [(CGFloat(0), false), (1, false), (-1, true), (-2, true)] {
            let metrics = metrics(forCardWidth: composerHeader.singleLineWidth + offset)
            let composer = ReviewComposerRowView(frame: NSRect(x: 0, y: 0, width: 900, height: 200))
            composer.configure(line(1200), start: line(1180), text: "", isEditing: false, metrics: metrics, locale: ja)
            composer.setFrameSize(NSSize(
                width: 900,
                height: ReviewRowMetrics.composerHeight(for: "", header: composerHeader, metrics: metrics)
            ))
            composer.layoutSubtreeIfNeeded()
            try expectWhole(composerHeader, in: composer, wraps: wraps)
        }
    }

    // MARK: - Helpers

    /// The header's title and position each drawn at least as wide as their
    /// words, on one line or on two as `wraps` says.
    private func expectWhole(_ header: ReviewCardHeader, in row: NSView, wraps: Bool) throws {
        let card = try #require(row.subviews.first { $0 is ReviewCardView })
        let labels = card.subviews.compactMap { $0 as? NSTextField }
        let title = try #require(labels.first { $0.stringValue == header.title })
        let position = try #require(labels.first { $0.stringValue == header.detail })
        #expect(header.wraps(inCardWidth: card.frame.width) == wraps)
        #expect(title.frame.width >= title.intrinsicContentSize.width, "title cut at \(card.frame.width)")
        #expect(position.frame.width >= position.intrinsicContentSize.width, "position cut at \(card.frame.width)")
        #expect(card.bounds.contains(position.frame))
        if wraps {
            // Not flipped: under the title is lower on the y axis.
            #expect(position.frame.maxY <= title.frame.minY)
        } else {
            #expect(abs(position.frame.midY - title.frame.midY) < 1)
        }
    }

    /// Metrics whose card is exactly `width` wide: beside a two-digit
    /// gutter while that leaves room, else stepped over it to the edge.
    private func metrics(forCardWidth width: CGFloat) -> ReviewCardMetrics {
        let numberWidth = numberWidth(digits: 2)
        let inset = ReviewRowMetrics.cardInset(numberWidth: numberWidth, layout: .unified)
        let viewport = width >= ReviewRowMetrics.cardComfortableWidth
            ? width + inset + ReviewRowMetrics.cardTrailing
            : width + ReviewRowMetrics.cardEdgeInset + ReviewRowMetrics.cardTrailing
        let metrics = ReviewCardMetrics(viewport: viewport, numberWidth: numberWidth, layout: .unified)
        #expect(metrics.frame.width == width)
        return metrics
    }

    private func numberWidth(digits: Int) -> CGFloat {
        ReviewRowMetrics.numberWidth(forHighestLine: Int(pow(10, Double(digits - 1))))
    }

    private func line(_ number: Int) -> ReviewLine {
        ReviewLine(id: number, kind: .added, text: "new", oldLine: number, newLine: number)
    }

    private func comment(body: String, isInserted: Bool = false) -> ReviewComment {
        var comment = ReviewComment(
            file: ReviewFile(path: "a.swift", layer: .untracked, status: .added),
            fingerprint: "snapshot",
            anchor: ReviewAnchor(lineID: 1, oldLine: 12340, newLine: 12345),
            code: "+x",
            codeMarkers: "+",
            body: body
        )
        if isInserted {
            comment.insertedAt = Date(timeIntervalSince1970: 0)
        }
        return comment
    }

    private func fieldHeight(in composer: ReviewComposerRowView) -> CGFloat? {
        descendants(of: composer).first { $0 is ReviewFieldView }?.frame.height
    }

    private func scrollView(in host: NSView) throws -> ReviewScrollView {
        try #require(descendants(of: host).compactMap { $0 as? ReviewScrollView }.first)
    }

    /// The first comment card's frame in the document's coordinates.
    private func cardFrame(in scroll: NSScrollView) throws -> NSRect {
        let table = try #require(scroll.documentView as? NSTableView)
        return try #require(cardFrames(in: table).first)
    }

    /// Every comment card on a row the table holds, in its coordinates.
    private func cardFrames(in table: NSTableView) -> [NSRect] {
        var frames: [NSRect] = []
        table.enumerateAvailableRowViews { rowView, _ in
            guard let row = rowView.view(atColumn: 0) as? ReviewCommentRowView,
                  let card = row.subviews.first(where: { $0 is ReviewCardView }) else { return }
            frames.append(card.convert(card.bounds, to: table))
        }
        return frames
    }

    private func rowViews(in table: NSTableView) -> [NSTableRowView] {
        var views: [NSTableRowView] = []
        table.enumerateAvailableRowViews { rowView, _ in views.append(rowView) }
        return views
    }

    /// The comment cards on rows the table holds outside what it shows.
    private func offscreenCards(in table: NSTableView) -> [NSRect] {
        cardFrames(in: table).filter { !$0.intersects(table.visibleRect) }
    }

    /// `lines` code rows, the first far longer than the viewport, with a
    /// comment row after each line index in `commentsAfter`.
    private static func rows(lines: Int, commentsAfter: Set<Int>) -> [ReviewRow] {
        let file = ReviewFile(path: "a.swift", layer: .unstaged, status: .modified)
        var rows: [ReviewRow] = []
        for index in 0..<lines {
            let text = index == 0 ? String(repeating: "x", count: 400) : "line \(index)"
            let line = ReviewLine(id: index, kind: .added, text: text, oldLine: nil, newLine: index + 1)
            rows.append(ReviewRow(id: rows.count, kind: .code(line)))
            if commentsAfter.contains(index) {
                let comment = ReviewComment(
                    file: file, fingerprint: "f", anchor: ReviewAnchor(lineID: index, oldLine: nil, newLine: index + 1),
                    code: "+x", codeMarkers: "+", body: "Fix this."
                )
                rows.append(ReviewRow(id: rows.count, kind: .comment(comment)))
            }
        }
        return rows
    }

    private func makeTable(rows: [ReviewRow]) -> ReviewDiffTable {
        let file = ReviewFile(path: "a.swift", layer: .unstaged, status: .modified)
        let lines = rows.compactMap { row -> ReviewLine? in
            if case let .code(line) = row.kind {
                return line
            }
            return nil
        }
        return ReviewTableFixture.table(
            file,
            rows: rows,
            lines: lines,
            key: "scroll",
            selection: .constant(ReviewDiffSelection()),
            composer: .closed,
            locale: en
        )
    }
}
