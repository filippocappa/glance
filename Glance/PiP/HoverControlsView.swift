import SwiftUI
import KeyboardShortcuts

// MARK: - HoverControlsView
// ─────────────────────────────────────────────────────────────────────────────
// The control bar that fades in over the video when the cursor is inside the
// PiP panel.
//
// Glance is a SINGLE-window app: this bar is a SwiftUI layer inside the same
// NSPanel as the video, not a separate child window. (It used to live in a
// child window above a click-through video panel; that two-window "ghost mode"
// was removed because keeping the two frames in sync during a drag produced
// visible ghosting.)
//
// Controls, left to right:
//   ×   Close       — stops the capture and closes the PiP.
//   ⧉   Show source — activates the app that owns the captured window, bringing
//                     the real window forward. It does NOT toggle click-through
//                     and does NOT change the capture.
//   ⚙︎  Size        — zoom presets (50%-200%) that resize the PiP panel only;
//                     the stream keeps running at its source resolution.
//
// Click-through ("ghost mode") is automatic and has no button: the panel passes
// clicks through whenever the cursor is outside it, and becomes interactive on
// hover. See GlanceWindowController.
// ─────────────────────────────────────────────────────────────────────────────

struct HoverControlsView: View {
    
    // MARK: - Properties
    
    /// Tracks whether the cursor is currently inside the PiP window bounds.
    /// Drives the show/hide animation for the controls bar.
    let isHovering: Bool

    /// Whether Ghost Mode is engaged, so the button can render its active state.
    let isGhostMode: Bool
    
    // MARK: - Callbacks & Bindings
    
    /// Called when the user clicks the close button.
    var onClose: () -> Void
    
    /// Called when the user clicks the "bring to front" button.
    var onBringToFront: () -> Void

    /// Called when the user toggles Ghost Mode.
    var onToggleGhostMode: () -> Void
    
    /// Two-way binding to the current zoom level in AppState.
    /// The zoom menu sets this value; the window controller reads it to
    /// resize the PiP window accordingly.
    var zoomLevel: Binding<CGFloat>
    
    // MARK: - Body
    
    var body: some View {
        ZStack(alignment: .topLeading) {
            if isHovering {
                // MARK: Controls Bar
                // Slides down from the top when hovering. Contains close button
                // on the left, bring-to-front and settings on the right.
                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        // Close button — prominent placement on the left,
                        // matching macOS window control conventions
                        Button(action: onClose) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 18))
                                .foregroundStyle(.white.opacity(0.9))
                                .shadow(color: .black.opacity(0.5), radius: 2)
                        }
                        .buttonStyle(.plain)
                        .help("Close — stop capturing and close this PiP")
                        .accessibilityLabel("Close Glance")
                        
                        Spacer()
                        
                        // Activates the source application so its real window
                        // comes forward. Purely a convenience — it does not
                        // affect the stream, and it is NOT a click-through
                        // toggle (click-through is automatic on hover).
                        Button(action: onBringToFront) {
                            Image(systemName: "macwindow.on.rectangle")
                                .font(.system(size: 14))
                                .foregroundStyle(.white.opacity(0.9))
                                .shadow(color: .black.opacity(0.5), radius: 2)
                        }
                        .buttonStyle(.plain)
                        .help("Show source — bring the original window to the front")
                        .accessibilityLabel("Bring source window to front")

                        // Ghost Mode — dim the PiP and let clicks pass straight
                        // through to whatever is behind it.
                        Button(action: onToggleGhostMode) {
                            Image(systemName: isGhostMode
                                  ? "cursorarrow.slash.square.fill"
                                  : "cursorarrow.slash")
                                .font(.system(size: 14))
                                .foregroundStyle(isGhostMode
                                                 ? AnyShapeStyle(Theme.accent)
                                                 : AnyShapeStyle(.white.opacity(0.9)))
                                .shadow(color: .black.opacity(0.5), radius: 2)
                        }
                        .buttonStyle(.plain)
                        .help("Ghost Mode — dim the PiP and click through it (\(Self.ghostShortcutLabel))")
                        .accessibilityLabel("Toggle Ghost Mode")
                        
