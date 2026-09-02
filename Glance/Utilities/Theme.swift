// Theme.swift
// Glance
//
// A strictly monochrome design system.
//
// Glance draws over the user's own content — their windows, their wallpaper,
// their video. A brand hue competes with all of it and dates quickly; white at
// graded alphas reads correctly against anything, which is why the system UI
// (screenshot selection, window chrome) works the same way.
//
// There is exactly one colour here. Depth comes from the alpha ladder below,
// never from a second hue.

import SwiftUI
import AppKit

enum Theme {

    // MARK: Alpha ladder
    //
    // Every tint in the app is white at one of these levels. Introducing an
    // intermediate value is usually a sign the hierarchy is wrong, not that a
    // new step is needed.

    /// Primary content: active icons, key text, the selection border.
    static let primaryAlpha: CGFloat = 1.00
    /// Secondary content: inactive icons, supporting text.
    static let secondaryAlpha: CGFloat = 0.70
    /// Tertiary: hairlines and inactive strokes.
    static let tertiaryAlpha: CGFloat = 0.30
    /// Subtle fills: hover washes, selected backgrounds.
    static let subtleAlpha: CGFloat = 0.15
    /// Borders on frosted surfaces.
    static let borderAlpha: CGFloat = 0.12

    // MARK: Accent
    //
    // Named `accent` so call sites read intentionally, but it is pure white.
    // Anything that needs to recede uses `.opacity()` from the ladder above.

    static let accent = Color.white
    static let accentNSColor = NSColor.white

    /// Solid white for the primary action pill, and the dark ink that sits on it.
    static let mono = Color.white
    static let onMono = Color(.sRGB, red: 0.06, green: 0.07, blue: 0.09)

    /// Control tint (toggles, shortcut recorder pills). Pure white, not silver:
    /// a grey tint reads as a disabled control rather than an active one.
    static let monoTint = Color.white

    // MARK: Surfaces
    //
    // Vocabulary shared with Hum so the two apps read as one family: the same
    // card fills, hairline strokes, corner radii and transition curve.

    /// Card surfaces, shared by the splash rows and the control HUD.
    static let cardFill = Color.white.opacity(0.04)
    static let cardFillHover = Color.white.opacity(0.08)
    static let cardStroke = Color.white.opacity(borderAlpha)
    static let hairline = Color.primary.opacity(0.08)

    /// Darkening laid over the vibrancy so light text keeps its contrast.
    /// Raising this trades legibility for translucency.
    static let scrim = 0.30

    /// Card corner radius. Continuous curvature, matching macOS geometry.
    static let cardRadius: CGFloat = 11

    /// Window corner radius.
    static let cornerRadius: CGFloat = 20

    /// Every state change uses this exact curve, so tinted elements cross-fade
    /// as one rather than at three speeds.
    static let accentTransition = Animation.easeInOut(duration: 0.25)
}
