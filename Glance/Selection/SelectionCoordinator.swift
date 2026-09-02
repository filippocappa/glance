// SelectionCoordinator.swift
// Glance
//
// Manages the lifecycle of the full-screen transparent overlay windows
// used for interactive region selection. Handles multi-display setups
// by creating one overlay per screen, and routes selection results or
// cancellation back to the caller through a unified completion handler.

import AppKit

// MARK: - SelectionCoordinator

/// Coordinates the presentation and dismissal of selection overlay windows.
///
/// ## Architecture
/// `SelectionCoordinator` creates one borderless, transparent `NSWindow`
/// per connected display. Each window hosts a `SelectionOverlayView` that
/// handles rendering and mouse interaction. When the user completes or
/// cancels a selection on any screen, all overlays are dismissed together.
///
/// ## Usage
/// ```swift
/// let coordinator = SelectionCoordinator()
/// coordinator.beginSelection { selection in
///     if let selection {
///         print("Selected region: \(selection.rect) on \(selection.screen)")
///     } else {
///         print("Selection cancelled")
///     }
/// }
/// ```
///
/// ## Thread Safety
/// All methods are `@MainActor`-isolated because they create and manage
/// `NSWindow` instances, which must only be accessed from the main thread.
@MainActor
final class SelectionCoordinator {

    // MARK: - Properties

    /// The overlay windows currently displayed, one per screen.
    /// Emptied when overlays are dismissed.
    private var overlayWindows: [NSWindow] = []

    /// The completion handler supplied by the caller of `beginSelection`.
    /// Called exactly once with either a valid selection or `nil` (cancelled).
    private var completion: ((Selection?) -> Void)?

    /// True while overlays are on screen. Guards against a second selection
    /// session stacking overlays on top of the first.
    private var isActive: Bool { !overlayWindows.isEmpty }

    // MARK: - Public API

    /// Enters selection mode by presenting transparent overlays across all screens.
    ///
    /// The user can drag on any screen to select a rectangular region.
    /// - Completing a drag calls `completion` with the selected `CGRect` in
    ///   screen coordinates using a top-left origin (ready for ScreenCaptureKit).
    /// - Pressing ESC or right-clicking calls `completion` with `nil`.
    ///
    /// Only one selection session should be active at a time. Starting a new
    /// session while one is in progress will replace the previous completion handler.
    ///
    /// - Parameter completion: Called on the main actor with the selected rect
    ///   or `nil` if the user cancelled.
    func beginSelection(completion: @escaping (Selection?) -> Void) {
        // Single-instance guard: re-entering selection while overlays are up
        // would leave the first set orphaned on screen forever.
        guard !isActive else {
            Log.selection.error("beginSelection called while a session is already active — ignoring")
            completion(nil)
            return
        }

        self.completion = completion

        // Create an overlay window for each connected display.
        // This ensures the dimmed overlay and crosshair cursor appear
        // everywhere, even on external monitors.
        for screen in NSScreen.screens {
            let window = createOverlayWindow(for: screen)
            overlayWindows.append(window)
            window.makeKeyAndOrderFront(nil)
        }

        // Ensure the primary screen's overlay is the key window so it
        // receives keyboard events (ESC to cancel).
        overlayWindows.first?.makeKey()

        // Push the crosshair cursor onto the cursor stack so it persists
        // even outside tracking areas during the drag.
        NSCursor.crosshair.push()
    }

    // MARK: - Window Factory

    /// Creates a borderless, transparent overlay window sized to cover `screen`.
    ///
    /// The window is configured to:
    /// - Float above all other windows (`.screenSaver` level)
    /// - Be fully transparent with no shadow
    /// - Accept mouse events (not pass-through)
    /// - Track mouse movement for the crosshair
    /// - Join all Spaces so it works in full-screen environments
    ///
    /// - Parameter screen: The screen this window should cover.
    /// - Returns: A configured `NSWindow` with a `SelectionOverlayView` as its content.
    private func createOverlayWindow(for screen: NSScreen) -> NSWindow {
        let window = NSWindow(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false,
            screen: screen
        )

        // --- Window Configuration ---

        // Place the overlay above virtually everything, including the Dock
        // and menu bar. `.screenSaver` level is high enough to sit above
        // most system UI without requiring accessibility permissions.
        window.level = .screenSaver

        // The window itself must be transparent — the overlay's dimming
        // effect comes from the view's drawing, not the window background.
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false

        // We need to receive mouse events for selection interaction.
        window.ignoresMouseEvents = false
        window.acceptsMouseMovedEvents = true

        // Ensure the overlay appears on every Space and plays nicely
        // with full-screen apps.
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        // --- Content View Setup ---

        let overlayView = SelectionOverlayView(frame: screen.frame)

        // Wire up the overlay's callbacks to this coordinator's
        // finish/cancel methods. Weak self prevents retain cycles.
        overlayView.onSelectionComplete = { [weak self] rect, selectedScreen in
            self?.finishSelection(with: Selection(rect: rect, screen: selectedScreen))
        }
        overlayView.onSelectionCancelled = { [weak self] in
            self?.cancelSelection()
        }

        window.contentView = overlayView

        // Make the overlay view the first responder so it receives
        // key events (ESC) and mouse events immediately.
        window.makeFirstResponder(overlayView)

        return window
    }

    // MARK: - Selection Lifecycle

    /// Completes the selection session with a valid rectangle.
    ///
    /// Dismisses all overlay windows and calls the completion handler
    /// with the selected region.
    ///
    /// - Parameter selection: The selected rectangle in Cocoa global
    ///   coordinates, together with the screen it was drawn on.
    private func finishSelection(with selection: Selection) {
        dismissOverlays()
        completion?(selection)
        completion = nil
    }

    /// Cancels the selection session.
    ///
    /// Dismisses all overlay windows and calls the completion handler
    /// with `nil` to indicate no selection was made.
    private func cancelSelection() {
        dismissOverlays()
        completion?(nil)
        completion = nil
    }

    /// Removes all overlay windows from the screen and restores the cursor.
    ///
    /// This method:
    /// 1. Pops the crosshair cursor pushed during `beginSelection`.
    /// 2. Orders out (hides) every overlay window.
    /// 3. Clears the window array so they can be deallocated.
    private func dismissOverlays() {
        // Restore the previous cursor (removes the crosshair).
        NSCursor.pop()

        // Hide and release all overlay windows
        for window in overlayWindows {
            window.orderOut(nil)
        }
        overlayWindows.removeAll()
    }
}


// MARK: - Selection

/// A completed region selection.
///
/// `rect` is in Cocoa global coordinates (bottom-left origin) and `screen` is
/// the display it was drawn on. Both are needed to build a correct
/// ScreenCaptureKit `sourceRect`, which is top-left and display-relative.
struct Selection {
    let rect: CGRect
    let screen: NSScreen
}
