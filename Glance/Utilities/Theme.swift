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

    static let accentDeepNSColor = NSColor(
        srgbRed: accentDeepComponents.r,
        green: accentDeepComponents.g,
        blue: accentDeepComponents.b,
        alpha: 1.0
    )
}
