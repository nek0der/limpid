// AttentionSummaryText.swift
// Weir — the attention count in words: the banner after a wake, and the pill's breakdown.

import Foundation
import WeirDomain

/// "Needs Attention · 3" over "1 Approval · 2 Unread", in the words the
/// title bar uses.
enum AttentionSummaryText {
    /// `nil` when nothing needs attention, which posts nothing.
    static func make(_ counts: AttentionCounts, locale: Locale) -> (title: String, body: String)? {
        guard counts.total > 0 else { return nil }
        let title = NeedsAttentionPillModel.label(counts.total).resolved(in: locale)
        return (title, AgentStatusText.joined(breakdown(counts, locale: locale), locale: locale))
    }

    /// The count by kind, leaving out the kinds with none: "1 Approval",
    /// "2 Unread". The banner after a wake and the title bar pill's tooltip
    /// read the same words.
    static func breakdown(_ counts: AttentionCounts, locale: Locale) -> [String] {
        var parts: [String] = []
        if counts.approvals > 0 {
            parts.append(LocalizedStringResource("\(counts.approvals) Approval", comment: "Attention count by kind").resolved(in: locale))
        }
        // A wait at the agent's prompt we cannot name, as its row names it.
        if counts.prompts > 0 {
            parts.append(LocalizedStringResource(
                "\(counts.prompts) Response",
                comment: "Attention count by kind: waits at the agent's prompt that are neither a known approval nor a known question"
            ).resolved(in: locale))
        }
        if counts.signIns > 0 {
            parts.append(LocalizedStringResource(
                "\(counts.signIns) Sign-in",
                comment: "Attention count by kind: agents waiting for the person to sign in again"
            ).resolved(in: locale))
        }
        if counts.questions > 0 {
            parts.append(LocalizedStringResource("\(counts.questions) Question", comment: "Attention count by kind").resolved(in: locale))
        }
        if counts.stops > 0 {
            parts.append(LocalizedStringResource("\(counts.stops) Stopped", comment: "Attention count by kind").resolved(in: locale))
        }
        if counts.unread > 0 {
            parts.append(LocalizedStringResource("\(counts.unread) Unread", comment: "Attention count by kind").resolved(in: locale))
        }
        return parts
    }
}
