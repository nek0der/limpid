// HeldBanners.swift
// Limpid — the banners held back after the Mac wakes, and what to post when the hold ends.

import Foundation

/// The agents' banners held back for a while (after the Mac wakes), by
/// identifier, so one taken back meanwhile is never posted.
struct HeldBanners<Banner> {
    enum Outcome {
        /// Nothing to post: nothing arrived, or all of it was taken back.
        case nothing
        /// One banner arrived; it is posted as it is.
        case single(Banner)
        /// Several arrived; one summary stands for them.
        case summary
    }

    private var banners: [(identifier: String, banner: Banner)] = []

    mutating func hold(_ banner: Banner, identifier: String) {
        banners.removeAll { $0.identifier == identifier }
        banners.append((identifier, banner))
    }

    /// Takes back a held banner, as `removeDeliveredNotifications` would
    /// take back a delivered one.
    mutating func drop(identifier: String) {
        banners.removeAll { $0.identifier == identifier }
    }

    var outcome: Outcome {
        switch banners.count {
        case 0: .nothing
        case 1: .single(banners[0].banner)
        default: .summary
        }
    }
}
