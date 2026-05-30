// KeyboardShortcut.swift
// Limpid — vocabulary + on-disk shape for user-customizable
// shortcuts. `LimpidShortcutAction` enumerates every rebindable
// action (with default, localized title, category, optional
// libghostty action); `StoredShortcut` is the key+modifier blob the
// menu bar and `GhosttyConfigBridge` both read so the two routing
// paths can't disagree.

import Foundation
import SwiftUI

// MARK: - Categories

/// Grouping shown in Settings → Keyboard. Mirrors the menu bar's
/// shape (File / View / Pane / Find) plus a terminal-only Font
/// bucket for libghostty actions that don't have menu items but
/// are useful to rebind.
enum LimpidShortcutCategory: Int, CaseIterable, Identifiable {
    case file
    case view
    case navigation
    case splits
    case search
    case terminal
    case font

    var id: Int {
        rawValue
    }

    /// SwiftUI-only `Text` literal (consumed by `Text(_:)` directly).
    /// Kept as `LocalizedStringKey` rather than the broader
    /// `LocalizedStringResource` because category titles are only
    /// ever rendered inside the Settings pane — we never need to
    /// concatenate them or feed them to `String(localized:)`. The
    /// action vocabulary uses `LocalizedStringResource` instead.
    var sectionTitle: LocalizedStringKey {
        switch self {
        case .file: "File"
        case .view: "View"
        case .navigation: "Navigation"
        case .splits: "Splits"
        case .search: "Find"
        case .terminal: "Terminal"
        case .font: "Font"
        }
    }
}

// MARK: - Actions

/// Every action the user can rebind. When adding a new case,
/// update these locations:
///   1. `defaultShortcut`, `localizedTitle`, `category`, `ghosttyAction`
///   2. `SessionActions.dispatchShortcutAction` (palette dispatch)
///   3. `CommandPaletteCatalog.icon(for:)` + `isActionEnabled`
///   4. `LimpidApp.commands` block (menu bar Button)
///
/// 1--3 are compiler-enforced via switch exhaustiveness; 4 is manual.
///
/// The menu bar pulls its shortcut via `View.limpidShortcut(_:in:)`;
/// libghostty pulls keybinds via `GhosttyConfigBridge`. Both branches
/// read the same store.
///
/// Note on ⌘1…⌘9 / ⌘⌃1…⌘⌃9: per-tab and per-section jumps stay
/// hardcoded in the menu (see `LimpidApp`). They're not in this
/// enum because we'd need 18 cases for what is really one
/// parametric action; the conflict checker reserves the triggers
/// so a user remap can't shadow them.
enum LimpidShortcutAction: String, CaseIterable, Codable, Identifiable {
    // File
    case newTab
    case newWorktree
    case renameTab
    case reopenClosedTab
    case closeSurface
    case closeTab

    // View
    case toggleSidebar
    case toggleTabLayout
    case notificationHistory

    // Navigation (container + tab cycling)
    case nextSection
    case previousSection
    case nextTab
    case previousTab

    // Splits
    case splitRight
    case splitDown
    case equalizeSplits
    case toggleSplitZoom
    case focusPaneLeft
    case focusPaneRight
    case focusPaneUp
    case focusPaneDown

    // Find
    case find
    case findNext
    case findPrevious

    // Terminal (libghostty)
    case nextPrompt
    case previousPrompt

    // Font (libghostty)
    case increaseFontSize
    case decreaseFontSize
    case resetFontSize

    /// General
    case commandPalette
    case quickOpen

    // Copy / Paste are intentionally absent: macOS's standard Edit
    // menu owns ⌘C / ⌘V via the responder chain (NSResponder's
    // `copy:` / `paste:` selectors), and we can't reliably suppress
    // the default key equivalents from Settings. Limpid's terminal
    // surface still gets Copy/Paste through libghostty's built-in
    // handling for those selectors.

    var id: String {
        rawValue
    }

    var category: LimpidShortcutCategory {
        switch self {
        case .newTab, .newWorktree, .renameTab, .reopenClosedTab,
             .closeSurface, .closeTab: .file
        case .toggleSidebar, .toggleTabLayout, .notificationHistory: .view
        case .nextSection, .previousSection, .nextTab, .previousTab: .navigation
        case .splitRight, .splitDown, .equalizeSplits, .toggleSplitZoom,
             .focusPaneLeft, .focusPaneRight, .focusPaneUp, .focusPaneDown: .splits
        case .find, .findNext, .findPrevious: .search
        case .nextPrompt, .previousPrompt: .terminal
        case .increaseFontSize, .decreaseFontSize, .resetFontSize: .font
        case .commandPalette, .quickOpen: .view
        }
    }

