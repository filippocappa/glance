import ScreenCaptureKit
import AppKit
import CoreGraphics

// MARK: - Permissions

/// Utility namespace for macOS privacy-permission checks.
///
/// ScreenCaptureKit requires the **Screen Recording** TCC entitlement. There is
/// no entitlement key for it — the grant lives in the TCC database and is keyed
/// to the app's *designated requirement*. That is why Glance must be signed with
/// a stable identity (see `project.yml`): an ad-hoc signature has no team
/// identifier, so TCC pins the grant to the cdhash and every rebuild silently
/// revokes access.
///
/// This enum is deliberately *not* a class — it's a pure bag of static helpers
/// with no stored state, so an enum-without-cases is the idiomatic Swift way
/// to express a "namespace" that can never be instantiated.
enum Permissions {

    // ──────────────────────────────────────────────
    // MARK: - Screen Recording
    // ──────────────────────────────────────────────

    /// Non-blocking, non-prompting check of the current Screen Recording grant.
    ///
    /// `CGPreflightScreenCaptureAccess()` is the only API that answers this
    /// question *without* side effects. `SCShareableContent` was previously used
    /// for this, but it conflates "denied" with "transient WindowServer error"
    /// and it triggers the consent dialog as a side effect.
    static func hasScreenRecordingAccess() -> Bool {
        let granted = CGPreflightScreenCaptureAccess()
        Log.permissions.debug("CGPreflightScreenCaptureAccess() -> \(granted, privacy: .public)")
        return granted
    }

    /// Asks the system to present the Screen Recording consent dialog.
    ///
    /// - Returns: `true` if access is already granted. A `false` return means the
    ///   prompt was (or has previously been) shown; macOS requires the app to be
    ///   **relaunched** after the user flips the switch, so the caller should say
    ///   so rather than silently retrying.
    @discardableResult
    static func requestScreenRecordingAccess() -> Bool {
        let granted = CGRequestScreenCaptureAccess()
        Log.permissions.info("CGRequestScreenCaptureAccess() -> \(granted, privacy: .public)")
        return granted
    }

    /// Preflight, then prompt if needed. This is the single gate every capture
    /// path must pass through — no `SCStream` may be created when it returns
    /// `false`, because starting a stream while denied fails with
    /// `SCStreamErrorDomain` code -3801 and leaves a dead stream object behind.
    static func ensureScreenRecordingAccess() -> Bool {
        if hasScreenRecordingAccess() { return true }

        Log.permissions.error("Screen Recording not granted — requesting access")
        if requestScreenRecordingAccess() { return true }

        Log.permissions.error("Screen Recording denied. Grant it in System Settings, then relaunch Glance.")
        return false
    }

    /// Opens **System Settings → Privacy & Security → Screen Recording** so
    /// the user can grant or revoke permission without hunting through menus.
    static func openScreenRecordingSettings() {
        if let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        ) {
            NSWorkspace.shared.open(url)
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - Error Interpretation
    // ──────────────────────────────────────────────

    /// Human-readable explanation for a ScreenCaptureKit failure.
    ///
    /// SCStream reports permission problems as opaque `SCStreamErrorDomain`
    /// codes; -3801 in particular is the one that looks like "capture is just
    /// broken" when it actually means "TCC said no".
    static func describe(_ error: Error) -> String {
        let nsError = error as NSError
        guard nsError.domain == SCStreamErrorDomain else {
            return "\(nsError.domain) \(nsError.code): \(nsError.localizedDescription)"
        }

        let explanation: String
        switch nsError.code {
        case -3801:
            explanation = "Screen Recording permission was declined or denied by the system. "
                        + "Enable Glance in System Settings → Privacy & Security → Screen Recording, then relaunch."
        case -3802:
            explanation = "Failed to start the capture stream (SCStream refused to begin)."
        case -3808:
            explanation = "The capture stream was stopped by the system."
        case -3811:
            explanation = "The capture target (window or display) no longer exists."
        default:
            explanation = nsError.localizedDescription
        }
        return "SCStreamErrorDomain \(nsError.code): \(explanation)"
    }
}
