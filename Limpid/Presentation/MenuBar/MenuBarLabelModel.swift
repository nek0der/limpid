// MenuBarLabelModel.swift
// Limpid — what the menu bar extra's icon shows: which lamp the attention state lights, and what VoiceOver says.

import Foundation

/// The menu bar extra's icon: a lamp that shows the state alone,
/// in the title bar pill's tone, and no count, since the menu bar is
/// shared with every other app and the popover's heading says the number.
/// Something that blocks on the person (an approval, a question, a wait
/// at the prompt, a stop) fills the ring; unread turns alone put a dot in
/// the ring; nothing leaves the ring empty.
struct MenuBarLabelModel: Equatable {
    /// Which lamp is lit. The menu bar takes one image for its item and
    /// draws a template in its own text color, which drops any other
    /// color (https://developer.apple.com/forums/thread/726565): the two
    /// template lamps differ in shape, so the meaning survives the loss.
    enum Lamp: Equatable, CaseIterable {
        /// Nothing needs attention: an empty ring.
        case off
        /// Only finished turns nobody has read: the ring with a dot at its
        /// center, as the pill's count turns blue, so the shape says it without the
        /// color the template drops.
        case unread
        /// Something blocks on the person: a solid disc, the ring filled,
        /// with an exclamation mark cut out of it, so it does not read as
        /// the ring with a dot at a glance.
        case blocking
    }

    let pill: NeedsAttentionPillModel

    init(_ counts: AttentionCounts) {
        pill = NeedsAttentionPillModel(counts)
    }

    /// The icon no longer shows it; VoiceOver and the menu's heading do.
    var count: Int {
        pill.count
    }

    /// The pill's tone, so the icon and the title bar never disagree on
    /// what the state means.
    var style: NeedsAttentionPillModel.Style {
        pill.style
    }

    var lamp: Lamp {
        switch style {
        case .blocking: .blocking
        case .unreadOnly: .unread
        case .empty: .off
        }
    }

    /// "Limpid, Needs Attention 3, 1 Approval, 2 Unread": the app, the
    /// count in the words of the pill's label, then its breakdown, each
    /// spoken as a pause. The count is here because the icon no longer
    /// shows it. No "·" anywhere, which a tooltip reads but VoiceOver says
    /// aloud as a symbol.
    func accessibilityLabel(locale: Locale) -> String {
        let spokenCount = LocalizedStringResource(
            "Needs Attention \(count)",
            comment: "Menu bar item, VoiceOver: the attention count, without the · the pill shows"
        ).resolved(in: locale)
        return AgentStatusText.spokenList(
            ["Limpid", spokenCount] + AttentionSummaryText.breakdown(pill.counts, locale: locale),
            locale: locale
        )
    }
}
