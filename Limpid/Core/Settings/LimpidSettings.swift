// LimpidSettings.swift
// Limpid — Codable shape for everything the Settings UI writes plus
// everything the GhosttyConfigBridge consumes when it builds the
// libghostty config string. One JSON file (settings.json) is the
// single source of truth: UI changes write it, the file watcher
// re-reads it, and downstream code observes the in-memory mirror via
// `SettingsStore.settings`.
//
// Each section's structure mirrors a Settings sidebar pane (see
// `SettingsSection`). Default values are set so a fresh install
// produces a sensible Liquid Glass terminal without the user opening
// Settings at all.

import Foundation

// MARK: - Top-level container

/// Versioned root document persisted to `settings.json`. The
/// `schemaVersion` lets the loader migrate an older file forward
/// (`VersionedDocumentMigrator.settings`); a newer one is read as is.
struct LimpidSettings: Codable, Equatable {
    var schemaVersion: Int = currentSchemaVersion
    var appearance: AppearanceSettings = .init()
    var font: FontSettings = .init()
    var terminal: TerminalSettings = .init()
    var keyboard: KeyboardSettings = .init()
    var confirmations: ConfirmationSettings = .init()
    var advanced: AdvancedSettings = .init()
    var quickTerminal: QuickTerminalSettings = .init()
    var review: ReviewSettings = .init()
    var general: GeneralSettings = .init()
    var newSession: NewSessionSettings = .init()
    var jumpOpensTurnReview = true

    /// Trailing root-level keys the current build doesn't recognize.
    /// Preserved across decode → encode so a newer build's writes
    /// survive a Sparkle rollback to an older one. See `LimpidJSONValue`.
    var unknownFields: [String: LimpidJSONValue] = [:]

    /// 2: the supervision window's keyboard actions, with `unbound` and
    /// `retired` (`LimpidSettings.migrateFromV1`).
    static let currentSchemaVersion = 2

    static let `default` = LimpidSettings()

    init() {}

    /// Hand-rolled decoder specifically so a `settings.json` written
    /// before `keyboard` existed still loads cleanly — synthesized
    /// Codable would throw `keyNotFound` and discard every other
    /// section the user has carefully tuned. Note that `appearance`
    /// / `font` / `terminal` / `advanced` are still `decode` (not
    /// `decodeIfPresent`): they predate this PR and are always
    /// written by `saveNow`, so a missing one means the file is
    /// genuinely corrupt. New optional sections added later should
    /// follow `keyboard`'s pattern (decodeIfPresent + default init).
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion)
            ?? Self.currentSchemaVersion
        self.appearance = try c.decode(AppearanceSettings.self, forKey: .appearance)
        self.font = try c.decode(FontSettings.self, forKey: .font)
        self.terminal = try c.decode(TerminalSettings.self, forKey: .terminal)
        self.keyboard = try c.decodeIfPresent(KeyboardSettings.self, forKey: .keyboard) ?? .init()
        self.confirmations = try c.decodeIfPresent(
            ConfirmationSettings.self, forKey: .confirmations
        ) ?? .init()
        self.advanced = try c.decode(AdvancedSettings.self, forKey: .advanced)
        self.quickTerminal = try c.decodeIfPresent(
            QuickTerminalSettings.self, forKey: .quickTerminal
        ) ?? .init()
        self.review = try c.decodeIfPresent(ReviewSettings.self, forKey: .review) ?? .init()
        self.general = try c.decodeIfPresent(GeneralSettings.self, forKey: .general) ?? .init()
        self.newSession = try c.decodeIfPresent(NewSessionSettings.self, forKey: .newSession) ?? .init()
        self.jumpOpensTurnReview = try c.decodeIfPresent(
            Bool.self,
            forKey: .jumpOpensTurnReview
        ) ?? true
        self.unknownFields = try CodableSidecar.decodeUnknownFields(
            from: decoder,
            knownKeys: Self.knownKeyStrings
        )
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(appearance, forKey: .appearance)
        try c.encode(font, forKey: .font)
        try c.encode(terminal, forKey: .terminal)
        try c.encode(keyboard, forKey: .keyboard)
        try c.encode(confirmations, forKey: .confirmations)
        try c.encode(advanced, forKey: .advanced)
        try c.encode(quickTerminal, forKey: .quickTerminal)
        try c.encode(review, forKey: .review)
        try c.encode(general, forKey: .general)
        try c.encode(newSession, forKey: .newSession)
        try c.encode(jumpOpensTurnReview, forKey: .jumpOpensTurnReview)
        try CodableSidecar.encodeUnknownFields(unknownFields, to: encoder)
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion, appearance, font, terminal, keyboard, confirmations, advanced, quickTerminal
        case review, general, newSession, jumpOpensTurnReview
    }

    private static let knownKeyStrings: Set<String> = Set(CodingKeys.allCases.map(\.stringValue))
}

// MARK: - Confirmations

