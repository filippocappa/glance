// SnapEngine.swift
// Glance
//
// Handles snapping the PiP window to screen corners and edges
// with fluid spring animations that feel native to macOS.
//
// Architecture Notes:
// ──────────────────
// SnapEngine is a pure-function utility (enum with no cases) that owns
// two responsibilities:
//
//   1. **Geometry** – Given a window size and a screen, compute the eight
//      canonical snap anchors (4 corners + 4 edge midpoints), respecting
//      a configurable margin from the visible screen edges.
//
//   2. **Animation** – Drive the window to a chosen anchor using
//      NSAnimationContext with a custom cubic-bezier timing function
//      that approximates a critically-damped spring, producing the
//      same "sticky" feel used by system PiP on macOS.
//
// The engine works entirely in AppKit screen coordinates (origin at
// bottom-left of the primary display). Callers — typically the window
// controller or a drag-end handler — ask for the nearest snap position,
// then pass the result to `animateSnap(window:to:)`.
//
// Usage:
//   let target = SnapEngine.snapPosition(for: window.frame, on: screen)
//   SnapEngine.animateSnap(window: window, to: target)

import AppKit

// MARK: - SnapEngine

/// Namespace for PiP window snap-to-edge / snap-to-corner logic.
///
/// Declared as a caseless `enum` so it cannot be instantiated — all
/// members are static, making this a true utility namespace.
enum SnapEngine {

    // MARK: Configuration

    /// Inset (in points) from each edge of the screen's visible frame.
    /// The visible frame already excludes the menu bar and Dock, so this
    /// margin provides additional breathing room from those system chrome
    /// boundaries.
    static let margin: CGFloat = 16

    /// Maximum distance (in points) between the window's current origin
    /// and a snap anchor for the snap to engage automatically. When the
    /// user releases a drag and the nearest anchor is farther than this
    /// threshold, the caller may choose to leave the window in place
    /// instead of animating.
    static let snapThreshold: CGFloat = 80

    // MARK: Anchor Calculation

    /// Computes the eight canonical snap positions for a window of the
    /// given size on the specified screen.
    ///
    /// The positions are expressed as `CGPoint` origins (bottom-left
    /// corner of the window frame in AppKit coordinates).
    ///
    /// Layout diagram (screen visible frame):
    /// ```
    ///  ┌──────────────────────────────────┐
    ///  │ TL          TC          TR       │
    ///  │                                  │
    ///  │ ML                      MR       │
    ///  │                                  │
    ///  │ BL          BC          BR       │
    ///  └──────────────────────────────────┘
    /// ```
    ///
    /// - Parameters:
    ///   - windowSize: The current (or desired) size of the PiP window.
    ///   - screen: The screen whose `visibleFrame` defines the snap region.
    /// - Returns: An array of four `CGPoint` values, one per corner.
    static func snapAnchors(for windowSize: CGSize, on screen: NSScreen) -> [CGPoint] {
        let visibleFrame = screen.visibleFrame
        let w = windowSize.width
        let h = windowSize.height

        // Pre-compute the four inset corners (respecting Menu Bar and Dock bounds)
        let left   = visibleFrame.minX + margin
        let right  = visibleFrame.maxX - w - margin
        let top    = visibleFrame.maxY - h - margin   // AppKit: Y grows upward
        let bottom = visibleFrame.minY + margin

        return [
            CGPoint(x: left,  y: top),      // Top-left
            CGPoint(x: right, y: top),      // Top-right
            CGPoint(x: left,  y: bottom),   // Bottom-left
            CGPoint(x: right, y: bottom)    // Bottom-right
        ]
    }

    // MARK: Nearest Anchor

    /// Returns the snap anchor closest to the window's current position.
    ///
    /// Distance is measured as the Euclidean distance between the
    /// window's origin and each anchor point.
    ///
    /// - Parameters:
    ///   - windowFrame: The window's current frame rectangle.
    ///   - screen: The screen to compute anchors for.
    /// - Returns: The `CGPoint` origin the window should animate to.
    static func snapPosition(for windowFrame: NSRect, on screen: NSScreen) -> CGPoint {
        let anchors = snapAnchors(for: windowFrame.size, on: screen)
        let currentOrigin = windowFrame.origin

        // Start with bottom-right as the fallback default
        var nearest = anchors[3]
        var minDistance = CGFloat.greatestFiniteMagnitude

        for anchor in anchors {
            let dx = anchor.x - currentOrigin.x
            let dy = anchor.y - currentOrigin.y
            let distance = sqrt(dx * dx + dy * dy)
            if distance < minDistance {
                minDistance = distance
                nearest = anchor
            }
        }

        return nearest
    }

    /// Snapping is always required for release in corner-only snap mode.
    ///
    /// - Parameters:
    ///   - windowFrame: The window's frame at the end of the drag.
    ///   - screen: The screen the window lives on.
    /// - Returns: Always `true` to ensure the window snaps to one of the 4 corners.
    static func shouldSnap(for windowFrame: NSRect, on screen: NSScreen) -> Bool {
        return true
    }

    // MARK: Animation

