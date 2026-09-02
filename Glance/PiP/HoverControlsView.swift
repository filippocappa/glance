import SwiftUI
import KeyboardShortcuts

// MARK: - HoverControlsView
// ─────────────────────────────────────────────────────────────────────────────
// A single floating capsule HUD that fades in over the video on hover.
//
// Glance is a SINGLE-window app: this bar is a SwiftUI layer inside the same
// NSPanel as the video, not a separate child window. (It used to live in a
// child window above a click-through video panel; that two-window "ghost mode"
// was removed because keeping the two frames in sync during a drag produced
// visible ghosting.)
//
// It sits bottom-centre rather than spanning the top edge. A full-width bar
// with a control pinned to each end reads as window chrome and crowds the
// corners — where the Ghost Mode exit badge and the resize handles already
// live. A centred capsule is a discrete object floating over the content, the
// way transport controls sit in a video player.
//
// Controls, left to right:
//   ×   Close        — stops the capture and closes the PiP.
//   ⧉   Show source  — activates the app that owns the captured window and
//                      un-minimises it. Does NOT change the capture.
//   ⃠   Ghost Mode   — dims the panel and passes clicks through.
//   ⤢   Size         — zoom presets that resize the panel only; the stream
//                      keeps running at its source resolution.
//
// Click-through is automatic and has no button of its own: the panel passes
// clicks through whenever the cursor is outside it. Ghost Mode is the manual,
// sticky version of the same thing. See GlanceWindowController.
// ─────────────────────────────────────────────────────────────────────────────

struct HoverControlsView: View {

    /// Whether the cursor is inside the PiP window. Drives the HUD's presence.
    let isHovering: Bool

    /// Whether Ghost Mode is engaged, so its control can render an active state.
    let isGhostMode: Bool

    var onClose: () -> Void
    var onBringToFront: () -> Void
    var onToggleGhostMode: () -> Void

    /// Two-way binding to the current zoom level in AppState.
    var zoomLevel: Binding<CGFloat>

    var body: some View {
        VStack {
            Spacer()
            hud
                .padding(.bottom, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Scale-in from slightly small, so the HUD reads as arriving rather
        // than blinking on.
        .opacity(isHovering ? 1 : 0)
        .scaleEffect(isHovering ? 1 : 0.92, anchor: .bottom)
        .animation(.spring(response: 0.28, dampingFraction: 0.82), value: isHovering)
        // Fully inert when hidden, so an invisible HUD cannot eat clicks meant
        // for the video beneath it.
        .allowsHitTesting(isHovering)
    }

    private var hud: some View {
        HStack(spacing: 2) {
            ControlPill(
                symbol: "xmark",
                help: "Close — stop capturing and close this PiP",
                accessibility: "Close Glance",
                action: onClose
            )

            ControlPill(
                symbol: "arrow.up.forward.app",
                help: "Show source — bring the original window to the front",
                accessibility: "Bring source window to front",
                action: onBringToFront
            )

            ControlPill(
                symbol: "cursorarrow.slash",
                help: "Ghost Mode — dim the PiP and click through it (\(Self.ghostShortcutLabel))",
                accessibility: "Toggle Ghost Mode",
                isActive: isGhostMode,
                action: onToggleGhostMode
            )

            ZoomPill(zoomLevel: zoomLevel)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 5)
        .background(
            Capsule(style: .continuous)
                .fill(.ultraThinMaterial)
                .environment(\.colorScheme, .dark)
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(.white.opacity(Theme.borderAlpha), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.35), radius: 10, y: 3)
        .fixedSize()
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

// MARK: - PressableStyle

/// Immediate tactile feedback on mouse-down.
///
/// `configuration.isPressed` flips on the raw press, before any hover or
/// animation state resolves, so the control acknowledges the click at the
/// moment it happens rather than after the surrounding view settles.
private struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.88 : 1)
            .opacity(configuration.isPressed ? 0.65 : 1)
            // Short enough to read as tactile rather than animated.
            .animation(.easeOut(duration: 0.07), value: configuration.isPressed)
    }
}

// MARK: - ControlPill

/// One circular control inside the HUD capsule.
///
/// Hover is expressed as a white wash behind the glyph plus a lift in the
/// glyph's own opacity — no colour, no ring. Active state (Ghost Mode engaged)
/// is a stronger, persistent version of the same wash, so "hovered" and
/// "engaged" read as points on one scale rather than two different languages.
private struct ControlPill: View {
    let symbol: String
    let help: String
    let accessibility: String
    var isActive: Bool = false
    var action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(
                    .white.opacity(isActive || hovering ? Theme.primaryAlpha : Theme.secondaryAlpha)
                )
                .frame(width: 28, height: 28)
                .background(
                    Circle().fill(
                        .white.opacity(isActive ? Theme.subtleAlpha
                                       : (hovering ? 0.10 : 0))
                    )
                )
                .contentShape(Circle())
        }
        .buttonStyle(PressableStyle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .animation(.easeOut(duration: 0.15), value: isActive)
        .help(help)
        .accessibilityLabel(accessibility)
    }
}

// MARK: - ZoomPill

/// The size control. A `Menu` rather than a `Button`, but styled to be
/// indistinguishable from its neighbours — the stock menu chrome would
/// otherwise break the run of circular glyphs.
private struct ZoomPill: View {
    var zoomLevel: Binding<CGFloat>

    @State private var hovering = false

    var body: some View {
        Menu {
            Text("PiP window size")
            Divider()
            Button("50%") { zoomLevel.wrappedValue = 0.5 }
            Button("75%") { zoomLevel.wrappedValue = 0.75 }
            Button("100%") { zoomLevel.wrappedValue = 1.0 }
            Button("150%") { zoomLevel.wrappedValue = 1.5 }
            Button("200%") { zoomLevel.wrappedValue = 2.0 }
        } label: {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(hovering ? Theme.primaryAlpha : Theme.secondaryAlpha))
                .frame(width: 28, height: 28)
                .background(Circle().fill(.white.opacity(hovering ? 0.10 : 0)))
                .contentShape(Circle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help("Size — scale this PiP window (the capture is unchanged)")
        .accessibilityLabel("PiP size")
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

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "cursorarrow.slash")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white.opacity(hovering ? 1.0 : 0.85))
                .frame(width: 34, height: 34)
                .background(
                    Circle()
                        .fill(.black.opacity(0.55))
                        .overlay(Circle().strokeBorder(
                            .white.opacity(hovering ? 0.55 : 0.30), lineWidth: 1
                        ))
                )
                .contentShape(Circle())
        }
        .buttonStyle(PressableStyle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help("Leave Ghost Mode (\(HoverControlsView.ghostShortcutLabel))")
        .accessibilityLabel("Leave Ghost Mode")
    }
}

// MARK: - VisualEffectBlur

/// NSVisualEffectView wrapper for SwiftUI.
///
/// SwiftUI doesn't natively expose NSVisualEffectView, so we bridge it via
/// NSViewRepresentable. This gives us access to macOS vibrancy materials
/// (e.g. `.hudWindow`, `.fullScreenUI`) for native-looking translucent
/// backgrounds.
struct VisualEffectBlur: NSViewRepresentable {

    /// The material type determines the appearance and blur radius.
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