    /// libghostty action string for `keybind = trigger=action`, or
    /// `nil` when the menu bar owns the shortcut. Only actions with
    /// **no menu item** get a non-`nil` value: the menu bar's
    /// `keyboardShortcut` and libghostty's keybind table would
    /// otherwise both match the same keystroke and fire their
    /// handlers in parallel (menu → `SessionActions.…`, libghostty
    /// → `GhosttyActionRouter` callback), producing two splits per
    /// ⌘D / two tab closes per ⌘⌥W / etc. So `splitRight`,
    /// `splitDown`, `closeTab`, and `find` — all of which have menu
    /// items — route exclusively through the menu Button. Only the
    /// three font-size actions stay on the libghostty path because
    /// they have no menu equivalent.
    var ghosttyAction: String? {
        switch self {
        case .nextPrompt: "jump_to_prompt:1"
        case .previousPrompt: "jump_to_prompt:-1"
        case .increaseFontSize: "increase_font_size:1"
        case .decreaseFontSize: "decrease_font_size:1"
        case .resetFontSize: "reset_font_size"
        // Menu-owned + Limpid-only actions: the menu Button or a
        // notification fires `SessionActions.…` directly.
        case .newTab, .newWorktree, .renameTab, .reopenClosedTab,
             .closeSurface, .closeTab, .toggleSidebar, .toggleTabLayout,
             .notificationHistory,
             .nextSection, .previousSection, .nextTab, .previousTab,
             .splitRight, .splitDown,
             .equalizeSplits, .toggleSplitZoom,
             .focusPaneLeft, .focusPaneRight,
             .focusPaneUp, .focusPaneDown,
             .find, .findNext, .findPrevious,
             .commandPalette, .quickOpen: nil
        }
    }

    /// Localized display name shown in Settings and in the (future)
    /// command palette. Keys live in `Localizable.xcstrings` with
    /// en + ja translations (CLAUDE.md hard requirement).
    var localizedTitle: LocalizedStringResource {
        switch self {
        case .newTab: "New Tab"
        case .newWorktree: "New Worktree…"
        case .renameTab: "Rename Tab"
        case .reopenClosedTab: "Reopen Closed Tab"
        case .closeSurface: "Close Pane"
        case .closeTab: "Close Tab"
        case .toggleSidebar: "Toggle Sidebar"
        case .toggleTabLayout: "Toggle Tab Layout"
        case .notificationHistory: "Notification History"
        case .nextSection: "Next Section"
        case .previousSection: "Previous Section"
        case .nextTab: "Next Tab"
        case .previousTab: "Previous Tab"
        case .splitRight: "Split Right"
        case .splitDown: "Split Down"
        case .equalizeSplits: "Equalize Splits"
        case .toggleSplitZoom: "Toggle Split Zoom"
        case .focusPaneLeft: "Focus Left Pane"
        case .focusPaneRight: "Focus Right Pane"
        case .focusPaneUp: "Focus Pane Above"
        case .focusPaneDown: "Focus Pane Below"
        case .find: "Find…"
        case .findNext: "Find Next"
        case .findPrevious: "Find Previous"
        case .nextPrompt: "Next Prompt"
        case .previousPrompt: "Previous Prompt"
        case .increaseFontSize: "Increase Font Size"
        case .decreaseFontSize: "Decrease Font Size"
        case .resetFontSize: "Reset Font Size"
        case .commandPalette: "Command Palette"
        case .quickOpen: "Quick Open"
        }
    }

    private static let iconNames: [LimpidShortcutAction: String] = [
        .newTab: "plus",
        .newWorktree: "arrow.triangle.branch",
        .renameTab: "pencil",
        .reopenClosedTab: "arrow.uturn.backward",
        .closeSurface: "xmark.square",
        .closeTab: "xmark",
        .toggleSidebar: "sidebar.left",
        .toggleTabLayout: "rectangle.topthird.inset.filled",
        .notificationHistory: "bell",
        .nextSection: "chevron.left.chevron.right",
        .previousSection: "chevron.left.chevron.right",
        .nextTab: "arrow.left.arrow.right",
        .previousTab: "arrow.left.arrow.right",
        .splitRight: "rectangle.split.2x1",
        .splitDown: "rectangle.split.1x2",
        .equalizeSplits: "equal.square",
        .toggleSplitZoom: "arrow.up.left.and.arrow.down.right",
        .focusPaneLeft: "arrow.left",
        .focusPaneRight: "arrow.right",
        .focusPaneUp: "arrow.up",
        .focusPaneDown: "arrow.down",
        .find: "magnifyingglass",
        .findNext: "chevron.down",
        .findPrevious: "chevron.up",
        .nextPrompt: "arrow.down.to.line",
        .previousPrompt: "arrow.up.to.line",
        .increaseFontSize: "textformat.size.larger",
        .decreaseFontSize: "textformat.size.smaller",
        .resetFontSize: "textformat.size",
        .commandPalette: "text.magnifyingglass"
    ]

