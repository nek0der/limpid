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
//
// `Reloadability` (declared below) annotates **at the schema level**
// whether changing each key is safe to apply live, requires a new
// terminal surface, or needs an app restart. The Settings UI surfaces
// the badge via this enum so the user can predict the apply cadence.

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
    }
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
}

/// Per-action confirmation policy. The keyboard / mouse split for tab
/// close is intentional: the × button is the most mis-clicked
/// affordance in the app and warrants its own knob so the user can
/// keep it strict while leaving deliberate ⌘W / ⌘⌥W untouched. Pane
/// close has only a keyboard path today, so there's no mouse twin.
///
/// Every close path — SwiftUI menu, libghostty's `close_tab` action,
/// L2's × button — funnels through `CloseConfirmer`, which consults
/// the right field below based on the request's `(kind, source)`. So
/// a new caller can't accidentally bypass confirmation by reaching
/// for `session.closeTab` directly.
struct ConfirmationSettings: Codable, Equatable {
    var quit: ConfirmPolicy = .onlyWhenAgent
    var closeTabKeyboard: ConfirmPolicy = .onlyWhenAgent
    var closeTabMouse: ConfirmPolicy = .onlyWhenAgent
    var closePane: ConfirmPolicy = .onlyWhenAgent

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
    }
}

// MARK: - Appearance

struct AppearanceSettings: Codable, Equatable {
    /// Curated window tint applied to the L2 / L3 column fills.
    /// Replaces the older "Theme" concept: Limpid forces terminal
    /// cells transparent anyway, so a libghostty theme would only
    /// recolour text + ANSI palette and feel muted. The tint
    /// instead changes the whole window's atmosphere — see
    /// `WindowTint`.
    var windowTint: WindowTint = .default

    /// Terminal pane background opacity (0.0 fully transparent
    /// through to 1.0 opaque). We keep this independent of the
    /// surrounding slab's Liquid Glass: the slab is always Material
    /// (or solid when `transparency` resolves to off), the pane sits
    /// on top with its own opacity so the user can read terminal
    /// content against the wallpaper.
    var backgroundOpacity: Double = 0.92

    /// Whether the chrome (L1 / L2 slabs, window backdrop — not the
    /// terminal pane) uses Liquid Glass. macOS Accessibility's
    /// "Reduce Transparency" always wins: when the system flag is on,
    /// AppKit renders vibrancy opaque and strips Liquid Glass no matter
    /// what we ask for, so this toggle only has an effect while that
    /// system setting is off. See `ReduceTransparencyResolver`.
    var transparencyEnabled: Bool = true

    /// User-chosen colour scheme. `.system` follows the macOS
    /// Appearance preference; `.light` / `.dark` pin Limpid (both
    /// SwiftUI chrome via `NSApp.appearance` and libghostty's bundled
    /// theme) regardless of the OS setting.
    var colorScheme: ColorSchemePreference = .system

    /// We diverge from the other settings structs (Font/Terminal/Advanced)
    /// and write a custom `init(from:)` so older `settings.json` files
    /// (no `colorScheme` key) decode cleanly with the new field
    /// defaulted, instead of throwing and falling back to a fresh
    /// defaults document that would also wipe the user's `windowTint`,
    /// `backgroundOpacity`, and `transparency`. This struct is the
    /// only one that's worth defending because every field here is a
    /// visible Settings choice — losing them mid-upgrade is the kind
    /// of regression a user notices immediately.
    init() {}

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.windowTint = try c.decodeIfPresent(WindowTint.self, forKey: .windowTint) ?? .default
        self.backgroundOpacity = try c.decodeIfPresent(Double.self, forKey: .backgroundOpacity) ?? 0.92
        // Migrate the older three-way `transparency` enum: only its
        // explicit `off` opted out of glass, so every other value (and
        // a missing key) maps to enabled.
        if let enabled = try c.decodeIfPresent(Bool.self, forKey: .transparencyEnabled) {
            self.transparencyEnabled = enabled
        } else if let legacy = try c.decodeIfPresent(String.self, forKey: .transparency) {
            self.transparencyEnabled = legacy != "off"
        } else {
            self.transparencyEnabled = true
        }
        self.colorScheme = try c.decodeIfPresent(ColorSchemePreference.self, forKey: .colorScheme) ?? .system
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(windowTint, forKey: .windowTint)
        try c.encode(backgroundOpacity, forKey: .backgroundOpacity)
        try c.encode(transparencyEnabled, forKey: .transparencyEnabled)
        try c.encode(colorScheme, forKey: .colorScheme)
        // `transparency` is intentionally not written — it exists only
        // as a decode-time migration path off older settings files.
    }

    private enum CodingKeys: String, CodingKey {
        case windowTint
        case backgroundOpacity
        case transparencyEnabled
        case transparency // legacy, decode-only for migration
        case colorScheme
    }
}

/// User Appearance preference, mirrored after macOS 26 System
/// Settings ("Appearance"). `.system` follows the OS; the other two
/// pin Limpid regardless of the OS setting.
enum ColorSchemePreference: String, Codable, CaseIterable {
    case system
    case light
    case dark
}

