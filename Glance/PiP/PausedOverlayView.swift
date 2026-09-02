import SwiftUI

// MARK: - PausedOverlayView
// ─────────────────────────────────────────────────────────────────────────────
// Displayed when the capture stream is interrupted — typically because the
// source application has been minimized to the Dock, or the ScreenCaptureKit
// stream has stopped for another reason.
//
// This overlay sits in the controls child window (the interactive top layer),
// so it appears above the last captured video frame. It provides visual
// feedback that the PiP is not actively updating, preventing the user from
// thinking the app has frozen.
//
// Design: A heavy vibrancy blur over the frozen frame, with a centered pause
// icon and label. The muted styling communicates "inactive but not broken."
// ─────────────────────────────────────────────────────────────────────────────

/// Overlay shown when the capture stream is paused (e.g., source app minimized).
/// Displays a dark translucent material background with a pause icon.
struct PausedOverlayView: View {
    var body: some View {
        ZStack {
            // Full-area blur that obscures the frozen video frame underneath.
            // `.fullScreenUI` is a heavy, dark material that signals "modal state"
            // to the user. `.behindWindow` blurs content from windows below.
            VisualEffectBlur(material: .fullScreenUI, blendingMode: .withinWindow)
            
            VStack(spacing: 12) {
                // Pause icon — large but thin-weighted to stay elegant
                Image(systemName: "pause.circle")
                    .font(.system(size: 40, weight: .thin))
                    .foregroundStyle(.white.opacity(0.7))
                
                // Status label — low opacity to avoid drawing too much attention
                Text("Paused")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
    }
}
