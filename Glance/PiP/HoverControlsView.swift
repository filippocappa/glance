import SwiftUI

// MARK: - HoverControlsView
// ─────────────────────────────────────────────────────────────────────────────
// The top layer in Glance's two-layer Ghost Mode architecture.
//
// Architecture Overview:
// ┌─────────────────────────────────────────┐
// │  Controls Child Window (intercepts mouse)│  ← THIS VIEW lives here
// ├─────────────────────────────────────────┤
// │  Video Panel (ignoresMouseEvents = true) │  ← VideoLayerView (click-through)
// └─────────────────────────────────────────┘
//
// Unlike the video layer below, this view DOES intercept mouse events so the
// user can interact with close/settings buttons. It lives in a separate child
// NSWindow that sits above the main video panel.
//
// The controls are hidden by default and appear with a fade-in + slide-down
// animation when the cursor enters the PiP window area. This keeps the PiP
// window clean and unobtrusive during normal use.
//
// Controls provided:
// - Close button (×): Closes the PiP window and stops capture
// - Bring to front (⧉): Activates the source application
// - Zoom menu (⚙): Quick access to common zoom levels (50%–200%)
// ─────────────────────────────────────────────────────────────────────────────

struct HoverControlsView: View {
    
    // MARK: - Properties
    
    /// Tracks whether the cursor is currently inside the PiP window bounds.
    /// Drives the show/hide animation for the controls bar.
    let isHovering: Bool
    
    // MARK: - Callbacks & Bindings
    
    /// Called when the user clicks the close button.
    var onClose: () -> Void
    
    /// Called when the user clicks the "bring to front" button.
    var onBringToFront: () -> Void
    
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
                        .help("Close Glance")
                        
                        Spacer()
                        
                        // Bring source window to front — useful when the user
                        // wants to interact with the source app directly
                        Button(action: onBringToFront) {
                            Image(systemName: "macwindow.on.rectangle")
                                .font(.system(size: 14))
                                .foregroundStyle(.white.opacity(0.9))
                                .shadow(color: .black.opacity(0.5), radius: 2)
                        }
                        .buttonStyle(.plain)
                        .help("Bring source window to front")
                        
                        // Zoom level menu — provides quick preset zoom values.
                        // Using a Menu instead of a Picker for cleaner styling
                        // and because we want specific percentage labels.
                        Menu {
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
                        .help("Settings")
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        // Vibrancy blur that samples the content behind the window,
                        // giving the controls bar a native macOS "HUD" appearance
                        VisualEffectBlur(material: .hudWindow, blendingMode: .behindWindow)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
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