/// Tri-state policy for destructive actions (⌘Q, tab/pane close).
/// `onlyWhenAgent` consults the live-agent predicate; the modal body
/// always reflects actual state (agent-specific copy iff an agent is
/// live), so `always` without an agent renders a plain "Close this tab?"
/// without misleading agent copy.
enum ConfirmPolicy: String, Codable, CaseIterable {
    case never
    /// Raw value kept as `dirtyOnly` so existing `settings.json` files
    /// written under the prior name still decode cleanly.
    case onlyWhenAgent = "dirtyOnly"
    case always

    /// Default applied when a `settings.json` carries a raw value this
    /// build doesn't recognize — typically a newer Limpid that added a
    /// case the user later downgraded away from. Matches the in-code
    /// default for every confirmation field so the fallback is the
    /// least-surprising option.
    static let unknownFallback: ConfirmPolicy = .onlyWhenAgent

    init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ConfirmPolicy(rawValue: raw) ?? .unknownFallback
    }
}

/// Per-action confirmation policy. The keyboard / mouse split for tab
/// close is intentional: the × button is the most mis-clicked
/// affordance in the app and warrants its own knob so the user can
/// keep it strict while leaving deliberate ⌘W / ⌘⌥W untouched. Pane
/// close has only a keyboard path today, so there's no mouse twin.
///
/// Every close path — SwiftUI menu, libghostty's `close_tab` action,
/// a pane strip tab's × button — funnels through `CloseConfirmer`, which consults
/// the right field below based on the request's `(kind, source)`. So
/// a new caller can't accidentally bypass confirmation by reaching
/// for `session.closeTab` directly.
struct ConfirmationSettings: Codable, Equatable {
    var quit: ConfirmPolicy = .onlyWhenAgent
    var closeTabKeyboard: ConfirmPolicy = .onlyWhenAgent
    var closeTabMouse: ConfirmPolicy = .onlyWhenAgent
    var closePane: ConfirmPolicy = .onlyWhenAgent

    /// See `LimpidSettings.unknownFields`.
    var unknownFields: [String: LimpidJSONValue] = [:]

    init() {}

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.quit = try c.decodeIfPresent(
            ConfirmPolicy.self, forKey: .quit
        ) ?? .onlyWhenAgent
        self.closeTabKeyboard = try c.decodeIfPresent(
            ConfirmPolicy.self, forKey: .closeTabKeyboard
        ) ?? .onlyWhenAgent
        self.closeTabMouse = try c.decodeIfPresent(
            ConfirmPolicy.self, forKey: .closeTabMouse
        ) ?? .onlyWhenAgent
        self.closePane = try c.decodeIfPresent(
            ConfirmPolicy.self, forKey: .closePane
        ) ?? .onlyWhenAgent
        self.unknownFields = try CodableSidecar.decodeUnknownFields(
            from: decoder,
            knownKeys: Self.knownKeyStrings
        )
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(quit, forKey: .quit)
        try c.encode(closeTabKeyboard, forKey: .closeTabKeyboard)
        try c.encode(closeTabMouse, forKey: .closeTabMouse)
        try c.encode(closePane, forKey: .closePane)
        try CodableSidecar.encodeUnknownFields(unknownFields, to: encoder)
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case quit, closeTabKeyboard, closeTabMouse, closePane
    }

    private static let knownKeyStrings: Set<String> = Set(CodingKeys.allCases.map(\.stringValue))
}

// MARK: - Appearance

/// Whether the window's surfaces (the rails, the panels, the window
/// backdrop) render with Liquid Glass. Currently a two-state knob; the enum
/// shape lets a future `medium` / `auto` value land without rewriting
/// the wire format (the boolean trap the schema-anti-pattern study
/// flagged for every two-state flag in `settings.json`).
enum TransparencyMode: String, Codable, CaseIterable {
    case off
    case on

    static let unknownFallback: TransparencyMode = .on

    /// Convenience for call sites that historically read a `Bool` —
    /// keeps `if settings.appearance.transparency.isOn { … }` short.
    var isOn: Bool {
        self == .on
    }

    init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = TransparencyMode(rawValue: raw) ?? .unknownFallback
    }
}

struct AppearanceSettings: Codable, Equatable {
    /// The single accent color painted on focus rings, drop targets,
    /// active row pills, and other single-point highlights. We follow the
    /// "5% rule": one accent per screen, used
    /// sparingly. The actual `Color` is resolved by
    /// `LimpidColor.accent(for:)` so callers don't have to know about
    /// the enum.
    var accentColor: AccentColor = .default

    /// Terminal pane background opacity (0.0 fully transparent
    /// through to 1.0 opaque). We keep this independent of the
    /// surrounding surfaces' Liquid Glass: they are always Material
    /// (or solid when `transparency` resolves to off), the pane sits
    /// on top with its own opacity so the user can read terminal
    /// content against the wallpaper.
    var backgroundOpacity: Double = 0.92

    /// Whether the window's surfaces (the rails, the panels, the window
    /// backdrop — not the terminal pane) use Liquid Glass. macOS Accessibility's
    /// "Reduce Transparency" always wins: when the system flag is on,
    /// AppKit renders vibrancy opaque and strips Liquid Glass no matter
    /// what we ask for, so this toggle only has an effect while that
    /// system setting is off. See `ReduceTransparencyResolver`.
    var transparency: TransparencyMode = .on

