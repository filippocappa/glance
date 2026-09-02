import SwiftUI
import ScreenCaptureKit

// MARK: - AppState

/// Global application state — the single source of truth for Glance.
///
/// Uses the `@Observable` macro (Observation framework, macOS 14+) instead of
/// the older `ObservableObject` / `@Published` pattern. SwiftUI views that read
/// any property are automatically tracked and re-rendered only when *that*
/// property changes — no manual `objectWillChange` bookkeeping required.
///
/// Architecturally this plays the same role as a React Context provider wrapping
/// the entire component tree combined with a `useReducer`-style store: one
/// object, injected at the root, readable everywhere via `@Environment`.
@Observable
final class AppState {

    // ──────────────────────────────────────────────
    // MARK: - Capture State
    // ──────────────────────────────────────────────

    /// The screen-space rectangle the user selected for capture.
    /// `.zero` means no region has been chosen yet.
    var sourceRect: CGRect = .zero

    /// The `SCDisplay` that contains the selected region.
    /// `nil` until the user completes a selection on a specific display.
    var targetDisplay: SCDisplay?

    /// `true` while a `SCStream` is actively delivering frames.
    var isStreaming: Bool = false

    /// `true` while the translucent selection overlay is visible and the user
    /// is drawing / adjusting the capture rectangle.
    var isSelecting: Bool = false

    /// `true` when the source application is minimized or fully occluded,
    /// meaning the captured content is stale and playback should pause.
    var isPaused: Bool = false

    /// Zoom multiplier applied to the PiP window's content.
    /// `1.0` = pixel-accurate native resolution of the captured region.
    var zoomLevel: CGFloat = 1.0

    /// The most recent frame delivered by `SCStream`, stored as an `IOSurface`
    /// so it can be handed directly to Metal / Core Animation for zero-copy
    /// rendering.
    var currentFrame: IOSurface?

    /// `true` when the mouse is hovering over the PiP window, showing controls.
    var isHovering: Bool = false

    /// `true` while the window is being dragged by the user.
    var isDragging: Bool = false

    /// `true` when Ghost Mode is engaged: the panel is dimmed and passes all
    /// clicks through to whatever is behind it.
    var isGhostMode: Bool = false

    /// `true` while AppKit is performing a live corner/edge resize.
    ///
    /// Snapping, spring animation and click-through toggling are all suspended
    /// while this is set — running any of them concurrently with a live resize
    /// makes the window fight the cursor.
    var isResizing: Bool = false

    /// The size, in points, of the region actually being captured.
    ///
    /// This is the crop the stream is configured with — not the raw selection —
    /// and it is the authority for the PiP panel's aspect ratio. In
    /// window-relative mode the crop is clamped to the window's content rect, so
    /// it can be smaller than what the user dragged.
    var captureSize: CGSize = .zero

    /// The Unix PID of the application that owns the captured region.
    /// Used to implement "click PiP → bring source app to front".
    var sourceAppPID: pid_t?

    /// A user-visible error message. When non-`nil` the menu bar icon and/or
    /// PiP overlay should display it, then the caller clears it.
    var errorMessage: String?

    // ──────────────────────────────────────────────
    // MARK: - Window State
    // ──────────────────────────────────────────────

    /// The current on-screen origin of the PiP window (bottom-left in
    /// AppKit's coordinate system).
    var windowPosition: CGPoint = .zero

    /// The current content size of the PiP window.
    /// Defaults to a 4 : 3 thumbnail that feels at home in any corner.
    var windowSize: CGSize = CGSize(width: 320, height: 240)

    // ──────────────────────────────────────────────
    // MARK: - Methods
    // ──────────────────────────────────────────────

    /// Resets every piece of state back to its launch-time default.
    ///
    /// Call this when the user stops a capture session so the next session
    /// starts from a clean slate (no stale frames, no leftover PID, etc.).
    func reset() {
        sourceRect = .zero
        targetDisplay = nil
        captureSize = .zero
        isStreaming = false
        isPaused = false
        isHovering = false
        isDragging = false
        isResizing = false
        isGhostMode = false
        currentFrame = nil
        sourceAppPID = nil
        errorMessage = nil
    }
}
