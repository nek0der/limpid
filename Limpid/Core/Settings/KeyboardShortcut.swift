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
    case help

    var id: Int {
        rawValue
    }

    /// SwiftUI-only `Text` literal (consumed by `Text(_:)` directly).
    /// Kept as `LocalizedStringKey` rather than the broader
    /// `LocalizedStringResource` because category titles are only
    /// ever rendered inside the Settings pane — we never need to
    /// concatenate them or resolve them to a `String`. Surfaces that do
    /// (the cheat sheet, Settings search) use `resourceTitle`, and the
    /// action vocabulary uses `LocalizedStringResource` throughout.
    var sectionTitle: LocalizedStringKey {
        switch self {
        case .file: "File"
        case .view: "View"
        case .navigation: "Navigation"
        case .splits: "Splits"
        case .search: "Find"
        case .terminal: "Terminal"
        case .font: "Font"
        case .help: "Help"
        }
    }
}

// MARK: - Actions

/// Every action the user can rebind. When adding a new case,
/// update these locations:
///   1. `defaultShortcut`, `localizedTitle`, `category`, `ghosttyAction`
///   2. `TabActions.dispatchShortcutAction` (palette dispatch)
///   3. `CommandPaletteCatalog.icon(for:)` + `isActionEnabled`
///   4. `iconNames` dictionary (same file) — missing entries fall back to
///      a placeholder, so omissions ship.
///   5. `LimpidApp.commands` block (menu bar Button)
///
/// 1–3 are compiler-enforced via switch exhaustiveness; 4–5 are manual.
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
    case reviewChanges
    case reviewTurn

    // Navigation (container + tab cycling)
    case nextSection
    case previousSection
    case nextTab
    case previousTab
    /// Jump focus to the next / previous pane whose agent needs the
    /// user (needsInput / error) — cross-tab attention cursor. Displayed
    /// as "Next/Previous Action" (the agent is waiting on the user to
    /// act); the symbol keeps the "attention" intent.
    case nextAttention
    case previousAttention

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

    /// Help. Opens the read-only cheat sheet listing every binding above
    /// (plus the reserved and system-wide ones). Lives in its own
    /// category so Settings → Keyboard and the sheet group it under
    /// Help, matching the menu that owns it.
    case keyboardShortcuts

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
        case .toggleSidebar, .toggleTabLayout, .notificationHistory, .reviewChanges, .reviewTurn: .view
        case .nextSection, .previousSection, .nextTab, .previousTab,
             .nextAttention, .previousAttention: .navigation
        case .splitRight, .splitDown, .equalizeSplits, .toggleSplitZoom,
             .focusPaneLeft, .focusPaneRight, .focusPaneUp, .focusPaneDown: .splits
        case .find, .findNext, .findPrevious: .search
        case .nextPrompt, .previousPrompt: .terminal
        case .increaseFontSize, .decreaseFontSize, .resetFontSize: .font
        case .commandPalette, .quickOpen: .view
        case .keyboardShortcuts: .help
        }
    }

    /// libghostty action string for `keybind = trigger=action`, or
    /// `nil` when the menu bar owns the shortcut. Only actions with
    /// **no menu item** get a non-`nil` value: the menu bar's
    /// `keyboardShortcut` and libghostty's keybind table would
    /// otherwise both match the same keystroke and fire their
    /// handlers in parallel (menu → `TabActions.…`, libghostty
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
        // notification fires `TabActions.…` directly.
        case .newTab, .newWorktree, .renameTab, .reopenClosedTab,
             .closeSurface, .closeTab, .toggleSidebar, .toggleTabLayout,
             .notificationHistory, .reviewChanges, .reviewTurn,
             .nextSection, .previousSection, .nextTab, .previousTab,
             .nextAttention, .previousAttention,
             .splitRight, .splitDown,
             .equalizeSplits, .toggleSplitZoom,
             .focusPaneLeft, .focusPaneRight,
             .focusPaneUp, .focusPaneDown,
             .find, .findNext, .findPrevious,
             .commandPalette, .quickOpen, .keyboardShortcuts: nil
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
        case .reviewChanges: "Review Changes"
        case .reviewTurn: "Review This Turn"
        case .nextSection: "Next Section"
        case .previousSection: "Previous Section"
        case .nextTab: "Next Tab"
        case .previousTab: "Previous Tab"
        case .nextAttention: "Next Action"
        case .previousAttention: "Previous Action"
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
        case .keyboardShortcuts: "Keyboard Shortcuts"
        }
    }

    /// SF Symbol displayed next to this action in the command palette
    /// and the Keyboard pane. A `switch` instead of a dictionary so
    /// `LimpidShortcutAction.allCases` adding a new case fails the
    /// build until the icon is picked — the prior `[Action: String]`
    /// map silently fell back to `"questionmark"`.
    var iconName: String {
        switch self {
        case .newTab: "plus"
        case .newWorktree: "arrow.triangle.branch"
        case .renameTab: "pencil"
        case .reopenClosedTab: "arrow.uturn.backward"
        case .closeSurface: "xmark.square"
        case .closeTab: "xmark"
        case .toggleSidebar: "sidebar.left"
        case .toggleTabLayout: "rectangle.topthird.inset.filled"
        case .notificationHistory: "bell"
        case .reviewChanges: ReviewPresentation.symbol
        case .reviewTurn: ReviewPresentation.symbol
        case .nextSection: "chevron.left.chevron.right"
        case .previousSection: "chevron.left.chevron.right"
        case .nextTab: "arrow.left.arrow.right"
        case .previousTab: "arrow.left.arrow.right"
        case .nextAttention: "arrow.right.to.line"
        case .previousAttention: "arrow.left.to.line"
        case .splitRight: "rectangle.split.2x1"
        case .splitDown: "rectangle.split.1x2"
        case .equalizeSplits: "equal.square"
        case .toggleSplitZoom: "arrow.up.left.and.arrow.down.right"
        case .focusPaneLeft: "arrow.left"
        case .focusPaneRight: "arrow.right"
        case .focusPaneUp: "arrow.up"
        case .focusPaneDown: "arrow.down"
        case .find: "magnifyingglass"
        case .findNext: "chevron.down"
        case .findPrevious: "chevron.up"
        case .nextPrompt: "arrow.down.to.line"
        case .previousPrompt: "arrow.up.to.line"
        case .increaseFontSize: "textformat.size.larger"
        case .decreaseFontSize: "textformat.size.smaller"
        case .resetFontSize: "textformat.size"
        case .commandPalette: "text.magnifyingglass"
        case .quickOpen: "doc.text.magnifyingglass"
        case .keyboardShortcuts: "keyboard"
        }
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
        case .reviewChanges: .init(key: "r", modifiers: [.command, .option])
        case .reviewTurn: .init(key: "j", modifiers: [.command, .option])
        case .nextSection: .init(key: "]", modifiers: [.command])
        case .previousSection: .init(key: "[", modifiers: [.command])
        case .nextTab: .init(key: "]", modifiers: [.command, .shift])
        case .previousTab: .init(key: "[", modifiers: [.command, .shift])
        case .nextAttention: .init(key: "j", modifiers: [.command])
        case .previousAttention: .init(key: "j", modifiers: [.command, .shift])
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
        // ⌘+ is the cross-app zoom convention — `⇧=` on a US keyboard layout.
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
        // ⌘/ is the cross-app convention for a shortcut cheat sheet
        // (Slack, Linear, the Claude app). Stored as the literal `/`
        // so JIS layouts, where the key sits elsewhere, still match
        // through libghostty's utf8 fallback.
        case .keyboardShortcuts: .init(key: "/", modifiers: [.command])
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
        if contains(.command) {
            tokens.append("super")
        }
        if contains(.control) {
            tokens.append("ctrl")
        }
        if contains(.option) {
            tokens.append("alt")
        }
        if contains(.shift) {
            tokens.append("shift")
        }
        return tokens
    }

    /// macOS symbol order matches Apple's HIG: ⌃⌥⇧⌘.
    var displaySymbols: String {
        var out = ""
        if contains(.control) {
            out += "⌃"
        }
        if contains(.option) {
            out += "⌥"
        }
        if contains(.shift) {
            out += "⇧"
        }
        if contains(.command) {
            out += "⌘"
        }
        return out
    }

    /// SwiftUI `EventModifiers` equivalent — used by
    /// `View+limpidShortcut` to wire the menu bar shortcut.
    var swiftUIEventModifiers: EventModifiers {
        var out: EventModifiers = []
        if contains(.command) {
            out.insert(.command)
        }
        if contains(.shift) {
            out.insert(.shift)
        }
        if contains(.option) {
            out.insert(.option)
        }
        if contains(.control) {
            out.insert(.control)
        }
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
///     and to a SwiftUI `KeyEquivalent` (see `NamedKey.keyEquivalent`). Our stored `return`
///     name becomes Ghostty's `enter` alias at serialization time.
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
        let emitted = switch key {
        case "+": "plus"
        case "return": "enter"
        default: key
        }
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
        if modifiers.contains(.control) {
            tokens.append("⌃")
        }
        if modifiers.contains(.option) {
            tokens.append("⌥")
        }
        if modifiers.contains(.shift) {
            tokens.append("⇧")
        }
        if modifiers.contains(.command) {
            tokens.append("⌘")
        }
        tokens.append(Self.displayKey(for: key))
        return tokens
    }

    /// Map our stored key string to the glyph macOS shows in menus.
    /// Letters get uppercased; named keys (arrows, etc.) get their
    /// canonical symbol; punctuation and digits print as-is.
    private static func displayKey(for key: String) -> String {
        NamedKey(storedName: key)?.glyph ?? key.uppercased()
    }
}

