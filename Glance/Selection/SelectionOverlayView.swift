// SelectionOverlayView.swift
// Glance
//
// A full-screen transparent overlay view that mimics the native macOS
// screenshot selection tool (Cmd+Shift+4). Users drag to select a
// rectangular region of the screen, which is reported back via a
// completion handler in screen coordinates suitable for ScreenCaptureKit.

import AppKit

// MARK: - SelectionOverlayView

/// A custom `NSView` that renders a full-screen selection overlay.
///
/// ## Visual Design
/// - The entire screen is dimmed with a semi-transparent black wash.
/// - The user-selected rectangle is "cut out" (cleared) so the underlying
///   screen content shows through at full brightness.
/// - A thin white border and subtle drop shadow frame the selection.
/// - A floating tooltip displays the selection dimensions (W × H) in pixels.
/// - When idle (before dragging begins), crosshair guide lines track the
///   mouse position to help the user align their selection.
///
/// ## Interaction Model
/// - **Left-click + drag**: Rubber-band selection. The drag origin becomes
///   one corner; the current mouse position becomes the opposite corner.
/// - **Mouse-up**: Completes the selection if the rect exceeds a minimum
///   size threshold (10×10 px). Smaller selections are discarded.
/// - **ESC key**: Cancels the selection entirely.
/// - **Right-click**: Also cancels (consistent with macOS screenshot tool).
///
/// ## Coordinate System
/// The view works in the standard AppKit coordinate system (origin at
/// bottom-left). On completion, coordinates are converted to the
/// Core Graphics / ScreenCaptureKit coordinate system (origin at top-left)
/// before being passed to the completion handler.
class SelectionOverlayView: NSView {

    // MARK: - Callbacks

    /// Called when the user completes a valid selection.
    ///
    /// The rect is in **Cocoa global screen coordinates** (bottom-left origin),
    /// paired with the `NSScreen` it was drawn on. The flip into
    /// ScreenCaptureKit's top-left, display-relative space happens in
    /// `CaptureEngine`, where the target `SCDisplay` is known — doing it here
    /// against the primary screen's height was wrong on any secondary display.
    var onSelectionComplete: ((CGRect, NSScreen) -> Void)?

    /// Called when the user cancels the selection via ESC or right-click.
    var onSelectionCancelled: (() -> Void)?

    // MARK: - Selection State

    /// The point where the mouse-down occurred (drag origin), in view coords.
    private var selectionStart: NSPoint?

    /// The current drag endpoint (updated during mouseDragged), in view coords.
    private var selectionEnd: NSPoint?

    /// Tracks the mouse position for drawing the crosshair guides when idle.
    private var currentMousePosition: NSPoint = .zero

    /// True while the user is actively dragging to create a selection.
    private var isSelecting: Bool = false

    // MARK: - Computed Properties

