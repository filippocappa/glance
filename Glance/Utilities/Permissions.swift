import ScreenCaptureKit
import AppKit

// MARK: - Permissions

/// Utility namespace for macOS privacy-permission checks.
///
/// ScreenCaptureKit requires the **Screen Recording** TCC entitlement.
/// The first call to `SCShareableContent` automatically triggers the system
/// consent dialog; subsequent calls return instantly once the user has decided.
///
/// This enum is deliberately *not* a class — it's a pure bag of static helpers
/// with no stored state, so an enum-without-cases is the idiomatic Swift way
/// to express a "namespace" that can never be instantiated.
enum Permissions {

    // ──────────────────────────────────────────────
    // MARK: - Screen Recording
    // ──────────────────────────────────────────────

    /// Checks whether the app currently has Screen Recording permission.
    ///
    /// On macOS 14+ this works by attempting to enumerate shareable content via
    /// `SCShareableContent`. If the user has not yet been prompted, the system
    /// will show the TCC dialog automatically. If the user denied access the
    /// call throws, and we return `false`.
    ///
    /// - Returns: `true` when the app is authorized; `false` otherwise.
    static func checkScreenRecordingPermission() async -> Bool {
        do {
            // `excludingDesktopWindows(false, onScreenWindowsOnly: false)`
            // asks for the full content graph — including off-screen windows
            // and the desktop — which is the broadest permission surface.
            // If the user hasn't granted access yet, macOS presents the
            // system TCC prompt at this point.
            let _ = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: false
            )
            return true
        } catch {
            // Common errors:
            //   • SCStreamError(.userDeclined) — user clicked "Don't Allow"
            //   • SCStreamError(.attemptToStartStreamWhileDenied)
            // Either way, we don't have permission.
            return false
        }
    }

    /// Opens **System Settings → Privacy & Security → Screen Recording** so
    /// the user can grant or revoke permission without hunting through menus.
    ///
    /// The `x-apple.systempreferences:` URL scheme is the officially supported
    /// deep-link into the Settings app on macOS 13+.
    static func openScreenRecordingSettings() {
        if let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        ) {
            NSWorkspace.shared.open(url)
        }
    }
}