    /// Animates the window to the given origin with a spring-like curve.
    ///
    /// The animation uses `NSAnimationContext` with a custom cubic-bezier
    /// timing function whose control points `(0.2, 1.0, 0.3, 1.0)`
    /// approximate a critically-damped spring:
    ///
    /// - The curve overshoots very slightly at the start (fast ease-out),
    ///   then decelerates smoothly to rest — the same feel as the native
    ///   macOS Picture-in-Picture snap.
    /// - Duration is set to 0.5 s which, combined with the aggressive
    ///   ease-out, makes the window feel "pulled" toward the anchor.
    ///
    /// `allowsImplicitAnimation` is enabled so that `setFrameOrigin(_:)`
    /// on the window's animator proxy is enough to drive the position
    /// change through Core Animation.
    ///
    /// - Parameters:
    ///   - window: The PiP window to animate.
    ///   - targetOrigin: The destination origin (snap anchor point).
    static func animateSnap(window: NSWindow, to targetOrigin: CGPoint) {
        NSAnimationContext.runAnimationGroup { context in
            // Duration chosen to balance responsiveness with visual polish.
            context.duration = 0.5

            // Custom cubic-bezier that approximates a critically-damped
            // spring. Control points: P1(0.2, 1.0)  P2(0.3, 1.0).
            //
            //   • The high Y values on both control points create an
            //     aggressive ease-out — the window reaches its target
            //     quickly and decelerates over the remaining time.
            //   • Compared to `.easeInEaseOut` this feels more physical,
            //     closer to UIKit's `UISpringTimingParameters`.
            context.timingFunction = CAMediaTimingFunction(
                controlPoints: 0.2, 1.0, 0.3, 1.0
            )

            // Required for `animator().setFrameOrigin` to take effect
            // through the animation context.
            context.allowsImplicitAnimation = true

            window.animator().setFrameOrigin(targetOrigin)
        }
    }

    private static var activeTimer: Timer?

    /// Animates the window frame origin using a mathematically exact spring simulation.
    /// Uses response: 0.3, dampingFraction: 0.6.
    static func animateSpring(window: NSWindow, to targetOrigin: CGPoint) {
        activeTimer?.invalidate()

        let startOrigin = window.frame.origin
        let x0 = Double(startOrigin.x - targetOrigin.x)
        let y0 = Double(startOrigin.y - targetOrigin.y)

        let spring = AnalyticalSpring(response: 0.3, dampingFraction: 0.6)
        let startTime = Date()

        let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { timer in
            let elapsed = Date().timeIntervalSince(startTime)

            let solX = spring.solve(t: elapsed, x0: x0, v0: 0.0)
            let solY = spring.solve(t: elapsed, x0: y0, v0: 0.0)

            let currentX = targetOrigin.x + CGFloat(solX.x)
            let currentY = targetOrigin.y + CGFloat(solY.x)

            window.setFrameOrigin(CGPoint(x: currentX, y: currentY))

            // The settling duration for response=0.3, dampingFraction=0.6 is about 0.6s
            if elapsed >= 0.8 || (abs(solX.x) < 0.1 && abs(solY.x) < 0.1) {
                window.setFrameOrigin(targetOrigin)
                timer.invalidate()
            }
        }

        activeTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    /// Convenience that finds the nearest anchor *and* animates in one call.
    ///
    /// - Parameters:
    ///   - window: The PiP window to snap.
    ///   - screen: The screen whose visible frame defines snap positions.
    static func snapToNearest(window: NSWindow, on screen: NSScreen) {
        let target = snapPosition(for: window.frame, on: screen)
        animateSpring(window: window, to: target)
    }
}

// MARK: - AnalyticalSpring

/// A mathematically exact implementation of a spring simulation.
/// Solves the second-order differential equation for a spring damper.
struct AnalyticalSpring {
    let response: Double
    let dampingFraction: Double

    func solve(t: Double, x0: Double, v0: Double) -> (x: Double, v: Double) {
        let w0 = 2 * Double.pi / response

        if dampingFraction < 1.0 {
            // Underdamped
            let wd = w0 * sqrt(1.0 - dampingFraction * dampingFraction)
            let expTerm = exp(-dampingFraction * w0 * t)
            let cosTerm = cos(wd * t)
            let sinTerm = sin(wd * t)

            let c1 = x0
            let c2 = (v0 + dampingFraction * w0 * x0) / wd

            let x = expTerm * (c1 * cosTerm + c2 * sinTerm)
            let v = -dampingFraction * w0 * x + expTerm * (-c1 * wd * sinTerm + c2 * wd * cosTerm)
            return (x, v)
        } else if dampingFraction == 1.0 {
            // Critically damped
            let expTerm = exp(-w0 * t)
            let c1 = x0
            let c2 = v0 + w0 * x0

            let x = expTerm * (c1 + c2 * t)
            let v = -w0 * x + expTerm * c2
            return (x, v)
        } else {
            // Overdamped
            let r1 = -w0 * (dampingFraction - sqrt(dampingFraction * dampingFraction - 1.0))
            let r2 = -w0 * (dampingFraction + sqrt(dampingFraction * dampingFraction - 1.0))

            let c1 = (v0 - r2 * x0) / (r1 - r2)
            let c2 = x0 - c1

            let x = c1 * exp(r1 * t) + c2 * exp(r2 * t)
            let v = c1 * r1 * exp(r1 * t) + c2 * r2 * exp(r2 * t)
            return (x, v)
        }
    }
}