// MARK: - SwiftUI bridge

extension StoredShortcut {

    /// Stored key → SwiftUI `KeyEquivalent`. Named keys come from
    /// `NamedKey.keyEquivalent`; single-character keys (letters / digits /
    /// punctuation) wrap as `KeyEquivalent(Character(key))`. Returns
    /// `nil` only for a stored value that is neither, which a hand-edited
    /// settings file can produce.
    var swiftUIKeyEquivalent: KeyEquivalent? {
        if let named = NamedKey(storedName: key) {
            return named.keyEquivalent
        }
        return key.count == 1 ? KeyEquivalent(Character(key)) : nil
    }
}

extension NamedKey {
    /// The glyph macOS shows for this key in menus.
    var glyph: String {
        switch self {
        case .return: "⏎"
        case .tab: "⇥"
        case .space: "␣"
        case .escape: "⎋"
        case .backspace: "⌫"
        case .delete: "⌦"
        case .left: "←"
        case .right: "→"
        case .up: "↑"
        case .down: "↓"
        case .home: "↖"
        case .end: "↘"
        case .pageUp: "⇞"
        case .pageDown: "⇟"
        default: rawValue.uppercased()
        }
    }

    /// The key a menu item needs to fire on this key. `KeyEquivalent` has
    /// constants only for the keys it names; for a function key we hand it
    /// the character AppKit itself uses for that key, one of the private-use
    /// characters from `NSF1FunctionKey` (U+F704) upward. SwiftUI passes the
    /// character through to `NSMenuItem.keyEquivalent` unchanged, so the
    /// menu both shows the key and fires on it, and a menu-owned action bound
    /// to a function key works like one bound to a letter.
    var keyEquivalent: KeyEquivalent {
        switch self {
        case .return: .return
        case .tab: .tab
        case .space: .space
        case .escape: .escape
        case .backspace: .delete
        case .delete: .deleteForward
        case .left: .leftArrow
        case .right: .rightArrow
        case .up: .upArrow
        case .down: .downArrow
        case .home: .home
        case .end: .end
        case .pageUp: .pageUp
        case .pageDown: .pageDown
        case .f1, .f2, .f3, .f4, .f5, .f6, .f7, .f8, .f9, .f10,
             .f11, .f12, .f13, .f14, .f15, .f16, .f17, .f18, .f19, .f20:
            KeyEquivalent(Character(Self.functionKeyCharacter(number: functionKeyNumber ?? 1)))
        }
    }

    /// AppKit numbers the function-key characters contiguously from F1, so
    /// F*n* is U+F704 + *n* − 1. We write the value out rather than read
    /// `NSF1FunctionKey` because this file stays free of AppKit; the tests
    /// check each key against AppKit's constants.
    private static func functionKeyCharacter(number: Int) -> Unicode.Scalar {
        // The sum stays inside the Private Use Area for every key we name,
        // which is never a surrogate, so the initializer cannot fail; the
        // fallback only keeps the accessor total.
        Unicode.Scalar(UInt32(0xF704 + number - 1)) ?? "\u{F704}"
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
        // ⇧↩ — `GhosttyConfigBridge` always emits
        // `keybind = shift+enter=text:\n` so TUIs like Claude Code
        // can distinguish ↩ from ⇧↩. A user override
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