    var iconName: String {
        Self.iconNames[self] ?? "questionmark"
    }

    /// Default shortcut. Mirrors the bindings the macOS menu shipped
    /// with before Pattern A; users who never visit Keyboard see
    /// exactly the menu shortcuts they're used to.
    ///
    /// Keys store the **literal character** the user presses (not a
    /// physical-key name). That's what makes us layout-agnostic:
    /// libghostty's match cascade (physical → utf8 → unshifted) hits
    /// our unicode trigger regardless of whether the user is on US
    /// or JIS, because at least one of the three tries lands on the
    /// same codepoint. Named keys (return, left, …) stay as named
    /// strings because they aren't layout-dependent and don't have a
    /// useful literal character.
    var defaultShortcut: StoredShortcut? {
        switch self {
        case .newTab: .init(key: "t", modifiers: [.command])
        case .newWorktree: .init(key: "n", modifiers: [.command, .option])
        case .renameTab: .init(key: "r", modifiers: [.command, .shift])
        case .reopenClosedTab: .init(key: "t", modifiers: [.command, .shift])
        case .closeSurface: .init(key: "w", modifiers: [.command])
        case .closeTab: .init(key: "w", modifiers: [.command, .option])
        case .toggleSidebar: .init(key: "b", modifiers: [.command])
        case .toggleTabLayout: .init(key: "t", modifiers: [.command, .option])
        case .notificationHistory: .init(key: "n", modifiers: [.command, .shift])
        case .nextSection: .init(key: "]", modifiers: [.command])
        case .previousSection: .init(key: "[", modifiers: [.command])
        case .nextTab: .init(key: "]", modifiers: [.command, .shift])
        case .previousTab: .init(key: "[", modifiers: [.command, .shift])
        case .splitRight: .init(key: "d", modifiers: [.command])
        case .splitDown: .init(key: "d", modifiers: [.command, .shift])
        case .equalizeSplits: .init(key: "=", modifiers: [.command, .option])
        case .toggleSplitZoom: .init(key: "return", modifiers: [.command, .shift])
        case .focusPaneLeft: .init(key: "left", modifiers: [.command, .option])
        case .focusPaneRight: .init(key: "right", modifiers: [.command, .option])
        case .focusPaneUp: .init(key: "up", modifiers: [.command, .option])
        case .focusPaneDown: .init(key: "down", modifiers: [.command, .option])
        case .find: .init(key: "f", modifiers: [.command])
        case .findNext: .init(key: "g", modifiers: [.command])
        case .findPrevious: .init(key: "g", modifiers: [.command, .shift])
        case .nextPrompt: .init(key: "down", modifiers: [.command])
        case .previousPrompt: .init(key: "up", modifiers: [.command])
        // ⌘+ is the cross-app convention (iTerm2 / Ghostty /
        // Terminal.app / Safari / Chrome all use shift+equal).
        // Stored as `= + [.command, .shift]` because libghostty's
        // matcher hits this binding via the `unshifted_codepoint`
        // fallback (=) on US layouts and the `utf8` fallback (=) on
        // JIS layouts, where the physical key that produces `=`
        // differs but the resulting character is the same.
        case .increaseFontSize: .init(key: "=", modifiers: [.command, .shift])
        case .decreaseFontSize: .init(key: "-", modifiers: [.command])
        case .resetFontSize: .init(key: "0", modifiers: [.command])
        case .commandPalette: .init(key: "p", modifiers: [.command, .shift])
        case .quickOpen: .init(key: "p", modifiers: [.command])
        }
    }
}

// MARK: - Modifiers

/// Modifier bitset. We don't use `NSEvent.ModifierFlags` directly in
/// the Codable layer because its raw values are AppKit-private and
/// can shift across SDK revisions — pin our own stable set.
struct ShortcutModifiers: OptionSet, Codable, Hashable {
    let rawValue: UInt8

    static let command = ShortcutModifiers(rawValue: 1 << 0)
    static let shift = ShortcutModifiers(rawValue: 1 << 1)
    static let option = ShortcutModifiers(rawValue: 1 << 2)
    static let control = ShortcutModifiers(rawValue: 1 << 3)

