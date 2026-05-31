// ScreenPicker.swift
// Glance
//
// Utility for enumerating available displays, mapping screen coordinates
// to displays, and identifying the running application at a given point.
// Uses ScreenCaptureKit's SCShareableContent for display enumeration and
// Core Graphics window-list APIs for window-level hit testing.

import ScreenCaptureKit
import AppKit

// MARK: - ScreenPicker

/// A stateless utility that bridges between screen coordinates and
/// ScreenCaptureKit's ``SCDisplay`` objects.
///
/// All methods are `async` because ``SCShareableContent`` requires an
/// asynchronous system call to snapshot the current display and window
/// state from the WindowServer.
///
/// ## Usage
///
/// ```swift
/// // Find which display contains the user's click
/// if let display = try await ScreenPicker.display(containing: clickPoint) {
///     try await captureEngine.startCapture(
///         display: display,
///         sourceRect: selectedRect,
///         appState: appState
///     )
/// }
/// ```
enum ScreenPicker {

    // MARK: - Display Enumeration

    /// Returns every display currently known to the WindowServer.
    ///
    /// This includes both built-in and external displays. The result is
    /// a snapshot; if displays are connected/disconnected the caller
    /// should re-query.
    ///
    /// - Returns: An array of ``SCDisplay`` objects.
    /// - Throws: If ScreenCaptureKit cannot enumerate displays (e.g. the
    ///   user has not granted screen-recording permission).
    static func availableDisplays() async throws -> [SCDisplay] {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,                  // include desktop windows
            onScreenWindowsOnly: true
        )
        return content.displays
    }

    // MARK: - Point / Rect → Display

    /// Find the display whose frame contains *point*.
    ///
    /// Useful for determining which display the user clicked on when
    /// initiating a region selection.
    ///
    /// - Parameter point: A point in the global (flipped) screen
    ///   coordinate system.
    /// - Returns: The matching ``SCDisplay``, or `nil` if the point is
    ///   outside all known displays.
    static func display(containing point: CGPoint) async throws -> SCDisplay? {
        let displays = try await availableDisplays()
        return displays.first { display in
            // SCDisplay.frame is already in global display coordinates.
            let frame = CGRect(
                x: CGFloat(display.frame.origin.x),
                y: CGFloat(display.frame.origin.y),
                width: CGFloat(display.frame.width),
                height: CGFloat(display.frame.height)
            )
            return frame.contains(point)
        }
    }

    /// Find the display that has the **largest overlap** with *rect*.
    ///
    /// When a selection rectangle spans two displays, this returns the
    /// display that covers more of the selection. This is the right
    /// display to use as the capture source because it contains the
    /// majority of the content the user selected.
    ///
    /// - Parameter rect: A rectangle in global screen coordinates.
    /// - Returns: The best-matching ``SCDisplay``, or `nil` if the rect
    ///   doesn't intersect any display.
    static func display(for rect: CGRect) async throws -> SCDisplay? {
        let displays = try await availableDisplays()

        var bestDisplay: SCDisplay?
        var bestOverlap: CGFloat = 0

        for display in displays {
            let displayFrame = CGRect(
                x: CGFloat(display.frame.origin.x),
                y: CGFloat(display.frame.origin.y),
                width: CGFloat(display.frame.width),
                height: CGFloat(display.frame.height)
            )

            let intersection = displayFrame.intersection(rect)

            // `intersection` is `CGRect.null` when there is no overlap.
            guard !intersection.isNull else { continue }

            let overlap = intersection.width * intersection.height
            if overlap > bestOverlap {
                bestOverlap = overlap
                bestDisplay = display
            }
        }

        return bestDisplay
    }

    // MARK: - Window Hit Testing

    /// Identify the frontmost application whose window is under *point*.
    ///
    /// Uses the Core Graphics window-list API, which returns windows
    /// in front-to-back order. The first window whose bounds contain
    /// the point determines the owning application.
    ///
    /// > Note: This uses `CGWindowListCopyWindowInfo`, which requires
    /// > the screen-recording permission on macOS 14+. If the permission
    /// > has not been granted, the window list will be empty and the
    /// > method returns `nil`.
    ///
    /// - Parameter point: A point in the global (top-left origin)
    ///   coordinate system used by Core Graphics.
    /// - Returns: The ``NSRunningApplication`` that owns the topmost
    ///   window under the point, or `nil` if none is found.
    static func application(at point: CGPoint) async throws -> NSRunningApplication? {
        // Request the on-screen window list, excluding desktop elements
        // (wallpaper, Dock background, etc.). The list is ordered
        // front-to-back, so the first hit is the topmost window.
        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return nil
        }

        for windowInfo in windowList {
            // Each entry has a bounds dictionary and an owner PID.
            guard let boundsDict = windowInfo[kCGWindowBounds as String] as? [String: CGFloat],
                  let pid = windowInfo[kCGWindowOwnerPID as String] as? pid_t
            else { continue }

            // Skip windows with zero area (e.g. status-bar items).
            let bounds = CGRect(
                x: boundsDict["X"] ?? 0,
                y: boundsDict["Y"] ?? 0,
                width: boundsDict["Width"] ?? 0,
                height: boundsDict["Height"] ?? 0
            )
            guard bounds.width > 0, bounds.height > 0 else { continue }

            if bounds.contains(point) {
                return NSRunningApplication(processIdentifier: pid)
            }
        }

        return nil
    }

    // MARK: - Window Enumeration

    /// Return all on-screen windows belonging to a specific application.
    ///
    /// Useful for enumerating a source app's windows so the user can
    /// pick which one to track.
    ///
    /// - Parameter pid: The process identifier of the target application.
    /// - Returns: An array of window-info dictionaries (from
    ///   `CGWindowListCopyWindowInfo`) for windows owned by *pid*.
    static func windows(for pid: pid_t) -> [[String: Any]] {
        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return []
        }

        return windowList.filter { info in
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t else {
                return false
            }
            return ownerPID == pid
        }
    }

    /// Return the bounding rectangle of a specific window.
    ///
    /// - Parameter windowID: The Core Graphics window ID.
    /// - Returns: The window's on-screen bounds, or `nil` if the window
    ///   cannot be found.
    static func bounds(ofWindow windowID: CGWindowID) -> CGRect? {
        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return nil
        }

        for info in windowList {
            guard let wid = info[kCGWindowNumber as String] as? CGWindowID,
                  wid == windowID,
                  let boundsDict = info[kCGWindowBounds as String] as? [String: CGFloat]
            else { continue }

            return CGRect(
                x: boundsDict["X"] ?? 0,
                y: boundsDict["Y"] ?? 0,
                width: boundsDict["Width"] ?? 0,
                height: boundsDict["Height"] ?? 0
            )
        }

        return nil
    }

    /// Identify the topmost `SCWindow` containing *point*.
    static func window(at point: CGPoint) async throws -> SCWindow? {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        
        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return nil
        }
        
        for windowInfo in windowList {
            guard let boundsDict = windowInfo[kCGWindowBounds as String] as? [String: CGFloat],
                  let windowID = windowInfo[kCGWindowNumber as String] as? CGWindowID,
                  let ownerPID = windowInfo[kCGWindowOwnerPID as String] as? pid_t
            else { continue }
            
            let bounds = CGRect(
                x: boundsDict["X"] ?? 0,
                y: boundsDict["Y"] ?? 0,
                width: boundsDict["Width"] ?? 0,
                height: boundsDict["Height"] ?? 0
            )
            
            // Skip Glance's own windows or very small helper/system UI components
            guard bounds.width > 30, bounds.height > 30 else { continue }
            if ownerPID == NSRunningApplication.current.processIdentifier {
                continue
            }
            
            if bounds.contains(point) {
                if let scWindow = content.windows.first(where: { $0.windowID == windowID }) {
                    return scWindow
                }
            }
        }
        return nil
    }
}