                        // Zoom level menu — provides quick preset zoom values.
                        // Using a Menu instead of a Picker for cleaner styling
                        // and because we want specific percentage labels.
                        Menu {
                            Text("PiP window size")
                            Divider()
                            Button("50%") { zoomLevel.wrappedValue = 0.5 }
                            Button("75%") { zoomLevel.wrappedValue = 0.75 }
                            Button("100%") { zoomLevel.wrappedValue = 1.0 }
                            Button("150%") { zoomLevel.wrappedValue = 1.5 }
                            Button("200%") { zoomLevel.wrappedValue = 2.0 }
                        } label: {
                            Image(systemName: "gearshape.fill")
                                .font(.system(size: 14))
                                .foregroundStyle(.white.opacity(0.9))
                                .shadow(color: .black.opacity(0.5), radius: 2)
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .help("Size — scale this PiP window (the capture is unchanged)")
                        .accessibilityLabel("PiP size")
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        // Vibrancy blur that samples the content behind the window,
                        // giving the controls bar a native macOS "HUD" appearance
                        VisualEffectBlur(material: .hudWindow, blendingMode: .withinWindow)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(Theme.accent.opacity(0.35), lineWidth: 1)
                            )
                    )
                    .padding(8)
                    
                    Spacer()
                }
                // Combined transition: fades in while sliding down from top edge
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

// MARK: - Shortcut label

extension HoverControlsView {
    /// Human-readable form of the current Ghost Mode hotkey, for the tooltip.
    static var ghostShortcutLabel: String {
        KeyboardShortcuts.getShortcut(for: .toggleGhostMode)
            .map(String.init(describing:)) ?? "no shortcut set"
    }
}

// MARK: - GhostExitBadge
// ─────────────────────────────────────────────────────────────────────────────
// The one clickable target while Ghost Mode is engaged.
//
// The panel ignores mouse events everywhere else, so without this the only ways
// out would be the global hotkey and the menu bar. The window controller keeps
// a matching hit rect in sync (see GlanceWindowController.updateGhostHitTesting).
// ─────────────────────────────────────────────────────────────────────────────

struct GhostExitBadge: View {
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "cursorarrow.slash.square.fill")
                .font(.system(size: 16))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(
                    Circle()
                        .fill(.black.opacity(0.6))
                        .overlay(Circle().strokeBorder(Theme.accent.opacity(0.9), lineWidth: 1.5))
                )
        }
        .buttonStyle(.plain)
        .help("Leave Ghost Mode (\(HoverControlsView.ghostShortcutLabel))")
        .accessibilityLabel("Leave Ghost Mode")
    }
}

// MARK: - VisualEffectBlur

/// NSVisualEffectView wrapper for SwiftUI.
///
/// SwiftUI doesn't natively expose NSVisualEffectView, so we bridge it via
/// NSViewRepresentable. This gives us access to macOS vibrancy materials
/// (e.g., `.hudWindow`, `.fullScreenUI`) for native-looking translucent
/// backgrounds.
struct VisualEffectBlur: NSViewRepresentable {
    
    /// The material type determines the appearance and blur radius.
    /// Common choices:
    /// - `.hudWindow`: Dark, high-contrast blur for floating controls
    /// - `.fullScreenUI`: Heavy blur for modal overlays
    let material: NSVisualEffectView.Material
    
    /// How the blur composites with content:
    /// - `.behindWindow`: Blurs content from windows behind this one
    /// - `.withinWindow`: Blurs content within the same window
    let blendingMode: NSVisualEffectView.BlendingMode
    
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        // `.active` ensures the blur effect is always visible, even when
        // the window is not key/main. This is important for floating panels
        // which may never become the key window.
        view.state = .active
        return view
    }
    
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}