    /// User-chosen color scheme. `.system` follows the macOS
    /// Appearance preference; `.light` / `.dark` pin Limpid (both
    /// SwiftUI toolbar via `NSApp.appearance` and libghostty's bundled
    /// theme) regardless of the OS setting.
    var colorScheme: ColorSchemePreference = .system

    /// Opacity painted on every unfocused leaf when a tab carries more
    /// than one pane (single-pane tabs and zoomed leaves stay at 1.0).
    /// Default mirrors ghostty's GTK `unfocused-split-opacity` (0.7);
    /// floor matches its 0.15 clamp so the unfocused pane is always
    /// at least readable. Applied SwiftUI-side because libghostty
    /// only honors the config knob inside its own internal split UI,
    /// which Limpid doesn't use.
    var unfocusedPaneOpacity: Double = 0.7

    /// See `LimpidSettings.unknownFields`.
    var unknownFields: [String: LimpidJSONValue] = [:]

    /// We ship a defensive `init(from:)` (matching `Terminal` /
    /// `Keyboard` / `Confirmations`) so older `settings.json` files
    /// decode cleanly when a new field is added or an old one renamed,
    /// instead of throwing and falling back to a fresh defaults
    /// document that would also wipe the user's `accentColor`,
    /// `backgroundOpacity`, and `transparency`. Every field here is a
    /// visible Settings choice — losing them mid-upgrade is the kind
    /// of regression a user notices immediately.
    init() {}

    init(from decoder: any Decoder) throws {
        // Every field defaults if absent (forward compatibility). There is no
        // back-compat migration — the schema starts fresh at v1.
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.accentColor = try c.decodeIfPresent(AccentColor.self, forKey: .accentColor) ?? .default
        self.backgroundOpacity = try c.decodeIfPresent(Double.self, forKey: .backgroundOpacity) ?? 0.92
        self.transparency = try c.decodeIfPresent(TransparencyMode.self, forKey: .transparency) ?? .on
        self.colorScheme = try c.decodeIfPresent(ColorSchemePreference.self, forKey: .colorScheme) ?? .system
        let rawUnfocused = try c.decodeIfPresent(Double.self, forKey: .unfocusedPaneOpacity) ?? 0.7
        self.unfocusedPaneOpacity = min(1.0, max(0.15, rawUnfocused))
        self.unknownFields = try CodableSidecar.decodeUnknownFields(
            from: decoder,
            knownKeys: Self.knownKeyStrings
        )
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(accentColor, forKey: .accentColor)
        try c.encode(backgroundOpacity, forKey: .backgroundOpacity)
        try c.encode(transparency, forKey: .transparency)
        try c.encode(colorScheme, forKey: .colorScheme)
        try c.encode(unfocusedPaneOpacity, forKey: .unfocusedPaneOpacity)
        try CodableSidecar.encodeUnknownFields(unknownFields, to: encoder)
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case accentColor
        case backgroundOpacity
        case transparency
        case colorScheme
        case unfocusedPaneOpacity
    }

    private static let knownKeyStrings: Set<String> = Set(CodingKeys.allCases.map(\.stringValue))
}

/// User Appearance preference, mirrored after macOS 26 System
/// Settings ("Appearance"). `.system` follows the OS; the other two
/// pin Limpid regardless of the OS setting.
enum ColorSchemePreference: String, Codable, CaseIterable {
    case system
    case light
    case dark
}

/// Curated accent palette painted on focus rings, drop targets, and
/// other single-point toolbar highlights. Lineup mirrors macOS Tahoe's
/// own Accent Color (minus Graphite — a neutral gray reads as "no
/// accent" against Limpid's already-gray toolbar and adds noise to the
/// picker), so the choice feels familiar. `.default` defers to
/// Limpid's stock accent (light indigo / dark mint); the named cases
/// pin a specific hue. Replaces the older `WindowTint` atmosphere
/// enum, which washed the tab and terminal columns in a colored fill so faint
/// it barely registered; an accent point used sparingly (per the 5%
/// rule) is more visible and matches industry shape.
enum AccentColor: String, Codable, CaseIterable {
    case `default`
    case blue
    case purple
    case pink
    case red
    case orange
    case yellow
    case green

    /// Defensive decoder: an unknown raw value (e.g. a `graphite`
    /// settings.json written by a pre-release build, or a future case
    /// rolled back) falls back to `.default` instead of poisoning the
    /// whole `AppearanceSettings` decode with a `DecodingError`.
    init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = AccentColor(rawValue: raw) ?? .default
    }

}

// MARK: - Font

struct FontSettings: Codable, Equatable {
    /// PostScript family name. `nil` = the Ghostty config's family when
    /// that file is read, else libghostty's embedded JetBrains Mono
    /// (`GhosttyUserConfig.defaultFontFamily`). The picker only offers
    /// monospace families.
    var family: String?

    /// Font size in points. Live-reloadable — libghostty resizes the
    /// surface grid on the fly.
    var size: Double = 13

