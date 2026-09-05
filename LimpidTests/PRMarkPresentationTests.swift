// PRMarkPresentationTests.swift
// Limpid — how a row's pull-request mark reflects the request.
//
// The mapping is pure, and it carries one rule that is easy to break
// by accident: there is a single badge slot, and a failing check has
// to win it. A merged request whose checks went red must show the
// failure, not the tick — otherwise the row reports success while CI
// is saying the opposite.
//
// Whether a mark is drawn at all is decided elsewhere
// (`PRInfo.needsAttention` plus the Settings toggle), so every case
// here assumes something already asked for one.

import SwiftUI
import Testing
@testable import Limpid

@Suite("PRMarkPresentation")
struct PRMarkPresentationTests {
    private let accent = Color.blue

    /// A row with no request draws no mark at all, so the row looks
    /// exactly as it did before this feature existed.
    @Test("no request resolves to no style")
    func style_nilInfo_isNil() {
        #expect(PRMarkPresentation.style(for: nil, accent: accent) == nil)
    }

    @Test("an open request takes the accent it is handed")
    func style_open_usesSuppliedAccent() throws {
        let style = try #require(PRMarkPresentation.style(for: PRInfoFixture.make(state: .open), accent: accent))
        #expect(style.tint == accent)
        #expect(style.badge == nil)
    }

    /// Every state draws a different glyph, so none of them depends on
    /// tint to be told apart. That matters twice over: the accent is
    /// user-configurable, so someone who picks purple would otherwise
    /// see open and merged render alike, and colour-only encoding
    /// fails anyone who cannot separate the hues at all.
    ///
    /// Two earlier symbol sets could not hold this — one had no
    /// four-variant family, the other no hollow or filled variants —
    /// which is the reason the glyphs are bundled assets now.
    @Test("each state draws its own glyph")
    func style_states_haveDistinctGlyphs() throws {
        let glyphs = try [
            PRMarkPresentation.style(for: PRInfoFixture.make(state: .open), accent: accent),
            PRMarkPresentation.style(for: PRInfoFixture.make(isDraft: true), accent: accent),
            PRMarkPresentation.style(for: PRInfoFixture.make(state: .merged), accent: accent),
            PRMarkPresentation.style(for: PRInfoFixture.make(state: .closed), accent: accent)
        ].map { try #require($0).glyph }
        #expect(Set(glyphs).count == glyphs.count)
    }

    /// Nothing but a failing check earns the badge slot, so a healthy
    /// row carries exactly one mark.
    @Test(
        "a healthy request carries no badge",
        arguments: [PRState.open, .merged, .closed]
    )
    func style_healthyStates_carryNoBadge(state: PRState) throws {
        let style = try #require(PRMarkPresentation.style(for: PRInfoFixture.make(state: state), accent: accent))
        #expect(style.badge == nil)
    }

    /// The rule this suite exists for.
    @Test(
        "a failing check outranks the state badge",
        arguments: [PRState.open, .merged, .closed]
    )
    func style_failingChecks_winTheBadgeSlot(state: PRState) throws {
        let style = try #require(PRMarkPresentation.style(
            for: PRInfoFixture.make(state: state, checks: .failure),
            accent: accent
        ))
        #expect(style.badge?.glyph == "x-circle-fill")
    }

    /// Passing and running checks must not claim the slot — only a
    /// failure is worth a second mark on the row.
    @Test(
        "non-failing checks add no badge",
        arguments: [PRChecksConclusion.success, .pending],
        [PRState.open, .merged, .closed]
    )
    func style_nonFailingChecks_addNoBadge(
        conclusion: PRChecksConclusion,
        state: PRState
    ) throws {
        let style = try #require(PRMarkPresentation.style(
            for: PRInfoFixture.make(state: state, checks: conclusion),
            accent: accent
        ))
        #expect(style.badge == nil)
    }

    /// The spoken label is the only channel a VoiceOver user has, so
    /// two states must never resolve to the same one. Nothing else
    /// here would catch a copy-paste that left `.merged` announcing
    /// "PR open": `style_states_haveDistinctGlyphs` compares glyphs,
    /// and `style_draft_doesNotMaskTerminalState` asserts two keys are
    /// *equal*.
    @Test("each state speaks its own label")
    func style_states_haveDistinctAccessibilityKeys() throws {
        let keys = try [
            PRMarkPresentation.style(for: PRInfoFixture.make(state: .open), accent: accent),
            PRMarkPresentation.style(for: PRInfoFixture.make(isDraft: true), accent: accent),
            PRMarkPresentation.style(for: PRInfoFixture.make(state: .merged), accent: accent),
            PRMarkPresentation.style(for: PRInfoFixture.make(state: .closed), accent: accent)
        ].map { try #require($0).accessibilityKey.key }
        #expect(Set(keys).count == keys.count)
    }

    /// Draft modulates the open state rather than replacing it: the
    /// request exists, but nobody is waiting on it yet. Both channels
    /// move — the glyph goes hollow *and* the tint drops off the
    /// accent — so the distinction survives for a reader who cannot
    /// separate the hues.
    @Test("draft differs from open in both glyph and tint")
    func style_draft_modulatesOpen() throws {
        let draft = try #require(PRMarkPresentation.style(for: PRInfoFixture.make(isDraft: true), accent: accent))
        let open = try #require(PRMarkPresentation.style(for: PRInfoFixture.make(state: .open), accent: accent))
        #expect(draft.glyph != open.glyph)
        #expect(draft.tint != open.tint)
        #expect(draft.badge == nil)
    }

    /// The flag must not mask a finished request. A draft that was
    /// closed is closed, and both forges present it that way.
    @Test(
        "a terminal state outranks the draft flag",
        arguments: [PRState.merged, .closed]
    )
    func style_draft_doesNotMaskTerminalState(state: PRState) throws {
        let drafted = try #require(PRMarkPresentation.style(
            for: PRInfoFixture.make(state: state, isDraft: true),
            accent: accent
        ))
        let plain = try #require(PRMarkPresentation.style(for: PRInfoFixture.make(state: state), accent: accent))
        #expect(drafted.glyph == plain.glyph)
        #expect(drafted.accessibilityKey.key == plain.accessibilityKey.key)
    }
}
