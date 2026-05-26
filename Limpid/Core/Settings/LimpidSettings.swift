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
    var advanced: AdvancedSettings = .init()

    static let currentSchemaVersion = 1

    static let `default` = LimpidSettings()
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

    /// Transparency mode for the L1 / L2 slabs (the Liquid Glass
    /// chrome — not the terminal pane). `.system` honors macOS
    /// Accessibility's `accessibilityDisplayShouldReduceTransparency`
    /// (system "Reduce Transparency" ON → slabs go opaque). `.on` /
    /// `.off` ignore the system setting and force translucent / opaque
    /// respectively.
    var transparency: TransparencyMode = .system

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
        self.transparency = try c.decodeIfPresent(TransparencyMode.self, forKey: .transparency) ?? .system
        self.colorScheme = try c.decodeIfPresent(ColorSchemePreference.self, forKey: .colorScheme) ?? .system
    }
}

enum TransparencyMode: String, Codable, CaseIterable {
    case system
    case on
    case off
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
        "appearance.transparency": .live,
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