    /// Enable ligatures for fonts that ship contextual alternates
    /// (Fira Code, JetBrains Mono, Cascadia Code…). Many monospaced
    /// fonts ignore this even when on. Requires a new terminal —
    /// libghostty's font atlas is built at surface init.
    var ligatures: Bool = false

    /// Extra pixels added to the cell's natural line height. Useful
    /// for fonts that pack glyphs too tightly to read comfortably.
    /// Range: -4 ... +10 (`FontPane.lineSpacingRange`).
    var lineHeight: Double = 0

    /// See `LimpidSettings.unknownFields`.
    var unknownFields: [String: LimpidJSONValue] = [:]

    init() {}

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.family = try c.decodeIfPresent(String.self, forKey: .family)
        self.size = try c.decodeIfPresent(Double.self, forKey: .size) ?? 13
        self.ligatures = try c.decodeIfPresent(Bool.self, forKey: .ligatures) ?? false
        self.lineHeight = try c.decodeIfPresent(Double.self, forKey: .lineHeight) ?? 0
        self.unknownFields = try CodableSidecar.decodeUnknownFields(
            from: decoder,
            knownKeys: Self.knownKeyStrings
        )
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(family, forKey: .family)
        try c.encode(size, forKey: .size)
        try c.encode(ligatures, forKey: .ligatures)
        try c.encode(lineHeight, forKey: .lineHeight)
        try CodableSidecar.encodeUnknownFields(unknownFields, to: encoder)
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case family, size, ligatures, lineHeight
    }

    private static let knownKeyStrings: Set<String> = Set(CodingKeys.allCases.map(\.stringValue))
}

// MARK: - Terminal

struct TerminalSettings: Codable, Equatable {
    static let defaultMinPaneSize: Double = 80
    /// What one click of the Settings stepper moves the minimum by.
    static let minPaneSizeStep: Double = 20

    /// The floor is the split pane header's narrowest width (the kind glyph
    /// and the menu, `PaneHeaderMetrics.minimumWidth`) rounded up to a whole
    /// stepper step, so a split pane always has room for its header and the
    /// width minimum can be the user's number as-is. Rounding keeps the
    /// stepper on its round values. A stored value below it is raised on
    /// load.
    static let minPaneSizeRange: ClosedRange<Double> =
        (Double(PaneHeaderMetrics.minimumWidth) / minPaneSizeStep).rounded(.up) * minPaneSizeStep...300

    /// Maximum number of scrollback lines per pane. libghostty
    /// allocates the ring at surface init, so changing this requires
    /// a new terminal — existing surfaces keep their original limit.
    var scrollbackLines: Int = 10000

    /// What happens when an app rings the bell (BEL / `\a`).
    var bellAction: BellAction = .visual

    /// Block / Bar / Underline.
    var cursorStyle: CursorStyle = .block

    /// Cursor blink. Set `.off` for power users who find blinking
    /// distracting.
    var cursorBlink: CursorBlink = .on

    /// Default working-directory strategy for tabs opened among the
    /// scratch tabs (the implicit `.loose` container). The key keeps the
    /// scratch tabs' earlier name, Quick Tabs, so saved settings read. Defaults to
    /// `.inheritPrevious`, which preserves the historical "open where
    /// I left off, else home" behavior.
    var quickTabCwdMode: WorkingDirectoryMode = .inheritPrevious

    /// Fixed directory used only when `quickTabCwdMode == .fixed`.
    var quickTabCwdPath: URL?

    /// Smallest visible width / height, in points, of every pane below a
    /// split. Divider drags, restored layouts, and split pre-flights share
    /// this value. Raising it gives more breathing room before a split is
    /// refused.
    var minPaneSize: Double = Self.defaultMinPaneSize

    /// Whether each pane of a split tab carries a one-line header naming
    /// it. On by default: with two or more panes the tab row names only the
    /// tab, and the header is what tells the panes apart. Lives beside
    /// `minPaneSize` because both shape how a split lays out its panes.
    var showsSplitPaneHeaders: Bool = true

    /// See `LimpidSettings.unknownFields`.
    var unknownFields: [String: LimpidJSONValue] = [:]