    /// Ghostty modifier names, joined with `+` in canonical order:
    /// super, ctrl, alt, shift. Order matters for libghostty's
    /// trigger parser only loosely (it accepts any), but we pin one
    /// order so unit tests and round-trips are stable.
    var ghosttyTokens: [String] {
        var tokens: [String] = []
        if contains(.command) { tokens.append("super") }
        if contains(.control) { tokens.append("ctrl") }
        if contains(.option) { tokens.append("alt") }
        if contains(.shift) { tokens.append("shift") }
        return tokens
    }

    /// macOS symbol order matches Apple's HIG: ⌃⌥⇧⌘.
    var displaySymbols: String {
        var out = ""
        if contains(.control) { out += "⌃" }
        if contains(.option) { out += "⌥" }
        if contains(.shift) { out += "⇧" }
        if contains(.command) { out += "⌘" }
        return out
    }

    /// SwiftUI `EventModifiers` equivalent — used by
    /// `View+limpidShortcut` to wire the menu bar shortcut.
    var swiftUIEventModifiers: EventModifiers {
        var out: EventModifiers = []
        if contains(.command) { out.insert(.command) }
        if contains(.shift) { out.insert(.shift) }
        if contains(.option) { out.insert(.option) }
        if contains(.control) { out.insert(.control) }
        return out
    }
}

// MARK: - Stored shortcut

/// On-disk representation of a single binding. `key` is either:
///
///   - A **literal character** (`"t"`, `"="`, `"["`, `"0"`, …) — what
///     the user's keyboard produces (unshifted). Stored as a literal
///     so libghostty's match cascade resolves it via utf8 /
///     unshifted_codepoint, which is layout-agnostic.
///
///   - A **named key** (`"return"`, `"left"`, `"f1"`, …) — for keys
///     that don't have a single useful character (arrows, function
///     keys, modifiers). These map to Ghostty's physical-key enum
///     and to SwiftUI's `KeyEquivalent` constants.
///
/// Why not use Ghostty's `equal` / `bracket_left` / `digit_0` names
/// for punctuation? Those parse as **physical** keys in libghostty,
/// which fails on non-US layouts: a JIS user pressing shift+- to
/// produce `=` triggers `physical.minus`, not `physical.equal`, so
/// `keybind = super+shift+equal=…` never fires. Literals route
/// through the codepoint fallbacks instead and hit any layout.
struct StoredShortcut: Codable, Hashable {
    var key: String
    var modifiers: ShortcutModifiers

    /// `super+shift+t` — left-hand side of a `keybind = …` line.
    ///
    /// Single-character keys emit literally (Ghostty parses them as
    /// unicode codepoints). Named keys emit their Ghostty enum-field
    /// name. The literal `+` would split ambiguously across the
    /// trigger parser's `+` separator, so we route it through the
    /// `plus` alias.
    var ghosttyTrigger: String {
        // `+` only needs the alias for libghostty's parser;
        // `displayString` keeps the literal character as-is.
        let emitted = key == "+" ? "plus" : key
        return (modifiers.ghosttyTokens + [emitted]).joined(separator: "+")
    }

    /// `⌘⇧T` — what the Keyboard pane row shows on the right.
    ///
    /// We render exactly what's stored — no `= + shift → +` shorthand.
    /// The cross-app convention of showing `⌘+` for font-increase is
    /// misleading on non-US layouts (on JIS `+` sits on shift+; while
    /// the actual key that fires our binding is shift+-, which
    /// produces `=`). Showing the literal `⇧⌘=` keeps the display
    /// honest about what physical keys trigger the action.
    var displayString: String {
        modifiers.displaySymbols + Self.displayKey(for: key)
    }

    /// `["⇧", "⌘", "T"]` — one token per keycap, in Apple's HIG order
    /// (⌃⌥⇧⌘ then the key glyph). `displayString` concatenates these
    /// for inline menu-style display; this splits them for surfaces
    /// that render each modifier and the key as its own chip (the
    /// welcome screen).
    var displayTokens: [String] {
        var tokens: [String] = []
        if modifiers.contains(.control) { tokens.append("⌃") }
        if modifiers.contains(.option) { tokens.append("⌥") }
        if modifiers.contains(.shift) { tokens.append("⇧") }
        if modifiers.contains(.command) { tokens.append("⌘") }
        tokens.append(Self.displayKey(for: key))
        return tokens
    }

