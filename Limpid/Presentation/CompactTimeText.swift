// CompactTimeText.swift
// Limpid — a time in one short unit, as the sidebar's and the changes panel's columns say it.

import Foundation

/// A time in one whole unit: "40s", "12m", "3h", "2d"; 「40秒」「12分」
/// 「3時間」「2日」. The sidebar's time since a row last moved and a turn
/// card's duration count different things, but they sit in the same
/// window, so they share these words: two ways of writing a unit read as
/// two rules. Each caller picks the unit; this only words it.
enum CompactTimeText {
    static func seconds(_ value: Int, locale: Locale) -> String {
        LocalizedStringResource(
            "duration.compact.seconds",
            defaultValue: "\(value)s",
            comment: "A time in one short unit, under a minute (a turn card's duration); argument: the whole seconds"
        ).resolved(in: locale)
    }

    static func minutes(_ value: Int, locale: Locale) -> String {
        LocalizedStringResource(
            "duration.compact.minutes",
            defaultValue: "\(value)m",
            comment: "A time in one short unit, in minutes (a turn card's duration, a sidebar row's time since); argument: the minutes"
        ).resolved(in: locale)
    }

    static func hours(_ value: Int, locale: Locale) -> String {
        LocalizedStringResource(
            "duration.compact.hours",
            defaultValue: "\(value)h",
            comment: "A time in one short unit, in hours (a turn card's duration, a sidebar row's time since); argument: the hours"
        ).resolved(in: locale)
    }

    static func days(_ value: Int, locale: Locale) -> String {
        LocalizedStringResource(
            "duration.compact.days",
            defaultValue: "\(value)d",
            comment: "A time in one short unit, in days (the sidebar's time since a row last moved); argument: the whole days"
        ).resolved(in: locale)
    }

    /// Less than a minute ago, where the sidebar counts no seconds.
    static func now(locale: Locale) -> String {
        LocalizedStringResource(
            "duration.compact.now",
            defaultValue: "now",
            comment: "Sidebar row: its agent moved less than a minute ago, in the column that says the time since"
        ).resolved(in: locale)
    }
}
