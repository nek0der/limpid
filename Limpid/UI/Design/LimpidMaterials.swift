// LimpidMaterials.swift
// Limpid — glass-layer material tokens; maps design-rules.md §1–§3
// into reusable SwiftUI material constants.

import SwiftUI

/// Limpid glass-layer definitions. Maps design-rules.md §1–§3 into SwiftUI.
///
/// **Usage**:
/// ```swift
/// SomeView()
///     .limpidGlass(.sidebar)
/// ```
/// applies the matching material, corner radius, shadow, and rim highlight
/// in one call.
enum LimpidGlassLayer {
    /// Main pane — the glass slab around the libghostty drawing area.
    case mainPane
    /// Left sidebar — the thinnest layer; lets the background show through.
    case sidebar
    /// Right-side Blocks panel.
    case blocks
    /// Nested card inside Blocks (individual block).
    case innerCard
    /// Floating bottom status bar.
    case statusBar
    /// Command palette — top-most layer, largest corner radius and strongest blur.
    case palette

    private var material: Material {
        switch self {
        case .sidebar, .blocks: .ultraThinMaterial
        case .innerCard: .thinMaterial
        case .mainPane, .statusBar: .regularMaterial
        case .palette: .thickMaterial
        }
    }

    /// Design value §3.1.
    fileprivate var cornerRadius: CGFloat {
        switch self {
        case .innerCard: 8
        case .palette: 16
        default: 14
        }
    }

}

// MARK: - View modifier

extension View {
    /// Apply the standard Limpid glass treatment for the given layer.
    func limpidGlass(_ layer: LimpidGlassLayer) -> some View {
        modifier(LimpidGlassModifier(layer: layer))
    }
}

private struct LimpidGlassModifier: ViewModifier {
    let layer: LimpidGlassLayer

    func body(content: Content) -> some View {
        // macOS 26 / iOS 26 ships the native Liquid Glass material via
        // `.glassEffect(_:in:)`. Use it; it provides the refraction,
        // depth, and built-in shadow that hand-rolled Materials can't —
        // stacking a manual `.shadow` underneath read as a dark cloud
        // in light mode, so we leave depth entirely to the system.
        content.glassEffect(
            layer.glass,
            in: RoundedRectangle(cornerRadius: layer.cornerRadius, style: .continuous)
        )
    }
}

private extension LimpidGlassLayer {
    /// Glass variant per layer. `.regular` is the standard Liquid Glass
    /// material; `.clear` is more transparent (for the lightest panels).
    var glass: Glass {
        switch self {
        case .sidebar, .blocks: .clear
        case .innerCard: .regular
        case .mainPane: .regular
        case .statusBar: .regular
        case .palette: .regular
        }
    }
}
