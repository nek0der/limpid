// PRMarkPresentationTests.swift
// Weir — how a row's pull-request mark reflects the request.
//
// The mapping is pure, and it carries one rule that is easy to break
// by accident: the corner badge follows the checks whatever the
// request's state. A merged request whose checks went red must show the
// failure — otherwise the row reports success while CI is saying the
// opposite. Each outcome draws and speaks its own badge, and a request
// with no checks draws none.
//
// Whether a mark is drawn at all is the row's
// (`SessionRowFact.pullRequest`), so every case here assumes
// something already asked for one.

import AppKit
import SwiftUI
import Testing
@testable import Weir

@Suite("PRMarkPresentation")
struct PRMarkPresentationTests {
    /// A row with no request draws no mark at all.
    @Test("no request resolves to no style")
    func supervisionStyle_nilInfo_isNil() {
        #expect(PRMarkPresentation.supervisionStyle(for: nil) == nil)
    }

    /// Every state draws its own shape, so none of them depends on a hue
    /// to be told apart (a request has no color of its own). The spoken label
    /// is the only channel a VoiceOver user has, so two states never
    /// resolve to the same one either.
    @Test("the supervision mark draws and speaks each state its own way")
    func supervisionStyle_states_haveTheirOwnKindAndLabel() throws {
        let styles = try [
            PRMarkPresentation.supervisionStyle(for: PRInfoFixture.make(state: .open)),
            PRMarkPresentation.supervisionStyle(for: PRInfoFixture.make(isDraft: true)),
            PRMarkPresentation.supervisionStyle(for: PRInfoFixture.make(state: .merged)),
            PRMarkPresentation.supervisionStyle(for: PRInfoFixture.make(state: .closed))
        ].map { try #require($0) }
        #expect(styles.map(\.kind) == [.open, .draft, .merged, .closed])
        let keys = styles.map(\.accessibilityKey.key)
        #expect(Set(keys).count == keys.count)
    }

    /// The rule this suite exists for: each outcome of the checks draws
    /// its own badge in every state of the request, and speaks it, since
    /// color and shape would otherwise be its only channels.
    @Test(
        "each outcome of the checks draws and speaks its own badge",
        arguments: [
            CheckCase(conclusion: .failure, kind: .failing, key: "Checks failing"),
            CheckCase(conclusion: .pending, kind: .running, key: "Checks running"),
            CheckCase(conclusion: .success, kind: .passing, key: "Checks passed")
        ],
        [(PRState.open, false), (.open, true), (.merged, false), (.closed, false)]
    )
    func supervisionStyle_checks_drawTheirOwnBadge(check: CheckCase, request: (state: PRState, isDraft: Bool)) throws {
        let style = try #require(PRMarkPresentation.supervisionStyle(
            for: PRInfoFixture.make(state: request.state, isDraft: request.isDraft, checks: check.conclusion)
        ))
        let badge = try #require(style.badge)
        #expect(badge.kind == check.kind)
        #expect(badge.accessibilityKey.key == check.key)
    }

    /// No checks means nothing to report, so the corner stays empty
    /// rather than claiming a pass.
    @Test(
        "a request without checks carries no badge",
        arguments: [(PRState.open, false), (.open, true), (.merged, false), (.closed, false)]
    )
    func supervisionStyle_noChecks_addNoBadge(state: PRState, isDraft: Bool) throws {
        let style = try #require(PRMarkPresentation.supervisionStyle(
            for: PRInfoFixture.make(state: state, isDraft: isDraft, checks: nil)
        ))
        #expect(style.badge == nil)
    }

    /// The flag must not mask a finished request. A draft that was
    /// closed is closed, and both forges present it that way.
    @Test(
        "a terminal state outranks the draft flag",
        arguments: [PRState.merged, .closed]
    )
    func supervisionStyle_draft_doesNotMaskTerminalState(state: PRState) throws {
        let drafted = try #require(PRMarkPresentation.supervisionStyle(for: PRInfoFixture.make(state: state, isDraft: true)))
        let plain = try #require(PRMarkPresentation.supervisionStyle(for: PRInfoFixture.make(state: state)))
        #expect(drafted.kind == plain.kind)
        #expect(drafted.accessibilityKey.key == plain.accessibilityKey.key)
    }

    /// The supervision UI adds no color for a request: every state is
    /// muted and told apart by its drawing.
    @Test(
        "the supervision mark is muted in every state",
        arguments: [(PRState.open, false), (.open, true), (.merged, false), (.closed, false)]
    )
    @MainActor
    func supervisionStyle_isMutedInEveryState(state: PRState, isDraft: Bool) throws {
        let style = try #require(PRMarkPresentation.supervisionStyle(
            for: PRInfoFixture.make(state: state, isDraft: isDraft)
        ))
        // Each token's color is made afresh, so the two are compared as
        // they are drawn, in both appearances.
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try #require(NSAppearance(named: name))
            let tint = try #require(SRGB(NSColor(style.tint), in: appearance))
            #expect(Self.isSame(tint, SupervisionTokens.muted.value(isDark: name == .darkAqua)))
        }
    }

    /// Only the checks are colored: a failure in the stopped glyph's red,
    /// since both are failures; a run in the waiting color, since it is
    /// something to wait on; and a pass in the hover card's green.
    @Test(
        "each outcome of the checks takes its own color",
        arguments: [
            (PRChecksConclusion.failure, SupervisionTokens.stopped),
            (.pending, SupervisionTokens.waiting),
            (.success, SupervisionTokens.added)
        ]
    )
    @MainActor
    func supervisionStyle_checks_takeTheirColor(conclusion: PRChecksConclusion, token: ThemedColor) throws {
        let style = try #require(PRMarkPresentation.supervisionStyle(for: PRInfoFixture.make(checks: conclusion)))
        let badge = try #require(style.badge)
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try #require(NSAppearance(named: name))
            let badgeColor = try #require(SRGB(NSColor(badge.color), in: appearance))
            #expect(Self.isSame(badgeColor, token.value(isDark: name == .darkAqua)))
        }
    }

    /// One outcome of the checks, the badge it draws, and what it speaks.
    struct CheckCase: Sendable, CustomTestStringConvertible {
        let conclusion: PRChecksConclusion
        let kind: PRMarkPresentation.BadgeKind
        let key: String

        var testDescription: String {
            key
        }
    }

    /// The same color, within what a round trip through AppKit may move it.
    private static func isSame(_ lhs: SRGB, _ rhs: SRGB) -> Bool {
        abs(lhs.red - rhs.red) < 0.002 && abs(lhs.green - rhs.green) < 0.002 && abs(lhs.blue - rhs.blue) < 0.002
    }
}