    /// Hand-rolled decoder so existing `settings.json` files (written
    /// before these keys existed) decode cleanly with the new fields
    /// defaulted, instead of throwing and discarding the user's other
    /// terminal choices. Mirrors `AppearanceSettings`.
    init() {}

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.scrollbackLines = try c.decodeIfPresent(Int.self, forKey: .scrollbackLines) ?? 10000
        self.bellAction = try c.decodeIfPresent(BellAction.self, forKey: .bellAction) ?? .visual
        self.cursorStyle = try c.decodeIfPresent(CursorStyle.self, forKey: .cursorStyle) ?? .block
        self.cursorBlink = try c.decodeIfPresent(CursorBlink.self, forKey: .cursorBlink) ?? .on
        self.quickTabCwdMode = try c.decodeIfPresent(
            WorkingDirectoryMode.self, forKey: .quickTabCwdMode
        ) ?? .inheritPrevious
        self.quickTabCwdPath = try c.decodeIfPresent(URL.self, forKey: .quickTabCwdPath)
        let decodedMinPaneSize = try c.decodeIfPresent(
            Double.self,
            forKey: .minPaneSize
        ) ?? Self.defaultMinPaneSize
        self.minPaneSize = min(
            max(decodedMinPaneSize, Self.minPaneSizeRange.lowerBound),
            Self.minPaneSizeRange.upperBound
        )
        self.showsSplitPaneHeaders = try c.decodeIfPresent(
            Bool.self,
            forKey: .showsSplitPaneHeaders
        ) ?? true
        self.unknownFields = try CodableSidecar.decodeUnknownFields(
            from: decoder,
            knownKeys: Self.knownKeyStrings
        )
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(scrollbackLines, forKey: .scrollbackLines)
        try c.encode(bellAction, forKey: .bellAction)
        try c.encode(cursorStyle, forKey: .cursorStyle)
        try c.encode(cursorBlink, forKey: .cursorBlink)
        try c.encode(quickTabCwdMode, forKey: .quickTabCwdMode)
        try c.encodeIfPresent(quickTabCwdPath, forKey: .quickTabCwdPath)
        try c.encode(minPaneSize, forKey: .minPaneSize)
        try c.encode(showsSplitPaneHeaders, forKey: .showsSplitPaneHeaders)
        try CodableSidecar.encodeUnknownFields(unknownFields, to: encoder)
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case scrollbackLines, bellAction, cursorStyle, cursorBlink
        case quickTabCwdMode, quickTabCwdPath, minPaneSize, showsSplitPaneHeaders
    }

    private static let knownKeyStrings: Set<String> = Set(CodingKeys.allCases.map(\.stringValue))
}

enum BellAction: String, Codable, CaseIterable {
    case none
    case visual
    case audio
    case both
}

/// Whether the terminal cursor blinks. Two states today; the enum
/// shape leaves room for a future `fast` / `slow` choice without a
/// wire-format break (same boolean-trap rationale as `TransparencyMode`).
enum CursorBlink: String, Codable, CaseIterable {
    case off
    case on

    static let unknownFallback: CursorBlink = .on

    var isOn: Bool {
        self == .on
    }

    init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = CursorBlink(rawValue: raw) ?? .unknownFallback
    }
}

enum CursorStyle: String, Codable, CaseIterable {
    case block
    case bar
    case underline
}

// MARK: - Keyboard

/// User-bound shortcuts. Each entry overrides libghostty's default
/// for the same action; entries omitted from this map keep the
/// `LimpidShortcutAction.defaultShortcut` value, which itself
/// mirrors Ghostty's macOS defaults. Storing only the overrides
/// (instead of the full table) keeps `settings.json` short and
/// makes "reset to default" a `removeValue(forKey:)`.
struct KeyboardSettings: Codable, Equatable {
    /// Action rawValue → override. Stored keyed by `String` so the
    /// on-disk JSON is a readable map (`{"newTab": {…}}`) instead
    /// of the array shape Swift uses for non-String-keyed enum
    /// dictionaries. Unknown rawValues (e.g. an action removed in
    /// a future version) decode silently to nothing.
    var overrides: [String: StoredShortcut] = [:]

    /// Actions whose default was given up because a person's own binding
    /// or the quick terminal's hotkey already holds the same keys: the
    /// person's choice wins over a default that arrived later.
    /// Derived from the overrides and the hotkey on every change
    /// (`normalize`), so a default comes back once its keys are free. A
    /// separate key rather than a marker inside `overrides`, so an older
    /// build reads `overrides` unchanged and carries this through
    /// `unknownFields`.
    var unbound: [String] = []

    /// Actions the person left with no keys (Keyboard's "Unassign"), kept
    /// apart from `unbound`, which `normalize` rebuilds: a default given up
    /// to a binding comes back when the keys are free, one the person
    /// unassigned stays off until they restore it. A key older builds do
    /// not know, so they read it as absent and carry it through
    /// `unknownFields`.
    var unassigned: [String] = []

    /// Bindings that no longer apply, by action raw value: an action that
    /// lost its default, or keys Limpid now reserves (⌘⏎). Kept rather
    /// than dropped, listed in Settings → Keyboard, and discarded there by
    /// the person. Never bound.
    var retired: [String: StoredShortcut] = [:]

    /// Actions, by raw value, whose keys did something else in the release
    /// the person updated from, and that say so the first time they are
    /// used (`noteChangedKeys(since:)`); taken off once said. A key older
    /// builds do not know, carried through `unknownFields`.
    var keysToIntroduce: [String] = []

    /// See `LimpidSettings.unknownFields`.
    var unknownFields: [String: LimpidJSONValue] = [:]

