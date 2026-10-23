// AttentionEffect.swift
// Limpid — the side effects an attention change asks for, as values.

import Foundation

/// A side effect the attention rules ask for. The rules return these rather
/// than performing them, so they stay testable without VoiceOver, the
/// notification center, or the Dock; the app performs them.
enum AttentionEffect: Equatable, Sendable {
    /// Read the item out with VoiceOver.
    case announce(AttentionItemID)
    /// Post a notification for the item: a request that just arrived. The
    /// app posts it only while the request's pane is out of sight.
    case notify(AttentionItemID)
}
