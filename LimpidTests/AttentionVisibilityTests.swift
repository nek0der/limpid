// AttentionVisibilityTests.swift
// Limpid — whether the person sees a pane, and whether a request may go to its agent's own prompt.

import Foundation
import Testing
@testable import Limpid

struct AttentionVisibilityTests {
    static let pane = UUID()
    static let other = UUID()

    private static func visibility(
        attended: Set<UUID>,
        isAppActive: Bool,
        isVoiceOverRunning: Bool
    ) -> AttentionVisibility {
        AttentionVisibility(attendedPanes: attended, isAppActive: isAppActive, isVoiceOverRunning: isVoiceOverRunning)
    }

    /// Seen while Limpid is in front and a window attends the pane; a pane
    /// minimized, hidden, covered, zoomed out, or under the review is left
    /// out of the attended set. VoiceOver does not change what is seen.
    @Test(arguments: [
        (Set([pane]), true, false, true),
        (Set([pane]), false, false, false),
        (Set<UUID>(), true, false, false),
        (Set([pane]), true, true, true)
    ])
    func aPane_isSeen_whileLimpidIsInFrontAndAWindowAttendsIt(
        attended: Set<UUID>,
        isAppActive: Bool,
        isVoiceOverRunning: Bool,
        isSeen: Bool
    ) {
        let visibility = Self.visibility(attended: attended, isAppActive: isAppActive, isVoiceOverRunning: isVoiceOverRunning)
        #expect(visibility.isSeen(Self.pane) == isSeen)
    }

    /// A request goes to the agent's prompt when any pane it is attached
    /// to is seen (tmux attaches one to several), and is held with no known
    /// pane, under VoiceOver, with another app in front, or with no pane
    /// of its seen.
    @Test(arguments: [
        (Set([pane]), true, false, [pane], true),
        (Set([pane]), true, false, [other, pane], true),
        (Set([pane]), true, false, [UUID](), false),
        (Set([pane]), true, true, [pane], false),
        (Set([pane]), false, false, [pane], false),
        (Set([other]), true, false, [pane], false)
    ])
    func aRequest_isHandedOff_onlyToASeenPane_withoutVoiceOver(
        attended: Set<UUID>,
        isAppActive: Bool,
        isVoiceOverRunning: Bool,
        panes: [UUID],
        allowsHandOff: Bool
    ) {
        let visibility = Self.visibility(attended: attended, isAppActive: isAppActive, isVoiceOverRunning: isVoiceOverRunning)
        #expect(visibility.allowsHandOff(toAnyOf: panes) == allowsHandOff)
    }
}
