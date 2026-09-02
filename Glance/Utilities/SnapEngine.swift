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
import QuartzCore

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

    /// Maximum distance (in points) between the window's origin and a corner
    /// anchor for a snap to engage on release.
    ///
    /// This used to be declared and never read: `snapPosition` returned the
    /// nearest corner unconditionally and the drag handler always animated to
    /// it, so the panel sprang back to a corner from anywhere on screen and
    /// could not be left in the middle. Honouring the threshold is what makes
    /// the window releasable; the value is deliberately small so the pull is
    /// felt only right at a corner.
    static let snapThreshold: CGFloat = 64

    /// Release speed, in points per second, above which a drag is treated as a
    /// flick and carries momentum instead of stopping dead.
    static let flickThreshold: CGFloat = 220

    /// How far ahead a flick is projected when choosing its snap target.
    ///
    /// This is the time constant of the decay, not the full glide duration —
    /// the spring does the actual deceleration. 0.22s makes a firm flick reach
    /// a corner from roughly a third of the screen away.
    static let projectionInterval: CGFloat = 0.22

    /// Upper bound on tracked velocity. A single stray sample across two frames
    /// can otherwise report thousands of points per second.
    static let maxFlickSpeed: CGFloat = 3600

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
    static func nearestAnchor(for windowFrame: NSRect, on screen: NSScreen) -> (point: CGPoint, distance: CGFloat) {
        let anchors = snapAnchors(for: windowFrame.size, on: screen)
        let origin = windowFrame.origin

        var nearest = anchors[3]
        var minDistance = CGFloat.greatestFiniteMagnitude

        for anchor in anchors {
            let dx = anchor.x - origin.x
            let dy = anchor.y - origin.y
            let distance = (dx * dx + dy * dy).squareRoot()
            if distance < minDistance {
                minDistance = distance
                nearest = anchor
            }
        }
        return (nearest, minDistance)
    }

    /// The corner to snap to on release, or `nil` when the window was dropped
    /// far enough from every corner to be left where it is.
    ///
    /// All four anchors are produced by the same inset arithmetic in
    /// ``snapAnchors(for:on:)`` and compared with the same Euclidean distance,
    /// so attraction and release behave identically at every corner.
    static func snapPosition(for windowFrame: NSRect, on screen: NSScreen) -> CGPoint? {
        let nearest = nearestAnchor(for: windowFrame, on: screen)
        return nearest.distance <= snapThreshold ? nearest.point : nil
    }

    /// The corner to place a freshly created panel at — always snaps, since
    /// there is no user intent to respect yet.
    static func initialPosition(for windowFrame: NSRect, on screen: NSScreen) -> CGPoint {
        nearestAnchor(for: windowFrame, on: screen).point
    }

    /// Where a flick would come to rest, ignoring snapping.
    ///
    /// Used to choose the snap target: a window thrown *toward* a corner should
    /// land in it, even though the release point itself was nowhere near.
    static func projectedOrigin(
        from frame: NSRect,
        velocity: CGVector,
        on screen: NSScreen
    ) -> CGPoint {
        let projected = NSRect(
            x: frame.minX + velocity.dx * projectionInterval,
            y: frame.minY + velocity.dy * projectionInterval,
            width: frame.width,
            height: frame.height
        )
        return clampOnScreen(projected, on: screen)
    }

    /// Keeps a window fully on screen, so it can never be dropped out of reach.
    static func clampOnScreen(_ frame: NSRect, on screen: NSScreen) -> CGPoint {
        let visible = screen.visibleFrame
        return CGPoint(
            x: min(max(frame.minX, visible.minX), max(visible.minX, visible.maxX - frame.width)),
            y: min(max(frame.minY, visible.minY), max(visible.minY, visible.maxY - frame.height))
        )
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

    /// Drives the settle animation, retained so it can be cancelled.
    private static var settleLink: CADisplayLink?
    private static var settleTick: ((CADisplayLink) -> Void)?

    /// Stops any in-flight snap animation.
    ///
    /// The spring writes `setFrameOrigin` every frame. If the user grabs the
    /// window while that is still running, the animation and the drag both write
    /// the origin and the window visibly judders. Every interactive gesture
    /// cancels the spring first.
    static func cancelAnimation() {
        settleLink?.invalidate()
        settleLink = nil
        settleTick = nil
    }

    /// Settles the window to `targetOrigin` with one analytically-solved spring.
    ///
    /// Driven by `CADisplayLink` rather than a `Timer`. A 120 Hz timer is not
    /// aligned to the display's refresh, so frames land at arbitrary phases
    /// relative to vsync and the motion stutters even though the maths is
    /// smooth. A display link fires once per frame, in step with the compositor.
    /// - Parameters:
    ///   - velocity: Release velocity in points per second. The spring solver
    ///     already models a damped oscillator with an initial velocity term, so
    ///     a throw is expressed by seeding `v0` rather than by bolting a
    ///     separate friction phase in front of the animation. Momentum and
    ///     snapping are then the same motion, not two chained ones.
    ///   - screen: When given, every frame is clamped to its `visibleFrame`, so
    ///     an underdamped overshoot can never carry the window off-screen.
    static func animateSpring(
        window: NSWindow,
        to targetOrigin: CGPoint,
        velocity: CGVector = .zero,
        on screen: NSScreen? = nil
    ) {
        cancelAnimation()

        let startOrigin = window.frame.origin
        let dx = Double(startOrigin.x - targetOrigin.x)
        let dy = Double(startOrigin.y - targetOrigin.y)
        let vx = Double(velocity.dx)
        let vy = Double(velocity.dy)

        // Already there and not moving — nothing to animate.
        guard abs(dx) > 0.5 || abs(dy) > 0.5 || abs(vx) > 1 || abs(vy) > 1 else {
            window.setFrameOrigin(targetOrigin)
            return
        }

        // A thrown window gets a longer, looser spring so the glide reads as
        // momentum decaying rather than as a snap that happens to start fast.
        let thrown = hypot(vx, vy) > Double(flickThreshold)
        let spring = thrown
            ? AnalyticalSpring(response: 0.45, dampingFraction: 0.82)
            : AnalyticalSpring(response: 0.3, dampingFraction: 0.6)
        let settleTime = thrown ? 1.2 : 0.8
        let start = CACurrentMediaTime()

        let tick: (CADisplayLink) -> Void = { link in
            let elapsed = CACurrentMediaTime() - start
            let x = spring.solve(t: elapsed, x0: dx, v0: vx)
            let y = spring.solve(t: elapsed, x0: dy, v0: vy)

            var origin = CGPoint(
                x: targetOrigin.x + CGFloat(x.x),
                y: targetOrigin.y + CGFloat(y.x)
            )
            if let screen {
                origin = clampOnScreen(
                    NSRect(origin: origin, size: window.frame.size),
                    on: screen
                )
            }
            window.setFrameOrigin(origin)

            // Stop once the displacement has decayed, or the budget is spent.
            if elapsed >= settleTime || (abs(x.x) < 0.1 && abs(y.x) < 0.1 && abs(x.v) < 4 && abs(y.v) < 4) {
                window.setFrameOrigin(targetOrigin)
                cancelAnimation()
            }
        }
        settleTick = tick

        // NSView.displayLink(target:selector:) is macOS 14+, and the panel's
        // content view gives us the link for the display it is actually on.
        guard let view = window.contentView else {
            window.setFrameOrigin(targetOrigin)
            return
        }
        let link = view.displayLink(target: SpringProxy.shared, selector: #selector(SpringProxy.step(_:)))
        settleLink = link
        link.add(to: .main, forMode: .common)
    }

    /// Objective-C target for the display link. `CADisplayLink` needs a real
    /// selector target, which a static closure cannot provide.
    private final class SpringProxy: NSObject {
        static let shared = SpringProxy()
        @objc func step(_ link: CADisplayLink) {
            SnapEngine.settleTick?(link)
        }
    }

    /// Convenience that finds the nearest anchor *and* animates in one call.
    ///
    /// - Parameters:
    ///   - window: The PiP window to snap.
    ///   - screen: The screen whose visible frame defines snap positions.
    static func snapToNearest(window: NSWindow, on screen: NSScreen) {
        guard let target = snapPosition(for: window.frame, on: screen) else { return }
        animateSpring(window: window, to: target, on: screen)
    }

    /// Settles a window after a drag, carrying any release momentum into the
    /// snap decision.
    ///
    /// The projected landing point — not the release point — chooses the
    /// corner, so a window flicked *toward* a corner lands in it even when the
    /// mouse was released far away.
    static func release(window: NSWindow, velocity: CGVector, on screen: NSScreen) {
        let speed = hypot(velocity.dx, velocity.dy)

        guard speed > flickThreshold else {
            // Gentle release: snap only if already near a corner, otherwise
            // leave it exactly where it was dropped.
            if let target = snapPosition(for: window.frame, on: screen) {
                animateSpring(window: window, to: target, on: screen)
            } else {
                let clamped = clampOnScreen(window.frame, on: screen)
                if clamped != window.frame.origin {
                    animateSpring(window: window, to: clamped, on: screen)
                }
            }
            return
        }

        let landing = projectedOrigin(from: window.frame, velocity: velocity, on: screen)
        let projectedFrame = NSRect(origin: landing, size: window.frame.size)
        let target = snapPosition(for: projectedFrame, on: screen) ?? landing

        animateSpring(window: window, to: target, velocity: velocity, on: screen)
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
