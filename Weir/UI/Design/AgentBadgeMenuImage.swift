// AgentBadgeMenuImage.swift
// Weir — an agent's badge, and the shell's mark, drawn as an image an AppKit menu's item can carry.

import AppKit
import SwiftUI
import WeirDomain

/// The badge every row draws for each agent, and the shell's mark, as
/// images a menu's items can carry: an AppKit menu draws no SwiftUI view. A
/// drawn image also keeps its own colors, where a symbol in the menu would
/// take the window's tint, the accent. The new worktree sheet's agent menu
/// and the menus of conversations (the changes panel's filter, the review's
/// scope menu) draw through here, so a badge reads alike in each, in the
/// appearance and at the scale the menu opens in.
///
/// Drawn when an item asks, and kept per appearance, so a menu has every
/// image the first time it is built. They were once drawn after the sheet's
/// first render, into the sheet's state: the menu's items were already
/// built by then, and its first opening showed the agents with no badge.
@MainActor
enum AgentBadgeMenuImage {
    /// What an image is drawn for.
    struct Appearance: Hashable {
        let colorScheme: ColorScheme
        let scale: CGFloat

        /// The app's appearance and the main screen's scale: what a menu
        /// built as it opens, outside any SwiftUI view, is drawn in.
        @MainActor static var current: Appearance {
            Appearance(
                colorScheme: NSApp.effectiveAppearance.isDark ? .dark : .light,
                scale: NSScreen.main?.backingScaleFactor ?? 2
            )
        }
    }

    private struct Key: Hashable {
        /// `nil` for the shell's mark.
        let kind: AgentKind?
        let size: SessionAgentBadge.Size
        /// The conversation's identity color drawn before the badge, `nil`
        /// for none.
        var identity: Int?
        let appearance: Appearance
    }

    /// A hundred or so at most: two appearances, a scale or two, two sizes,
    /// each agent with no bar or one of the identity colors, and the shell.
    private static var cache: [Key: NSImage] = [:]

    /// `kind`'s badge at `size`: `.regular` beside a field's choice (the new
    /// workspace's agent), `.row` beside a conversation's name. With an
    /// `identity`, the conversation's bar stands before the badge in the
    /// one image, as `ConversationIdentityLead` draws it in a view: a menu
    /// item carries a single image, and the bar drawn into it keeps the
    /// same side and gap as everywhere else.
    static func image(
        for kind: AgentKind,
        size: SessionAgentBadge.Size,
        identity: Int? = nil,
        in appearance: Appearance
    ) -> NSImage {
        let badge = SessionRowFact.Badge.agent(kind)
        return image(Key(kind: kind, size: size, identity: identity, appearance: appearance)) {
            ConversationIdentityLead(identity: identity) {
                // The badge's letters are the same in every language.
                SessionAgentBadge(badge: badge, text: SessionRowFactText.badge(badge, locale: .english), size: size)
            }
        }
    }

    /// The shell's mark in its quiet color, as a field and every other place
    /// a shell shows draw it, at the larger badge's height.
    static func shellImage(in appearance: Appearance) -> NSImage {
        image(Key(kind: nil, size: .regular, appearance: appearance)) {
            ShellPromptBadge()
                .frame(height: WeirLayout.Supervision.agentBadgeLargeHeight)
        }
    }

    private static func image(_ key: Key, @ViewBuilder content: () -> some View) -> NSImage {
        if let cached = cache[key] {
            return cached
        }
        let renderer = ImageRenderer(content: content().environment(\.colorScheme, key.appearance.colorScheme))
        renderer.scale = key.appearance.scale
        // `nil` only when the view cannot be drawn at all; an empty image
        // then, rather than a stand-in that reads as another agent.
        let image = renderer.nsImage ?? NSImage(size: .zero)
        cache[key] = image
        return image
    }
}