    /// Defensive decoder so settings.json files written before this
    /// key existed still load cleanly. Same pattern other sections
    /// use.
    init() {}

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.overrides = try c.decodeIfPresent(
            [String: StoredShortcut].self,
            forKey: .overrides
        ) ?? [:]
        self.unbound = try c.decodeIfPresent([String].self, forKey: .unbound) ?? []
        self.unassigned = try c.decodeIfPresent([String].self, forKey: .unassigned) ?? []
        self.retired = try c.decodeIfPresent([String: StoredShortcut].self, forKey: .retired) ?? [:]
        self.keysToIntroduce = try c.decodeIfPresent([String].self, forKey: .keysToIntroduce) ?? []
        self.unknownFields = try CodableSidecar.decodeUnknownFields(
            from: decoder,
            knownKeys: Self.knownKeyStrings
        )
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(overrides, forKey: .overrides)
        // Written only when there is something to keep, so a file that
        // never needed them reads as it did.
        if !unbound.isEmpty {
            try c.encode(unbound, forKey: .unbound)
        }
        if !unassigned.isEmpty {
            try c.encode(unassigned, forKey: .unassigned)
        }
        if !retired.isEmpty {
            try c.encode(retired, forKey: .retired)
        }
        if !keysToIntroduce.isEmpty {
            try c.encode(keysToIntroduce, forKey: .keysToIntroduce)
        }
        try CodableSidecar.encodeUnknownFields(unknownFields, to: encoder)
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case overrides
        case unbound
        case unassigned
        case retired
        case keysToIntroduce
    }

    private static let knownKeyStrings: Set<String> = Set(CodingKeys.allCases.map(\.stringValue))

    /// Effective shortcut for `action`: user override if present,
    /// otherwise the action's built-in default, unless that default was
    /// given up (`unbound`) or unassigned (`unassigned`). `nil` for an
    /// action with neither.
    func shortcut(for action: LimpidShortcutAction) -> StoredShortcut? {
        if let override = overrides[action.rawValue] {
            return override
        }
        let isOff = unbound.contains(action.rawValue) || unassigned.contains(action.rawValue)
        return isOff ? nil : action.defaultShortcut
    }

    /// Conflict-check `proposed` against every other action's
    /// effective shortcut. Returns `.ok` if safe to assign, or the
    /// reason we can't. Called by the recorder before committing —
    /// Pattern A means two actions sharing a trigger would silently
    /// pick one winner in libghostty's last-write-wins, which is
    /// always surprising; we reject up front instead.
    func validate(
        _ proposed: StoredShortcut,
        for action: LimpidShortcutAction,
        quickTerminalHotKey: StoredShortcut? = nil
    ) -> ShortcutValidation {
        // Require at least one of ⌘/⌥/⌃/⇧. A bare letter would
        // hijack every plain keypress of that character and make
        // the terminal untypeable.
        if proposed.modifiers.isEmpty {
            return .missingModifier
        }
        if ReservedShortcuts.triggers.contains(proposed.ghosttyTrigger) {
            return .reserved
        }
        if action.keysItsPlaceKeeps.contains(proposed) {
            return .keptBySidebar
        }
        // The one action that answers somewhere else may keep the same keys
        // (`LimpidShortcutAction.sharesKeys`).
        for other in LimpidShortcutAction.allCases where other != action && !action.sharesKeys(with: other) {
            if shortcut(for: other) == proposed {
                // A pair holding the keys together is named as one, so the
                // person learns both lose them.
                if let partner = other.sharesKeys, partner != action, shortcut(for: partner) == proposed {
                    return .conflictWithPair(other, partner)
                }
                return .conflict(other)
            }
        }
        if proposed == quickTerminalHotKey {
            return .quickTerminalConflict
        }
        return .ok
    }

    /// Replace (or set) the override for `action`; a binding of the
    /// person's own also ends their unassigning it.
    mutating func setOverride(_ shortcut: StoredShortcut, for action: LimpidShortcutAction) {
        overrides[action.rawValue] = shortcut
        unbound.removeAll { $0 == action.rawValue }
        unassigned.removeAll { $0 == action.rawValue }
    }

    /// Drop the user override so the action falls back to its built-in
    /// default. Whether that default is free again is `normalize`'s call,
    /// which `SettingsStore` makes after every change.
    mutating func resetOverride(for action: LimpidShortcutAction) {
        overrides.removeValue(forKey: action.rawValue)
    }

    /// Every binding back to its default: overrides, given-up defaults,
    /// and the retired list. A default the quick terminal's hotkey holds
    /// stays given up (`normalize`).
    mutating func restoreDefaults() {
        overrides.removeAll()
        unbound.removeAll()
        unassigned.removeAll()
        retired.removeAll()
    }

    /// Forgets a retired binding the person has read.
    mutating func discardRetired(_ rawValue: String) {
        retired.removeValue(forKey: rawValue)
    }

    /// What is left from the update to the supervision window's shortcuts,
    /// as the bindings stand now: retired bindings not yet
    /// discarded, and defaults still given up. `nil` when there is none.
    /// A default the person unassigned is in `unassigned`, not here.
    var migrationNotice: KeyboardMigrationNotice? {
        let notice = KeyboardMigrationNotice(
            retired: retired.keys.sorted().compactMap { raw in retired[raw].map { (raw, $0) } }
                .map { KeyboardMigrationNotice.Retired(rawValue: $0.0, shortcut: $0.1) },
            conflicts: unbound.compactMap(LimpidShortcutAction.init(rawValue:))
        )
        return notice.retired.isEmpty && notice.conflicts.isEmpty ? nil : notice
    }

    /// The `retired` key for a quick terminal hotkey this build reserves.
    static let quickTerminalHotKeyID = "quickTerminalHotKey"

    /// What holds the keys of `action`'s default, when something else
    /// does: another action's binding or the quick terminal's hotkey.
    func holderOfDefault(
        for action: LimpidShortcutAction,
        quickTerminalHotKey: StoredShortcut?
    ) -> DefaultKeysHolder? {
        guard let trigger = action.defaultShortcut?.ghosttyTrigger else { return nil }
        if let holder = LimpidShortcutAction.allCases.first(where: {
            $0 != action && !action.sharesKeys(with: $0) && overrides[$0.rawValue]?.ghosttyTrigger == trigger
        }) {
            return .action(holder)
        }
        return quickTerminalHotKey?.ghosttyTrigger == trigger ? .quickTerminalHotKey : nil
    }

    /// Keeps the bindings consistent with this build's keys. Run on
    /// every load, not only on the move to schema 2: a rolled-back build
    /// keeps the file at schema 2 while it lets a person bind keys this
    /// build reserves or gave to a new action, and a hand edit can do the
    /// same. Running it twice changes nothing more.
    ///
    /// A binding on a reserved key (⌘⏎, which the decision bar takes)
    /// moves to `retired`, and so does a quick terminal hotkey on one. A
    /// default whose keys a person's own binding or the hotkey already
    /// holds is given up (`unbound`): the person's choice wins over a
    /// default that arrived later, and no two actions share keys. First, a
    /// binding of an action folded into another moves to the one that took
    /// it over (`foldActions`).
    mutating func normalize(quickTerminalHotKey: inout StoredShortcut?) {
        foldActions()
        for (raw, binding) in overrides where ReservedShortcuts.triggers.contains(binding.ghosttyTrigger) {
            overrides.removeValue(forKey: raw)
            retired[raw] = binding
        }
        if let hotKey = quickTerminalHotKey, ReservedShortcuts.triggers.contains(hotKey.ghosttyTrigger) {
            retired[Self.quickTerminalHotKeyID] = hotKey
            quickTerminalHotKey = nil
        }
        // Rebuilt rather than added to, so a default whose keys were freed
        // (an override reset, a hotkey changed) comes back. What the person
        // unassigned is kept apart, in `unassigned`, and is not touched;
        // nor is it listed here, so `unbound` is only the defaults that
        // gave way, which the update notice shows.
        let hotKey = quickTerminalHotKey
        unbound = LimpidShortcutAction.allCases
            .filter {
                overrides[$0.rawValue] == nil && !unassigned.contains($0.rawValue)
                    && holderOfDefault(for: $0, quickTerminalHotKey: hotKey) != nil
            }
            .map(\.rawValue)
    }
}

