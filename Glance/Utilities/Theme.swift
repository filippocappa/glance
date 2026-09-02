// Theme.swift
// Glance
//
// The single source of truth for Glance's accent colour.
//
// Everything tinted in the app — selection crosshairs, the drag rectangle,
// active hover controls, the splash, the menu bar icon's active state and the
// app icon itself — resolves through here, so the palette can be changed in one
// place. `Assets.xcassets/AccentColor.colorset` carries the same values so that
// SwiftUI's `Color.accentColor` and AppKit's `NSColor.controlAccentColor`
// fallbacks match rather than reverting to system blue.

import SwiftUI
import AppKit

enum Theme {

    // MARK: Accent — electric cyan

    /// Primary accent. sRGB #0FCBF5.
    static let accentComponents: (r: CGFloat, g: CGFloat, b: CGFloat) = (0.059, 0.796, 0.961)

    /// Deeper end of the accent, for gradients and pressed states. sRGB #0A87C4.
    static let accentDeepComponents: (r: CGFloat, g: CGFloat, b: CGFloat) = (0.039, 0.529, 0.769)

    static let accent = Color(
        .sRGB,
        red: accentComponents.r,
        green: accentComponents.g,
        blue: accentComponents.b
    )

    static let accentDeep = Color(
        .sRGB,
        red: accentDeepComponents.r,
        green: accentDeepComponents.g,
        blue: accentDeepComponents.b
    )

    /// Top-left → bottom-right accent gradient used on the splash glyph and
    /// the app icon's foreground panel.
    static let accentGradient = LinearGradient(
        colors: [accent, accentDeep],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    // MARK: AppKit equivalents

    static let accentNSColor = NSColor(
        srgbRed: accentComponents.r,
        green: accentComponents.g,
        blue: accentComponents.b,
        alpha: 1.0
    )

    // MARK: Surfaces
    //
    // Vocabulary shared with Hum so the two apps read as one family: the same
    // card fills, hairline strokes, corner radii and transition curve.

    /// Card surfaces, shared by the splash rows and the settings sheet.
    static let cardFill = Color.white.opacity(0.04)
    static let cardFillHover = Color.white.opacity(0.08)
    static let cardStroke = Color.white.opacity(0.08)
    static let hairline = Color.primary.opacity(0.08)

    /// Darkening laid over the vibrancy so light text keeps its contrast.
    /// Raising this trades legibility for translucency.
    static let scrim = 0.30

    /// Card corner radius. Continuous curvature, matching macOS geometry.
    static let cardRadius: CGFloat = 11

    /// Window corner radius.
    static let cornerRadius: CGFloat = 20

    /// Every accent-driven change uses this exact curve, so tinted elements
    /// cross-fade as one rather than at three speeds.
    static let accentTransition = Animation.easeInOut(duration: 0.25)

    // MARK: AppKit equivalents

    static let accentDeepNSColor = NSColor(
        srgbRed: accentDeepComponents.r,
        green: accentDeepComponents.g,
        blue: accentDeepComponents.b,
        alpha: 1.0
    )
}