/// Curated tints layered onto the L2 / L3 column fills. Each case
/// resolves to a single colour; SwiftUI mixes it with the user's
/// `backgroundOpacity` so the wallpaper can still show through.
/// We intentionally don't expose a free-form colour picker — the
/// curated set is small (8 atmospheres), Limpid-supervised, and
/// keeps every tint legible against libghostty's default ANSI
/// palette.
enum WindowTint: String, Codable, CaseIterable {
    case `default`
    case slate
    case navy
    case plum
    case forest
    case amber
    case crimson
    case black
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

    /// Cursor blink. Set false for power users who find blinking
    /// distracting.
    var cursorBlink: Bool = true

    /// Default working-directory strategy for tabs opened in the
    /// Quick Tabs scope (the implicit `.loose` container). Defaults to
    /// `.inheritPrevious`, which preserves the historical "open where
    /// I left off, else home" behaviour.
    var quickTabCwdMode: WorkingDirectoryMode = .inheritPrevious

    /// Fixed directory used only when `quickTabCwdMode == .fixed`.
    var quickTabCwdPath: URL?

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
        self.cursorBlink = try c.decodeIfPresent(Bool.self, forKey: .cursorBlink) ?? true
        self.quickTabCwdMode = try c.decodeIfPresent(
            WorkingDirectoryMode.self, forKey: .quickTabCwdMode
        ) ?? .inheritPrevious
        self.quickTabCwdPath = try c.decodeIfPresent(URL.self, forKey: .quickTabCwdPath)
    }
}

enum BellAction: String, Codable, CaseIterable {
    case none
    case visual
    case audio
    case both
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
    }

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

struct AdvancedSettings: Codable, Equatable {
    /// When true, Limpid includes `~/.config/ghostty/config` as a
    /// base layer under the Limpid-managed settings. Forbidden keys
    /// (background, window-decoration, etc — anything that would
    /// break the Liquid Glass chrome) are silently stripped even
    /// when this is on. Limpid Settings values always win over user
    /// `ghostty/config` values where they overlap.
    var useGhosttyConfigFile: Bool = false
}

// MARK: - Reloadability schema

/// How a given setting key can be applied after the user changes it.
/// Surfaced by the UI as a "Restart required" / "Reopen tab required"
/// badge so the user can predict whether their tweak takes effect now
/// or later — avoids the "I changed it but nothing happened" trap.
enum Reloadability: String, Codable {
    /// Applies immediately to every running surface. Use for keys
    /// libghostty accepts via `ghostty_surface_set_config_*` or
    /// SwiftUI-only state.
    case live

    /// Applies only to terminals opened after the change — existing
    /// surfaces keep the old value until they close. Font family,
    /// scrollback limit, and ligature settings live here because
    /// libghostty allocates buffers / glyph atlases at surface init.
    case newTerminal

    /// Requires a full app restart. Reserved for things that touch
    /// global state (advanced toggle that flips `ghostty/config`
    /// loading, deep AppKit changes).
    case restart
}

/// Per-key reloadability metadata. The Settings UI looks values up
/// by key path. Anything not present defaults to `.newTerminal`,
/// which is the conservative choice.
enum LimpidSettingsSchema {
    static let reloadability: [String: Reloadability] = [
        // Appearance
        "appearance.windowTint": .live,
        "appearance.backgroundOpacity": .live,
        "appearance.transparencyEnabled": .live,
        // Font
        "appearance.font.family": .newTerminal,
        "appearance.font.size": .live,
        "appearance.font.ligatures": .newTerminal,
        "appearance.font.lineHeight": .newTerminal,
        // Terminal
        "terminal.scrollbackLines": .newTerminal,
        "terminal.bellAction": .live,
        // libghostty propagates `cursor-style` to existing surfaces
        // via `default_cursor_style`, but the live cursor on screen
        // only re-evaluates when the terminal receives a DECSCUSR
        // escape — which, with `shell-integration-features = no-cursor`,
        // never happens for the lifetime of the current shell. So
        // cursor changes only show up on new terminals in practice.
        "terminal.cursorStyle": .newTerminal,
        "terminal.cursorBlink": .newTerminal,
        // Advanced
        "advanced.useGhosttyConfigFile": .restart
    ]
}

// MARK: - Ghostty config key forbidden list

/// Keys Limpid forces to specific values regardless of where they
/// come from (Limpid settings.json, user `ghostty/config`, or any
/// future config layer). These all control the surface's visual
/// chrome — the Liquid Glass slab assumes the terminal pane is
/// transparent and the `NSWindow` has no native decoration, so any
/// attempt to flip them would break the design.
///
/// The bridge silently drops these when serializing user config; it
/// then prepends Limpid's own forced values so libghostty sees the
/// expected state.
enum GhosttyForbiddenKeys {
    static let keys: Set<String> = [
        "background",
        "background-opacity", // Limpid controls via AppearanceSettings.backgroundOpacity
        "background-blur-radius", // ditto
        "window-decoration", // Limpid uses borderless + Liquid Glass
        "macos-titlebar-style", // Limpid sets manually
        "macos-titlebar-proxy-icon", // ditto
        "window-padding-x",
        "window-padding-y",
        "window-padding-balance",
        "confirm-close-surface" // Limpid has its own close alert
    ]
}
