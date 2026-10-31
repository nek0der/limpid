// SurfaceRegistry+PaneOcclusion.swift
// Weir — lets the window registry put terminals to sleep through the surface registry.

/// The window registry hands the union of every window's visible panes
/// here. Declared in the app layer because Core cannot name a
/// Presentation protocol.
extension SurfaceRegistry: PaneOcclusionApplying {}