/// What holds a default's keys instead of its action.
enum DefaultKeysHolder: Equatable {
    case action(LimpidShortcutAction)
    case quickTerminalHotKey
}

/// What moving the keyboard settings to schema 2 left for the person to
/// look at: bindings kept aside, and new actions left without a
/// default because their keys were the person's.
struct KeyboardMigrationNotice: Equatable {
    struct Retired: Equatable {
        let rawValue: String
        let shortcut: StoredShortcut
    }

    let retired: [Retired]
    let conflicts: [LimpidShortcutAction]
}

// MARK: - Advanced

/// Whether Limpid layers `~/.config/ghostty/config` under its own
/// settings. Two-state today; the enum leaves room for future
/// strategies (e.g. `.watch` for live reload, `.mergePerSurface`).
enum GhosttyConfig: String, Codable, CaseIterable {
    case off
    case on

    static let unknownFallback: GhosttyConfig = .off

    var isOn: Bool {
        self == .on
    }

    init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = GhosttyConfig(rawValue: raw) ?? .unknownFallback
    }
}

struct AdvancedSettings: Codable, Equatable {
    /// When `.on`, Limpid includes `~/.config/ghostty/config` as a
    /// base layer under the Limpid-managed settings. Forbidden keys
    /// (background, window-decoration, etc — anything that would
    /// break the Liquid Glass toolbar) are silently stripped even
    /// when this is on. Limpid Settings values always win over user
    /// `ghostty/config` values where they overlap.
    var ghosttyConfig: GhosttyConfig = .off

    /// Run agent commands inside a tmux session of their own instead of
    /// directly on the pane's pty, so the agent survives Limpid quitting
    /// — including the restart Sparkle performs after applying an
    /// update, which otherwise kills every running agent. A pane comes
    /// back to its session through the reattach path, which needs
    /// nothing from this setting.
    ///
    /// Off by default. It needs a tmux the user may not have, and it
    /// costs the pane's scrollback: history stays in tmux's copy mode
    /// rather than entering Limpid's own. That is a fair trade for an
    /// agent, whose transcript lives in its session file, and a poor one
    /// for a shell — which is why only the agent command is wrapped and
    /// the pane's shell keeps the pty.
    var hostsAgentsInTmux: Bool = false