    /// The normalized selection rectangle derived from the start and end points.
    /// Returns `nil` when no drag is in progress. The rect is always
    /// axis-aligned with positive width and height regardless of drag direction.
    private var selectionRect: NSRect? {
        guard let start = selectionStart, let end = selectionEnd else { return nil }
        return NSRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )
    }

    // MARK: - First Responder

    /// The overlay must accept first responder status to receive key events
    /// (specifically ESC for cancellation).
    override var acceptsFirstResponder: Bool { true }

    // MARK: - Cursor Management

    /// Registers a crosshair cursor rect covering the entire view bounds.
    /// AppKit automatically swaps to this cursor when the mouse enters the rect.
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard let context = NSGraphicsContext.current?.cgContext else { return }

        // --- Step 1: Draw the dimmed background overlay ---
        // A semi-transparent black fill covers the entire screen to
        // visually de-emphasize content outside the selection.
        context.setFillColor(NSColor.black.withAlphaComponent(0.3).cgColor)
        context.fill(bounds)

        // --- Step 2: Draw the selection rectangle (if active) ---
        if let rect = selectionRect, rect.width > 1, rect.height > 1 {
            // Clear the selection area so the underlying screen shows
            // through at full brightness. We use `.clear` blend mode to
            // punch a hole in the dimmed overlay.
            context.setBlendMode(.clear)
            context.fill(rect)
            context.setBlendMode(.normal)

            // --- Selection border ---
            // A thin white stroke outlines the selection. We inset by 0.5pt
            // so the 1pt stroke sits entirely inside the selection bounds,
            // preventing sub-pixel bleed.
            context.setStrokeColor(NSColor.white.cgColor)
            context.setLineWidth(1.0)
            context.stroke(rect.insetBy(dx: 0.5, dy: 0.5))

            // --- Subtle outer glow / shadow ---
            // A soft shadow around the selection edge provides depth and
            // helps separate it from the dimmed surroundings.
            context.setShadow(
                offset: .zero,
                blur: 8,
                color: NSColor.black.withAlphaComponent(0.5).cgColor
            )
            context.setStrokeColor(NSColor.white.withAlphaComponent(0.3).cgColor)
            context.setLineWidth(0.5)
            context.stroke(rect)
            // Reset shadow state to avoid affecting subsequent drawing
            context.setShadow(offset: .zero, blur: 0)

            // --- Dimensions label ---
            drawDimensionsLabel(for: rect, in: context)
        }

        // --- Step 3: Draw crosshair guide lines (when not dragging) ---
        // Full-width and full-height lines through the mouse position
        // help the user align their starting point before they click.
        if !isSelecting {
            drawCrosshair(at: currentMousePosition, in: context)
        }
    }

    /// Draws vertical and horizontal guide lines through `point`.
    ///
    /// The lines span the full view bounds and are rendered with a subtle
    /// white tint so they're visible against the dimmed background but
    /// not visually distracting.
    private func drawCrosshair(at point: NSPoint, in context: CGContext) {
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.6).cgColor)
        context.setLineWidth(0.5)

        // Vertical guide line (top to bottom of view)
        context.move(to: CGPoint(x: point.x, y: 0))
        context.addLine(to: CGPoint(x: point.x, y: bounds.height))

        // Horizontal guide line (left to right of view)
        context.move(to: CGPoint(x: 0, y: point.y))
        context.addLine(to: CGPoint(x: bounds.width, y: point.y))

        context.strokePath()
    }

    /// Draws a floating tooltip showing the selection dimensions in pixels.
    ///
    /// The label is centered horizontally below the selection rectangle.
    /// It uses a rounded dark background pill with white monospaced text
    /// for readability at any position on screen.
    ///
    /// Format: `"W × H"` (e.g., `"640 × 480"`).
    private func drawDimensionsLabel(for rect: NSRect, in context: CGContext) {
        let text = "\(Int(rect.width)) × \(Int(rect.height))"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let attrString = NSAttributedString(string: text, attributes: attrs)
        let textSize = attrString.size()

        // Position the label centered below the selection, offset 8pt down.
        let labelPadding: CGFloat = 6
        let labelWidth = textSize.width + labelPadding * 2
        let labelHeight = textSize.height + labelPadding * 2
        let labelRect = CGRect(
            x: rect.midX - labelWidth / 2,
            y: rect.minY - labelHeight - 8,
            width: labelWidth,
            height: labelHeight
        )

        // Semi-transparent dark background pill
        let bgPath = NSBezierPath(roundedRect: labelRect, xRadius: 4, yRadius: 4)
        NSColor.black.withAlphaComponent(0.7).setFill()
        bgPath.fill()

        // Draw the dimension text inside the pill
        attrString.draw(at: CGPoint(
            x: labelRect.origin.x + labelPadding,
            y: labelRect.origin.y + labelPadding
        ))
    }

    // MARK: - Mouse Events

    /// Records the drag origin and enters selection mode.
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        selectionStart = point
        selectionEnd = point
        isSelecting = true
        needsDisplay = true
    }

    /// Updates the selection endpoint as the user drags, causing a redraw.
    override func mouseDragged(with event: NSEvent) {
        selectionEnd = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    /// Completes the selection on mouse-up if the rectangle is large enough.
    ///
    /// Selections smaller than 10×10 px are discarded (likely accidental clicks).
    /// Valid selections are converted from AppKit's bottom-left coordinate
    /// system to the top-left origin system used by Core Graphics and
    /// ScreenCaptureKit before being reported.
    override func mouseUp(with event: NSEvent) {
        selectionEnd = convert(event.locationInWindow, from: nil)
        isSelecting = false

        guard let rect = selectionRect, rect.width > 10, rect.height > 10 else {
            // Selection too small — treat as a click, not a selection. Reset.
            selectionStart = nil
            selectionEnd = nil
            needsDisplay = true
            return
        }

        // --- Coordinate Conversion ---
        // View coordinates → Cocoa global screen coordinates (bottom-left
        // origin). No Y flip here: the caller needs to know which display the
        // selection belongs to before it can flip correctly, and this view's
        // window is pinned to exactly that display.
        guard let window = self.window,
              let screen = window.screen ?? NSScreen.main else { return }
        let screenRect = window.convertToScreen(rect)

        onSelectionComplete?(screenRect, screen)
    }

    /// Tracks mouse movement for crosshair rendering when not dragging.
    override func mouseMoved(with event: NSEvent) {
        currentMousePosition = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    // MARK: - Keyboard Events

    /// Handles key presses — ESC (keyCode 53) cancels the selection.
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // ESC key
            onSelectionCancelled?()
        }
    }

    /// Right-click also cancels, consistent with macOS screenshot behavior.
    override func rightMouseDown(with event: NSEvent) {
        onSelectionCancelled?()
    }

    // MARK: - Tracking Areas

    /// Maintains a tracking area covering the full view bounds so we receive
    /// `mouseMoved` events. The tracking area is rebuilt whenever the view
    /// resizes or its bounds change.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        // Remove all existing tracking areas to prevent stale rects
        for area in trackingAreas {
            removeTrackingArea(area)
        }

        // Install a new tracking area matching the current bounds.
        // - `.mouseMoved`: We need move events for the crosshair.
        // - `.activeAlways`: Track even when the app isn't frontmost
        //   (the overlay window sits above everything).
        // - `.inVisibleRect`: Automatically clips to the visible portion.
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .activeAlways, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
    }
}