    /// Single lookup table for every named key Limpid understands.
    /// Each row pairs the storage string (Ghostty's vocabulary) with
    /// (a) the glyph macOS shows in menus and (b) SwiftUI's
    /// `KeyEquivalent` constant — the two surfaces our renderers care
    /// about. Single-character keys (letters, digits, punctuation)
    /// aren't in here; they fall through to `key.uppercased()` for
    /// display and `KeyEquivalent(Character(key))` for SwiftUI.
    ///
    /// F-keys (`f1`–`f12`) appear with `swiftUI = nil`: SwiftUI's
    /// `KeyEquivalent` has no constants for them, so the menu glyph
    /// is dropped. libghostty's own keybind still fires whenever the
    /// terminal surface has focus, so the binding works — only the
    /// menu-visible affordance is missing.
    private static let namedKeys: [String: (glyph: String, swiftUI: KeyEquivalent?)] = [
        "return": ("⏎", .return),
        "enter": ("⏎", .return),
        "tab": ("⇥", .tab),
        "space": ("␣", .space),
        "escape": ("⎋", .escape),
        "backspace": ("⌫", .delete),
        "delete": ("⌦", .deleteForward),
        "left": ("←", .leftArrow),
        "right": ("→", .rightArrow),
        "up": ("↑", .upArrow),
        "down": ("↓", .downArrow),
        "home": ("↖", .home),
        "end": ("↘", .end),
        "page_up": ("⇞", .pageUp),
        "page_down": ("⇟", .pageDown),
        "f1": ("F1", nil), "f2": ("F2", nil), "f3": ("F3", nil),
        "f4": ("F4", nil), "f5": ("F5", nil), "f6": ("F6", nil),
        "f7": ("F7", nil), "f8": ("F8", nil), "f9": ("F9", nil),
        "f10": ("F10", nil), "f11": ("F11", nil), "f12": ("F12", nil)
    ]

    /// Map our stored key string to the glyph macOS shows in menus.
    /// Letters get uppercased; named keys (arrows, etc.) get their
    /// canonical symbol; punctuation and digits print as-is.
    private static func displayKey(for key: String) -> String {
        namedKeys[key]?.glyph ?? key.uppercased()
    }
}

// MARK: - SwiftUI bridge

extension StoredShortcut {

    /// Stored key → SwiftUI `KeyEquivalent`. Named keys come from
    /// `namedKeys`; single-character keys (letters / digits /
    /// punctuation) wrap as `KeyEquivalent(Character(key))`. Returns
    /// `nil` for stored values SwiftUI can't express — see the
    /// `namedKeys` doc for which ones (notably F-keys).
    var swiftUIKeyEquivalent: KeyEquivalent? {
        if let entry = Self.namedKeys[key] {
            return entry.swiftUI
        }
        return key.count == 1 ? KeyEquivalent(Character(key)) : nil
    }
}

// The `NSEvent` → `StoredShortcut` capture path lives in
// `KeyboardShortcut+Capture.swift` so this file can stay AppKit-free.

// MARK: - Reserved triggers

/// Shortcuts the user CANNOT remap because Limpid uses them for
/// numbered tab / section jumps (⌘1…⌘9 / ⌘⌃1…⌘⌃9). Those bindings
/// stay hardcoded in `LimpidApp`'s menu — they're parametric
/// (one shortcut per slot) and don't fit our flat enum cleanly.
/// The recorder rejects any attempt to bind to one of these so
/// users can't accidentally shadow tab-jump.
enum ReservedShortcuts {
    static let triggers: Set<String> = {
        var set: Set<String> = []
        // ⌘Q — system Quit. `SurfaceView.performKeyEquivalent`
        // routes it to `NSApp.terminate(nil)` so the normal
        // app-termination path (notification → state save) runs.
        // Letting a user remap ⌘Q to some other action would race
        // that termination path.
        set.insert(StoredShortcut(key: "q", modifiers: [.command]).ghosttyTrigger)
        // ⇧Enter — `GhosttyConfigBridge` always emits
        // `keybind = shift+enter=text:\n` so TUIs like Claude Code
        // can distinguish Enter from Shift+Enter. A user override
        // on the same trigger would double-emit and last-write-wins
        // would silently break the newline workaround.
        set.insert(StoredShortcut(key: "return", modifiers: [.shift]).ghosttyTrigger)
        for n in 1...9 {
            // ⌘0 is rebindable (it's resetFontSize's default).
            // ⌘1…⌘9 — go to tab N.
            set.insert(StoredShortcut(key: "\(n)", modifiers: [.command]).ghosttyTrigger)
            // ⌘⌃1…⌘⌃9 — go to section N.
            set.insert(
                StoredShortcut(key: "\(n)", modifiers: [.command, .control])
                    .ghosttyTrigger
            )
        }
        return set
    }()
}
