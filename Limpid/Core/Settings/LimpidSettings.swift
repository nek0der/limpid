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
/// `schemaVersion` exists so we can migrate forward without losing
/// the file if a future field is renamed; current loader treats
/// unknown versions as "fall back to defaults + log".
struct LimpidSettings: Codable, Equatable {
    var schemaVersion: Int = currentSchemaVersion
    var appearance: AppearanceSettings = .init()
    var font: FontSettings = .init()
    var terminal: TerminalSettings = .init()
    var keyboard: KeyboardSettings = .init()
    var confirmations: ConfirmationSettings = .init()
    var advanced: AdvancedSettings = .init()

    /// Trailing root-level keys the current build doesn't recognize.
    /// Preserved across decode → encode so a newer build's writes
    /// survive a Sparkle rollback to an older one. See `LimpidJSONValue`.
    var unknownFields: [String: LimpidJSONValue] = [:]

    static let currentSchemaVersion = 1

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
        try CodableSidecar.encodeUnknownFields(unknownFields, to: encoder)
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion, appearance, font, terminal, keyboard, confirmations, advanced
    }

    private static let knownKeyStrings: Set<String> = Set(CodingKeys.allCases.map(\.stringValue))
}

// MARK: - Confirmations

/// Tri-state policy for destructive actions (⌘Q, tab/pane close).
/// `onlyWhenAgent` consults the live-agent predicate; the modal body
/// always reflects actual state (agent-specific copy iff an agent is
/// live), so `always` without an agent renders a plain "Close tab?"
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
/// tab column's × button — funnels through `CloseConfirmer`, which consults
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

/// Whether the toolbar (container / tab column slabs, window backdrop)
/// renders with Liquid Glass. Currently a two-state knob; the enum
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
    /// active row pills, and other toolbar highlights. We follow the
    /// "5% rule" (design-rules.md §5.3): one accent per screen, used
    /// sparingly. The actual `Color` is resolved by
    /// `LimpidColor.accent(for:)` so callers don't have to know about
    /// the enum.
    var accentColor: AccentColor = .default

    /// Terminal pane background opacity (0.0 fully transparent
    /// through to 1.0 opaque). We keep this independent of the
    /// surrounding slab's Liquid Glass: the slab is always Material
    /// (or solid when `transparency` resolves to off), the pane sits
    /// on top with its own opacity so the user can read terminal
    /// content against the wallpaper.
    var backgroundOpacity: Double = 0.92

    /// Whether the toolbar (container / tab column slabs, window backdrop — not the
    /// terminal pane) uses Liquid Glass. macOS Accessibility's
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
    /// PostScript family name. `nil` = libghostty's default
    /// (currently SF Mono on macOS). The picker only offers
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
    /// Range: -2 ... +6.
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

    /// Default working-directory strategy for tabs opened in the
    /// Quick Tabs scope (the implicit `.loose` container). Defaults to
    /// `.inheritPrevious`, which preserves the historical "open where
    /// I left off, else home" behavior.
    var quickTabCwdMode: WorkingDirectoryMode = .inheritPrevious

    /// Fixed directory used only when `quickTabCwdMode == .fixed`.
    var quickTabCwdPath: URL?

    /// Smallest fraction of width / height (in points) either side of a
    /// split divider may shrink to. Used to clamp divider drags and to
    /// pre-flight `PaneActions.split` so panes can't be cut into 1-pixel
    /// strips. Default `80` matches the historical hardcoded value;
    /// raising it gives more breathing room before the split prompt
    /// refuses.
    var minPaneSize: Double = 80

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
        self.minPaneSize = try c.decodeIfPresent(Double.self, forKey: .minPaneSize) ?? 80
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
        try CodableSidecar.encodeUnknownFields(unknownFields, to: encoder)
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case scrollbackLines, bellAction, cursorStyle, cursorBlink
        case quickTabCwdMode, quickTabCwdPath, minPaneSize
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

/// Outcome of `KeyboardSettings.validate`. The recorder surfaces
/// these to the user as a small warning under the row; `.ok` is the
/// only outcome that commits.
enum ShortcutValidation: Equatable {
    case ok
    /// Another action is already bound to the same trigger.
    case conflict(LimpidShortcutAction)
    /// Trigger collides with a parametric range Limpid reserves
    /// (⌘1…⌘9, ⌘⌃1…⌘⌃9). See `ReservedShortcuts`.
    case reserved
    /// Modifier-less binding — would hijack every plain keystroke
    /// of that character and break terminal input. The recorder
    /// requires at least one of ⌘/⌥/⌃/⇧.
    case missingModifier
}

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
        self.unknownFields = try CodableSidecar.decodeUnknownFields(
            from: decoder,
            knownKeys: Self.knownKeyStrings
        )
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(overrides, forKey: .overrides)
        try CodableSidecar.encodeUnknownFields(unknownFields, to: encoder)
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case overrides
    }

    private static let knownKeyStrings: Set<String> = Set(CodingKeys.allCases.map(\.stringValue))

    /// Effective shortcut for `action`: user override if present,
    /// otherwise the action's built-in default. Returns `nil` only
    /// when the user has explicitly cleared the binding (reserved
    /// for a future "Unbind" affordance — currently every action
    /// has a default).
    func shortcut(for action: LimpidShortcutAction) -> StoredShortcut? {
        overrides[action.rawValue] ?? action.defaultShortcut
    }

    /// Conflict-check `proposed` against every other action's
    /// effective shortcut. Returns `.ok` if safe to assign, or the
    /// reason we can't. Called by the recorder before committing —
    /// Pattern A means two actions sharing a trigger would silently
    /// pick one winner in libghostty's last-write-wins, which is
    /// always surprising; we reject up front instead.
    func validate(
        _ proposed: StoredShortcut,
        for action: LimpidShortcutAction
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
        for other in LimpidShortcutAction.allCases where other != action {
            if shortcut(for: other) == proposed {
                return .conflict(other)
            }
        }
        return .ok
    }

    /// Replace (or set) the override for `action`.
    mutating func setOverride(_ shortcut: StoredShortcut, for action: LimpidShortcutAction) {
        overrides[action.rawValue] = shortcut
    }

    /// Drop the user override so the action falls back to its
    /// built-in default.
    mutating func resetOverride(for action: LimpidShortcutAction) {
        overrides.removeValue(forKey: action.rawValue)
    }
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

    /// See `LimpidSettings.unknownFields`.
    var unknownFields: [String: LimpidJSONValue] = [:]

    init() {}

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.ghosttyConfig = try c.decodeIfPresent(
            GhosttyConfig.self, forKey: .ghosttyConfig
        ) ?? .off
        self.unknownFields = try CodableSidecar.decodeUnknownFields(
            from: decoder,
            knownKeys: Self.knownKeyStrings
        )
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(ghosttyConfig, forKey: .ghosttyConfig)
        try CodableSidecar.encodeUnknownFields(unknownFields, to: encoder)
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case ghosttyConfig
    }

    private static let knownKeyStrings: Set<String> = Set(CodingKeys.allCases.map(\.stringValue))
}
