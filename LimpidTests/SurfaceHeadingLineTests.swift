// SurfaceHeadingLineTests.swift
// Limpid — the surfaces' headings and the rails' ends, laid out, sit on shared lines across the window.

import AppKit
import SwiftUI
import Testing
@testable import Limpid

@Suite("Surface heading line", .hostsWindows)
@MainActor
struct SurfaceHeadingLineTests {
    private typealias Layout = LimpidLayout.Supervision

    /// Within the half point that rounding a text's or a symbol's height to
    /// the pixel grid can leave.
    private static let tolerance: CGFloat = 0.5

    // MARK: - The headings

    /// The sidebar's heading line: "Projects" starts 16pt in, and the ＋
    /// is centered on the heading line with its glyph, not its hover fill,
    /// 16pt in from the other edge.
    @Test func sidebarHeading_centersItsButtonOnTheLine_withItsGlyphInset() async throws {
        let width = Layout.sidebarDefaultWidth
        let book = NamedFrameRecorder(space: Self.space)
        let view = VStack(spacing: 0) {
            SurfaceHeadingLine {
                Text(verbatim: "Projects")
                    .recordFrame(in: book, as: "title")
            } trailing: {
                Button {} label: {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .medium))
                        .recordFrame(in: book, as: "glyph")
                        .frame(height: Layout.sidebarHeadingButtonHeight)
                }
                .buttonStyle(.supervisionIcon)
                .recordFrame(in: book, as: "button")
            }
            Spacer(minLength: 0)
        }
        let frames = try #require(await Self.layOut(view, width: width, height: 200, book: book, count: 3))
        let title = try #require(frames["title"])
        let glyph = try #require(frames["glyph"])
        let button = try #require(frames["button"])

        let centerLine = Layout.surfaceHeadingLineHeight / 2
        #expect(abs(title.midY - centerLine) <= Self.tolerance)
        #expect(button.midY == centerLine)
        #expect(title.minX == Layout.surfaceHeadingInset)
        #expect(abs(width - glyph.maxX - Layout.surfaceHeadingInset) <= Self.tolerance)
    }

    /// The changes panel's title and its buttons are centered on the
    /// heading line whether the counts sit beside the title or under it;
    /// the ×'s glyph ends 16pt in from the panel's edge, as the sidebar's
    /// ＋ does.
    @Test(arguments: [false, true])
    func changesHead_centersItsTitleLineOnTheHeadingLine(hasFilter: Bool) async throws {
        let width = Layout.changesPanelDefaultWidth
        let book = NamedFrameRecorder(space: Self.space)
        let view = ChangesPanelHeadLayout(summary: "1 turn · 1 unviewed", hasFilter: hasFilter) {
            Text(verbatim: "Changes")
                .font(LimpidFont.Supervision.surfaceHeading)
                .fixedSize()
                .recordFrame(in: book, as: "title")
        } buttons: {
            Button("Review Unviewed") {}
                .buttonStyle(.supervisionSecondary(size: .compact))
                .recordFrame(in: book, as: "button")
            Button {} label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .recordFrame(in: book, as: "close")
                    .frame(height: Layout.secondaryButtonCompactHeight)
            }
            .buttonStyle(.supervisionIcon)
        } filter: {
            Text(verbatim: "Claude 1 | Codex 0")
        }
        .padding(Layout.changesHeadInsets)
        .frame(width: width, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .top)
        let frames = try #require(await Self.layOut(view, width: width, height: 240, book: book, count: 3))
        let title = try #require(frames["title"])
        let button = try #require(frames["button"])
        let close = try #require(frames["close"])

        let centerLine = Layout.surfaceHeadingLineHeight / 2
        #expect(abs(title.midY - centerLine) <= Self.tolerance)
        #expect(button.midY == centerLine)
        #expect(abs(close.midY - centerLine) <= Self.tolerance)
        #expect(title.minX == Layout.surfaceHeadingInset)
        #expect(abs(width - close.maxX - Layout.surfaceHeadingInset) <= Self.tolerance)
    }

    // MARK: - The rails

    /// A rail's first button is centered on the heading line beside it, and
    /// its last on the foot bar's line, as the scratch row is.
    @Test func railEnds_sitOnTheHeadingLineAndTheFootBarLine() async throws {
        let book = NamedFrameRecorder(space: Self.space)
        let view = HStack(spacing: 0) {
            RailColumn {
                RailButton(systemImage: "list.bullet.rectangle", name: "Worktrees", shortcut: nil) {}
                    .recordFrame(in: book, as: "first")
                RailButton(systemImage: "bell", name: "Notification History", shortcut: nil) {}
            } bottom: {
                RailButton(systemImage: "keyboard", name: "Keyboard Shortcuts", shortcut: nil) {}
                    .recordFrame(in: book, as: "last")
            }
            VStack(spacing: 0) {
                SurfaceHeadingLine {
                    Text(verbatim: "Projects")
                } trailing: {
                    EmptyView()
                }
                .recordFrame(in: book, as: "heading")
                Spacer(minLength: 0)
                SidebarFootBar {
                    ScratchRowView(isActive: true, actions: SessionRowActions()) {}
                        .recordFrame(in: book, as: "scratch")
                }
            }
            .frame(width: Layout.sidebarDefaultWidth)
        }
        let width = Layout.railWidth + Layout.sidebarDefaultWidth
        // The scratch row's keyboard ring reads the accent from the store.
        let frames = try await withTempDir { directory in
            try #require(await Self.layOut(
                view.environment(SettingsStore(directory: directory)),
                width: width,
                height: 500,
                book: book,
                count: 4
            ))
        }
        let first = try #require(frames["first"])
        let last = try #require(frames["last"])
        let heading = try #require(frames["heading"])
        let scratch = try #require(frames["scratch"])

        #expect(heading.height == Layout.surfaceHeadingLineHeight)
        #expect(first.midY == heading.midY)
        #expect(last.midY == scratch.midY)
        #expect(last.midY == 500 - Layout.footBarHeight / 2)
    }

    // MARK: - The review's top edge

    /// At the review's minimum width the scope's line keeps its trailing
    /// controls inside the column, its inset clear, in either language and
    /// with the longest scopes: the dropdown gives way first.
    @Test(arguments: ["en", "ja"])
    func reviewScopeLine_fitsTheReviewsMinimumWidth(language: String) async throws {
        let locale = Locale(identifier: language)
        // A choice of one conversation's turns names the conversation too,
        // its badge and name before the choice.
        let conversation = ConversationChoice(
            conversation: TurnSummaryFixture.conversation("c12"),
            ordinal: 12,
            unviewedCount: 3
        )
        let scopes: [(ReviewScopeOption, ConversationChoice?)] = [
            (.uncommitted(includesChangesOutsideTurns: true), nil),
            (.branch(base: "feature/a-rather-long-branch-name-for-review"), nil),
            (.worktreeUnviewedTurns(.incomplete(1...4)), nil),
            (.unviewedTurns(.none), conversation)
        ]
        for (scope, conversation) in scopes {
            let width = LimpidLayout.reviewMinWidth
            let book = NamedFrameRecorder(space: Self.space)
            let review = fakeReviewSession(git: FakeReviewRepository())
            let view = ReviewTabScopeLayout(notes: []) {
                ReviewTabScopePicker(current: ReviewTabText.option(scope, locale: locale), conversation: conversation) { [] }
                    .recordFrame(in: book, as: "scope")
            } trailing: {
                ReviewSnapshotButtons(
                    reviewSession: review,
                    isInserting: false,
                    prompt: "",
                    isShowingPrompt: .constant(false),
                    onRefresh: {},
                    onJump: { _ in }
                )
                .recordFrame(in: book, as: "trailing")
            }
            .frame(width: width, alignment: .leading)
            .frame(maxHeight: .infinity, alignment: .top)
            .environment(\.locale, locale)
            let frames = try #require(await Self.layOut(view, width: width, height: 120, book: book, count: 2))
            let scopeFrame = try #require(frames["scope"])
            let trailing = try #require(frames["trailing"])

            #expect(trailing.maxX <= width - Layout.reviewTabTopInset)
            #expect(scopeFrame.minX == Layout.reviewTabTopInset)
            #expect(scopeFrame.maxX < trailing.minX)
        }
    }

    // MARK: - A row's name

    /// A label at rest is as wide as its text: the editing field is laid
    /// over the label and adds nothing to it, so a row's name starts where
    /// its second line does and a tab's title sits its spacing from its
    /// badge (`InlineRenameGeometryTests` pins the editing side).
    @Test func renameLabel_atRest_isAsWideAsItsText() {
        let font = Font.system(size: 13, weight: .medium)
        let label = InlineRenameField(
            name: "feature-login",
            isEditing: .constant(false),
            font: font,
            foregroundColor: .primary,
            fillsWidth: false
        )
        let text = Text(verbatim: "feature-login").font(font).lineLimit(1)
        #expect(Self.fittingWidth(of: label) == Self.fittingWidth(of: text))
    }

    // MARK: - Helpers

    nonisolated static let space = "surfaceHeadingTest"

    private static func fittingWidth(of view: some View) -> CGFloat {
        NSHostingView(rootView: view.fixedSize()).fittingSize.width
    }

    /// Lays `view` out in a window `width` by `height` and returns the
    /// frames recorded in it once `count` of them have settled.
    private static func layOut(
        _ view: some View,
        width: CGFloat,
        height: CGFloat,
        book: NamedFrameRecorder,
        count: Int
    ) async -> [String: CGRect]? {
        let (window, host) = hostedInWindow(
            view
                .frame(width: width, height: height, alignment: .topLeading)
                .coordinateSpace(.named(Self.space))
                .environment(\.locale, Locale(identifier: "en")),
            width: width,
            height: height
        )
        defer { window.close() }
        return await settledValue(in: host) { book.frames.count == count ? book.frames : nil }
    }
}