    /// What review puts above the comments it hands to an agent.
    ///
    /// Empty means the built-in text, which is localized — so the default
    /// follows the app's language rather than pinning one. Only the
    /// instructions are the reader's: the worktree, the counts and the
    /// comment blocks are generated, so editing this cannot lose them or
    /// break the escaping the blocks depend on.
    var reviewInstructions: String = ""

    /// The application that opens a local file, whether from Review or from a
    /// path ⌘-clicked in a terminal pane. `nil` leaves file handling to
    /// macOS's default application for that file type.
    ///
    /// We persist the bundle identifier rather than the selected bundle's URL:
    /// applications move when they are updated or installed on another volume.
    /// The display name is only a last-known label for a missing application;
    /// opening always resolves the identifier again through `NSWorkspace`.
    var fileApplication: FileApplication?

    /// Whether Limpid holds an approval request while its pane is out of
    /// sight and hands it to the TUI only once the pane is seen. Not shown in
    /// Settings: it is the way out if a provider draws its own prompt while
    /// the request is held, which would leave two prompts for one request.
    /// Off hands every request to the TUI at once, as if nothing held it.
    var holdsApprovalsWhileHidden = true

    /// How long the turns' records are kept.
    var turnRetention: TurnRetentionSettings = .init()

    /// See `LimpidSettings.unknownFields`. It also carries the two
    /// pull-request switches earlier builds read (`showPRStatusInSidebar`
    /// and `showPRStatusOnlyWhenAttention`): pull requests now show
    /// wherever `gh` or `glab` can read them, and a build
    /// that still reads the switches finds the person's value after a
    /// rollback.
    var unknownFields: [String: LimpidJSONValue] = [:]

    init() {}

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.holdsApprovalsWhileHidden = try c.decodeIfPresent(
            Bool.self, forKey: .holdsApprovalsWhileHidden
        ) ?? true
        self.reviewInstructions = try c.decodeIfPresent(
            String.self, forKey: .reviewInstructions
        ) ?? ""
        self.fileApplication = try c.decodeIfPresent(
            FileApplication.self, forKey: .fileApplication
        )
        self.ghosttyConfig = try c.decodeIfPresent(
            GhosttyConfig.self, forKey: .ghosttyConfig
        ) ?? .off
        self.hostsAgentsInTmux = try c.decodeIfPresent(
            Bool.self, forKey: .hostsAgentsInTmux
        ) ?? false
        self.turnRetention = try c.decodeIfPresent(TurnRetentionSettings.self, forKey: .turnRetention) ?? .init()
        self.unknownFields = try CodableSidecar.decodeUnknownFields(
            from: decoder,
            knownKeys: Self.knownKeyStrings
        )
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(ghosttyConfig, forKey: .ghosttyConfig)
        try c.encode(turnRetention, forKey: .turnRetention)
        try c.encode(hostsAgentsInTmux, forKey: .hostsAgentsInTmux)
        try c.encode(reviewInstructions, forKey: .reviewInstructions)
        try c.encodeIfPresent(fileApplication, forKey: .fileApplication)
        // Written only when changed, so a file nobody touched does not grow
        // a key nobody can see.
        if !holdsApprovalsWhileHidden {
            try c.encode(holdsApprovalsWhileHidden, forKey: .holdsApprovalsWhileHidden)
        }
        try CodableSidecar.encodeUnknownFields(unknownFields, to: encoder)
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case ghosttyConfig
        case reviewInstructions
        /// Named for Review, its first user; the stored key stays so
        /// existing settings files keep their choice.
        case fileApplication = "reviewFileApplication"
        case hostsAgentsInTmux
        case holdsApprovalsWhileHidden = "approvalHoldWhileHidden"
        case turnRetention
    }

    private static let knownKeyStrings: Set<String> = Set(CodingKeys.allCases.map(\.stringValue))
}

/// A user-selected application for opening files from Review.
///
/// `bundleIdentifier` is the durable identity. `lastKnownDisplayName` keeps
/// Settings intelligible when the selected application has since been removed;
/// it never participates in locating or launching the application.
struct FileApplication: Codable, Equatable {
    let bundleIdentifier: String
    let lastKnownDisplayName: String

    /// See `LimpidSettings.unknownFields`.
    var unknownFields: [String: LimpidJSONValue] = [:]

    init(bundleIdentifier: String, lastKnownDisplayName: String) {
        self.bundleIdentifier = bundleIdentifier
        self.lastKnownDisplayName = lastKnownDisplayName
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.bundleIdentifier = try c.decode(String.self, forKey: .bundleIdentifier)
        self.lastKnownDisplayName = try c.decode(String.self, forKey: .lastKnownDisplayName)
        self.unknownFields = try CodableSidecar.decodeUnknownFields(
            from: decoder,
            knownKeys: Self.knownKeyStrings
        )
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(bundleIdentifier, forKey: .bundleIdentifier)
        try c.encode(lastKnownDisplayName, forKey: .lastKnownDisplayName)
        try CodableSidecar.encodeUnknownFields(unknownFields, to: encoder)
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case bundleIdentifier, lastKnownDisplayName
    }

    private static let knownKeyStrings: Set<String> = Set(CodingKeys.allCases.map(\.stringValue))
}
